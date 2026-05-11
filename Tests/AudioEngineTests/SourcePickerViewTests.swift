import XCTest
import AVFoundation
import CoreAudio
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - Test doubles

/// Stub mic provider: fixed status, no actual prompt.
private final class SPTestMicProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    var _status: AVAuthorizationStatus
    init(status: AVAuthorizationStatus) { self._status = status }
    var status: AVAuthorizationStatus { _status }
    func requestAccess() async -> Bool { _status == .authorized }
}

private final class SPPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data { url.absoluteString.data(using: .utf8) ?? Data() }
    func resolve(data: Data) throws -> URL {
        let s = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: s) else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }
}

private struct SPEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

// MARK: - Helpers

@MainActor
private func makeSettings(lastPreset: String = "Everything") -> AppSettings {
    let defaults = UserDefaults(suiteName: "com.tomkaczocha.SPTests.\(UUID().uuidString)")!
    let s = AppSettings(defaults: defaults, bookmarkProvider: SPPassthroughBookmarkProvider())
    s.lastSourcePreset = lastPreset
    return s
}

@MainActor
private func makePermissionManager(
    mic: AVAuthorizationStatus,
    tapAvailable: Bool
) -> PermissionManager {
    let pm = PermissionManager(micProvider: SPTestMicProvider(status: mic))
    // Force audioTapStatus synchronously via a Task that we run immediately.
    // We set it via the helper that exercises the public surface.
    // Because we can't set it directly, we expose it through the ViewModel tests instead.
    _ = tapAvailable // used by ViewModel directly
    return pm
}

// MARK: - SourcePickerViewModelTests

@MainActor
final class SourcePickerViewModelTests: XCTestCase {

    // -----------------------------------------------------------------------
    // AC #1: Default selected item is "Everything" on first launch
    // -----------------------------------------------------------------------
    func testDefaultSelectedItemIsEverything() {
        let settings = makeSettings(lastPreset: "Everything")
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertEqual(vm.selectedPresetKey, "Everything")
    }

    // -----------------------------------------------------------------------
    // AC #1: Loads persisted non-default preset from AppSettings
    // -----------------------------------------------------------------------
    func testLoadsPersistedPresetFromSettings() {
        let settings = makeSettings(lastPreset: "MicOnly")
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertEqual(vm.selectedPresetKey, "MicOnly")
    }

    // -----------------------------------------------------------------------
    // AC #2: Selecting an item updates AppSettings.lastSourcePreset immediately
    // -----------------------------------------------------------------------
    func testSelectingItemPersistsToSettings() {
        let settings = makeSettings(lastPreset: "Everything")
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.select(.micOnly)

        XCTAssertEqual(settings.lastSourcePreset, "MicOnly")
        XCTAssertEqual(vm.selectedPresetKey, "MicOnly")
    }

    func testSelectingEverythingPersistsToSettings() {
        let settings = makeSettings(lastPreset: "MicOnly")
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.select(.everything)

        XCTAssertEqual(settings.lastSourcePreset, "Everything")
    }

    func testSelectingEverythingPlusMicPersistsToSettings() {
        let settings = makeSettings(lastPreset: "Everything")
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.select(.everythingPlusMic)

        XCTAssertEqual(settings.lastSourcePreset, "EverythingPlusMic")
    }

