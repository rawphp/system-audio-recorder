import XCTest
@testable import SystemAudioRecorder

// MARK: - SourcePresetTests (REQ-064)

/// Tests covering `SourcePreset` bundle-keyed payload introduced in REQ-064.
///
/// The key behaviour changes:
/// - `.specificApp` now carries a `bundleID: String` rather than `processID: pid_t`.
/// - `settingsKey` emits `SpecificApp:<bundleID>` (e.g. "SpecificApp:com.google.Chrome").
/// - `from(settingsKey:)` parses bundle-keyed values and round-trips correctly.
/// - Legacy `SpecificApp:<numeric-pid>` values silently fall back to `.everything`.
/// - Empty bundle IDs (`SpecificApp:`) are rejected and fall back to `.everything`.
final class SourcePresetTests: XCTestCase {

    // -----------------------------------------------------------------------
    // settingsKey encoding
    // -----------------------------------------------------------------------

    func testSettingsKeyForEverything() {
        XCTAssertEqual(SourcePreset.everything.settingsKey, "Everything")
    }

    func testSettingsKeyForMicOnly() {
        XCTAssertEqual(SourcePreset.micOnly.settingsKey, "MicOnly")
    }

    func testSettingsKeyForSpecificAppWithBundleID() {
        let preset = SourcePreset.specificApp(bundleID: "com.google.Chrome")
        XCTAssertEqual(preset.settingsKey, "SpecificApp:com.google.Chrome")
    }

    func testSettingsKeyForSpecificAppWithElectronBundleID() {
        let preset = SourcePreset.specificApp(bundleID: "com.microsoft.VSCode")
        XCTAssertEqual(preset.settingsKey, "SpecificApp:com.microsoft.VSCode")
    }

    // -----------------------------------------------------------------------
    // from(settingsKey:) — well-formed bundle-ID values
    // -----------------------------------------------------------------------

    func testFromSettingsKeyEverything() {
        XCTAssertEqual(SourcePreset.from(settingsKey: "Everything"), .everything)
    }

    func testFromSettingsKeyMicOnly() {
        XCTAssertEqual(SourcePreset.from(settingsKey: "MicOnly"), .micOnly)
    }

    func testFromSettingsKeySpecificAppBundleIDRoundTrip() {
        let parsed = SourcePreset.from(settingsKey: "SpecificApp:com.google.Chrome")
        XCTAssertEqual(parsed, .specificApp(bundleID: "com.google.Chrome"),
                       "Bundle-ID keyed value must round-trip through settingsKey ↔ from(settingsKey:)")
    }

    func testFromSettingsKeySpecificAppAnotherBundleID() {
        let parsed = SourcePreset.from(settingsKey: "SpecificApp:com.microsoft.VSCode")
        XCTAssertEqual(parsed, .specificApp(bundleID: "com.microsoft.VSCode"))
    }

    // -----------------------------------------------------------------------
    // from(settingsKey:) — legacy pid-keyed fallback (REQ-064 AC #4)
    // -----------------------------------------------------------------------

    /// Old persisted `SpecificApp:<numeric-pid>` values must silently fall back
    /// to `.everything` (not crash, not parse as a bundle ID).
    func testLegacyNumericPIDFallsBackToEverything() {
        let result = SourcePreset.from(settingsKey: "SpecificApp:1234")
        XCTAssertEqual(result, .everything,
                       "Legacy numeric-PID key 'SpecificApp:1234' must fall back to .everything")
    }

    func testLegacyNumericPIDZeroFallsBackToEverything() {
        let result = SourcePreset.from(settingsKey: "SpecificApp:0")
        XCTAssertEqual(result, .everything,
                       "Legacy numeric-PID key 'SpecificApp:0' must fall back to .everything")
    }

    func testLegacyLargePIDFallsBackToEverything() {
        let result = SourcePreset.from(settingsKey: "SpecificApp:99999")
        XCTAssertEqual(result, .everything,
                       "Legacy large numeric-PID key must fall back to .everything")
    }

    // -----------------------------------------------------------------------
    // from(settingsKey:) — empty bundle ID (REQ-064 AC #5)
    // -----------------------------------------------------------------------

    /// `SpecificApp:` with an empty suffix must be rejected and fall back to `.everything`.
    func testEmptyBundleIDFallsBackToEverything() {
        let result = SourcePreset.from(settingsKey: "SpecificApp:")
        XCTAssertEqual(result, .everything,
                       "Empty bundle ID 'SpecificApp:' must fall back to .everything")
    }

    // -----------------------------------------------------------------------
    // from(settingsKey:) — unknown / garbage values
    // -----------------------------------------------------------------------

    func testUnknownKeyFallsBackToEverything() {
        XCTAssertEqual(SourcePreset.from(settingsKey: "garbage"), .everything)
    }

    func testEmptyKeyFallsBackToEverything() {
        XCTAssertEqual(SourcePreset.from(settingsKey: ""), .everything)
    }

    // -----------------------------------------------------------------------
    // Full round-trip: settingsKey → from(settingsKey:) → settingsKey
    // -----------------------------------------------------------------------

    func testRoundTripEverything() {
        let preset = SourcePreset.everything
        XCTAssertEqual(SourcePreset.from(settingsKey: preset.settingsKey), preset)
    }

    func testRoundTripMicOnly() {
        let preset = SourcePreset.micOnly
        XCTAssertEqual(SourcePreset.from(settingsKey: preset.settingsKey), preset)
    }

    func testRoundTripSpecificApp() {
        let preset = SourcePreset.specificApp(bundleID: "com.google.Chrome")
        XCTAssertEqual(SourcePreset.from(settingsKey: preset.settingsKey), preset)
    }
}
