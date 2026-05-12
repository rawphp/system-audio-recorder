import AVFoundation
import Foundation
import Observation
import SwiftUI

// MARK: - SourcePreset

/// User-facing source preset. Mirrors the spec §4.2 source picker options:
/// - `.everything`        — all running audio-emitting processes (system audio).
/// - `.specificApp(pid:)` — a single tapped process.
/// - `.micOnly`           — microphone only, no process taps.
public enum SourcePreset: Equatable, Sendable {
    case everything
    case specificApp(processID: pid_t)
    case micOnly

    /// String key used by `AppSettings.lastSourcePreset` for persistence.
    public var settingsKey: String {
        switch self {
        case .everything:                return "Everything"
        case .specificApp(let pid):      return "SpecificApp:\(pid)"
        case .micOnly:                   return "MicOnly"
        }
    }

    /// Inverse of `settingsKey`: parse a persisted string back into a preset.
    /// Returns `.everything` for unknown values (graceful default).
    public static func from(settingsKey key: String) -> SourcePreset {
        if key == "Everything" { return .everything }
        if key == "MicOnly"    { return .micOnly }
        if key.hasPrefix("SpecificApp:") {
            let raw = String(key.dropFirst("SpecificApp:".count))
            if let pid = pid_t(raw) {
                return .specificApp(processID: pid)
            }
        }
        return .everything
    }
}

// MARK: - SessionConfigBuilder

/// Builds a `SessionConfig` (REQ-013) from a `SourcePreset` + `AppSettings`.
///
/// Production implementation (`DefaultSessionConfigBuilder`) translates the
/// preset into one or more `RecordingSourceEmitter`s by composing
/// `MicrophoneSourceEmitter` (REQ-008/013) and/or `ProcessTapSourceEmitter`
/// (REQ-007/013).
///
/// Tests inject a stub builder that returns a config wired to no-op emitters,
/// so the AppStore state machine can be exercised without touching real audio.
@MainActor
public protocol SessionConfigBuilder: AnyObject {
    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig
}

// MARK: - DefaultSessionConfigBuilder (production)

/// Production builder. NOT exercised by tests directly — tests inject their own stub.
///
/// This implementation is intentionally minimal: it builds a microphone-only
/// session for `.micOnly`, and otherwise wires a `ProcessTapCapture` per the
/// preset. Future REQs (specifically the wider UI wiring REQs in UR-001) may
/// extend or replace this.
@MainActor
public final class DefaultSessionConfigBuilder: SessionConfigBuilder {

    public enum BuilderError: Error, Equatable {
        case noOutputFolder
        case unsupportedPreset
        case noAudibleProcesses
    }

    private let catalog: AudioSourceCatalog?

    /// - Parameter catalog: Optional shared `AudioSourceCatalog`. When provided,
    ///   `.everything` taps every pid currently listed by the catalog. When `nil`
    ///   (e.g. older test wiring), the builder refreshes a private catalog.
    public init(catalog: AudioSourceCatalog? = nil) {
        self.catalog = catalog
    }

    public func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        // Resolve output folder from settings; create the default if needed.
        guard let outputFolder = settings.resolvedOutputFolder() else {
            throw BuilderError.noOutputFolder
        }

        let timestamp = Self.timestampString()
        let mode: SessionConfig.OutputMode =
            (settings.outputMode == .separate) ? .separate : .mixed

        var sources: [SessionConfig.Source] = []
        var initialErrors: [PerPIDInitFailure] = []

        switch preset {
        case .micOnly:
            let mic = try MicrophoneCapture()
            let emitter = MicrophoneSourceEmitter(id: "mic", capture: mic)
            sources.append(SessionConfig.Source(id: "mic", emitter: emitter))

        case .everything:
            // Tap every audio-emitting process the catalog currently knows about.
            // Filtering (no coreaudiod, must have bundle id) is handled by
            // AudioSourceCatalog.refresh().
            let activeCatalog = catalog ?? AudioSourceCatalog()
            activeCatalog.refresh()
            let pids = activeCatalog.processes.map(\.pid)

            guard !pids.isEmpty else {
                throw BuilderError.noAudibleProcesses
            }

            // ProcessTapCapture only throws when EVERY pid fails (REQ-045 /
            // UR-004 graceful failure). Surviving pids' streams are exposed
            // via `capture.streams`; failed pids are surfaced via initFailures
            // for the recording session to forward to REQ-033 ErrorSurface.
            let capture = try ProcessTapCapture(pids: pids)
            initialErrors.append(contentsOf: capture.initFailures)
            for pid in pids {
                guard let emitter = ProcessTapSourceEmitter(
                    id: "app:\(pid)",
                    capture: capture,
                    pid: pid
                ) else {
                    continue
                }
                sources.append(SessionConfig.Source(id: "app:\(pid)", emitter: emitter))
            }

        case .specificApp(let pid):
            let capture = try ProcessTapCapture(pids: [pid])
            guard let emitter = ProcessTapSourceEmitter(
                id: "app:\(pid)",
                capture: capture,
                pid: pid
            ) else {
                throw BuilderError.unsupportedPreset
            }
            sources.append(SessionConfig.Source(id: "app:\(pid)", emitter: emitter))
        }

