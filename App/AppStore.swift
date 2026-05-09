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
    }

    public init() {}

    public func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        // Resolve output folder from settings; create the default if needed.
        guard let outputFolder = settings.resolvedOutputFolder() else {
            throw BuilderError.noOutputFolder
        }

        let timestamp = Self.timestampString()
        let mode: SessionConfig.OutputMode =
            (settings.outputMode == .separate) ? .separate : .mixed

        var sources: [SessionConfig.Source] = []

        switch preset {
        case .micOnly:
            let mic = try MicrophoneCapture()
            let emitter = MicrophoneSourceEmitter(id: "mic", capture: mic)
            sources.append(SessionConfig.Source(id: "mic", emitter: emitter))

        case .everything:
            // For v1 ".everything" maps to tapping every pid in the catalog.
            // Wider catalog → emitter wiring is out-of-scope for REQ-022; the
            // production builder rejects it for now and will be extended by a
            // later UI/wiring REQ.
            throw BuilderError.unsupportedPreset

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
            autoStopSilenceSeconds: settings.autoStopSilenceSeconds
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
        self.init(
            settings: AppSettings(),
            sourceCatalog: AudioSourceCatalog(),
            permissionManager: PermissionManager(),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: DefaultSessionConfigBuilder()
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
    public func startRecording(preset: SourcePreset) async {
        guard sessionState == .idle || sessionState == .stopped || sessionState == .failed else {
            return
        }
        // Persist preset choice.
        settings.lastSourcePreset = preset.settingsKey

        let config: SessionConfig
        do {
            config = try sessionConfigBuilder.build(preset: preset, settings: settings)
        } catch {
            lastError = error
            return
        }

        let session = RecordingSession()
        // Update observable state BEFORE awaiting start so SwiftUI flips immediately.
        currentSession = session
        sessionState = .recording

        do {
            try await session.start(config: config)
        } catch {
            // Roll back state on failure.
            lastError = error
            currentSession = nil
            sessionState = .idle
        }
    }

    /// Pause the current session. No-op if not recording.
    public func pauseRecording() async throws {
        guard sessionState == .recording, let session = currentSession else { return }
        try await session.pause()
        sessionState = .paused
    }

    /// Resume a paused session. No-op if not paused.
    public func resumeRecording() async throws {
        guard sessionState == .paused, let session = currentSession else { return }
        try await session.resume()
        sessionState = .recording
    }

    /// Stop the current session and enqueue MP3 encoding for each WAV produced.
    public func stopRecording() async {
        guard let session = currentSession,
              sessionState == .recording || sessionState == .paused || sessionState == .failed
        else {
            return
        }
        let urls = await session.stop()

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

        currentSession = nil
        sessionState = .idle
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
