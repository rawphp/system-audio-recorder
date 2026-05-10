import Foundation

/// Centralised URL constant for the end-user guide opened by the Help menu (REQ-056)
/// and the in-window Help button (REQ-057).
public enum UserGuide {
    public static let url: URL = URL(
        string: "https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md"
    )!
}
