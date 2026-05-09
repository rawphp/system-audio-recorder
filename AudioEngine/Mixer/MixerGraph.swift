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
/// [source stream 1] ─┐                                ┌── [src 1 tap]
/// [source stream 2] ─┤── gain scale ── per-source FIFO┤── [src 2 tap]
/// [source stream N] ─┘                                └── [src N tap]
///                              │
///                              ▼
///                       (mix loop: pulls equal-size chunks
///                        from every active source's FIFO,
///                        sums element-wise, yields one
///                        sample-aligned buffer per tick)
///                              │
///                              ▼
///                        [mix bus stream]
/// ```
///
/// Each source `AsyncStream` is consumed by a dedicated `Task`. Incoming
/// buffers are gain-scaled and yielded to the per-source tap immediately, then
/// pushed into a per-source FIFO. A single mix-loop thread drains equal-sized
/// chunks from every active source's FIFO and sums them into one mix buffer
/// per tick, so the mix bus rate equals the slowest source's rate — never the
/// concatenation of all sources.
///
/// Thread-safety: all mutable state is guarded by `NSCondition` (which doubles
/// as the wake-up channel for the mix loop).
public final class MixerGraph {

    // MARK: - Mix tick configuration

    /// Frames per mix tick. 480 frames @ 48 kHz = 10 ms — matches the natural
    /// granularity of Core Audio process-tap buffers and the in-tree test
    /// helpers.
    private static let mixFrameCount = 480

    private static let mixFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Private types

    private struct SourceRecord {
        let task: Task<Void, Never>
        var gain: Float   // 0.0 – 2.0; default 1.0
    }

    /// Per-source FIFO of incoming buffers awaiting consumption by the mix loop.
    private struct Pending {
        var buffers: [AVAudioPCMBuffer] = []
        /// Read offset (in frames) into `buffers[0]`.
        var headOffset: Int = 0
        /// Sum of un-consumed frames across all `buffers`.
        var availableFrames: Int = 0
        /// `true` once the upstream `AsyncStream` has finished — once the
        /// remaining frames are below one tick, the source is dropped.
        var streamFinished: Bool = false
    }

    // MARK: - Private state

    /// Guards every piece of mutable state below AND signals the mix loop
    /// whenever sources are added, removed, finished, or have new buffers.
    private let condition = NSCondition()

    /// Per-source metadata: task + gain.
    private var records: [String: SourceRecord] = [:]

    /// Per-source AsyncStream tap (read ends kept here for consumers).
    private var sourceReadStreams: [String: AsyncStream<AVAudioPCMBuffer>] = [:]

    /// Per-source AsyncStream tap continuations (write ends — used to close them on removal).
    private var sourceWriteConts: [String: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]

    /// Per-source FIFO awaiting consumption by the mix loop.
    private var pending: [String: Pending] = [:]

    /// The mix-bus write end. The mix loop yields one summed buffer per tick.
    private var mixWriteCont: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// The mix-bus read end. Returned to callers of `mixBufferStream()`.
    private let mixReadStream: AsyncStream<AVAudioPCMBuffer>

    private var stopped = false

