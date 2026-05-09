import AVFoundation
import Foundation
import os.log

// MARK: - RecordingSourceEmitter

/// Public capture-source contract consumed by `RecordingSession`.
///
/// A `RecordingSourceEmitter` produces an `AsyncStream<AVAudioPCMBuffer>` of
/// raw (un-normalized) PCM buffers and can be `stop()`'d.
///
/// REQ-007 `ProcessTapCapture` and REQ-008 `MicrophoneCapture` both produce
/// such streams; this REQ adds tiny adapter wrappers (see `Adapters`) so they
/// conform without the archived files being modified.
///
/// REQ-035 will later move/formalize this protocol.
public protocol RecordingSourceEmitter: AnyObject {
    /// Stable identifier used in mixer + WAV file naming.
    var id: String { get }
    /// PCM buffer stream. May be at any sample rate / channel layout — the
    /// session normalizes to 48 kHz Float32 stereo via `FormatNormalizer`.
    var stream: AsyncStream<AVAudioPCMBuffer> { get }
    /// Tear down underlying capture resources. Idempotent.
    func stop()
}

// MARK: - SessionConfig

/// Configuration handed to `RecordingSession.start(config:)`.
public struct SessionConfig: Sendable {

    public enum OutputMode: Sendable {
        case mixed
        case separate
    }

    public struct Source: @unchecked Sendable {
        public let id: String
        public let emitter: RecordingSourceEmitter
        public init(id: String, emitter: RecordingSourceEmitter) {
            self.id = id
            self.emitter = emitter
        }
    }

    public let sources: [Source]
    public let outputMode: OutputMode
    public let outputFolder: URL
    public let timestamp: String
    /// When set, `RecordingSession` schedules a `DispatchSourceTimer` that fires
    /// after this many seconds of *active* recording time and calls `stop()`.
    /// Pausing cancels the timer; resuming reschedules with the remaining time.
    /// `nil` (default) means no timer is created. (REQ-021 will later wire this
    /// from `UserDefaults`; for now it lives only in `SessionConfig`.)
    public let autoStopDuration: TimeInterval?

    public init(
        sources: [Source],
        outputMode: OutputMode,
        outputFolder: URL,
        timestamp: String,
        autoStopDuration: TimeInterval? = nil
    ) {
        self.sources = sources
        self.outputMode = outputMode
        self.outputFolder = outputFolder
        self.timestamp = timestamp
        self.autoStopDuration = autoStopDuration
    }
}

// MARK: - SessionState

public enum SessionState: Equatable, Sendable {
    case idle
    case recording
    case paused
    case stopped
    case failed
}

// MARK: - SessionError

public enum SessionError: Error, Equatable {
    /// `start(config:)` was called with an empty source list.
    case noSourcesConfigured
    /// A lifecycle method was called from an invalid state.
    case invalidTransition(from: SessionState, to: SessionState)
    /// Underlying writer / mixer / capture failed to start.
    case startFailed(String)
}

// MARK: - RecordingSession

