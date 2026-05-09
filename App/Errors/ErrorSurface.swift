import Foundation
import Observation

// MARK: - ErrorSeverity

/// Determines which surface an error is routed to.
public enum ErrorSeverity: Sendable {
    /// Modal alert with "Try Again" + optional "Open System Settings".
    case fatal
    /// Inline dismissible banner at the top of the window content area.
    case nonFatal
    /// Non-modal toast (reuses SaveToast component from REQ-027). Dismissible = false.
    case background
}

// MARK: - SystemSettingsPane

/// Deep-link destinations in System Settings.
public enum SystemSettingsPane: Equatable, Sendable {
    /// Privacy → Microphone
    case microphone
    /// Privacy → Screen Recording (audio tap)
    case screenRecording

    /// The `x-apple.systempreferences:` URL for this pane.
    public var url: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

// MARK: - AppAlert

/// Data for a modal alert shown to the user.
public struct AppAlert: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    /// Primary button label (e.g. "Try Again", "OK").
    public let primaryButton: String
    /// Optional secondary button label (e.g. "Open System Settings").
    public let secondaryButton: String?
    /// If non-nil, tapping the secondary button opens this pane in System Settings.
    public let secondaryAction: SystemSettingsPane?

    public init(
        id: UUID = UUID(),
        title: String,
        message: String,
        primaryButton: String = "Try Again",
        secondaryButton: String? = nil,
        secondaryAction: SystemSettingsPane? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.secondaryAction = secondaryAction
    }
}

// MARK: - AppBanner

/// Data for an inline banner shown at the top of the window.
public struct AppBanner: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String
    /// Whether the user can dismiss this banner with an X button.
    public let dismissible: Bool

    public init(id: UUID = UUID(), message: String, dismissible: Bool = true) {
        self.id = id
        self.message = message
        self.dismissible = dismissible
    }
}

// MARK: - ErrorSurface

/// Routes typed errors to the appropriate UI surface.
///
/// - **fatal** → modal `AppAlert` with "Try Again" and optional "Open System Settings".
/// - **nonFatal** → inline dismissible `AppBanner` (max 3 visible, rest collapsed).
/// - **background** → non-modal toast banner (dismissible = false, appended to `banners`).
///
/// `report(_:severity:)` is safe to call from any thread — it dispatches
/// internally to `@MainActor` before mutating state.
@Observable
@MainActor
public final class ErrorSurface {

    // MARK: - Max visible banners

    private static let maxVisibleBanners = 3

    // MARK: - Observable state

    /// The current modal alert. Non-nil while a fatal alert is displayed.
    public private(set) var currentAlert: AppAlert?

    /// Visible banners (non-fatal + background toasts), capped at 3.
    public private(set) var banners: [AppBanner] = []

    /// Total number of banners (including those not in `banners`).
    private var totalBannerCount: Int = 0

    /// Number of banners above the 3-item cap that are hidden.
    public var collapsedCount: Int {
        max(0, totalBannerCount - Self.maxVisibleBanners)
    }

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Route an error to the appropriate surface.
    ///
    /// May be called from any thread. Dispatches to `@MainActor` before mutating state.
    public func report(_ error: Error, severity: ErrorSeverity) async {
        // Ensure main-actor execution, regardless of calling thread.
        await MainActor.run {
            self.route(error, severity: severity)
        }
    }

    /// Dismiss a banner by its identifier.
    public func dismiss(banner id: UUID) {
        banners.removeAll { $0.id == id }
        totalBannerCount = max(0, totalBannerCount - 1)
    }

    /// Clear the current modal alert.
    public func dismissAlert() {
        currentAlert = nil
    }

    // MARK: - Private routing

    @MainActor
    private func route(_ error: Error, severity: ErrorSeverity) {
        let mapped = ErrorSurface.map(error)

        switch severity {
        case .fatal:
            // Fatal → modal alert.
            currentAlert = AppAlert(
                title: mapped.alertTitle,
                message: mapped.message,
                primaryButton: "Try Again",
                secondaryButton: mapped.settingsPane != nil ? "Open System Settings" : nil,
                secondaryAction: mapped.settingsPane
            )

        case .nonFatal:
            // Non-fatal → dismissible inline banner (capped at 3 visible).
            let banner = AppBanner(message: mapped.message, dismissible: true)
            appendBanner(banner)

        case .background:
            // Background → non-dismissible toast banner.
            let banner = AppBanner(message: mapped.message, dismissible: false)
            appendBanner(banner)
        }
    }

    @MainActor
    private func appendBanner(_ banner: AppBanner) {
        totalBannerCount += 1
        if banners.count < Self.maxVisibleBanners {
            banners.append(banner)
        }
        // If already at cap, the banner is counted but not shown (collapsedCount reflects it).
    }

    // MARK: - Error mapping

    private struct MappedError {
        let alertTitle: String
        let message: String
        let settingsPane: SystemSettingsPane?
    }

    private static func map(_ error: Error) -> MappedError {
        // CaptureError.permissionRevoked → fatal with microphone settings link.
        if let captureError = error as? CaptureError {
            switch captureError {
            case .permissionRevoked:
                return MappedError(
                    alertTitle: "Permission Revoked",
                    message: "Microphone permission was revoked. Open System Settings to grant access.",
                    settingsPane: .microphone
                )
            default:
                return MappedError(
                    alertTitle: "Capture Error",
                    message: captureError.localizedDescription,
                    settingsPane: nil
                )
            }
        }

        // EncodingError.invalidInput → background toast.
        // EncodingError.lameInitFailed → fatal alert.
        if let encodingError = error as? EncodingError {
            switch encodingError {
            case .invalidInput:
                return MappedError(
                    alertTitle: "Encoding Error",
                    message: "Encoding failed — input WAV could not be opened.",
                    settingsPane: nil
                )
            case .lameInitFailed:
                return MappedError(
                    alertTitle: "Encoder Initialization Failed",
                    message: "Audio encoder failed to initialize.",
                    settingsPane: nil
                )
            default:
                return MappedError(
                    alertTitle: "Encoding Error",
                    message: encodingError.localizedDescription,
                    settingsPane: nil
                )
            }
        }

        // SessionError.noSourcesConfigured → non-fatal banner.
        if let sessionError = error as? SessionError {
            switch sessionError {
            case .noSourcesConfigured:
                return MappedError(
                    alertTitle: "No Audio Sources",
                    message: "Pick at least one audio source before recording.",
                    settingsPane: nil
                )
            default:
                return MappedError(
                    alertTitle: "Session Error",
                    message: sessionError.localizedDescription,
                    settingsPane: nil
                )
            }
        }

        // SettingsError.outputFolderUnavailable → non-fatal banner.
        if let settingsError = error as? SettingsError {
            switch settingsError {
            case .outputFolderUnavailable:
                return MappedError(
                    alertTitle: "Output Folder Unavailable",
                    message: "Output folder is unavailable. Re-pick a folder in Settings.",
                    settingsPane: nil
                )
            case .outputFolderFallback(let url):
                return MappedError(
                    alertTitle: "Output Folder Changed",
                    message: "Default output folder could not be created. Using: \(url.path)",
                    settingsPane: nil
                )
            }
        }

        // Fallback: use localizedDescription as a background toast.
        return MappedError(
            alertTitle: "Error",
            message: error.localizedDescription,
            settingsPane: nil
        )
    }
}
