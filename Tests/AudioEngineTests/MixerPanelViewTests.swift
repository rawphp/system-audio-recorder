import XCTest
import AVFoundation
import CoreAudio
import SwiftUI
@testable import SystemAudioToMP3

// MARK: - Test doubles (file-private, REQ-028)

private final class MPTestMicProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    var _status: AVAuthorizationStatus
    init(status: AVAuthorizationStatus) { self._status = status }
    var status: AVAuthorizationStatus { _status }
    func requestAccess() async -> Bool { _status == .authorized }
}

private final class MPPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data { url.absoluteString.data(using: .utf8) ?? Data() }
    func resolve(data: Data) throws -> URL {
        let s = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: s) else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }
}

private struct MPEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

private struct MPStubProcessListProvider: ProcessListProvider {
    let procs: [(AudioObjectID, pid_t)]
    init(procs: [(AudioObjectID, pid_t)]) { self.procs = procs }
    func audioProcessObjectIDs() -> [AudioObjectID] { procs.map(\.0) }
    func pid(for objectID: AudioObjectID) -> pid_t? {
        procs.first { $0.0 == objectID }?.1
    }
}

@MainActor
private func makeSettings(suiteName: String? = nil) -> AppSettings {
    let suite = suiteName ?? "com.test.MPTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return AppSettings(defaults: defaults, bookmarkProvider: MPPassthroughBookmarkProvider())
}

@MainActor
private func makePermissionManager(mic: AVAuthorizationStatus = .authorized) -> PermissionManager {
    PermissionManager(micProvider: MPTestMicProvider(status: mic))
}

@MainActor
private func makeAppStore(settings: AppSettings, permissionManager: PermissionManager) -> AppStore {
    AppStore(
        settings: settings,
        sourceCatalog: AudioSourceCatalog(provider: MPEmptyProcessListProvider()),
        permissionManager: permissionManager,
        encodingQueue: EncodingQueue(),
        meters: MeterPublisher(),
        sessionConfigBuilder: MPNoOpSessionConfigBuilder()
    )
}

@MainActor
private final class MPNoOpSessionConfigBuilder: SessionConfigBuilder {
    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        let emitter = MPNoOpEmitter(id: "noop")
        return SessionConfig(
            sources: [SessionConfig.Source(id: "noop", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()),
            timestamp: "20260510-000000"
        )
    }
}

private final class MPNoOpEmitter: RecordingSourceEmitter, @unchecked Sendable {
    let id: String
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let cont: AsyncStream<AVAudioPCMBuffer>.Continuation
    init(id: String) {
        self.id = id
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.cont = c
    }
    func stop() { cont.finish() }
}

// MARK: - MixerPanelViewModelTests

@MainActor
final class MixerPanelViewModelTests: XCTestCase {

    // -----------------------------------------------------------------------
    // AC #1: Panel lists every entry from AudioSourceCatalog plus a mic row
    // -----------------------------------------------------------------------

    func testRowsIncludeCatalogProcessesPlusMic() {
        let settings = makeSettings()
        let pm = makePermissionManager(mic: .authorized)
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        // Inject 2 fake processes into the catalog
        let proc1 = AudioProcess(pid: 100, bundleID: "com.app.one", displayName: "AppOne", icon: nil)
        let proc2 = AudioProcess(pid: 200, bundleID: "com.app.two", displayName: "AppTwo", icon: nil)
        appStore.sourceCatalog.processes = [proc1, proc2]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)

        // Should have 2 catalog rows + 1 mic row = 3
        XCTAssertEqual(vm.rows.count, 3)

        // First two are catalog entries
        XCTAssertEqual(vm.rows[0].id, "pid:100")
        XCTAssertEqual(vm.rows[0].name, "AppOne")
        XCTAssertEqual(vm.rows[1].id, "pid:200")
        XCTAssertEqual(vm.rows[1].name, "AppTwo")

