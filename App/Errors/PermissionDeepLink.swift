import Foundation

// MARK: - PermissionDeepLink

/// Centralised `x-apple.systempreferences:` URL constants for privacy panes.
///
/// Used by `SourcePickerViewModel.openMicrophoneSettings()` and by
/// `ErrorSurface`'s `SystemSettingsPane` enum so both share the same URLs.
///
/// REQ-034: consolidates deep-link URLs that were previously scattered between
/// `SourcePickerView` and `ErrorSurface`.
public enum PermissionDeepLink {

    // MARK: - Microphone

    /// System Settings → Privacy & Security → Microphone.
    public static let microphoneSettingsURL: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!

    // MARK: - Screen Recording (audio tap)

    /// System Settings → Privacy & Security → Screen Recording.
    ///
    /// The audio process-tap permission is gated under the Screen Recording privacy
    /// pane on macOS 14+.
    public static let screenRecordingSettingsURL: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
}
