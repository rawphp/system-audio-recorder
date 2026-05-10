import XCTest
@testable import SystemAudioRecorder

/// Tests for the UserGuide URL constant (REQ-056).
final class UserGuideTests: XCTestCase {

    func testUserGuideURLMatchesCanonical() {
        XCTAssertEqual(
            UserGuide.url.absoluteString,
            "https://github.com/rawphp/system-audio-recorder/blob/main/docs/user-guide.md"
        )
    }

    func testUserGuideURLIsHTTPS() {
        XCTAssertEqual(UserGuide.url.scheme, "https")
    }

    func testUserGuideURLHostIsGitHub() {
        XCTAssertEqual(UserGuide.url.host, "github.com")
    }
}
