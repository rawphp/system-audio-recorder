import AVFoundation
import Accelerate
@testable import SystemAudioRecorder

// MARK: - AudioBufferEmitter typealias
//
// REQ-035: `AudioBufferEmitter` is the test-facing alias for `RecordingSourceEmitter`.
//
// Note: `AudioBufferEmitter` in `ProcessTapCapture.swift` refers to the per-*process-tap*
// capture contract (with `streams: [pid_t: AsyncStream]`).  That is a different
// abstraction level.  The per-*source* single-stream contract that `RecordingSession`
// consumes is `RecordingSourceEmitter`.  AC#1 is already satisfied: `RecordingSession`
// references only `RecordingSourceEmitter`; it has no direct import of `ProcessTapCapture`
// or `MicrophoneCapture`.
//
// For REQ-035 the alias below gives test code the canonical `AudioBufferEmitter` name
// without touching any production file.
typealias AudioBufferEmitter = RecordingSourceEmitter

// MARK: - MockAudioSource Presets

/// Synthetic audio preset for `MockAudioSource`.
public enum MockAudioPreset {
    /// Pure sine wave at the given frequency (Hz) and linear amplitude.
    case sine(frequency: Double, level: Float)
    /// White noise at the given linear amplitude.
    case whiteNoise(level: Float)
    /// Digital silence (all samples == 0.0).
    case silence
    /// Playback from an audio file at the given URL.
    ///
    /// `MockAudioSource` reads the file once and loops its samples. If the file
    /// cannot be opened the source falls back to `.silence`.
    case file(URL)
}

// MARK: - MockAudioSource

/// A test-only `RecordingSourceEmitter` that generates PCM buffers without
/// opening any real audio device.
///
/// Buffers are emitted as fast as the consumer requests them (i.e. there is no
/// wall-clock pacing). Each `AVAudioPCMBuffer` contains `framesPerBuffer` frames
/// at `sampleRate` Hz, non-interleaved Float32, stereo.
///
/// **Usage**
/// ```swift
/// let src = MockAudioSource(id: "test", preset: .sine(frequency: 440, level: 0.5))
/// try await session.start(config: makeConfig(sources: [("test", src)]))
/// ```
///
/// **No real audio device opened.** `MockAudioSource` uses only `vDSP` for
/// waveform synthesis and `AVAudioFile` for file playback. It never instantiates
/// `AVAudioEngine` for capture; `AVAudioEngine` is exercised only by REQ-007 /
/// REQ-008 via their own injection seams, not by `RecordingSession` when the
/// sources are `MockAudioSource` instances.
public final class MockAudioSource: RecordingSourceEmitter, @unchecked Sendable {

    // MARK: - Protocol conformance

    public let id: String
    public let stream: AsyncStream<AVAudioPCMBuffer>

    // MARK: - Configuration

    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let framesPerBuffer: AVAudioFrameCount

    // MARK: - Private state

    private let lock = NSLock()
    private var _preset: MockAudioPreset
    private var _stopped = false
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    /// Phase accumulator for the sine generator (radians). Per-channel but both
    /// are kept in sync (same frequency, same phase → identical L/R).
    private var sinePhase: Double = 0.0

    /// Samples loaded from file (mono mix; duplicated to stereo on emit).
    private var fileSamples: [Float] = []
    private var fileReadHead: Int = 0

    // MARK: - Init

    /// Creates a `MockAudioSource` with the given preset.
    ///
    /// - Parameters:
    ///   - id:             Stable identifier (used for WAV file naming).
    ///   - preset:         Initial audio preset.
    ///   - sampleRate:     Output sample rate (default: 48 000 Hz).
    ///   - channelCount:   Number of output channels (default: 2, stereo).
    ///   - framesPerBuffer: Frame count per emitted buffer (default: 480 ≈ 10 ms).
    public init(
        id: String,
        preset: MockAudioPreset,
        sampleRate: Double = 48_000,
        channelCount: AVAudioChannelCount = 2,
        framesPerBuffer: AVAudioFrameCount = 480
    ) {
        self.id = id
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.framesPerBuffer = framesPerBuffer
        self._preset = preset

        // Establish stream/continuation before any method captures self.
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont

        // Load file samples if the initial preset is .file.
        if case .file(let url) = preset {
            self.fileSamples = Self.loadFileSamples(url: url, sampleRate: sampleRate)
        }
    }

    // MARK: - Protocol: stop

    public func stop() {
        lock.lock()
        let alreadyStopped = _stopped
        _stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        continuation.finish()
    }

    // MARK: - Preset switching

    /// Switches the active preset mid-stream. The change takes effect on the
    /// next emitted buffer. Thread-safe.
    public func setPreset(_ preset: MockAudioPreset) {
        lock.lock()
        defer { lock.unlock() }
        _preset = preset
        // Reload file samples if switching to .file.
        if case .file(let url) = preset {
            fileSamples = Self.loadFileSamples(url: url, sampleRate: sampleRate)
            fileReadHead = 0
        }
        // Reset sine phase on any preset switch so the transition is clean.
        sinePhase = 0.0
    }