    /// Dedicated worker queue for the blocking mix loop. Must not be a
    /// cooperative-pool thread — the loop blocks on `NSCondition.wait()`.
    private let mixQueue = DispatchQueue(
        label: "com.tomkaczocha.MixerGraph.mixLoop",
        qos: .userInitiated
    )

    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "MixerGraph"
    )

    // MARK: - Initialisation

    public init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        mixReadStream = AsyncStream<AVAudioPCMBuffer> { cont = $0 }
        mixWriteCont = cont

        mixQueue.async { [weak self] in
            self?.runMixLoop()
        }
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
        condition.lock()
        guard !stopped else { condition.unlock(); throw MixerError.stopped }
        guard records[id] == nil else { condition.unlock(); throw MixerError.duplicateSourceID(id) }

        // Build the per-source tap stream.
        var srcWriteCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let srcReadStream = AsyncStream<AVAudioPCMBuffer> { srcWriteCont = $0 }

        // Reserve a slot in the FIFO for the mix loop.
        pending[id] = Pending()

        condition.unlock()

        // Launch a task that consumes the upstream stream.
        let task = Task { [weak self] in
            guard let self else { return }
            for await buffer in stream {
                let g = self.currentGain(for: id)
                let scaled = self.scale(buffer: buffer, by: g)

                // Per-source tap: yield the gain-scaled buffer immediately.
                srcWriteCont.yield(scaled)

                // Push into the FIFO so the mix loop can drain it.
                self.condition.lock()
                if var p = self.pending[id] {
                    p.buffers.append(scaled)
                    p.availableFrames += Int(scaled.frameLength)
                    self.pending[id] = p
                }
                self.condition.broadcast()
                self.condition.unlock()
            }

            // Upstream finished — flag the FIFO so the mix loop drains the tail
            // and drops the source. Then unregister via removeSource so callers
            // see consistent state.
            self.condition.lock()
            if var p = self.pending[id] {
                p.streamFinished = true
                self.pending[id] = p
            }
            self.condition.broadcast()
            self.condition.unlock()

            self.log.info("MixerGraph: source '\(id)' stream terminated; removing.")
            self.removeSource(id: id)
        }

        condition.lock()
        // Double-check we didn't race (stop() could have been called between unlocks).
        guard !stopped else {
            pending.removeValue(forKey: id)
            condition.unlock()
            task.cancel()
            srcWriteCont.finish()
            return
        }
        records[id] = SourceRecord(task: task, gain: 1.0)
        sourceReadStreams[id] = srcReadStream
        sourceWriteConts[id] = srcWriteCont
        condition.broadcast()
        condition.unlock()
    }

    /// Sets the gain for a registered source. Value is clamped to [0.0, 2.0].
    /// No-op if `id` is not registered.
    public func setGain(forSource id: String, gain: Float) {
        condition.lock()
        defer { condition.unlock() }
        records[id]?.gain = max(0.0, min(2.0, gain))
    }

    /// Returns the shared mix-bus stream. The mix loop yields one
    /// sample-aligned, summed buffer per tick.
    public func mixBufferStream() -> AsyncStream<AVAudioPCMBuffer> {
        mixReadStream
    }

    /// Returns the per-source post-gain tap stream for `id`.
    /// If `id` is unknown returns an immediately-finishing empty stream.
    public func sourceBufferStream(forSource id: String) -> AsyncStream<AVAudioPCMBuffer> {
        condition.lock()
        defer { condition.unlock() }
        return sourceReadStreams[id] ?? AsyncStream { $0.finish() }
    }

    /// Removes a source, cancels its consumer task, and closes its tap stream.
    /// Idempotent — safe to call for an unknown ID.
    public func removeSource(id: String) {
        condition.lock()
        let record = records.removeValue(forKey: id)
        let cont   = sourceWriteConts.removeValue(forKey: id)
        sourceReadStreams.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        condition.broadcast()
        condition.unlock()

        record?.task.cancel()
        cont?.finish()
    }

    /// Stops the mixer: cancels all source tasks and closes all streams.
    /// Idempotent.
    public func stop() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        stopped = true

        let allRecords = records
        let allConts   = sourceWriteConts
        let mc         = mixWriteCont

        records.removeAll()
        sourceWriteConts.removeAll()
        sourceReadStreams.removeAll()
        pending.removeAll()
        mixWriteCont = nil

        condition.broadcast()
        condition.unlock()

        for (_, rec) in allRecords { rec.task.cancel() }
        for (_, cont) in allConts  { cont.finish() }
        mc?.finish()
    }

    // MARK: - Mix loop

    /// Blocking loop that runs on `mixQueue` for the mixer's lifetime. Each
    /// iteration waits until every active source has at least one tick of
    /// data buffered (or has finished), pulls one tick from each, sums them
    /// element-wise, and yields the result on the mix bus.
    private func runMixLoop() {
        let frameCount = Self.mixFrameCount
        let format     = Self.mixFormat
        let channels   = Int(format.channelCount)

        while true {
            // Resolve next mix decision under the lock.
            let decision = waitForNextTick(frameCount: frameCount)

            switch decision {
            case .stopped:
                return

            case .emit(let chunks, let mixCont):
                // Build a zero-initialised mix buffer.
                guard let mixBuf = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else { continue }
                mixBuf.frameLength = AVAudioFrameCount(frameCount)
                for ch in 0..<channels {
                    if let dst = mixBuf.floatChannelData?[ch] {
                        memset(dst, 0, frameCount * MemoryLayout<Float>.size)
                    }
                }

                // Sum each source's chunk into the mix.
                for chunk in chunks {
                    for ch in 0..<channels {
                        guard let dst = mixBuf.floatChannelData?[ch],
                              ch < chunk.count else { continue }
                        let src = chunk[ch]
                        for i in 0..<frameCount {
                            dst[i] += src[i]
                        }
                    }
                }

                mixCont.yield(mixBuf)
            }
        }
    }

    /// Outcome of a single mix-loop wait.
    private enum MixDecision {
        case stopped
        case emit(chunks: [[[Float]]], mixCont: AsyncStream<AVAudioPCMBuffer>.Continuation)
    }

    /// Waits until at least one full tick is available from every active
    /// source (or every active source has finished and been drained), then
    /// pulls one tick from each. If the only sources left are finished and
    /// have less than one tick remaining, they are dropped without emitting.
    private func waitForNextTick(frameCount: Int) -> MixDecision {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if stopped { return .stopped }

            // Drop any finished sources with too little data to emit.
            for id in pending.keys {
                if let p = pending[id], p.streamFinished, p.availableFrames < frameCount {
                    pending.removeValue(forKey: id)
                }
            }

            // No sources at all → wait for something to happen (new source
            // added, or stop()).
            if pending.isEmpty {
                condition.wait()
                continue
            }

            // If every active source has at least a tick, pull and return.
            let allReady = pending.values.allSatisfy { $0.availableFrames >= frameCount }
            if allReady {
                var chunks: [[[Float]]] = []
                chunks.reserveCapacity(pending.count)
                for id in pending.keys {
                    guard var p = pending[id] else { continue }
                    let chunk = pullChunk(from: &p, frameCount: frameCount)
                    pending[id] = p
                    chunks.append(chunk)
                }
                guard let cont = mixWriteCont else { return .stopped }
                return .emit(chunks: chunks, mixCont: cont)
            }

            // Some source is short — wait for more data.
            condition.wait()
        }
    }

    /// Pulls `frameCount` frames out of `p`, advancing the read cursor and
    /// dropping fully-consumed buffers. Returns `[left, right]` channel arrays
    /// of length `frameCount`. Caller must hold `condition.lock()`.
    private func pullChunk(from p: inout Pending, frameCount: Int) -> [[Float]] {
        var left  = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var written = 0

        while written < frameCount && !p.buffers.isEmpty {
            let buf = p.buffers[0]
            let bufLen = Int(buf.frameLength)
            let avail  = bufLen - p.headOffset
            let toCopy = min(avail, frameCount - written)
            guard toCopy > 0 else {
                p.buffers.removeFirst()
                p.headOffset = 0
                continue
            }

            if let lp = buf.floatChannelData?[0] {
                for i in 0..<toCopy { left[written + i] = lp[p.headOffset + i] }
            }
            let isStereo = buf.format.channelCount >= 2
            let rp = isStereo ? buf.floatChannelData?[1] : buf.floatChannelData?[0]
            if let rp = rp {
                for i in 0..<toCopy { right[written + i] = rp[p.headOffset + i] }
            }

            written += toCopy
            p.headOffset += toCopy
            p.availableFrames -= toCopy

            if p.headOffset >= bufLen {
                p.buffers.removeFirst()
                p.headOffset = 0
            }
        }

        return [left, right]
    }

    // MARK: - Private helpers

    private func currentGain(for id: String) -> Float {
        condition.lock()
        defer { condition.unlock() }
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
