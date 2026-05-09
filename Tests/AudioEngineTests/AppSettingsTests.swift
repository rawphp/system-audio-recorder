import XCTest
import Foundation
@testable import SystemAudioRecorder

// MARK: - AppSettingsTests
// REQ-021: Settings persistence with UserDefaults schema and security-scoped output bookmark

@MainActor
final class AppSettingsTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a fresh `AppSettings` backed by an ephemeral, isolated UserDefaults suite.
    /// Using a unique UUID for each test guarantees no cross-test pollution.
    private func makeFreshSettings(suiteName: String? = nil) -> AppSettings {
        let suite = suiteName ?? "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return AppSettings(defaults: defaults, bookmarkProvider: StubBookmarkProvider())
    }

    // MARK: - AC #1 + AC #5: Default values match spec Section 6.2

    func testDefaultBitrateIs192() {
        let settings = makeFreshSettings()
        XCTAssertEqual(settings.bitrate, 192, "Default bitrate must be 192 kbps per spec §6.2")
    }

    func testDefaultBitrateModeIsVBR() {
        let settings = makeFreshSettings()
        XCTAssertEqual(settings.bitrateMode, BitrateMode.vbr, "Default bitrateMode must be VBR per spec §6.2")
    }

    func testDefaultOutputModeIsMixed() {
        let settings = makeFreshSettings()
        XCTAssertEqual(settings.outputMode, AppOutputMode.mixed, "Default outputMode must be .mixed per spec §6.2")
    }

    func testDefaultKeepWAVIsFalse() {
        let settings = makeFreshSettings()
        XCTAssertFalse(settings.keepWAVAfterEncode, "Default keepWAVAfterEncode must be false per spec §6.2")
    }

    func testDefaultHotkeyIsUnset() {
        let settings = makeFreshSettings()
        XCTAssertNil(settings.hotkey, "Default hotkey must be nil (unset) per spec §6.2")
    }

    func testDefaultLastSourcePresetIsEverything() {
        let settings = makeFreshSettings()
        XCTAssertEqual(settings.lastSourcePreset, "Everything",
                       "Default lastSourcePreset must be 'Everything' per spec §6.2")
    }

    func testDefaultMicDeviceIDIsNil() {
        let settings = makeFreshSettings()
        // nil means system default
        XCTAssertNil(settings.micDeviceID, "Default micDeviceID must be nil (system default) per spec §6.2")
    }

    func testDefaultShowInDockIsTrue() {
        let settings = makeFreshSettings()
        XCTAssertTrue(settings.showInDock, "Default showInDock must be true per spec §6.2")
    }

    func testDefaultAutoStopDurationIsNil() {
        let settings = makeFreshSettings()
        XCTAssertNil(settings.autoStopDurationSeconds,
                     "Default autoStopDurationSeconds must be nil (off) per spec §6.2")
    }

    func testDefaultAutoStopSilenceIsNil() {
        let settings = makeFreshSettings()
        XCTAssertNil(settings.autoStopSilenceSeconds,
                     "Default autoStopSilenceSeconds must be nil (off) per spec §6.2")
    }

    // MARK: - AC #2: Output folder defaults to ~/Music/Recordings

    func testDefaultOutputFolderURL() {
        let settings = makeFreshSettings()
        // The stub bookmark provider returns the URL it was asked to store.
        // On first access with no persisted bookmark, settings should surface nil or the stub default.
        // Because StubBookmarkProvider.resolve returns nil (no real file), and the directory
        // creation path produces the ~/Music/Recordings URL, we accept either the computed
        // default URL or nil (if the stub resolves to nil).
        // The important contract is that AppSettings tried to create ~/Music/Recordings.
        let musicURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        let expected = musicURL.appendingPathComponent("Recordings")
        XCTAssertEqual(settings.defaultOutputFolderURL, expected,
                       "Default output folder must be ~/Music/Recordings per spec §6.2")
    }

    // MARK: - AC #4 + AC #5 (persistence): writes round-trip through UserDefaults

    func testBitrateRoundTrip() {
        let settings = makeFreshSettings()
        settings.bitrate = 256
        XCTAssertEqual(settings.bitrate, 256)
    }

    func testBitrateModeRoundTrip() {
        let settings = makeFreshSettings()
        settings.bitrateMode = .cbr
        XCTAssertEqual(settings.bitrateMode, BitrateMode.cbr)
    }

    func testOutputModeRoundTrip() {
        let settings = makeFreshSettings()
        settings.outputMode = .separate
        XCTAssertEqual(settings.outputMode, AppOutputMode.separate)
    }

    func testKeepWAVRoundTrip() {
        let settings = makeFreshSettings()
        settings.keepWAVAfterEncode = true
        XCTAssertTrue(settings.keepWAVAfterEncode)
    }

    func testLastSourcePresetRoundTrip() {
        let settings = makeFreshSettings()
        settings.lastSourcePreset = "Music"
        XCTAssertEqual(settings.lastSourcePreset, "Music")
    }

    func testShowInDockRoundTrip() {
        let settings = makeFreshSettings()
        settings.showInDock = false
        XCTAssertFalse(settings.showInDock)
    }

    func testAutoStopDurationRoundTrip() {
        let settings = makeFreshSettings()
        settings.autoStopDurationSeconds = 60.0
        XCTAssertEqual(settings.autoStopDurationSeconds, 60.0)
    }

    func testAutoStopSilenceRoundTrip() {
        let settings = makeFreshSettings()
        settings.autoStopSilenceSeconds = 5.0
        XCTAssertEqual(settings.autoStopSilenceSeconds, 5.0)
    }

    func testMicDeviceIDRoundTrip() {
        let settings = makeFreshSettings()
        settings.micDeviceID = "device-42"
        XCTAssertEqual(settings.micDeviceID, "device-42")
    }

    // MARK: - AC #5: Persistence across instances (simulated "relaunch")

    /// Sets bitrate to 256 on one AppSettings instance backed by a named suite,
    /// then creates a fresh instance pointing at the same suite and reads it back.
    /// This is the in-process relaunch simulation described in the REQ brief.
    func testBitratePersistsAcrossInstances() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let first = AppSettings(defaults: defaults, bookmarkProvider: StubBookmarkProvider())
        first.bitrate = 256
        defaults.synchronize()

        let secondDefaults = UserDefaults(suiteName: suiteName)!
        let second = AppSettings(defaults: secondDefaults, bookmarkProvider: StubBookmarkProvider())
        XCTAssertEqual(second.bitrate, 256,
                       "bitrate written by first instance must be readable by second (relaunch sim)")
    }

    func testBitrateModePeristsAcrossInstances() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let first = AppSettings(defaults: defaults, bookmarkProvider: StubBookmarkProvider())
        first.bitrateMode = .cbr
        defaults.synchronize()

        let secondDefaults = UserDefaults(suiteName: suiteName)!
        let second = AppSettings(defaults: secondDefaults, bookmarkProvider: StubBookmarkProvider())
        XCTAssertEqual(second.bitrateMode, BitrateMode.cbr,
                       "bitrateMode written by first instance must be readable by second (relaunch sim)")
    }

    // MARK: - AC #6: Schema migration — new v2 keys don't corrupt existing v1 keys

    func testSchemaMigrationDoesNotCorruptV1Keys() {
        let suiteName = "test-\(UUID().uuidString)"

        // Simulate v1 state: set some keys manually
        let v1Defaults = UserDefaults(suiteName: suiteName)!
        v1Defaults.set(320, forKey: "bitrate")
        v1Defaults.set("CBR", forKey: "bitrateMode")
        v1Defaults.synchronize()

        // Now create AppSettings (which adds new keys with defaults if absent)
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults, bookmarkProvider: StubBookmarkProvider())

        // v1 keys must be unchanged
        XCTAssertEqual(settings.bitrate, 320, "v1 bitrate must be preserved after schema migration")
        XCTAssertEqual(settings.bitrateMode, BitrateMode.cbr, "v1 bitrateMode must be preserved after schema migration")

        // A new v2 key (e.g., micDeviceID) must have its default (nil) without corrupting v1 keys
        XCTAssertNil(settings.micDeviceID, "v2 key micDeviceID must have default nil when absent from v1")

        // Re-read v1 keys to ensure they are still intact
        XCTAssertEqual(settings.bitrate, 320, "bitrate must still be 320 after reading micDeviceID")
    }

    // MARK: - AC #7: Bookmark resolution failure surfaces SettingsError

    func testBookmarkResolutionFailureSetsLastBookmarkError() {
        let stub = StubBookmarkProvider()
        stub.shouldFailResolve = true
        stub.hasStoredBookmark = true

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        // Store a dummy bookmark data so AppSettings tries to resolve it
        defaults.set(Data([0x00, 0x01]), forKey: AppSettings.Keys.outputFolderBookmark)

        let settings = AppSettings(defaults: defaults, bookmarkProvider: stub)
        // Trigger resolution by accessing outputFolderURL
        let url = settings.outputFolderURL
        XCTAssertNil(url, "outputFolderURL must be nil when bookmark resolution fails")
        XCTAssertNotNil(settings.lastBookmarkError,
                        "lastBookmarkError must be set when bookmark resolution fails")
    }

    func testOutputFolderUnavailableErrorType() {
        let stub = StubBookmarkProvider()
        stub.shouldFailResolve = true
        stub.hasStoredBookmark = true

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.set(Data([0x00, 0x01]), forKey: AppSettings.Keys.outputFolderBookmark)

        let settings = AppSettings(defaults: defaults, bookmarkProvider: stub)
        _ = settings.outputFolderURL

        if case .outputFolderUnavailable = settings.lastBookmarkError {
            // expected
        } else {
            XCTFail("Expected SettingsError.outputFolderUnavailable, got \(String(describing: settings.lastBookmarkError))")
        }
    }

    // MARK: - AC #8: Output folder creation failure falls back to temp dir

    func testCreationFailureFallsBackToTempDir() {
        let stub = StubBookmarkProvider()
        stub.shouldFailStore = true

        // Use an AppSettings with a failing folder creator
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: stub,
            folderCreator: FailingFolderCreator()
        )

        // Trigger the fallback by reading the folder URL (which will try to create the directory)
        let fallbackURL = settings.resolvedOutputFolder()
        XCTAssertNotNil(fallbackURL, "resolvedOutputFolder must return non-nil fallback URL when default creation fails")

        // The fallback must be in NSTemporaryDirectory
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
        if let fallback = fallbackURL {
            XCTAssertTrue(fallback.path.hasPrefix(tempBase.path),
                          "Fallback output folder must be under NSTemporaryDirectory, got: \(fallback.path)")
        }
    }

    func testCreationFailureSetsLastFolderCreationError() {
        let stub = StubBookmarkProvider()

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: stub,
            folderCreator: FailingFolderCreator()
        )

        _ = settings.resolvedOutputFolder()
        XCTAssertNotNil(settings.lastFolderCreationError,
                        "lastFolderCreationError must be set when default output folder creation fails")
    }

    // MARK: - Bookmark storage via stub

    func testSetOutputFolderStoresBookmark() {
        let stub = StubBookmarkProvider()
        let settings = makeFreshSettings()
        let url = URL(fileURLWithPath: "/tmp/test-recordings")
        settings.setOutputFolder(url)
        // The stub records the URL it was asked to bookmark
        XCTAssertEqual(stub.lastStoredURL, nil, // <-- makeFreshSettings doesn't pass *this* stub
                       "setOutputFolder must call bookmarkProvider.store(url:)")
        // Use a settings that has *this* stub
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings2 = AppSettings(defaults: defaults, bookmarkProvider: stub)
        settings2.setOutputFolder(url)
        XCTAssertEqual(stub.lastStoredURL, url, "store must be called with the provided URL")
    }
}

