import XCTest
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - Test doubles

private final class OSVPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        let s = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: s) else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }
}

/// `FolderPicker` stub that always returns a pre-set URL without showing a panel.
private final class StubFolderPicker: FolderPicker {
    var resultURL: URL?
    var callCount = 0

    func pickFolder() -> URL? {
        callCount += 1
        return resultURL
    }
}

// MARK: - Helpers

@MainActor
private func makeSettings(suiteName: String? = nil) -> AppSettings {
    let suite = suiteName ?? "com.test.OSVTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppSettings(
        defaults: defaults,
        bookmarkProvider: OSVPassthroughBookmarkProvider()
    )
}

// MARK: - OutputSettingsViewTests

@MainActor
final class OutputSettingsViewTests: XCTestCase {

    // -----------------------------------------------------------------------
    // AC #1 / TDD 1:
    // init(settings:) snapshots all editable values into the staging copy.
    // -----------------------------------------------------------------------

    func testInitSnapshotsBitrateIntoStage() throws {
        let settings = makeSettings()
        settings.bitrate = 256
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertEqual(vm.stageBitrate, 256, "stageBitrate must mirror settings.bitrate at init")
    }

    func testInitSnapshotsBitrateModeIntoStage() throws {
        let settings = makeSettings()
        settings.bitrateMode = .cbr
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertEqual(vm.stageBitrateMode, .cbr, "stageBitrateMode must mirror settings.bitrateMode at init")
    }

    func testInitSnapshotsOutputModeIntoStage() throws {
        let settings = makeSettings()
        settings.outputMode = .separate
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertEqual(vm.stageOutputMode, .separate, "stageOutputMode must mirror settings.outputMode at init")
    }

    func testInitSnapshotsKeepWAVIntoStage() throws {
        let settings = makeSettings()
        settings.keepWAVAfterEncode = true
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertTrue(vm.stageKeepWAV, "stageKeepWAV must mirror settings.keepWAVAfterEncode at init")
    }

    func testInitSnapshotsShowInDockIntoStage() throws {
        let settings = makeSettings()
        settings.showInDock = false
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertFalse(vm.stageShowInDock, "stageShowInDock must mirror settings.showInDock at init")
    }

    func testInitSnapshotsAutoStopDurationEnabledIntoStage() throws {
        let settings = makeSettings()
        settings.autoStopDurationSeconds = 60.0
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertTrue(vm.stageAutoStopDurationEnabled,
                      "stageAutoStopDurationEnabled must be true when settings.autoStopDurationSeconds is set")
        XCTAssertEqual(vm.stageAutoStopDuration, 60.0, accuracy: 0.001)
    }

    func testInitAutoStopDurationDisabledWhenNil() throws {
        let settings = makeSettings()
        settings.autoStopDurationSeconds = nil
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertFalse(vm.stageAutoStopDurationEnabled,
                       "stageAutoStopDurationEnabled must be false when settings.autoStopDurationSeconds is nil")
    }

    func testInitSnapshotsAutoStopSilenceEnabledIntoStage() throws {
        let settings = makeSettings()
        settings.autoStopSilenceSeconds = 30.0
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertTrue(vm.stageAutoStopSilenceEnabled,
                      "stageAutoStopSilenceEnabled must be true when settings.autoStopSilenceSeconds is set")
        XCTAssertEqual(vm.stageAutoStopSilence, 30.0, accuracy: 0.001)
    }

    func testInitAutoStopSilenceDisabledWhenNil() throws {
        let settings = makeSettings()
        settings.autoStopSilenceSeconds = nil
        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertFalse(vm.stageAutoStopSilenceEnabled,
                       "stageAutoStopSilenceEnabled must be false when settings.autoStopSilenceSeconds is nil")
    }

    // -----------------------------------------------------------------------
    // AC #5 / TDD 2:
    // cancel() does not write any changes back to settings.
    // -----------------------------------------------------------------------

    func testCancelDoesNotMutateSettings() throws {
        let settings = makeSettings()
        settings.bitrate = 192
        settings.bitrateMode = .vbr

        let vm = OutputSettingsViewModel(settings: settings)
        // Mutate the stage
        vm.stageBitrate = 320
        vm.stageBitrateMode = .cbr

        vm.cancel()

        // Settings must be untouched
        XCTAssertEqual(settings.bitrate, 192, "cancel() must not write stageBitrate to settings")
        XCTAssertEqual(settings.bitrateMode, .vbr, "cancel() must not write stageBitrateMode to settings")
    }

    // -----------------------------------------------------------------------
    // AC #5 / TDD 3:
    // done() writes ALL stage fields back to settings.
    // -----------------------------------------------------------------------

    func testDoneWritesBitrateToSettings() throws {
        let settings = makeSettings()
        settings.bitrate = 128

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageBitrate = 320
        vm.done()

        XCTAssertEqual(settings.bitrate, 320, "done() must persist stageBitrate to settings")
    }

    func testDoneWritesBitrateModeToSettings() throws {
        let settings = makeSettings()
        settings.bitrateMode = .vbr

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageBitrateMode = .cbr
        vm.done()

        XCTAssertEqual(settings.bitrateMode, .cbr, "done() must persist stageBitrateMode to settings")
    }

    func testDoneWritesOutputModeToSettings() throws {
        let settings = makeSettings()
        settings.outputMode = .mixed

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageOutputMode = .separate
        vm.done()

        XCTAssertEqual(settings.outputMode, .separate, "done() must persist stageOutputMode to settings")
    }