/// The single object the UI talks to in order to make a recording.
///
/// Owns:
/// - One `RecordingSourceEmitter` per chosen source (REQ-007 / REQ-008)
/// - Per-source `FormatNormalizer` (REQ-009)
/// - `MixerGraph` (REQ-010)
/// - `WAVWriter` (REQ-012)
///
/// State machine (`SessionState`):
/// ```
///  idle ──start──▶ recording ──pause──▶ paused ──resume──▶ recording
///                       │                                       │
///                       └────────────── stop ───────────────────▼
///                                                            stopped
///                       (any)                                  failed
/// ```
///
/// Public lifecycle methods are all `async` and serialised by the actor; safe
/// to call from any thread including the main thread.
///
/// **REQ-033 hand-off:** `errorStream` exposes any non-fatal capture errors
/// observed during the session. REQ-033 will subscribe to it.
public actor RecordingSession {

    // MARK: - State

    public private(set) var state: SessionState = .idle

    // MARK: - Owned components

    private var writer: WAVWriter?
    private var mixer: MixerGraph?
    private var sources: [SessionConfig.Source] = []

    /// Per-source normalization tasks: one task per source consumes raw buffers
    /// from the emitter, runs them through a per-source `FormatNormalizer`, and
    /// yields canonical buffers into the mixer's source stream.
    private var normalizationTasks: [Task<Void, Never>] = []

    /// The writer task — drains the mixer outputs into WAV files.
    private var writerTask: Task<[URL], Error>?

    /// URLs returned by the last completed `stop()`. Cached so repeat calls are idempotent.
    private var lastURLs: [URL] = []

    // MARK: - Auto-stop timer (REQ-014)

    /// The total configured auto-stop duration (nil = no auto-stop).
    private var autoStopDuration: TimeInterval?
    /// The remaining recording time when the timer was last armed.
    private var autoStopRemaining: TimeInterval = 0
    /// The wall-clock date when the current recording segment started (nil = paused/stopped).
    private var recordingSegmentStart: Date?
    /// The live `DispatchSourceTimer`. Cancelled on pause / stop.
    private var autoStopTimer: DispatchSourceProtocol?

    // MARK: - Error stream (REQ-033 hand-off)

    public nonisolated let errorStream: AsyncStream<Error>
    private let errorContinuation: AsyncStream<Error>.Continuation

    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "RecordingSession"
    )

    // MARK: - Init

    public init() {
        var c: AsyncStream<Error>.Continuation!
        self.errorStream = AsyncStream<Error> { c = $0 }
        self.errorContinuation = c
    }

    // MARK: - Lifecycle: start

    /// Starts a recording session.
    ///
    /// - Throws:
    ///   - `SessionError.noSourcesConfigured` if `config.sources` is empty.
    ///   - `SessionError.invalidTransition` if the session is not idle.
    ///   - `SessionError.startFailed` if the writer / mixer cannot be wired up.
    public func start(config: SessionConfig) async throws {
        guard state == .idle else {
            throw SessionError.invalidTransition(from: state, to: .recording)
        }
        guard !config.sources.isEmpty else {
            throw SessionError.noSourcesConfigured
        }

        let mixer = MixerGraph()
        let writer = WAVWriter(outputFolder: config.outputFolder, timestamp: config.timestamp)

        // Wire each source: emitter.stream → FormatNormalizer → mixer.addSource.
        for source in config.sources {
            // Build the canonical stream that the mixer will consume.
            var canonCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
            let canonStream = AsyncStream<AVAudioPCMBuffer> { canonCont = $0 }

            // Register with mixer first — surfaces duplicate-id errors early.
            do {
                try mixer.addSource(id: source.id, stream: canonStream)
            } catch {
                // Roll back: stop already-started emitters and the mixer.
                mixer.stop()
                throw SessionError.startFailed("mixer addSource failed for '\(source.id)': \(error)")
            }

            // Spin up the normalization task for this source.
            let normalizer = FormatNormalizer()
            let emitter = source.emitter
            let id = source.id
            let cont = canonCont!
            let errCont = self.errorContinuation
            let logger = self.log
            let task = Task.detached { [weak self] in
                for await raw in emitter.stream {
                    do {
                        let normalized = try normalizer.normalize(raw)
                        for buf in normalized {
                            cont.yield(buf)
                        }
                    } catch {
                        logger.error("RecordingSession: normalize failed for '\(id)': \(error.localizedDescription)")
                        errCont.yield(error)
                        await self?.handleSourceFailure(id: id, error: error)
                        break
                    }
                }
                cont.finish()
            }
            normalizationTasks.append(task)
        }

        // Snapshot for stop() teardown.
        self.mixer = mixer
        self.writer = writer
        self.sources = config.sources

        // Launch the writer task. It drains either the mix stream (mixed mode)
        // or the per-source streams + mix (separate mode) into WAV files.
        let mode = config.outputMode
        let mixStream = mixer.mixBufferStream()
        let perSourceStreams: [(String, AsyncStream<AVAudioPCMBuffer>)] = config.sources.map { src in
            (src.id, mixer.sourceBufferStream(forSource: src.id))
        }
        let errCont = self.errorContinuation
        let logger = self.log

        writerTask = Task.detached {
            do {
                switch mode {
                case .mixed:
                    return try await writer.runMixed(stream: mixStream)
                case .separate:
                    return try await writer.runSeparate(
                        sources: perSourceStreams,
                        mixStream: mixStream
                    )
                }
            } catch {
                logger.error("RecordingSession: writer failed: \(error.localizedDescription)")
                errCont.yield(error)
                throw error
            }
        }

        state = .recording

        // Arm the auto-stop timer if configured.
        if let duration = config.autoStopDuration {
            autoStopDuration = duration
            autoStopRemaining = duration
            armAutoStopTimer(remaining: duration)
        }
    }

    // MARK: - Lifecycle: pause

    /// Freezes WAV cursor; meters stop updating. Mixer + emitters keep running
    /// (buffers in flight are dropped by `WAVWriter` while paused).
    public func pause() async throws {
        guard state == .recording else {
            throw SessionError.invalidTransition(from: state, to: .paused)
        }
        // Cancel timer before state change; subtract elapsed segment time.
        cancelAutoStopTimer()
        await writer?.pause()
        state = .paused
    }

    // MARK: - Lifecycle: resume

    /// Resumes WAV writes. The resulting file has no silent gap (per REQ-012).
    public func resume() async throws {
        guard state == .paused else {
            throw SessionError.invalidTransition(from: state, to: .recording)
        }
        await writer?.resume()
        state = .recording
        // Re-arm timer with the remaining recording time.
        if autoStopDuration != nil {
            armAutoStopTimer(remaining: autoStopRemaining)
        }
    }

    // MARK: - Lifecycle: stop

    /// Stops every emitter, the mixer, the normalizers, and finalizes WAV files.
    /// Returns the file URLs ready for the encoding handoff (REQ-018).
    /// Idempotent.
    public func stop() async -> [URL] {
        // Always allow stop; mark stopped immediately so no further transitions race.
        let priorState = state
        guard priorState != .stopped else { return lastURLs }

        state = .stopped

        // Cancel auto-stop timer immediately (prevents double-stop from the timer).
        cancelAutoStopTimer()

        // 1) Stop emitters first so their AsyncStreams finish.
        for src in sources { src.emitter.stop() }

        // 2) Wait for normalization tasks to drain.
        for task in normalizationTasks {
            _ = await task.value
        }
        normalizationTasks.removeAll()

        // 3) Stop the mixer; this closes the mix + source streams the writer is on.
        mixer?.stop()

        // 4) Wait for the writer task to finish and collect URLs.
        var urls: [URL] = []
        if let wt = writerTask {
            do {
                urls = try await wt.value
            } catch {
                log.error("RecordingSession.stop: writer ended with error: \(error.localizedDescription)")
                errorContinuation.yield(error)
            }
        }

        // 5) Drop references.
        writerTask = nil
        writer = nil
        mixer = nil
        sources = []
        autoStopDuration = nil
        autoStopRemaining = 0
        recordingSegmentStart = nil

        lastURLs = urls
        return urls
    }

    // MARK: - Auto-stop timer helpers (REQ-014)

    /// Arms a `DispatchSourceTimer` that fires after `remaining` seconds and
    /// calls `stop()` on the actor.
    ///
    /// - Note: Must only be called when `state == .recording`.
    private func armAutoStopTimer(remaining: TimeInterval) {
        // Cancel any existing timer first (idempotent guard).
        cancelAutoStopTimer()

        recordingSegmentStart = Date()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let deadline = DispatchTime.now() + remaining
        // leeway of 50 ms — acceptable per AC (±0.1 s).
        timer.schedule(deadline: deadline, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { _ = await self.stop() }
        }
        timer.resume()
        autoStopTimer = timer
    }

    /// Cancels and clears the timer; updates `autoStopRemaining` so a future
    /// `resume()` can re-arm with the correct remaining time.
    private func cancelAutoStopTimer() {
        if let timer = autoStopTimer {
            timer.cancel()
            autoStopTimer = nil
            // Subtract however long we were actively recording in this segment.
            if let segStart = recordingSegmentStart {
                let elapsed = Date().timeIntervalSince(segStart)
                autoStopRemaining = max(0, autoStopRemaining - elapsed)
            }
            recordingSegmentStart = nil
        }
    }

    // MARK: - Failure handling

    /// Called when a source emitter / normalizer hits an unrecoverable error.
    /// Transitions the session to `.failed`, drains audio to disk via stop(),
    /// and yields the error on `errorStream` (already done at call site).
    private func handleSourceFailure(id: String, error: Error) async {
        // Only escalate to failed if we're actively recording; an error that
        // arrives during pause/stop teardown is handled by the normal flow.
        guard state == .recording || state == .paused else { return }
        state = .failed
        // Best-effort drain: schedule stop on a separate Task to avoid
        // re-entrancy on the actor (we may already be inside a normalization
        // task that the stop sequence is awaiting).
        Task { _ = await self.stop() }
    }
}

