import AVFoundation
import CoreAudio
import Observation

// MARK: - AudioTapStatus

/// Runtime availability of the Core Audio Process Tap capability.
public enum AudioTapStatus: Equatable {
    /// Probe has not run yet.
    case unknown
    /// `AudioHardwareCreateProcessTap` succeeded — audio tap is available.
    case available
    /// The audio-input entitlement is missing or revoked.
    case deniedByEntitlement
    /// System policy (MDM / parental controls) prevents tap creation.
    case deniedByPolicy
}

// MARK: - MicrophoneAuthorizationProvider

/// Seam that abstracts `AVCaptureDevice` authorization calls for testability.
///
/// The production implementation wraps the real AVCaptureDevice APIs.
/// Tests inject a `StubMicrophoneAuthorizationProvider` with deterministic results.
public protocol MicrophoneAuthorizationProvider: AnyObject {
    /// Current microphone authorization status (no side effects).
    var status: AVAuthorizationStatus { get }
    /// Request microphone access. Returns `true` if the user grants.
    func requestAccess() async -> Bool
}

// MARK: - SystemMicrophoneAuthorizationProvider (production)

/// Production wrapper around `AVCaptureDevice` authorization APIs.
public final class SystemMicrophoneAuthorizationProvider: MicrophoneAuthorizationProvider {

    public init() {}

    public var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - _TimerBox (nonisolated timer wrapper for deinit)

/// Wraps a `DispatchSourceTimer` in a class so it can be cancelled from a
/// `nonisolated` `deinit` context without touching `@MainActor`-isolated state.
final class _TimerBox: @unchecked Sendable {
    var timer: DispatchSourceTimer?
    func cancel() { timer?.cancel(); timer = nil }
}

// MARK: - PermissionManager

/// `@Observable` permission gate consumed by the UI and audio engine layers.
///
/// Checks microphone access via `AVCaptureDevice` and audio-tap availability
/// via a lightweight `AudioHardwareCreateProcessTap` probe.
///
/// All stored properties are updated on the `@MainActor` to satisfy `@Observable`
/// binding requirements. Permission requests must therefore be awaited from the
/// main actor context (or from `async` contexts that can hop to main).
@Observable
@MainActor
public final class PermissionManager {

    // MARK: - Public state

    /// Current microphone authorization status.
    public private(set) var microphoneStatus: AVAuthorizationStatus

    /// Runtime check result for audio tap capability.
    public private(set) var audioTapStatus: AudioTapStatus = .unknown

    // MARK: - Private

    private let micProvider: MicrophoneAuthorizationProvider
    // Stored nonisolated so deinit (which is nonisolated) can cancel without
    // crossing the @MainActor isolation boundary.
    private let timerBox: _TimerBox
    private var micPromptIssued = false

    // MARK: - Initialisation

    /// Designated initialiser.
    ///
    /// - Parameter micProvider: injectable seam; defaults to the system wrapper.
    public init(micProvider: MicrophoneAuthorizationProvider = SystemMicrophoneAuthorizationProvider()) {
        self.micProvider = micProvider
        self.microphoneStatus = micProvider.status
        self.timerBox = _TimerBox()
        startPolling()
    }

    deinit {
        timerBox.cancel()
    }

    // MARK: - Microphone

    /// Request microphone access from the user.
    ///
    /// On the first call the macOS permission sheet appears (if status is
    /// `.notDetermined`). Subsequent calls return the cached result without
    /// re-prompting.
    ///
    /// - Returns: `true` if the user has granted or already granted microphone
    ///   access.
    public func requestMicrophone() async -> Bool {
        // If already determined, return cached result without a prompt.
        let current = micProvider.status
        if current == .authorized {
            microphoneStatus = .authorized
            return true
        }
        if current == .denied || current == .restricted {
            microphoneStatus = current
            return false
        }
        // .notDetermined — issue the prompt once.
        if micPromptIssued {
            // Prompt already issued during this session; return current cached status.
            return microphoneStatus == .authorized
        }
        micPromptIssued = true
        let granted = await micProvider.requestAccess()
        microphoneStatus = micProvider.status
        return granted
    }

    /// Synchronously refresh `microphoneStatus` from the provider.
    ///
    /// Called by the 1 Hz poll timer so external revocations are surfaced
    /// within ~1 second.
    public func pollMicrophoneStatus() {
        microphoneStatus = micProvider.status
    }

    // MARK: - Audio Tap

    /// Check whether `AudioHardwareCreateProcessTap` can succeed.
    ///
    /// Runs a lightweight probe: attempts to create a tap with an empty process
    /// list; interprets the OSStatus to determine availability vs.
    /// entitlement/policy denial.
    ///
    /// - Returns: `true` when the tap capability is available.
    public func requestAudioTap() async -> Bool {
        let status = probeAudioTap()
        audioTapStatus = status
        return status == .available
    }

    // MARK: - Private helpers

    /// Probe tap creation and interpret the resulting OSStatus into `AudioTapStatus`.
    ///
    /// `AudioHardwareCreateProcessTap` with an empty process list fails quickly.
    /// The error code classification:
    ///   - Positive 4CC object-level errors → HAL accepted the entitlement check → `.available`
    ///   - Negative / entitlement-denied codes → `.deniedByEntitlement` or `.deniedByPolicy`
    private func probeAudioTap() -> AudioTapStatus {
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.name = "com.tomkaczocha.SystemAudioRecorder.probe"
        var tapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(desc, &tapID)

        // If it somehow succeeds, destroy and report available.
        if status == noErr {
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            return .available
        }

        // Positive 4CC codes (object-level errors) mean the HAL processed the
        // call — the entitlement layer passed.
        if status > 0 {
            return .available
        }

        // Negative codes indicate a system-level refusal.
        // kAudioHardwareNotRunningError (-66530) and similar HAL internal errors
        // are treated as policy denials for v1.
        return .deniedByPolicy
    }

    /// Start a 1 Hz timer that polls `microphoneStatus` so external revocations
    /// (via System Settings) are reflected within ~1 second.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.pollMicrophoneStatus()
            }
        }
        timer.resume()
        timerBox.timer = timer
    }
}
