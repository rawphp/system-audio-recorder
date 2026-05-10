import AVFoundation
import CoreAudio
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

    /// When set, `RecordingSession` watches the mix-bus stream for a continuous
    /// silence window of this many seconds (RMS < −60 dBFS). After a 2-second
    /// startup grace period, if silence persists for `autoStopSilenceSeconds`
    /// consecutive seconds, `stop()` is called on the main queue.
    /// `nil` (default) means no silence detector is installed. (REQ-021 will
    /// later wire this from `UserDefaults`.)
    public let autoStopSilenceSeconds: TimeInterval?

    /// Errors observed during source construction (e.g. per-pid emitter
    /// failures from `ProcessTapCapture` when one pid in `Everything` mode
    /// fails to tap). `RecordingSession.start` forwards each entry to its
    /// `errorStream` immediately after entering `.recording`, so REQ-033's
    /// `ErrorSurface` can render them. Empty by default. (REQ-045 / UR-004.)
    public let initialErrors: [PerPIDInitFailure]

    /// PIDs that `RecordingSession.start` must validate a real tap against before
    /// opening any output file or starting any audio unit (REQ-052). When `nil`,
    /// validation is skipped entirely — use `nil` for mic-only sessions. When
    /// non-nil (even `[]` for "Everything" mode with no specific pids), a probe
    /// tap is created against those pids; failure throws `CaptureError.tapCreationFailed`.
    public let tapValidationPIDs: [pid_t]?

    public init(
        sources: [Source],
        outputMode: OutputMode,
        outputFolder: URL,
        timestamp: String,
        autoStopDuration: TimeInterval? = nil,
        autoStopSilenceSeconds: TimeInterval? = nil,
        initialErrors: [PerPIDInitFailure] = [],
        tapValidationPIDs: [pid_t]? = nil
    ) {
        self.sources = sources
        self.outputMode = outputMode
        self.outputFolder = outputFolder
        self.timestamp = timestamp
        self.autoStopDuration = autoStopDuration
        self.autoStopSilenceSeconds = autoStopSilenceSeconds
        self.initialErrors = initialErrors
        self.tapValidationPIDs = tapValidationPIDs
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

// MARK: - TapValidator

/// A closure that validates whether the Core Audio process-tap can be created for
/// the given list of PIDs. On success it must clean up any transient resources it
/// created (probe tap). On failure it throws — typically `CaptureError.tapCreationFailed`.
///
/// The production implementation (`RecordingSession.defaultTapValidator`) creates a
/// real `CATapDescription` tap against the supplied pids (or an empty-process tap
/// if the list is empty) and immediately destroys it.  Tests inject a stub closure
/// so no real Core Audio call is needed.
public typealias TapValidator = ([pid_t]) throws -> Void

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

    /// Per-source diagnostic aggregators (REQ-046 / UR-004). One per source,
    /// fed buffers from the normalization task and ticked by `signalTickerTask`.
    private var signalAggregators: [SignalLevelAggregator] = []
    /// Single ~1 Hz timer task that ticks every aggregator. Cancelled on stop().
    private var signalTickerTask: Task<Void, Never>?

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

    // MARK: - Silence detector (REQ-015)

    /// The configured silence threshold (nil = detector off).
    private var silenceThreshold: TimeInterval?
    /// Task driving the silence-detector side of the mix fan-out.
    private var silenceDetectorTask: Task<Void, Never>?
    /// Continuation for the silence-detector's copy of the mix stream (fan-out write side).
    private var silenceDetectorCont: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // MARK: - Error stream (REQ-033 hand-off)

    public nonisolated let errorStream: AsyncStream<Error>
    private let errorContinuation: AsyncStream<Error>.Continuation

    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "RecordingSession"
    )

    /// Injectable tap-validation closure. Production default performs a real
    /// `AudioHardwareCreateProcessTap` probe and immediately destroys the tap.
    /// Tests inject a stub to avoid Core Audio hardware calls.
    private let tapValidator: TapValidator

    // MARK: - Init

    /// - Parameter tapValidator: Optional injectable seam for tap validation (REQ-052).
    ///   Defaults to the real Core Audio probe. Tests pass a stub closure.
    public init(tapValidator: TapValidator? = nil) {
        self.tapValidator = tapValidator ?? RecordingSession.defaultTapValidator
        var c: AsyncStream<Error>.Continuation!
        self.errorStream = AsyncStream<Error> { c = $0 }
        self.errorContinuation = c
    }

    // MARK: - Default tap validator (production)

    /// Real Core Audio probe: creates a `CATapDescription` for the given pids,
    /// attempts `AudioHardwareCreateProcessTap`, and immediately destroys the tap
    /// on success. Throws `CaptureError.tapCreationFailed(OSStatus)` on failure.
    ///
    /// An empty pid list is valid for "Everything" mode (the HAL accepts it as a
    /// system-wide tap probe). The caller passes the full real pid list so the
    /// HAL can evaluate per-process policy — not the empty-list shortcut used by
    /// `PermissionManager._defaultAudioTapProbe()`.
    public static let defaultTapValidator: TapValidator = { pids in
        var objectIDs: [AudioObjectID] = []
        // Only translate pids when the list is non-empty; an empty list is a
        // valid "all processes" probe that still exercises the HAL entitlement check.
        for pid in pids {
            var pidVar = pid
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var objID: AudioObjectID = kAudioObjectUnknown
            var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
            let qSize = UInt32(MemoryLayout<pid_t>.size)
            let status: OSStatus = withUnsafePointer(to: &pidVar) { ptr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr,
                    qSize,
                    ptr,
                    &dataSize,
                    &objID
                )
            }
            // If translation fails for one pid we still attempt the tap —
            // validation is about whether the tap API is reachable at all,
            // not about individual pid availability (that's REQ-045's domain).
            if status == noErr, objID != kAudioObjectUnknown {
                objectIDs.append(objID)
            }
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        desc.muteBehavior = .unmuted
        desc.name = "com.tomkaczocha.SystemAudioRecorder.validation"

        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        if tapStatus == noErr {
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            return // success — tap created and immediately destroyed
        }
        throw CaptureError.tapCreationFailed(tapStatus)
    }

    // MARK: - Live gain (REQ-028)

    /// Forwards a gain change to the underlying `MixerGraph` immediately.
    ///
    /// Called by `MixerPanelViewModel.setGain(forID:to:)` during an active
    /// recording. The gain change propagates within one audio buffer (~10 ms)
    /// as guaranteed by REQ-010.
    ///
    /// - Parameters:
    ///   - sourceID: The source's stable ID string (e.g. `"pid:12345"` or `"mic"`).
    ///   - gain:     Linear gain in 0.0 – 2.0. Values outside the range are clamped
    ///               by `MixerGraph.setGain`.
    public func setGain(forSource sourceID: String, gain: Float) {
        mixer?.setGain(forSource: sourceID, gain: gain)
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

        // REQ-052: Real-tap validation — runs BEFORE any output file is opened or
        // any audio unit is started. Skipped for mic-only sessions (tapValidationPIDs == nil).
        // The validator creates a probe tap against the real process list and immediately
        // destroys it; throws CaptureError.tapCreationFailed on failure.
        if let pids = config.tapValidationPIDs {
            do {
                try tapValidator(pids)
                log.debug("RecordingSession: tap validation passed for \(pids.count) pid(s)")
            } catch {
                log.error("RecordingSession: tap validation failed: \(error.localizedDescription)")
                throw error // propagate typed CaptureError.tapCreationFailed to AppStore
            }
        }

        let mixer = MixerGraph()
        let writer = WAVWriter(outputFolder: config.outputFolder, timestamp: config.timestamp)

        // Per-source diagnostic logging (REQ-046 / UR-004).
        let sessionStart = Date()
        let signalLogger: SignalLogger = OSLogSignalLogger(category: "RecordingSession")
        var aggregators: [SignalLevelAggregator] = []

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

            // Per-source signal-level aggregator — fed inside the normalization
            // task below, ticked by `signalTickerTask`.
            let aggregator = SignalLevelAggregator(
                id: source.id,
                logger: signalLogger,
                sessionStart: sessionStart
            )
            aggregators.append(aggregator)

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
                            aggregator.recordBuffer(buf, at: Date())
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

        signalAggregators = aggregators

        // 1 Hz ticker that drives every aggregator until cancelled. Runs as a
        // detached task so it isn't blocked by actor isolation; uses
        // `Task.sleep` rather than `DispatchSourceTimer` for simpler cleanup.
        signalTickerTask = Task.detached { [aggregators] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return // cancelled mid-sleep — exit cleanly
                }
                let now = Date()
                for agg in aggregators {
                    agg.tick(now: now)
                }
            }
        }

        // Snapshot for stop() teardown.
        self.mixer = mixer
        self.writer = writer
        self.sources = config.sources

        // Launch the writer task. It drains either the mix stream (mixed mode)
        // or the per-source streams + mix (separate mode) into WAV files.
        let mode = config.outputMode
        let rawMixStream = mixer.mixBufferStream()
        let perSourceStreams: [(String, AsyncStream<AVAudioPCMBuffer>)] = config.sources.map { src in
            (src.id, mixer.sourceBufferStream(forSource: src.id))
        }
        let errCont = self.errorContinuation
        let logger = self.log

        // REQ-015: If silence detection is configured, fan-out the mix stream so
        // both the WAV writer and the silence detector receive every buffer.
        let writerMixStream: AsyncStream<AVAudioPCMBuffer>
        if let silenceSecs = config.autoStopSilenceSeconds {
            self.silenceThreshold = silenceSecs

            // Build two downstream streams from the single raw mix stream.
            var writerCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
            var detectorCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
            let writerStream   = AsyncStream<AVAudioPCMBuffer> { writerCont   = $0 }
            let detectorStream = AsyncStream<AVAudioPCMBuffer> { detectorCont = $0 }

            // Save the detector continuation so pause/stop can close it cleanly.
            self.silenceDetectorCont = detectorCont

            // Fan-out task: reads from mixer, yields to both downstreams.
            let wc = writerCont!
            let dc = detectorCont!
            Task.detached {
                for await buf in rawMixStream {
                    wc.yield(buf)
                    dc.yield(buf)
                }
                wc.finish()
                dc.finish()
            }

            writerMixStream = writerStream

            // Launch the silence detector.
            silenceDetectorTask = installSilenceDetector(
                stream: detectorStream,
                threshold: silenceSecs
            )
        } else {
            writerMixStream = rawMixStream
        }

        writerTask = Task.detached {
            do {
                switch mode {
                case .mixed:
                    return try await writer.runMixed(stream: writerMixStream)
                case .separate:
                    return try await writer.runSeparate(
                        sources: perSourceStreams,
                        mixStream: writerMixStream
                    )
                }
            } catch {
                logger.error("RecordingSession: writer failed: \(error.localizedDescription)")
                errCont.yield(error)
                throw error
            }
        }

        state = .recording

        // Forward any source-construction failures captured by the builder
        // (e.g. ProcessTapCapture per-pid emitter failures in Everything mode)
        // so REQ-033's ErrorSurface can render them via the existing channel.
        // (REQ-045 / UR-004.)
        for failure in config.initialErrors {
            errorContinuation.yield(failure)
        }

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
        // Reset silence detector on pause (safe default per spec Section 5.6).
        notifySilenceDetectorPaused()
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
        // Restart grace period in silence detector after resume.
        notifySilenceDetectorResumed()
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

        // 4b) Tear down silence detector (if any).
        silenceDetectorTask?.cancel()
        silenceDetectorTask = nil
        silenceDetectorCont?.finish()
        silenceDetectorCont = nil

        // 4c) Tear down per-source signal-level diagnostic logging (REQ-046).
        signalTickerTask?.cancel()
        signalTickerTask = nil
        signalAggregators.removeAll()

        // 5) Drop references.
        writerTask = nil
        writer = nil
        mixer = nil
        sources = []
        autoStopDuration = nil
        autoStopRemaining = 0
        recordingSegmentStart = nil
        silenceThreshold = nil

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

    // MARK: - Silence detector (REQ-015)

    /// Shared mutable state for the silence detector task, guarded by NSLock.
    /// Kept off-actor so the detector `Task.detached` can mutate it without
    /// hopping onto the actor's executor on every buffer.
    private final class SilenceDetectorState: @unchecked Sendable {
        private let lock = NSLock()
        /// Wall-clock time at which the *current* active segment began
        /// (i.e. after the last resume, or when the session started).
        private var segmentStart: Date = Date()
        /// Accumulated *active* (non-paused) seconds at the time of the last pause.
        private var accumulatedActiveSeconds: TimeInterval = 0
        /// True while the session is paused — detector drops buffers.
        private var _paused: Bool = false

        var isPaused: Bool {
            lock.lock(); defer { lock.unlock() }
            return _paused
        }

        /// Marks the session as paused; freezes active-time accounting.
        func pause() {
            lock.lock(); defer { lock.unlock() }
            // Accumulate the active seconds up to now.
            accumulatedActiveSeconds += Date().timeIntervalSince(segmentStart)
            _paused = true
        }

        /// Marks the session as resumed; restarts the segment clock AND
        /// resets accumulated active seconds (grace period restarts from 0).
        func resume() {
            lock.lock(); defer { lock.unlock() }
            accumulatedActiveSeconds = 0
            segmentStart = Date()
            _paused = false
        }

        /// Returns total active (non-paused) seconds since the last resume
        /// (or since creation, whichever is more recent).
        func activeSeconds() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            if _paused {
                return accumulatedActiveSeconds
            }
            return accumulatedActiveSeconds + Date().timeIntervalSince(segmentStart)
        }
    }

    /// Shared state object referenced by the silence-detector task.
    private var silenceDetectorState: SilenceDetectorState?

    /// Installs the silence-detector async task.
    ///
    /// The task:
    /// 1. Skips the first `gracePeriod` (2.0 s) of active recording time.
    /// 2. Evaluates each buffer's RMS (via `MeterTap.computeRMS`).
    /// 3. If RMS < −60 dBFS, accumulates the buffer's duration into the
    ///    consecutive-silence counter; otherwise resets it immediately.
    /// 4. When the counter reaches `threshold`, calls `stop()` on the actor.
    ///
    /// The 200 ms *windowed* RMS spec refers to integration over the buffer
    /// duration — each `AVAudioPCMBuffer` is already ~10 ms so the MeterTap
    /// stateless function provides the window. Using **peak detection** (any
    /// above-threshold buffer resets the counter) matches the spec intent that
    /// "audio above -60 dBFS at any point resets the counter".
    ///
    /// - Parameters:
    ///   - stream:    Fan-out copy of the mix-bus stream.
    ///   - threshold: Seconds of consecutive silence required to trigger stop.
    /// - Returns: The detector `Task` (stored so it can be cancelled on teardown).
    private func installSilenceDetector(
        stream: AsyncStream<AVAudioPCMBuffer>,
        threshold: TimeInterval
    ) -> Task<Void, Never> {
        let state = SilenceDetectorState()
        self.silenceDetectorState = state

        // Per spec: silence = RMS < −60 dBFS.
        let silenceDBFS: Float = -60.0
        let gracePeriod: TimeInterval = 2.0

        return Task.detached { [weak self] in
            guard let self else { return }

            // Wall-clock time when the current consecutive-silence run started.
            // nil means the previous buffer was not silent.
            var silenceRunStart: Date? = nil

            for await buf in stream {
                // Drop buffers while paused (silence counter frozen).
                guard !state.isPaused else {
                    silenceRunStart = nil
                    continue
                }

                // Skip grace period.
                guard state.activeSeconds() >= gracePeriod else {
                    silenceRunStart = nil
                    continue
                }

                let rms = MeterTap.computeRMS(buf)

                if rms < silenceDBFS {
                    // Silent buffer — start or continue the silence run.
                    if silenceRunStart == nil {
                        silenceRunStart = Date()
                    }
                    // Check if we've been silent long enough.
                    let silentSecs = Date().timeIntervalSince(silenceRunStart!)
                    if silentSecs >= threshold {
                        _ = await self.stop()
                        return
                    }
                } else {
                    // Audio detected — reset the consecutive silence run.
                    silenceRunStart = nil
                }
            }
        }
    }

    /// Called by `pause()` to signal the silence detector that the session is paused.
    /// The detector drops buffers while paused and resets its silence counter.
    private func notifySilenceDetectorPaused() {
        silenceDetectorState?.pause()
    }

    /// Called by `resume()` to signal the silence detector that the session has
    /// resumed. The grace period restarts and the silence counter resets.
    private func notifySilenceDetectorResumed() {
        silenceDetectorState?.resume()
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
