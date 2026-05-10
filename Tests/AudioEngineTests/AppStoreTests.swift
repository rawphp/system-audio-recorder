import XCTest
import AVFoundation
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - Test doubles

/// Deterministic SessionConfigBuilder that returns a config with a single
/// no-op `FakeStoreEmitter` source. Records the last preset it was asked to build.
private final class StubSessionConfigBuilder: SessionConfigBuilder, @unchecked Sendable {
    var lastPreset: SourcePreset?
    var buildCount = 0
    var throwOnBuild: Error?

    let outputFolder: URL

    init(outputFolder: URL) {
        self.outputFolder = outputFolder
    }

    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        buildCount += 1
        lastPreset = preset
        if let err = throwOnBuild { throw err }

        let emitter = FakeStoreEmitter(id: "stub")
        return SessionConfig(
            sources: [SessionConfig.Source(id: "stub", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: outputFolder,
            timestamp: "20260510-120000"
        )
    }
}

private final class FakeStoreEmitter: RecordingSourceEmitter, @unchecked Sendable {
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

// MARK: - Helpers

@MainActor
private func makeAppStore(tempDir: URL) -> (AppStore, StubSessionConfigBuilder, AppSettings) {
    let suiteName = "com.tomkaczocha.AppStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(
        defaults: defaults,
        bookmarkProvider: PassthroughBookmarkProvider(),
        folderCreator: FileManagerFolderCreator()
    )
    let builder = StubSessionConfigBuilder(outputFolder: tempDir)
    let store = AppStore(
        settings: settings,
        sourceCatalog: AudioSourceCatalog(provider: EmptyAppStoreProcessListProvider()),
        permissionManager: PermissionManager(
            micProvider: StubMicAuthForAppStore(status: .authorized, requestResult: true)
        ),
        encodingQueue: EncodingQueue(),
        meters: MeterPublisher(),
        sessionConfigBuilder: builder
    )
    return (store, builder, settings)
}

/// Variant that wires a deterministic audio-tap status into `PermissionManager`
/// so tests can exercise the REQ-051 gate without real CoreAudio hardware.
@MainActor
private func makeAppStoreWithTapStatus(
    tempDir: URL,
    tapStatus: AudioTapStatus
) -> (AppStore, StubSessionConfigBuilder, ErrorSurface) {
    let suiteName = "com.tomkaczocha.AppStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(
        defaults: defaults,
        bookmarkProvider: PassthroughBookmarkProvider(),
        folderCreator: FileManagerFolderCreator()
    )
    let builder = StubSessionConfigBuilder(outputFolder: tempDir)
    let permManager = PermissionManager(
        micProvider: StubMicAuthForAppStore(status: .authorized, requestResult: true),
        audioTapProber: { tapStatus }
    )
    let surface = ErrorSurface()
    let store = AppStore(
        settings: settings,
        sourceCatalog: AudioSourceCatalog(provider: EmptyAppStoreProcessListProvider()),
        permissionManager: permManager,
        encodingQueue: EncodingQueue(),
        meters: MeterPublisher(),
        sessionConfigBuilder: builder,
        errorSurface: surface
    )
    return (store, builder, surface)
}

/// In-memory bookmark provider that round-trips a URL via its absoluteString.
private final class PassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        guard let s = String(data: data, encoding: .utf8), let u = URL(string: s) else {
            throw NSError(domain: "test", code: 1)
        }
        return u
    }
}

private struct EmptyAppStoreProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

private final class StubMicAuthForAppStore: MicrophoneAuthorizationProvider {
    var s: AVAuthorizationStatus
    var r: Bool
    init(status: AVAuthorizationStatus, requestResult: Bool) { self.s = status; self.r = requestResult }
    var status: AVAuthorizationStatus { s }
    func requestAccess() async -> Bool { r }
}

// MARK: - AppStoreTests