    func testDoneWritesKeepWAVToSettings() throws {
        let settings = makeSettings()
        settings.keepWAVAfterEncode = false

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageKeepWAV = true
        vm.done()

        XCTAssertTrue(settings.keepWAVAfterEncode, "done() must persist stageKeepWAV to settings")
    }

    func testDoneWritesShowInDockToSettings() throws {
        let settings = makeSettings()
        settings.showInDock = true

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageShowInDock = false
        vm.done()

        XCTAssertFalse(settings.showInDock, "done() must persist stageShowInDock to settings")
    }

    func testDoneWritesAutoStopDurationWhenEnabled() throws {
        let settings = makeSettings()
        settings.autoStopDurationSeconds = nil

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageAutoStopDurationEnabled = true
        vm.stageAutoStopDuration = 90.0
        vm.done()

        XCTAssertEqual(settings.autoStopDurationSeconds, 90.0)
    }

    func testDoneNilsAutoStopDurationWhenDisabled() throws {
        let settings = makeSettings()
        settings.autoStopDurationSeconds = 60.0

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageAutoStopDurationEnabled = false
        vm.done()

        XCTAssertNil(settings.autoStopDurationSeconds,
                     "done() must nil autoStopDurationSeconds when disabled toggle")
    }

    func testDoneWritesAutoStopSilenceWhenEnabled() throws {
        let settings = makeSettings()
        settings.autoStopSilenceSeconds = nil

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageAutoStopSilenceEnabled = true
        vm.stageAutoStopSilence = 30.0
        vm.done()

        XCTAssertEqual(settings.autoStopSilenceSeconds, 30.0)
    }

    func testDoneNilsAutoStopSilenceWhenDisabled() throws {
        let settings = makeSettings()
        settings.autoStopSilenceSeconds = 30.0

        let vm = OutputSettingsViewModel(settings: settings)
        vm.stageAutoStopSilenceEnabled = false
        vm.done()

        XCTAssertNil(settings.autoStopSilenceSeconds,
                     "done() must nil autoStopSilenceSeconds when disabled toggle")
    }

    // -----------------------------------------------------------------------
    // AC #6 / TDD 4:
    // Auto-stop toggle gating: disabling toggle does NOT zero the duration value
    // (preserving the last-entered value so UX remains friendly on re-enable).
    // -----------------------------------------------------------------------

    func testDisablingAutoStopDurationTogglePreservesValue() throws {
        let settings = makeSettings()
        settings.autoStopDurationSeconds = 60.0

        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertEqual(vm.stageAutoStopDuration, 60.0, accuracy: 0.001)

        vm.stageAutoStopDurationEnabled = false

        // The duration value in stage must NOT be zeroed
        XCTAssertEqual(vm.stageAutoStopDuration, 60.0, accuracy: 0.001,
                       "Disabling auto-stop duration toggle must not zero the stage duration value")
    }

    func testDisablingAutoStopSilenceTogglePreservesValue() throws {
        let settings = makeSettings()
        settings.autoStopSilenceSeconds = 30.0

        let vm = OutputSettingsViewModel(settings: settings)
        XCTAssertEqual(vm.stageAutoStopSilence, 30.0, accuracy: 0.001)

        vm.stageAutoStopSilenceEnabled = false

        XCTAssertEqual(vm.stageAutoStopSilence, 30.0, accuracy: 0.001,
                       "Disabling auto-stop silence toggle must not zero the stage silence value")
    }

    // -----------------------------------------------------------------------
    // TDD 5:
    // Folder picker: inject a StubFolderPicker; when pickFolder() returns a URL,
    // it is stored in settings on done().
    // -----------------------------------------------------------------------

    func testSelectFolderStoresFolderOnDone() throws {
        let settings = makeSettings()
        let pickerStub = StubFolderPicker()
        let folderURL = URL(fileURLWithPath: "/tmp/MyRecordings")
        pickerStub.resultURL = folderURL

        let vm = OutputSettingsViewModel(settings: settings, folderPicker: pickerStub)
        vm.selectFolder()

        XCTAssertEqual(pickerStub.callCount, 1, "selectFolder() must invoke the picker exactly once")

        vm.done()

        // Verify the folder was stored: outputFolderURL resolves to the picked URL.
        let stored = settings.outputFolderURL
        XCTAssertEqual(stored?.absoluteString, folderURL.absoluteString,
                       "done() must persist the picked folder URL via setOutputFolder")
    }

    func testSelectFolderNoOpWhenPickerReturnNil() throws {
        let settings = makeSettings()
        let pickerStub = StubFolderPicker()
        pickerStub.resultURL = nil

        // Seed an initial folder
        let initial = URL(fileURLWithPath: "/tmp/Initial")
        settings.setOutputFolder(initial)

        let vm = OutputSettingsViewModel(settings: settings, folderPicker: pickerStub)
        vm.selectFolder()

        vm.done()

        // Folder must remain unchanged
        let stored = settings.outputFolderURL
        XCTAssertEqual(stored?.absoluteString, initial.absoluteString,
                       "When picker returns nil, folder must not be changed")
    }

    // -----------------------------------------------------------------------
    // Compile-time contract: OutputSettingsView instantiates.
    // -----------------------------------------------------------------------

    func testOutputSettingsViewInstantiates() throws {
        let settings = makeSettings()
        var isPresented = true
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let view = OutputSettingsView(isPresented: binding, settings: settings)
        _ = view
        XCTAssert(true, "OutputSettingsView must compile and instantiate without error")
    }
}
