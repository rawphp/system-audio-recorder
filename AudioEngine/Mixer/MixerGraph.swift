import AVFoundation
import os.log

// MARK: - MixerError

/// Errors thrown by `MixerGraph`.
public enum MixerError: Error, Equatable {
    /// A source with this ID has already been registered.
    case duplicateSourceID(String)
    /// `addSource` was called after the mixer was stopped.
    case stopped
}

// MARK: - MixerGraph

/// Coordinates per-source gain, the mix bus, and separate-output taps.
///
/// **Graph model** (spec Section 5.3):
/// ```
/// [source stream 1] ─┐
/// [source stream 2] ─┤── gain scale ── per-source tap ─┐
/// [source stream N] ─┘                                  │
///                                                        ▼
///                                                  [mix bus stream]
/// ```
///
/// Each source `AsyncStream` is consumed by a dedicated `Task`. Incoming buffers
/// are gain-scaled and then yielded to both the per-source tap stream and the
/// shared mix-bus stream.
///
/// Thread-safety: all mutable state is guarded by `NSLock`.
public final class MixerGraph {

    // MARK: - Private types

    private struct SourceRecord {
        let task: Task<Void, Never>
        var gain: Float   // 0.0 – 2.0; default 1.0
    }

    // MARK: - Private state

    private let lock = NSLock()

    /// Per-source metadata: task + gain.
    private var records: [String: SourceRecord] = [:]

    /// Per-source AsyncStream tap (read ends kept here for consumers).
    private var sourceReadStreams: [String: AsyncStream<AVAudioPCMBuffer>] = [:]

    /// Per-source AsyncStream tap continuations (write ends — used to close them on removal).
    private var sourceWriteConts: [String: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]

    /// The mix-bus write end. All gain-scaled source buffers are yielded here.
    private var mixWriteCont: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// The mix-bus read end. Returned to callers of `mixBufferStream()`.
    private let mixReadStream: AsyncStream<AVAudioPCMBuffer>

    private var stopped = false

    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "MixerGraph"
    )

    // MARK: - Initialisation

    public init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        mixReadStream = AsyncStream<AVAudioPCMBuffer> { cont = $0 }
        mixWriteCont = cont
    }

    // MARK: - Public API

    /// Registers a new normalized source stream.
    ///
    /// - Parameters:
    ///   - id:     Unique string key for this source.
    ///   - stream: Canonical-format (48 kHz Float32 stereo) `AsyncStream`.
    /// - Throws:
    ///   - `MixerError.duplicateSourceID(id)` if `id` is already registered.
    ///   - `MixerError.stopped` if the mixer has been stopped.
    public func addSource(id: String, stream: AsyncStream<AVAudioPCMBuffer>) throws {
        lock.lock()
        guard !stopped else { lock.unlock(); throw MixerError.stopped }
        guard records[id] == nil else { lock.unlock(); throw MixerError.duplicateSourceID(id) }

        // Build the per-source tap stream.
        var srcWriteCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let srcReadStream = AsyncStream<AVAudioPCMBuffer> { srcWriteCont = $0 }

        // Capture the current mix-bus write end (safe: lock held).
        let mixCont = mixWriteCont

        // Release lock before starting the Task to avoid priority inversion.
        lock.unlock()

        // Launch a task that consumes the upstream stream.
        let task = Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                let g = self.currentGain(for: id)
                let scaled = self.scale(buffer: buffer, by: g)
                srcWriteCont.yield(scaled)
                mixCont?.yield(scaled)
            }
            // Upstream stream finished — log and remove this source.
            self.log.info("MixerGraph: source '\(id)' stream terminated; removing.")
            self.removeSource(id: id)
        }

        lock.lock()
        // Double-check we didn't race (stop() could have been called between unlocks).
        guard !stopped else {
            lock.unlock()
            task.cancel()
            srcWriteCont.finish()
            return
        }
        records[id] = SourceRecord(task: task, gain: 1.0)
        sourceReadStreams[id] = srcReadStream
        sourceWriteConts[id] = srcWriteCont
        lock.unlock()
    }

    /// Sets the gain for a registered source. Value is clamped to [0.0, 2.0].
    /// No-op if `id` is not registered.
    public func setGain(forSource id: String, gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        records[id]?.gain = max(0.0, min(2.0, gain))
    }

    /// Returns the shared mix-bus stream. All gain-scaled buffers from all
    /// sources are delivered here.
    public func mixBufferStream() -> AsyncStream<AVAudioPCMBuffer> {
        mixReadStream
    }

    /// Returns the per-source post-gain tap stream for `id`.
    /// If `id` is unknown returns an immediately-finishing empty stream.
    public func sourceBufferStream(forSource id: String) -> AsyncStream<AVAudioPCMBuffer> {
        lock.lock()
        defer { lock.unlock() }
        return sourceReadStreams[id] ?? AsyncStream { $0.finish() }
    }

    /// Removes a source, cancels its consumer task, and closes its tap stream.
    /// Idempotent — safe to call for an unknown ID.
    public func removeSource(id: String) {
        lock.lock()
        let record = records.removeValue(forKey: id)
        let cont   = sourceWriteConts.removeValue(forKey: id)
        sourceReadStreams.removeValue(forKey: id)
        lock.unlock()

        record?.task.cancel()
        cont?.finish()
    }

    /// Stops the mixer: cancels all source tasks and closes all streams.
    /// Idempotent.
    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true

        let allRecords = records
        let allConts   = sourceWriteConts
        let mc         = mixWriteCont

        records.removeAll()
        sourceWriteConts.removeAll()
        sourceReadStreams.removeAll()
        mixWriteCont = nil

        lock.unlock()

        for (_, rec) in allRecords { rec.task.cancel() }
        for (_, cont) in allConts  { cont.finish() }
        mc?.finish()
    }

    // MARK: - Private helpers

    private func currentGain(for id: String) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return records[id]?.gain ?? 1.0
    }

    /// Returns a new buffer with every sample multiplied by `gain`.
    /// If `gain == 1.0` the original buffer is returned directly (zero-copy).
    private func scale(buffer: AVAudioPCMBuffer, by gain: Float) -> AVAudioPCMBuffer {
        guard gain != 1.0 else { return buffer }
        guard let out = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity
        ) else { return buffer }
        out.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        let frameLength  = Int(buffer.frameLength)
        for ch in 0..<channelCount {
            guard let src = buffer.floatChannelData?[ch],
                  let dst = out.floatChannelData?[ch] else { continue }
            for i in 0..<frameLength {
                dst[i] = src[i] * gain
            }
        }
        return out
    }
}