        // Last row is the mic row
        XCTAssertEqual(vm.rows[2].id, "mic")
        XCTAssertEqual(vm.rows[2].name, "Microphone")
    }

    func testEmptyCatalogStillHasMicRow() {
        let settings = makeSettings()
        let pm = makePermissionManager(mic: .authorized)
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        // No processes in catalog
        appStore.sourceCatalog.processes = []

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows[0].id, "mic")
    }

    // -----------------------------------------------------------------------
    // AC #2: Each row tracks selected and gain with correct defaults
    // -----------------------------------------------------------------------

    func testDefaultGainIsOne() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 1, bundleID: "com.a", displayName: "A", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)

        XCTAssertEqual(vm.rows[0].gain, 1.0, accuracy: 1e-5)
        XCTAssertEqual(vm.rows[1].gain, 1.0, accuracy: 1e-5) // mic row
    }

    func testDefaultSelectedIsFalse() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 1, bundleID: "com.a", displayName: "A", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)

        XCTAssertFalse(vm.rows[0].selected)
        XCTAssertFalse(vm.rows[1].selected)
    }

    // -----------------------------------------------------------------------
    // AC #4: Apply persists selected source IDs + gains, sets preset to "Advanced"
    // -----------------------------------------------------------------------

    func testApplyWritesSelectedSourceIDsToSettings() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 10, bundleID: "com.a", displayName: "A", icon: nil),
            AudioProcess(pid: 20, bundleID: "com.b", displayName: "B", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        // Select row 0 and the mic row (index 2)
        vm.rows[0].selected = true
        vm.rows[2].selected = true

        vm.apply()

        let saved = settings.advancedSourceIDs
        XCTAssertTrue(saved.contains("pid:10"), "Selected process ID should be persisted")
        XCTAssertTrue(saved.contains("mic"), "Selected mic ID should be persisted")
        XCTAssertFalse(saved.contains("pid:20"), "Unselected process should not be persisted")
    }

    func testApplySetsLastPresetToAdvanced() {
        let settings = makeSettings()
        settings.lastSourcePreset = "Everything"
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        vm.apply()

        XCTAssertEqual(settings.lastSourcePreset, "Advanced")
    }

    func testApplyWritesGainsToSettings() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 10, bundleID: "com.a", displayName: "A", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        vm.rows[0].selected = true
        vm.rows[0].gain = 1.5

        vm.apply()

        let savedGains = settings.advancedGains
        XCTAssertEqual(savedGains["pid:10"] ?? 0.0, Float(1.5), accuracy: Float(1e-5))
    }

    // -----------------------------------------------------------------------
    // AC #5: Cancel reverts to previous preset; does NOT write to settings
    // -----------------------------------------------------------------------

    func testCancelDoesNotPersistSelectedSources() {
        let settings = makeSettings()
        settings.lastSourcePreset = "MicOnly"
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 10, bundleID: "com.a", displayName: "A", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        vm.rows[0].selected = true

        vm.cancel()

        // Settings should not be mutated
        XCTAssertEqual(settings.lastSourcePreset, "MicOnly", "Preset must remain unchanged after cancel")
        XCTAssertTrue(settings.advancedSourceIDs.isEmpty, "advancedSourceIDs must not be written on cancel")
    }

    func testCancelPreservesExistingPreset() {
        let settings = makeSettings()
        settings.lastSourcePreset = "Everything"
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        vm.cancel()

        XCTAssertEqual(settings.lastSourcePreset, "Everything")
    }

    // -----------------------------------------------------------------------
    // AC #3: setGain calls mixer.setGain immediately (view-model level: mutates row.gain)
    // -----------------------------------------------------------------------

    func testSetGainMutatesRowGain() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        appStore.sourceCatalog.processes = [
            AudioProcess(pid: 10, bundleID: "com.a", displayName: "A", icon: nil)
        ]

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        vm.setGain(forID: "pid:10", to: 0.75)

        XCTAssertEqual(vm.rows[0].gain, 0.75, accuracy: 1e-5)
    }

    func testSetGainForUnknownIDIsNoOp() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        // Should not crash
        vm.setGain(forID: "unknown:999", to: 0.5)
        XCTAssertTrue(true) // just verifies no crash
    }

    // -----------------------------------------------------------------------
    // AC #6: Mic row is greyed when mic permission is denied
    // -----------------------------------------------------------------------

    func testMicRowIsGreyedWhenDenied() {
        let settings = makeSettings()
        let pm = makePermissionManager(mic: .denied)
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)

        // The mic row is the last row
        let micRow = vm.rows.last!
        XCTAssertEqual(micRow.id, "mic")
        XCTAssertTrue(vm.isMicRowGreyed, "Mic row must be greyed when mic permission is denied")
    }

    func testMicRowIsNotGreyedWhenAuthorized() {
        let settings = makeSettings()
        let pm = makePermissionManager(mic: .authorized)
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        XCTAssertFalse(vm.isMicRowGreyed)
    }

    func testMicRowIsGreyedWhenRestricted() {
        let settings = makeSettings()
        let pm = makePermissionManager(mic: .restricted)
        let appStore = makeAppStore(settings: settings, permissionManager: pm)

        let vm = MixerPanelViewModel(appStore: appStore, settings: settings)
        XCTAssertTrue(vm.isMicRowGreyed)
    }

    // -----------------------------------------------------------------------
    // AppSettings v2 schema: advancedSourceIDs and advancedGains defaults
    // -----------------------------------------------------------------------

    func testAdvancedSourceIDsDefaultsToEmpty() {
        let settings = makeSettings()
        XCTAssertTrue(settings.advancedSourceIDs.isEmpty)
    }

    func testAdvancedGainsDefaultsToEmpty() {
        let settings = makeSettings()
        XCTAssertTrue(settings.advancedGains.isEmpty)
    }

    func testAdvancedSourceIDsRoundTrip() {
        let settings = makeSettings()
        settings.advancedSourceIDs = ["pid:100", "mic"]
        XCTAssertEqual(settings.advancedSourceIDs, ["pid:100", "mic"])
    }

    func testAdvancedGainsRoundTrip() {
        let settings = makeSettings()
        settings.advancedGains = ["pid:100": 1.5, "mic": 0.8]
        XCTAssertEqual(settings.advancedGains["pid:100"]!, 1.5, accuracy: 1e-5)
        XCTAssertEqual(settings.advancedGains["mic"]!, 0.8, accuracy: 1e-5)
    }

    /// Schema migration: v2 keys do not corrupt existing v1 keys
    func testV2KeysDoNotCorruptV1Keys() {
        let suiteName = "com.test.MPMigration.\(UUID().uuidString)"

        // Simulate v1 state
        let v1Defaults = UserDefaults(suiteName: suiteName)!
        v1Defaults.set(320, forKey: "bitrate")
        v1Defaults.set("CBR", forKey: "bitrateMode")
        v1Defaults.synchronize()

        // Create AppSettings (which adds v2 keys with defaults on access)
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(defaults: defaults, bookmarkProvider: MPPassthroughBookmarkProvider())

        // v1 keys must be intact
        XCTAssertEqual(settings.bitrate, 320)
        XCTAssertEqual(settings.bitrateMode, BitrateMode.cbr)

        // v2 keys have correct defaults
        XCTAssertTrue(settings.advancedSourceIDs.isEmpty)
        XCTAssertTrue(settings.advancedGains.isEmpty)

        // Writing v2 keys does not corrupt v1
        settings.advancedSourceIDs = ["pid:5"]
        XCTAssertEqual(settings.bitrate, 320, "v1 bitrate must survive v2 write")
    }

    // -----------------------------------------------------------------------
    // MixerPanelView compile-time contract
    // -----------------------------------------------------------------------

    func testMixerPanelViewInstantiates() {
        let settings = makeSettings()
        let pm = makePermissionManager()
        let appStore = makeAppStore(settings: settings, permissionManager: pm)
        var isPresented = true
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let view = MixerPanelView(isPresented: binding)
            .environment(\.appStore, appStore)
        _ = view
        XCTAssert(true, "MixerPanelView must compile and instantiate without error")
    }
}