        return SessionConfig(
            sources: sources,
            outputMode: mode,
            outputFolder: outputFolder,
            timestamp: timestamp,
            autoStopDuration: settings.autoStopDurationSeconds,
            autoStopSilenceSeconds: settings.autoStopSilenceSeconds,
            initialErrors: initialErrors
        )
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }
}

// MARK: - AppStore

/// Top-level `@Observable` state container — the single source of truth for the UI.
///
/// Composes the audio-engine subsystems built in REQ-006/007/008/013/018,
/// the supporting REQ-019 (`PermissionManager`) and REQ-021 (`AppSettings`),
/// and the REQ-011 `MeterPublisher`. The SwiftUI app injects a single instance
/// via `\.appStore` so every view sees the same state.
///
/// ## State machine (mirrored from `RecordingSession`)
/// ```
///  idle ──start──▶ recording ──pause──▶ paused ──resume──▶ recording
///                       │                                       │
///                       └──────────── stop ─────────────────────▼
///                                                              idle
/// ```
///
/// `sessionState` is updated *before* the underlying `RecordingSession` work
/// completes so SwiftUI bindings flip immediately on user action.
@Observable
@MainActor
public final class AppStore {

    // MARK: - Owned subsystems

    public let settings: AppSettings
    public let sourceCatalog: AudioSourceCatalog
    public let permissionManager: PermissionManager
    public let encodingQueue: EncodingQueue
    public let meters: MeterPublisher
    private let sessionConfigBuilder: SessionConfigBuilder

    // MARK: - Error surface (REQ-033)

    /// Routes typed errors to the appropriate UI surface (modal alert, banner, or toast).
    public let errorSurface: ErrorSurface

    // MARK: - Recording state

    /// The active session, or `nil` when idle/stopped.
    public private(set) var currentSession: RecordingSession?

    /// UI-visible session state, kept in lock-step with `currentSession`.
    /// Updated synchronously on the main actor so observers are notified
    /// within the same run-loop tick a user action is dispatched.
    public private(set) var sessionState: SessionState = .idle

    /// The most-recent error to surface in the UI banner (REQ-033 hand-off).
    public private(set) var lastError: Error?

    /// Ring buffer fed by the active session's mix-bus dBFS values and
    /// drained by `meters` at 50 Hz under the `"mix"` source ID. (REQ-061)
    /// Allocated on `startRecording`, released on `stopRecording`.
    private var mixMeterRing: MeterRingBuffer?

    /// Signals that `stopRecording()` has begun but `session.stop()` has not yet
    /// returned. Flips `true` synchronously at the start of `stopRecording()` and
    /// back to `false` once `await session.stop()` returns (success or failure).
    /// `SaveToastViewModel` observes this to show the "Finishing recording…" toast.
    /// (REQ-063)
    public private(set) var isFinishingRecording: Bool = false

    /// Set to `true` by `MenuBarController`'s "Settings…" action so `ContentView`
    /// opens the `OutputSettingsView` sheet. Reset to `false` by `ContentView`
    /// when the sheet is dismissed. (REQ-031)
    public var _shouldShowSettings: Bool = false

    // MARK: - Computed

    /// Currently-selected source preset, derived from `settings.lastSourcePreset`.
    public var selectedPreset: SourcePreset {
        SourcePreset.from(settingsKey: settings.lastSourcePreset)
    }

    // MARK: - Init