// MARK: - StubBookmarkProvider

/// Test double for `BookmarkProvider`. Avoids real security-scoped bookmark API
/// calls (which require an actual on-disk file and entitlements).
final class StubBookmarkProvider: BookmarkProvider {
    var shouldFailResolve = false
    var shouldFailStore = false
    var hasStoredBookmark = false
    var lastStoredURL: URL?
    var resolvedURL: URL?

    func store(url: URL) throws -> Data {
        lastStoredURL = url
        if shouldFailStore {
            throw NSError(domain: "StubBookmarkProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Stub: store failed"])
        }
        // Return dummy data
        return Data([0xDE, 0xAD, 0xBE, 0xEF])
    }

    func resolve(data: Data) throws -> URL {
        if shouldFailResolve {
            throw NSError(domain: "StubBookmarkProvider", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Stub: bookmark stale/invalid"])
        }
        return resolvedURL ?? URL(fileURLWithPath: "/tmp/stub-recordings")
    }
}

// MARK: - FailingFolderCreator

/// Test double that always fails to create directories.
struct FailingFolderCreator: FolderCreating {
    func createDirectory(at url: URL) throws {
        throw NSError(domain: "FailingFolderCreator", code: Int(EACCES),
                      userInfo: [NSLocalizedDescriptionKey: "Stub: permission denied"])
    }
}