    // -----------------------------------------------------------------------
    // AC #3: When mic permission is denied, mic-involving items are greyed
    // -----------------------------------------------------------------------
    func testMicDeniedGreysOutMicItems() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .denied))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertTrue(vm.isDisabled(.everythingPlusMic), "EverythingPlusMic should be disabled when mic is denied")
        XCTAssertTrue(vm.isDisabled(.micOnly), "MicOnly should be disabled when mic is denied")
    }

    func testMicAuthorizedEnablesMicItems() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        // Simulate audio tap available
        vm.overrideAudioTapAvailable = true

        XCTAssertFalse(vm.isDisabled(.everythingPlusMic), "EverythingPlusMic should be enabled when mic is authorized")
        XCTAssertFalse(vm.isDisabled(.micOnly), "MicOnly should be enabled when mic is authorized")
    }

    // -----------------------------------------------------------------------
    // AC #4: When audio-tap is denied, all items except "Microphone only" are greyed
    // -----------------------------------------------------------------------
    func testAudioTapDeniedGreysNonMicItems() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapAvailable = false

        XCTAssertTrue(vm.isDisabled(.everything), "Everything should be disabled when audio tap is denied")
        XCTAssertTrue(vm.isDisabled(.everythingPlusMic), "EverythingPlusMic should be disabled when audio tap is denied")
        XCTAssertTrue(vm.isDisabled(.specificApp), "SpecificApp should be disabled when audio tap is denied")
        XCTAssertFalse(vm.isDisabled(.micOnly), "MicOnly should NOT be disabled when audio tap is denied")
    }

    func testAudioTapAvailableEnablesNonMicItems() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapAvailable = true

        XCTAssertFalse(vm.isDisabled(.everything), "Everything should be enabled when audio tap is available")
        XCTAssertFalse(vm.isDisabled(.specificApp), "SpecificApp should be enabled when audio tap is available")
    }

    // -----------------------------------------------------------------------
    // AC #3: showMicDeniedAffordance returns true for mic-involving items when denied
    // -----------------------------------------------------------------------
    func testShowMicDeniedAffordanceWhenDenied() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .denied))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertTrue(vm.showMicDeniedAffordance(for: .everythingPlusMic))
        XCTAssertTrue(vm.showMicDeniedAffordance(for: .micOnly))
        XCTAssertFalse(vm.showMicDeniedAffordance(for: .everything))
        XCTAssertFalse(vm.showMicDeniedAffordance(for: .specificApp))
    }

    func testShowMicDeniedAffordanceFalseWhenAuthorized() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertFalse(vm.showMicDeniedAffordance(for: .everythingPlusMic))
        XCTAssertFalse(vm.showMicDeniedAffordance(for: .micOnly))
    }

    // -----------------------------------------------------------------------
    // AC #5: "Specific app…" sheet state is managed by the view model
    // -----------------------------------------------------------------------
    func testShowAppPickerStartsFalse() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertFalse(vm.showAppPicker)
    }

    func testOpenAppPickerSetsFlag() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.openAppPicker()

        XCTAssertTrue(vm.showAppPicker)
    }

    // -----------------------------------------------------------------------
    // AC #6: "Advanced…" sheet state is managed by the view model
    // -----------------------------------------------------------------------
    func testShowMixerPanelStartsFalse() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertFalse(vm.showMixerPanel)
    }

    func testOpenMixerPanelSetsFlag() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.openMixerPanel()

        XCTAssertTrue(vm.showMixerPanel)
    }

    // -----------------------------------------------------------------------
    // Selecting a specific app process updates selectedPresetKey and settings
    // -----------------------------------------------------------------------
    func testSelectingSpecificAppProcess() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.selectProcess(bundleID: "com.example.TestApp")

        XCTAssertEqual(settings.lastSourcePreset, "SpecificApp:com.example.TestApp")
        XCTAssertEqual(vm.selectedPresetKey, "SpecificApp:com.example.TestApp")
    }

    // -----------------------------------------------------------------------
    // availableItems returns all 5 picker items
    // -----------------------------------------------------------------------
    func testAvailableItemsContainsFiveItems() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertEqual(vm.availableItems.count, 5)
    }

    func testAvailableItemsOrder() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        XCTAssertEqual(vm.availableItems[0], .everything)
        XCTAssertEqual(vm.availableItems[1], .everythingPlusMic)
        XCTAssertEqual(vm.availableItems[2], .micOnly)
        XCTAssertEqual(vm.availableItems[3], .specificApp)
        XCTAssertEqual(vm.availableItems[4], .advanced)
    }

    // -----------------------------------------------------------------------
    // REQ-049: onMenuOpen() must invoke refreshAudioTapStatus() on PermissionManager
    // -----------------------------------------------------------------------

    /// Calling `onMenuOpen()` must invoke `PermissionManager.refreshAudioTapStatus()`,
    /// which in turn calls the injected `audioTapProber`. This test guards the
    /// menu-open → re-probe wiring contract: if `onMenuOpen()` is removed or
    /// stops calling `refreshAudioTapStatus()`, `proberCallCount` stays 0 and
    /// the test fails.
    func testOnMenuOpenCallsRefreshAudioTapStatus() async {
        var proberCallCount = 0
        let settings = makeSettings()
        let pm = PermissionManager(
            micProvider: SPTestMicProvider(status: .authorized),
            audioTapProber: {
                proberCallCount += 1
                return .available
            }
        )
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        let countBefore = proberCallCount
        vm.onMenuOpen()

        // refreshAudioTapStatus() schedules an async Task; yield to let it run.
        await Task.yield()
        await Task.yield()

        XCTAssertGreaterThan(proberCallCount, countBefore,
            "onMenuOpen() must invoke PermissionManager.refreshAudioTapStatus(), " +
            "which calls the audio-tap prober at least once")
    }

    /// `onMenuOpen()` must trigger a re-probe on every call, not just the first.
    /// This ensures that subsequent entitlement changes are reflected each time
    /// the user opens the menu.
    func testOnMenuOpenCallsRefreshOnEveryInvocation() async {
        var proberCallCount = 0
        let settings = makeSettings()
        let pm = PermissionManager(
            micProvider: SPTestMicProvider(status: .authorized),
            audioTapProber: {
                proberCallCount += 1
                return .available
            }
        )
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        // First open
        let countBefore = proberCallCount
        vm.onMenuOpen()
        await Task.yield()
        await Task.yield()
        let countAfterFirst = proberCallCount
        XCTAssertGreaterThan(countAfterFirst, countBefore,
            "First onMenuOpen() must trigger a re-probe")

        // Second open
        vm.onMenuOpen()
        await Task.yield()
        await Task.yield()
        XCTAssertGreaterThan(proberCallCount, countAfterFirst,
            "Second onMenuOpen() must also trigger a re-probe (not just the first)")
    }

    // -----------------------------------------------------------------------
    // REQ-050: showTapDeniedAffordance — three-state seam (denied / available / unknown)
    // -----------------------------------------------------------------------

    /// AC #1 (denied): When overrideAudioTapStatus is .deniedByEntitlement,
    /// showTapDeniedAffordance returns true for tap-needing items.
    func testShowTapDeniedAffordanceWhenDeniedByEntitlement() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapStatus = .deniedByEntitlement

        XCTAssertTrue(vm.showTapDeniedAffordance(for: .everything),
            "everything should show tap-denied affordance when status is .deniedByEntitlement")
        XCTAssertTrue(vm.showTapDeniedAffordance(for: .everythingPlusMic),
            "everythingPlusMic should show tap-denied affordance when status is .deniedByEntitlement")
        XCTAssertTrue(vm.showTapDeniedAffordance(for: .specificApp),
            "specificApp should show tap-denied affordance when status is .deniedByEntitlement")
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .micOnly),
            "micOnly must NOT show tap-denied affordance (it does not need the tap)")
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .advanced),
            "advanced must NOT show tap-denied affordance (it does not need the tap)")
    }

    /// AC #1 (denied): When overrideAudioTapStatus is .deniedByPolicy,
    /// showTapDeniedAffordance returns true for tap-needing items.
    func testShowTapDeniedAffordanceWhenDeniedByPolicy() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapStatus = .deniedByPolicy

        XCTAssertTrue(vm.showTapDeniedAffordance(for: .everything))
        XCTAssertTrue(vm.showTapDeniedAffordance(for: .everythingPlusMic))
        XCTAssertTrue(vm.showTapDeniedAffordance(for: .specificApp))
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .micOnly))
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .advanced))
    }

    /// AC #2 (available): When overrideAudioTapStatus is .available,
    /// showTapDeniedAffordance returns false for all items.
    func testShowTapDeniedAffordanceFalseWhenAvailable() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapStatus = .available

        XCTAssertFalse(vm.showTapDeniedAffordance(for: .everything))
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .everythingPlusMic))
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .specificApp))
    }

    /// AC #3 (unknown / transient): When overrideAudioTapStatus is .unknown,
    /// showTapDeniedAffordance must return false — items render disabled (not affordance).
    func testShowTapDeniedAffordanceFalseWhenUnknown() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        vm.overrideAudioTapStatus = .unknown

        XCTAssertFalse(vm.showTapDeniedAffordance(for: .everything),
            ".unknown must NOT show the affordance — items should render as disabled instead")
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .everythingPlusMic))
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .specificApp))
    }

    /// Regression guard: existing Boolean override seam (overrideAudioTapAvailable)
    /// still works correctly when overrideAudioTapStatus is nil.
    func testExistingBooleanSeamUnaffectedByNewSeam() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        // Both seams nil — falls back to real permissionManager.audioTapStatus (.unknown initially)
        vm.overrideAudioTapAvailable = false
        // overrideAudioTapStatus is nil — must not interfere with the bool seam

        // When the bool seam says false, tap items are disabled
        XCTAssertTrue(vm.isDisabled(.everything))
        XCTAssertTrue(vm.isDisabled(.specificApp))

        // And the tap-denied affordance must NOT appear (bool seam doesn't carry denial signal)
        XCTAssertFalse(vm.showTapDeniedAffordance(for: .everything),
            "overrideAudioTapAvailable=false alone must not trigger the denied affordance")
    }
}