    /// Designated initialiser with injectable dependencies (testing seam).
    public init(
        settings: AppSettings,
        sourceCatalog: AudioSourceCatalog,
        permissionManager: PermissionManager,
        encodingQueue: EncodingQueue,
        meters: MeterPublisher,
        sessionConfigBuilder: SessionConfigBuilder,
        errorSurface: ErrorSurface? = nil
    ) {
        self.settings = settings
        self.sourceCatalog = sourceCatalog
        self.permissionManager = permissionManager
        self.encodingQueue = encodingQueue
        self.meters = meters
        self.sessionConfigBuilder = sessionConfigBuilder
        self.errorSurface = errorSurface ?? ErrorSurface()
    }

    /// Convenience production initialiser — wires the default subsystems together.
    public convenience init() {
        let catalog = AudioSourceCatalog()
        self.init(
            settings: AppSettings(),
            sourceCatalog: catalog,
            permissionManager: PermissionManager(),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: DefaultSessionConfigBuilder(catalog: catalog)
        )
    }

    // MARK: - Actions

    /// Idempotent record-toggle (per AC #2):
    ///   - idle      → `startRecording(preset: selectedPreset)`
    ///   - recording → `stopRecording()`
    ///   - paused    → no-op
    ///   - other     → no-op
    public func toggleRecording() async {
        switch sessionState {
        case .idle, .stopped, .failed:
            await startRecording(preset: selectedPreset)
        case .recording:
            await stopRecording()
        case .paused:
            // Spec: toggleRecording is a no-op while paused — caller must
            // explicitly resume (or stop) to leave the paused state.
            return
        }
    }

    /// Start a new recording session with the given preset. Persists the preset
    /// to settings, builds a `SessionConfig` via the injected builder, and
    /// flips `sessionState` to `.recording` synchronously on success.
    ///
    /// On `CaptureError.tapCreationFailed` (MDM / policy denial), surfaces a
    /// fatal alert via `errorSurface` with "Switch to mic-only" + "Quit" buttons
    /// instead of a generic error banner (REQ-034).
    public func startRecording(preset: SourcePreset) async {
        guard sessionState == .idle || sessionState == .stopped || sessionState == .failed else {
            return
        }

        // REQ-051: Fail-fast tap availability gate.
        // Mic-only does not need the audio tap — skip the gate entirely.
        // For every other preset, re-probe tap status and abort early if unavailable.
        if preset != .micOnly {
            _ = await permissionManager.requestAudioTap()
            if permissionManager.audioTapStatus != .available {
                errorSurface.reportCustomAlert(AppAlert(
                    title: "Audio Tap Unavailable",
                    message: "Screen Recording permission is required to capture system audio. Open System Settings to grant access.",
                    primaryButton: "OK",
                    secondaryButton: "Open Settings",
                    secondaryAction: .screenRecording
                ))
                return
            }
        }

        // Persist preset choice.
        settings.lastSourcePreset = preset.settingsKey

        let baseConfig: SessionConfig
        do {
            baseConfig = try sessionConfigBuilder.build(preset: preset, settings: settings)
        } catch {
            lastError = error
            await routeSessionStartError(error)
            return
        }

        // REQ-061: Wire the mix-bus level meter for the lifetime of the session.
        // Allocate a fresh ring buffer per session, register it with the
        // publisher under the canonical `"mix"` source ID, start the 50 Hz
        // drain timer, and inject a sink closure into the SessionConfig so
        // RecordingSession writes per-buffer dBFS values into the ring.
        let ring = MeterRingBuffer(capacity: 64)
        mixMeterRing = ring
        meters.register(sourceID: MeterMath.mixSourceID, ring: ring)
        meters.start()

        let config = baseConfig.withMixMeterSink { [weak ring] dbfs in
            ring?.write(dbfs)
        }

        let session = RecordingSession()
        // Update observable state BEFORE awaiting start so SwiftUI flips immediately.
        currentSession = session
        sessionState = .recording

        do {
            try await session.start(config: config)
        } catch {
            // Roll back state on failure — also tear down the meter wiring.
            lastError = error
            currentSession = nil
            sessionState = .idle
            tearDownMixMeter()
            await routeSessionStartError(error)
        }
    }

    /// Unregisters the `"mix"` ring from the publisher and stops the drain
    /// timer. Called from `startRecording` rollback and `stopRecording`.
    /// (REQ-061)
    private func tearDownMixMeter() {
        meters.unregister(sourceID: MeterMath.mixSourceID)
        meters.stop()
        mixMeterRing = nil
    }

