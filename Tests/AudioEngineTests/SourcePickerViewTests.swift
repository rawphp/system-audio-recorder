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
    // Selecting a specific app bundle updates selectedPresetKey and settings
    // (REQ-068: renamed from selectProcess to selectBundle)
    // -----------------------------------------------------------------------
    func testSelectingSpecificAppProcess() {
        let settings = makeSettings()
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let catalog = AudioSourceCatalog(provider: SPEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        vm.selectBundle(bundleID: "com.example.TestApp")

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

// MARK: - SourcePickerViewModelBundleTests (REQ-068)

/// Tests for selectBundle(bundleID:) and currentSelectionLabel bundle-ID resolution.
@MainActor
final class SourcePickerViewModelBundleTests: XCTestCase {

    // -----------------------------------------------------------------------
    // Stub catalog provider that returns a fixed list of processes.
    // Used to exercise currentSelectionLabel without real HAL queries.
    //
    // Overrides executableName(for:) with the fixture displayName so that
    // AudioSourceCatalog.refresh() builds the correct displayName even when
    // NSRunningApplication returns nil for the fixture PIDs (which it always
    // does, since these are synthetic PIDs that don't correspond to real processes).
    // -----------------------------------------------------------------------
    private struct FixedProcessListProvider: ProcessListProvider {
        let fixedProcesses: [AudioProcess]
        init(_ processes: [AudioProcess] = []) { self.fixedProcesses = processes }
        func audioProcessObjectIDs() -> [AudioObjectID] { fixedProcesses.indices.map { AudioObjectID($0 + 1) } }
        func pid(for objectID: AudioObjectID) -> pid_t? {
            let idx = Int(objectID) - 1
            guard fixedProcesses.indices.contains(idx) else { return nil }
            return fixedProcesses[idx].pid
        }
        func bundleID(for objectID: AudioObjectID) -> String? {
            let idx = Int(objectID) - 1
            guard fixedProcesses.indices.contains(idx) else { return nil }
            return fixedProcesses[idx].bundleID
        }
        /// Return the fixture displayName so refresh() uses it as the process label.
        func executableName(for objectID: AudioObjectID) -> String? {
            let idx = Int(objectID) - 1
            guard fixedProcesses.indices.contains(idx) else { return nil }
            return fixedProcesses[idx].displayName
        }
    }

    private func makeVM(
        lastPreset: String = "Everything",
        processes: [AudioProcess] = []
    ) -> (SourcePickerViewModel, AppSettings) {
        let settings = makeSettings(lastPreset: lastPreset)
        let pm = PermissionManager(micProvider: SPTestMicProvider(status: .authorized))
        let provider = FixedProcessListProvider(processes)
        let catalog = AudioSourceCatalog(provider: provider)
        catalog.refresh()
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)
        return (vm, settings)
    }

    // -----------------------------------------------------------------------
    // REQ-068 AC: selectBundle sets SpecificApp:<bundleID> and dismisses sheet
    // -----------------------------------------------------------------------
    func testSelectBundleSetsBundleKeyAndDismissesPicker() {
        let (vm, settings) = makeVM()
        vm.showAppPicker = true

        vm.selectBundle(bundleID: "com.google.Chrome")

        XCTAssertEqual(settings.lastSourcePreset, "SpecificApp:com.google.Chrome",
            "selectBundle must write SpecificApp:<bundleID> to settings")
        XCTAssertEqual(vm.selectedPresetKey, "SpecificApp:com.google.Chrome")
        XCTAssertFalse(vm.showAppPicker, "selectBundle must dismiss the app picker sheet")
    }

    // -----------------------------------------------------------------------
    // currentSelectionLabel: parent-backed group → display name from catalog
    //
    // We use PIDs well above the macOS process limit (~99999) so
    // NSRunningApplication(processIdentifier:) returns nil — the implementation
    // then falls back to the catalog's displayName (step 2).
    // -----------------------------------------------------------------------
    func testCurrentSelectionLabelUsesDisplayNameWhenCatalogHasParent() {
        // Use impossibly large PIDs so NSRunningApplication returns nil → catalog fallback fires.
        let chromePID: pid_t = 99_001
        let processes: [AudioProcess] = [
            AudioProcess(pid: chromePID, bundleID: "com.google.Chrome", displayName: "Google Chrome", icon: nil),
            AudioProcess(pid: 99_002, bundleID: "com.google.Chrome.helper", displayName: "Chrome Helper", icon: nil),
        ]
        let (vm, _) = makeVM(processes: processes)

        vm.selectBundle(bundleID: "com.google.Chrome")

        XCTAssertEqual(vm.currentSelectionLabel, "Google Chrome",
            "Label should resolve to the catalog's displayName for the parent process when NSRunningApplication returns nil")
    }

    // -----------------------------------------------------------------------
    // currentSelectionLabel: orphan bundle (no parent in catalog) → raw bundleID
    // -----------------------------------------------------------------------
    func testCurrentSelectionLabelReturnsRawBundleIDForOrphan() {
        // "com.orphan.thing.helper" exists, but no parent "com.orphan.thing".
        // Use a large PID so NSRunningApplication returns nil (no real process at that PID).
        let processes: [AudioProcess] = [
            AudioProcess(pid: 99_003, bundleID: "com.orphan.thing.helper", displayName: "thing Helper", icon: nil),
        ]
        let (vm, _) = makeVM(processes: processes)

        vm.selectBundle(bundleID: "com.orphan.thing")

        XCTAssertEqual(vm.currentSelectionLabel, "com.orphan.thing",
            "Label should be raw bundle ID when pids exist but no parent matches")
    }

    // -----------------------------------------------------------------------
    // currentSelectionLabel: no pids at all → "Specific app" fallback
    // -----------------------------------------------------------------------
    func testCurrentSelectionLabelFallsBackToSpecificAppWhenNoPidsMatch() {
        let (vm, _) = makeVM(processes: []) // empty catalog

        vm.selectBundle(bundleID: "com.something.not.running")

        XCTAssertEqual(vm.currentSelectionLabel, "Specific app",
            "Label should fall back to 'Specific app' when no pids match the bundle")
    }

    // -----------------------------------------------------------------------
    // Legacy SpecificApp:<numeric-pid> does not crash; resolves via new path
    // which finds no pids → "Specific app" (REQ-064 makes this unreachable in
    // practice since the preset falls back to .everything upstream)
    // -----------------------------------------------------------------------
    func testLegacyNumericPidPresetDoesNotCrash() {
        // Load the VM with a legacy-format settings key directly (bypassing selectBundle)
        let (vm, _) = makeVM(lastPreset: "SpecificApp:1234", processes: [])

        // Must not crash; label resolves through new bundle-ID path:
        // "1234" is not a valid bundle ID, pids(forBundle: "1234") returns [] → "Specific app"
        let label = vm.currentSelectionLabel
        XCTAssertEqual(label, "Specific app",
            "Legacy numeric pid key must not crash; resolves to 'Specific app' fallback")
    }

    // -----------------------------------------------------------------------
    // selectProcess(bundleID:) must NOT exist — only selectBundle(bundleID:)
    // (compile-time check: this test file must compile with selectBundle only)
    // -----------------------------------------------------------------------
    func testSelectBundleAPIExists() {
        let (vm, _) = makeVM()
        // If selectBundle(bundleID:) doesn't exist, this won't compile.
        vm.selectBundle(bundleID: "com.test.App")
        XCTAssertEqual(vm.selectedPresetKey, "SpecificApp:com.test.App")
    }
}

// MARK: - AppPickerGroupTests (REQ-067)

/// Tests for the AppPickerGroup grouping logic extracted from AppPickerView.
final class AppPickerGroupTests: XCTestCase {

    // -----------------------------------------------------------------------
    // Fixture helper: build a minimal AudioProcess without NSRunningApplication
    // -----------------------------------------------------------------------
    private func process(pid: pid_t, bundleID: String, displayName: String, icon: NSImage? = nil) -> AudioProcess {
        AudioProcess(pid: pid, bundleID: bundleID, displayName: displayName, icon: icon)
    }

    // -----------------------------------------------------------------------
    // AC #1: 5-process fixture → 3 groups in correct order
    // -----------------------------------------------------------------------
    func testFixtureProducesThreeGroupsInOrder() {
        let chromeIcon = NSImage()
        let safariIcon = NSImage()

        let processes: [AudioProcess] = [
            process(pid: 100, bundleID: "com.google.Chrome",         displayName: "Google Chrome", icon: chromeIcon),
            process(pid: 101, bundleID: "com.google.Chrome.helper",  displayName: "Chrome Helper",  icon: nil),
            process(pid: 102, bundleID: "com.google.Chrome.helper.GPU", displayName: "Chrome Helper (GPU)", icon: nil),
            process(pid: 103, bundleID: "com.apple.Safari",          displayName: "Safari",         icon: safariIcon),
            process(pid: 104, bundleID: "com.orphan.thing.helper",   displayName: "thing Helper",   icon: nil),
        ]

        let groups = AppPickerGroup.groups(from: processes)

        XCTAssertEqual(groups.count, 3, "Expected 3 picker rows")

        // Row 0: Google Chrome (parent-backed)
        XCTAssertEqual(groups[0].bundleID, "com.google.Chrome")
        XCTAssertEqual(groups[0].displayName, "Google Chrome")
        XCTAssertTrue(groups[0].icon === chromeIcon, "Chrome row should have the parent's icon")
        XCTAssertFalse(groups[0].isOrphan)

        // Row 1: Safari (parent-backed)
        XCTAssertEqual(groups[1].bundleID, "com.apple.Safari")
        XCTAssertEqual(groups[1].displayName, "Safari")
        XCTAssertTrue(groups[1].icon === safariIcon, "Safari row should have the parent's icon")
        XCTAssertFalse(groups[1].isOrphan)

        // Row 2: orphan (no parent process for com.orphan.thing)
        XCTAssertEqual(groups[2].bundleID, "com.orphan.thing")
        XCTAssertEqual(groups[2].displayName, "com.orphan.thing")
        XCTAssertNil(groups[2].icon)
        XCTAssertTrue(groups[2].isOrphan)
    }

    // -----------------------------------------------------------------------
    // AC #2: selecting Chrome row → onSelect called with groupKey, not a pid
    // -----------------------------------------------------------------------
    func testSelectingChromeRowEmitsGroupKey() {
        let processes: [AudioProcess] = [
            process(pid: 100, bundleID: "com.google.Chrome",        displayName: "Google Chrome"),
            process(pid: 101, bundleID: "com.google.Chrome.helper", displayName: "Chrome Helper"),
        ]

        let groups = AppPickerGroup.groups(from: processes)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bundleID, "com.google.Chrome",
            "onSelect should receive the groupKey (bundleID), not a pid")
    }

    // -----------------------------------------------------------------------
    // AC #3: selecting orphan row → onSelect called with stripped bundle ID
    // -----------------------------------------------------------------------
    func testSelectingOrphanRowEmitsStrippedBundleID() {
        let processes: [AudioProcess] = [
            process(pid: 104, bundleID: "com.orphan.thing.helper", displayName: "thing Helper"),
        ]

        let groups = AppPickerGroup.groups(from: processes)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bundleID, "com.orphan.thing",
            "Orphan row should carry the stripped bundle ID")
    }

    // -----------------------------------------------------------------------
    // AC #4: parent-backed groups appear before orphan groups; both alphabetical
    // -----------------------------------------------------------------------
    func testSortingParentBeforeOrphansAndAlphabetical() {
        let processes: [AudioProcess] = [
            process(pid: 1, bundleID: "com.zzz.orphan.helper",     displayName: "zzz Helper"),
            process(pid: 2, bundleID: "com.beta.App",              displayName: "Beta App"),
            process(pid: 3, bundleID: "com.aaa.orphan.helper",     displayName: "aaa Helper"),
            process(pid: 4, bundleID: "com.alpha.App",             displayName: "Alpha App"),
        ]

        let groups = AppPickerGroup.groups(from: processes)

        // Parents first (alphabetical by displayName), then orphans (alphabetical by bundleID)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[0].bundleID, "com.alpha.App")
        XCTAssertEqual(groups[1].bundleID, "com.beta.App")
        XCTAssertEqual(groups[2].bundleID, "com.aaa.orphan")
        XCTAssertEqual(groups[3].bundleID, "com.zzz.orphan")
    }

    // -----------------------------------------------------------------------
    // AC #5: empty catalog → empty groups array
    // -----------------------------------------------------------------------
    func testEmptyCatalogProducesEmptyGroups() {
        let groups = AppPickerGroup.groups(from: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // -----------------------------------------------------------------------
    // Edge: .helper boundary — .helperish does NOT fold under parent
    // -----------------------------------------------------------------------
    func testHelperishSuffixDoesNotFold() {
        let processes: [AudioProcess] = [
            process(pid: 1, bundleID: "com.google.Chrome",         displayName: "Google Chrome"),
            process(pid: 2, bundleID: "com.google.Chromehelper",   displayName: "Chromehelper"),
        ]

        let groups = AppPickerGroup.groups(from: processes)
        // Chromehelper has no dot separator → should NOT fold under Chrome
        XCTAssertEqual(groups.count, 2)
    }
}