    // MARK: - Buffer emission

    /// Generates and yields one buffer. Call this in a loop to drive the stream.
    ///
    /// Returns `false` when `stop()` has been called (caller should cease looping).
    @discardableResult
    public func emit() -> Bool {
        lock.lock()
        if _stopped { lock.unlock(); return false }
        let preset = _preset
        lock.unlock()

        guard let buf = makeBuffer(preset: preset) else { return false }
        continuation.yield(buf)
        return true
    }

    /// Drives the source in a detached background task, emitting up to `count`
    /// buffers and then stopping. Useful for self-contained test helpers.
    ///
    /// - Parameters:
    ///   - count:       Maximum number of buffers to emit.
    ///   - delayNanos:  Nanoseconds between buffers (default: 0 — burst mode).
    public func driveAsync(count: Int, delayNanos: UInt64 = 0) {
        Task.detached { [weak self] in
            for _ in 0..<count {
                guard let self else { return }
                guard self.emit() else { return }
                if delayNanos > 0 {
                    try? await Task.sleep(nanoseconds: delayNanos)
                }
            }
            self?.stop()
        }
    }

    // MARK: - Buffer synthesis

    private func makeBuffer(preset: MockAudioPreset) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer) else {
            return nil
        }
        buf.frameLength = framesPerBuffer

        switch preset {
        case .sine(let freq, let level):
            fillSine(buf: buf, frequency: freq, level: level)
        case .whiteNoise(let level):
            fillWhiteNoise(buf: buf, level: level)
        case .silence:
            fillSilence(buf: buf)
        case .file:
            fillFromFile(buf: buf)
        }

        return buf
    }

    // MARK: - Waveform generators

    private func fillSine(buf: AVAudioPCMBuffer, frequency: Double, level: Float) {
        let n = Int(buf.frameLength)
        let phaseStep = 2.0 * Double.pi * frequency / sampleRate
        let amp = level

        for ch in 0..<Int(channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            var phase = sinePhase
            for i in 0..<n {
                ptr[i] = amp * Float(sin(phase))
                phase += phaseStep
            }
            // Only advance sinePhase once (all channels are in phase).
            if ch == 0 { sinePhase = phase }
        }
        // Wrap phase to [0, 2π) to prevent precision loss over long runs.
        sinePhase = sinePhase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
    }

    private func fillWhiteNoise(buf: AVAudioPCMBuffer, level: Float) {
        let n = Int(buf.frameLength)
        for ch in 0..<Int(channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<n {
                ptr[i] = level * Float.random(in: -1.0...1.0)
            }
        }
    }

    private func fillSilence(buf: AVAudioPCMBuffer) {
        let n = Int(buf.frameLength)
        for ch in 0..<Int(channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<n { ptr[i] = 0.0 }
        }
    }

    private func fillFromFile(buf: AVAudioPCMBuffer) {
        guard !fileSamples.isEmpty else {
            fillSilence(buf: buf)
            return
        }
        let n = Int(buf.frameLength)
        let total = fileSamples.count
        for ch in 0..<Int(channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<n {
                ptr[i] = fileSamples[(fileReadHead + i) % total]
            }
        }
        fileReadHead = (fileReadHead + n) % total
    }

    // MARK: - File loading

    /// Loads all samples from a file, mixing to mono at the target sample rate.
    /// Returns an empty array if the file cannot be opened.
    private static func loadFileSamples(url: URL, sampleRate: Double) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            return []
        }
        // Read via AVAudioConverter for sample-rate + channel conversion.
        let srcFormat = audioFile.processingFormat
        guard let converter = AVAudioConverter(from: srcFormat, to: monoFormat),
              let srcBuf = AVAudioPCMBuffer(
                pcmFormat: srcFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
              ),
              (try? audioFile.read(into: srcBuf)) != nil else {
            return []
        }
        var error: NSError?
        let status = converter.convert(to: buf, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuf
        }
        guard status != .error, let ptr = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
    }
}

// MARK: - Convenience factory methods

public extension MockAudioSource {

    /// 440 Hz sine, -12 dBFS (linear ≈ 0.2512).
    static func defaultSine(id: String = "mock-sine") -> MockAudioSource {
        let levelLinear = Float(pow(10.0, -12.0 / 20.0))
        return MockAudioSource(id: id, preset: .sine(frequency: 440, level: levelLinear))
    }

    /// White noise, -20 dBFS (linear ≈ 0.1).
    static func defaultNoise(id: String = "mock-noise") -> MockAudioSource {
        let levelLinear = Float(pow(10.0, -20.0 / 20.0))
        return MockAudioSource(id: id, preset: .whiteNoise(level: levelLinear))
    }

    /// Digital silence (all zeros).
    static func defaultSilence(id: String = "mock-silence") -> MockAudioSource {
        MockAudioSource(id: id, preset: .silence)
    }
}