    /// Translate session-start errors into the appropriate `errorSurface` report.
    ///
    /// `CaptureError.tapCreationFailed` is treated as an MDM / policy tap block and
    /// surfaces a **fatal** alert offering a mic-only fallback or a quit option.
    /// All other errors are delegated to `ErrorSurface.report(_:severity:)`.
    private func routeSessionStartError(_ error: Error) async {
        if case CaptureError.tapCreationFailed = error {
            // MDM / policy denial of process-tap APIs → offer fallback.
            errorSurface.reportCustomAlert(AppAlert(
                title: "Audio Tap Blocked",
                message: "System policy (MDM) prevents audio tap creation. You can record microphone-only audio instead.",
                primaryButton: "Switch to mic-only",
                secondaryButton: "Quit",
                secondaryAction: nil
            ))
        } else {
            await errorSurface.report(error, severity: .nonFatal)
        }
    }

    /// Pause the current session. No-op if not recording.
    ///
    /// State is updated synchronously BEFORE awaiting `session.pause()` so
    /// SwiftUI bindings flip immediately on user action (matches the class
    /// docstring pattern and startRecording's ordering). If `session.pause()`
    /// throws, the prior state is restored and the error is surfaced via
    /// `errorSurface`.
    public func pauseRecording() async throws {
        guard sessionState == .recording, let session = currentSession else { return }
        // Flip state before the await so SwiftUI reacts immediately.
        sessionState = .paused
        do {
            try await session.pause()
        } catch {
            // Roll back to recording on failure.
            sessionState = .recording
            await errorSurface.report(error, severity: .nonFatal)
            throw error
        }
    }

    /// Resume a paused session. No-op if not paused.
    ///
    /// State is updated synchronously BEFORE awaiting `session.resume()` so
    /// SwiftUI bindings flip immediately on user action. If `session.resume()`
    /// throws, the prior state is restored and the error is surfaced via
    /// `errorSurface`.
    public func resumeRecording() async throws {
        guard sessionState == .paused, let session = currentSession else { return }
        // Flip state before the await so SwiftUI reacts immediately.
        sessionState = .recording
        do {
            try await session.resume()
        } catch {
            // Roll back to paused on failure.
            sessionState = .paused
            await errorSurface.report(error, severity: .nonFatal)
            throw error
        }
    }

    /// Stop the current session and enqueue MP3 encoding for each WAV produced.
    ///
    /// State is updated synchronously BEFORE awaiting `session.stop()` so
    /// SwiftUI bindings flip immediately on user action (matches the class
    /// docstring pattern and startRecording's ordering). The session drains
    /// in the background; encoding is enqueued once draining completes.
    public func stopRecording() async {
        guard let session = currentSession,
              sessionState == .recording || sessionState == .paused || sessionState == .failed
        else {
            return
        }

        // Flip state and nil the session BEFORE the long await so the UI
        // collapses to the idle layout immediately on the first click. (REQ-062)
        currentSession = nil
        sessionState = .stopped

        // REQ-063: Signal that the stop-tail is in progress so the toast can
        // show "Finishing recording…" before any encoding job exists.
        isFinishingRecording = true

        // REQ-061: Drop the mix meter ring synchronously so the UI level meter
        // stops immediately when the user clicks Stop.
        tearDownMixMeter()

        let urls = await session.stop()

        // REQ-063: Clear the finishing signal — always, regardless of whether
        // stop() produced files or not (prevents stuck toast).
        isFinishingRecording = false

        // Transition to .idle now that the session has fully drained.
        sessionState = .idle

        // Hand off to the encoding queue.
        let bitrate = settings.bitrate
        let mode    = settings.bitrateMode
        let keep    = settings.keepWAVAfterEncode
        for wavURL in urls {
            let mp3URL = wavURL.deletingPathExtension().appendingPathExtension("mp3")
            let job = EncodingJob(
                wavURL: wavURL,
                mp3URL: mp3URL,
                bitrate: bitrate,
                mode: mode
            )
            await encodingQueue.enqueue(job: job, keepWAV: keep)
        }
    }
}

// MARK: - Environment integration (AC #1)

/// SwiftUI environment key for the shared `AppStore` instance.
///
/// Default value is `nil`; the `App` body must inject a real instance via
/// `.environment(\.appStore, store)`. Views read the store with
/// `@Environment(\.appStore) private var store`.
private struct AppStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppStore? = nil
}

public extension EnvironmentValues {
    var appStore: AppStore? {
        get { self[AppStoreEnvironmentKey.self] }
        set { self[AppStoreEnvironmentKey.self] = newValue }
    }
}