@MainActor
final class AppStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        XCTAssertEqual(store.sessionState, .idle)
        XCTAssertNil(store.currentSession)
    }

    // MARK: - selectedPreset derives from settings

    func testSelectedPresetDerivesFromSettings() {
        let (store, _, settings) = makeAppStore(tempDir: tempDir)
        XCTAssertEqual(store.selectedPreset, .everything)

        settings.lastSourcePreset = "MicOnly"
        XCTAssertEqual(store.selectedPreset, .micOnly)

        settings.lastSourcePreset = "Everything"
        XCTAssertEqual(store.selectedPreset, .everything)
    }

    // MARK: - toggleRecording state machine (AC #2)

    func testToggleRecordingFromIdleStartsRecording() async throws {
        let (store, builder, _) = makeAppStore(tempDir: tempDir)
        await store.toggleRecording()
        // Wait for state machine to settle
        try await waitForState(store, expected: .recording)
        XCTAssertEqual(store.sessionState, .recording)
        XCTAssertNotNil(store.currentSession)
        XCTAssertEqual(builder.buildCount, 1)
    }

    func testToggleRecordingFromRecordingStops() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        await store.toggleRecording()                   // start
        try await waitForState(store, expected: .recording)
        await store.toggleRecording()                   // stop
        try await waitForState(store, expected: .idle)
        XCTAssertEqual(store.sessionState, .idle)
        XCTAssertNil(store.currentSession)
    }

    func testToggleRecordingFromPausedIsNoOp() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        await store.toggleRecording()                   // start
        try await waitForState(store, expected: .recording)
        try await store.pauseRecording()
        try await waitForState(store, expected: .paused)
        let beforeSession = store.currentSession
        await store.toggleRecording()                   // no-op
        // give the run loop a tick
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.sessionState, .paused)
        XCTAssertTrue(store.currentSession === beforeSession)
    }

    /// AC #1 verification step: idle → recording → idle → recording → idle
    func testToggleRecordingFourTimesProducesExpectedSequence() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)

        XCTAssertEqual(store.sessionState, .idle)

        await store.toggleRecording()
        try await waitForState(store, expected: .recording)

        await store.toggleRecording()
        try await waitForState(store, expected: .idle)

        await store.toggleRecording()
        try await waitForState(store, expected: .recording)

        await store.toggleRecording()
        try await waitForState(store, expected: .idle)
    }

    // MARK: - Pause / resume

    func testPauseResumeLifecycle() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        await store.toggleRecording()
        try await waitForState(store, expected: .recording)

        try await store.pauseRecording()
        try await waitForState(store, expected: .paused)

        try await store.resumeRecording()
        try await waitForState(store, expected: .recording)

        await store.stopRecording()
        try await waitForState(store, expected: .idle)
    }

    // MARK: - Observability (AC verification #2)

    func testCurrentSessionMutationFiresObservation() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        let exp = expectation(description: "observation fires when currentSession mutates")
        exp.assertForOverFulfill = false

        withObservationTracking {
            _ = store.currentSession
        } onChange: {
            exp.fulfill()
        }

        await store.toggleRecording()
        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testSessionStateMutationFiresObservation() async throws {
        let (store, _, _) = makeAppStore(tempDir: tempDir)
        let exp = expectation(description: "observation fires when sessionState mutates")
        exp.assertForOverFulfill = false

        withObservationTracking {
            _ = store.sessionState
        } onChange: {
            exp.fulfill()
        }

        await store.toggleRecording()
        await fulfillment(of: [exp], timeout: 2.0)
    }

    // MARK: - SourcePreset persistence round-trip

    func testStartRecordingPersistsPresetInSettings() async throws {
        let (store, _, settings) = makeAppStore(tempDir: tempDir)
        await store.startRecording(preset: .micOnly)
        try await waitForState(store, expected: .recording)
        XCTAssertEqual(settings.lastSourcePreset, "MicOnly")
        await store.stopRecording()
    }

    // MARK: - SessionConfigBuilder is invoked with the right preset

    func testStartRecordingPassesPresetToBuilder() async throws {
        let (store, builder, _) = makeAppStore(tempDir: tempDir)
        await store.startRecording(preset: .specificApp(processID: 42))
        try await waitForState(store, expected: .recording)
        XCTAssertEqual(builder.lastPreset, .specificApp(processID: 42))
        await store.stopRecording()
    }

    // MARK: - Environment key exists

    func testAppStoreEnvironmentKeyHasDefault() {
        let env = EnvironmentValues()
        // Just verifies the @Environment(\.appStore) extension compiles + has a default value.
        // The default may be a freshly-built `AppStore` (production deps) or `nil`-typed Optional.
        _ = env.appStore
    }

    // MARK: - REQ-051: Fail-fast tap availability gate

    /// When tap status is denied and preset needs the tap, `startRecording` must NOT
    /// start the session (builder.buildCount == 0) and MUST surface an `AppAlert`.
    func testStartRecordingDeniedTapWithEverythingPresetDoesNotStart() async throws {
        let (store, builder, surface) = makeAppStoreWithTapStatus(
            tempDir: tempDir,
            tapStatus: .deniedByPolicy
        )
        // Seed the tap status — refreshAudioTapStatus() schedules async, so set via requestAudioTap()
        _ = await store.permissionManager.requestAudioTap()

        await store.startRecording(preset: .everything)

        XCTAssertEqual(builder.buildCount, 0, "SessionConfigBuilder must NOT be called when tap is denied")
        XCTAssertEqual(store.sessionState, .idle, "Session state must remain idle when tap gate blocks start")
        XCTAssertNotNil(surface.currentAlert, "An AppAlert must be surfaced when the tap gate fires")
        let alert = try XCTUnwrap(surface.currentAlert)
        XCTAssertEqual(alert.secondaryAction, .screenRecording,
                       "Alert's secondary action must deep-link to Screen Recording settings")
    }

    /// The gate must also block `.specificApp` presets since they require the audio tap.
    func testStartRecordingDeniedTapWithSpecificAppPresetDoesNotStart() async throws {
        let (store, builder, surface) = makeAppStoreWithTapStatus(
            tempDir: tempDir,
            tapStatus: .deniedByEntitlement
        )
        _ = await store.permissionManager.requestAudioTap()

        await store.startRecording(preset: .specificApp(processID: 99))

        XCTAssertEqual(builder.buildCount, 0, "Builder must NOT be called for specificApp preset when tap denied")
        XCTAssertEqual(store.sessionState, .idle)
        XCTAssertNotNil(surface.currentAlert)
    }

    /// Mic-only preset MUST bypass the gate entirely — no probe, no rejection.
    func testStartRecordingMicOnlyPresetBypassesTapGate() async throws {
        let (store, builder, surface) = makeAppStoreWithTapStatus(
            tempDir: tempDir,
            tapStatus: .deniedByPolicy
        )
        _ = await store.permissionManager.requestAudioTap()

        await store.startRecording(preset: .micOnly)

        // The builder may throw (no output folder configured in this minimal setup),
        // but the gate itself must NOT block the call — buildCount is incremented.
        XCTAssertGreaterThan(builder.buildCount, 0,
                             "Builder must be called for micOnly even when tap is denied")
        XCTAssertNil(surface.currentAlert,
                     "No tap-gate alert should appear for micOnly preset")
    }

    /// When tap status is `.available`, the gate is a no-op — session starts normally.
    func testStartRecordingAvailableTapAllowsStart() async throws {
        let (store, builder, _) = makeAppStoreWithTapStatus(
            tempDir: tempDir,
            tapStatus: .available
        )
        _ = await store.permissionManager.requestAudioTap()

        await store.startRecording(preset: .everything)

        XCTAssertGreaterThan(builder.buildCount, 0,
                             "Builder must be called when tap is available")
    }
}

// MARK: - Helpers

@MainActor
private func waitForState(
    _ store: AppStore,
    expected: SessionState,
    timeout: TimeInterval = 2.0
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while store.sessionState != expected {
        if Date() >= deadline {
            throw NSError(
                domain: "AppStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for state \(expected); got \(store.sessionState)"]
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
