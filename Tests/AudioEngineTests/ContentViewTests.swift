import XCTest
import AVFoundation
import CoreAudio
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - Test doubles

/// Stub PermissionManager provider that records requestMicrophone call count.
private final class CVTestMicProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    var requestCount = 0
    let status: AVAuthorizationStatus

    init(status: AVAuthorizationStatus = .authorized) {
        self.status = status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        return status == .authorized
    }
}

private final class CVPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        let str = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: str) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }
}

private struct CVEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

@MainActor
private final class CVNoOpSessionConfigBuilder: SessionConfigBuilder {
    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        let emitter = CVNoOpEmitter(id: "noop")
        return SessionConfig(
            sources: [SessionConfig.Source(id: "noop", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()),
            timestamp: "20260510-000000"
        )
    }
}

private final class CVNoOpEmitter: RecordingSourceEmitter, @unchecked Sendable {
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

// MARK: - ContentViewTests

@MainActor
final class ContentViewTests: XCTestCase {

    // -----------------------------------------------------------------------
    // AC #1 / TDD contract 1:
    // ContentView compiles and can be instantiated with an injected AppStore.
    // This is a compile-time / type-check test — if it builds, it passes.
    // -----------------------------------------------------------------------
    func testContentViewInstantiatesWithAppStore() throws {
        let store = makeStore()
        let sut = ContentView()
            .environment(\.appStore, store)
        _ = sut
        XCTAssert(true, "ContentView instantiated without compiler error")
    }

    // -----------------------------------------------------------------------
    // AC #4 / TDD contract 2:
    // Simply constructing ContentView with a fresh AppStore must NOT call
    // requestMicrophone() or any other permission API.
    // -----------------------------------------------------------------------
    func testContentViewDoesNotTriggerPermissionPrompt() throws {
        let countingProvider = CVTestMicProvider(status: .notDetermined)
        let store = makeStore(micProvider: countingProvider)
        let _ = ContentView()
            .environment(\.appStore, store)
        XCTAssertEqual(
            countingProvider.requestCount, 0,
            "ContentView construction must not call requestMicrophone()"
        )
    }

    // -----------------------------------------------------------------------
    // AC #3 / TDD contract 3:
    // ContentViewModel.showSettings starts false and toggles to true on
    // `openSettings()`, which models the settings-cog tap.
    // -----------------------------------------------------------------------
    func testContentViewModelShowSettingsToggles() {
        let vm = ContentViewModel()
        XCTAssertFalse(vm.showSettings, "showSettings should be false initially")
        vm.openSettings()
        XCTAssertTrue(vm.showSettings, "showSettings should be true after openSettings()")
    }

    // -----------------------------------------------------------------------
    // AC #5: Title is "System Audio Recorder"
    // We verify ContentViewModel carries the correct title constant.
    // -----------------------------------------------------------------------
    func testContentViewModelTitleIsCorrect() {
        let vm = ContentViewModel()
        XCTAssertEqual(vm.title, "System Audio Recorder")
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(micProvider: MicrophoneAuthorizationProvider? = nil) -> AppStore {
        let suiteName = "com.tomkaczocha.ContentViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: CVPassthroughBookmarkProvider(),
            folderCreator: FileManagerFolderCreator()
        )
        let mic = micProvider ?? CVTestMicProvider(status: .authorized)
        return AppStore(
            settings: settings,
            sourceCatalog: AudioSourceCatalog(provider: CVEmptyProcessListProvider()),
            permissionManager: PermissionManager(micProvider: mic),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: CVNoOpSessionConfigBuilder()
        )
    }
}
