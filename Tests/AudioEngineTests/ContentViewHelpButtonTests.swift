import XCTest

/// REQ-057: Verifies that ContentView contains a Help button wired to UserGuide.url.
///
/// These tests use source-file content assertions because SwiftUI views cannot be
/// introspected structurally at runtime in unit tests without a full UI host.
/// The approach survives the pre-existing TEST_HOST failure in the test bundle by
/// not relying on any XCTest host app — it just reads the file from the source tree.
final class ContentViewHelpButtonTests: XCTestCase {

    // Path resolved relative to the repo root at build time via SRCROOT.
    // SRCROOT is injected by Xcode as an env var.  Fall back to a known
    // relative path so the grep assertions still work when run via `make test`.
    private var contentViewSource: String {
        get throws {
            // Try SRCROOT env var first (Xcode sets this)
            let srcRoot: String
            if let env = ProcessInfo.processInfo.environment["SRCROOT"] {
                srcRoot = env
            } else {
                // Fallback: walk up from the test bundle to the repo root
                let bundlePath = Bundle(for: ContentViewHelpButtonTests.self).bundlePath
                // Tests/AudioEngineTests → repo root is 3 levels up
                let url = URL(fileURLWithPath: bundlePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                srcRoot = url.path
            }
            let filePath = "\(srcRoot)/App/Views/ContentView.swift"
            return try String(contentsOfFile: filePath, encoding: .utf8)
        }
    }

    func test_helpButton_iconSystemName_present() throws {
        let source = try contentViewSource
        XCTAssertTrue(
            source.contains("questionmark.circle"),
            "ContentView.swift must contain 'questionmark.circle' SF Symbol for the Help button"
        )
    }

    func test_helpButton_accessibilityLabel_present() throws {
        let source = try contentViewSource
        XCTAssertTrue(
            source.contains(#""Open User Guide""#),
            "ContentView.swift must contain accessibilityLabel(\"Open User Guide\") for the Help button"
        )
    }

    func test_helpButton_action_usesUserGuideUrl() throws {
        let source = try contentViewSource
        XCTAssertTrue(
            source.contains("NSWorkspace.shared.open(UserGuide.url)"),
            "ContentView.swift must call NSWorkspace.shared.open(UserGuide.url) for the Help button action"
        )
    }

    func test_helpButton_hasPlainButtonStyle() throws {
        let source = try contentViewSource
        // Verify the file has at least two .buttonStyle(.plain) occurrences
        // (one for the existing Settings cog, one for the new Help button)
        let occurrences = source.components(separatedBy: ".buttonStyle(.plain)").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences,
            2,
            "ContentView.swift should have at least 2 .buttonStyle(.plain) buttons (Settings + Help)"
        )
    }

    func test_helpButton_precedesSettingsButton() throws {
        let source = try contentViewSource
        // The Help button's icon must appear before the gearshape in the file
        guard let helpRange = source.range(of: "questionmark.circle"),
              let gearRange = source.range(of: "gearshape") else {
            XCTFail("Could not find expected SF Symbol names in ContentView.swift")
            return
        }
        XCTAssertLessThan(
            helpRange.lowerBound,
            gearRange.lowerBound,
            "Help '?' button must appear before the Settings gearshape button in ContentView.swift"
        )
    }
}