// MARK: - Adapters for REQ-007 / REQ-008

/// Adapter that wraps a `MicrophoneCapture` (REQ-008) as a `RecordingSourceEmitter`.
public final class MicrophoneSourceEmitter: RecordingSourceEmitter {
    public let id: String
    public let stream: AsyncStream<AVAudioPCMBuffer>
    private let mic: MicrophoneCapture

    public init(id: String = "mic", capture: MicrophoneCapture) {
        self.id = id
        self.stream = capture.stream
        self.mic = capture
    }

    public func stop() {
        mic.stop()
    }
}

/// Adapter that wraps a single per-pid stream from `ProcessTapCapture` (REQ-007)
/// as a `RecordingSourceEmitter`.
///
/// `ProcessTapCapture` emits `[pid_t: AsyncStream]`; one of these adapters per
/// pid lets `RecordingSession` treat each tapped process as a distinct source.
public final class ProcessTapSourceEmitter: RecordingSourceEmitter {
    public let id: String
    public let stream: AsyncStream<AVAudioPCMBuffer>
    private let owner: ProcessTapCapture

    /// - Parameters:
    ///   - id:     stable identifier (typically the bundle id or app name).
    ///   - capture: the shared `ProcessTapCapture` instance.
    ///   - pid:    the pid whose stream this emitter wraps.
    public init?(id: String, capture: ProcessTapCapture, pid: pid_t) {
        guard let stream = capture.streams[pid] else { return nil }
        self.id = id
        self.stream = stream
        self.owner = capture
    }

    /// Stops the *entire* underlying `ProcessTapCapture`. If multiple
    /// `ProcessTapSourceEmitter`s share the same `ProcessTapCapture`, only the
    /// first `stop()` does work — subsequent calls are no-ops thanks to the
    /// underlying capture's idempotent teardown.
    public func stop() {
        owner.stop()
    }
}
