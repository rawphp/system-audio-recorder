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

/// Emitter whose stream blocks until `release()` is called.
/// Used by synchronous-flip tests to hold `RecordingSession.stop/pause/resume`
/// inside the await while the test observes the pre-await state change.
private final class BlockingFakeEmitter: RecordingSourceEmitter, @unchecked Sendable {
    let id: String
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let cont: AsyncStream<AVAudioPCMBuffer>.Continuation

    init(id: String) {
        self.id = id
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.cont = c
    }

    /// Called by RecordingSession.stop() — does NOT finish the stream, keeping
    /// the session's normalization task alive so stop() stays in the await.
    func stop() { /* intentionally no-op — stream stays open */ }

    /// Finish the stream so the RecordingSession can drain and stop() can return.
    func release() { cont.finish() }
}

/// SessionConfigBuilder that vends a `BlockingFakeEmitter` and exposes it
/// so the test can call `release()` to unblock the session.
private final class BlockingStubSessionConfigBuilder: SessionConfigBuilder, @unchecked Sendable {
    let outputFolder: URL
    private(set) var lastEmitter: BlockingFakeEmitter?

    init(outputFolder: URL) {
        self.outputFolder = outputFolder
    }

    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        let emitter = BlockingFakeEmitter(id: "blocking-stub")
        lastEmitter = emitter
        return SessionConfig(
            sources: [SessionConfig.Source(id: "blocking-stub", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: outputFolder,
            timestamp: "20260510-120000"
        )
    }
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

@MainActor
private func makeBlockingAppStore(tempDir: URL) -> (AppStore, BlockingStubSessionConfigBuilder) {
    let suiteName = "com.tomkaczocha.AppStoreTests.Blocking.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(
        defaults: defaults,
        bookmarkProvider: PassthroughBookmarkProvider(),
        folderCreator: FileManagerFolderCreator()
    )
    let builder = BlockingStubSessionConfigBuilder(outputFolder: tempDir)
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
    return (store, builder)
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
        await store.startRecording(preset: .specificApp(bundleID: "com.example.TestApp"))
        // Note: DefaultSessionConfigBuilder.build for .specificApp currently throws
        // unsupportedPreset (REQ-066 will implement pid resolution); the builder
        // stub in tests does NOT throw, so state reaches .recording.
        try await waitForState(store, expected: .recording)
        XCTAssertEqual(builder.lastPreset, .specificApp(bundleID: "com.example.TestApp"))
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

        await store.startRecording(preset: .specificApp(bundleID: "com.example.TestApp"))

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

    // MARK: - REQ-062: Synchronous state flip before await

    /// `stopRecording()` must flip `sessionState` to `.stopped` (and nil
    /// `currentSession`) BEFORE `await session.stop()` returns.
    /// The test uses a `BlockingFakeEmitter` whose stream stays open so the
    /// session's normalization drain never completes — keeping `stop()` in the
    /// await while the test checks the synchronous state flip.
    func testStopRecordingFlipsStateBeforeAwaitReturns() async throws {
        let (store, builder) = makeBlockingAppStore(tempDir: tempDir)

        // Start recording so state == .recording.
        await store.startRecording(preset: .micOnly)
        try await waitForState(store, expected: .recording)

        // Grab the emitter BEFORE we stop (builder creates it on build()).
        let emitter = try XCTUnwrap(builder.lastEmitter)

        // Kick off stopRecording() in a background task so we can observe mid-flight.
        let stopTask = Task { await store.stopRecording() }

        // Poll until sessionState changes away from .recording, or we time out.
        // The flip must happen before stop() returns (i.e. before emitter.release()).
        let deadline = Date().addingTimeInterval(2.0)
        var flippedBeforeRelease = false
        while Date() < deadline {
            let state = await MainActor.run { store.sessionState }
            if state != .recording {
                flippedBeforeRelease = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }

        // Now release the emitter so session.stop() can drain and the task finishes.
        emitter.release()
        await stopTask.value

        XCTAssertTrue(flippedBeforeRelease,
                      "sessionState must flip away from .recording before session.stop() returns")
        XCTAssertEqual(store.sessionState, .idle,
                       "sessionState must be .idle after stopRecording() completes")
        XCTAssertNil(store.currentSession,
                     "currentSession must be nil after stopRecording() completes")
    }

    /// `pauseRecording()` must flip `sessionState` to `.paused` BEFORE
    /// `await session.pause()` returns.
    func testPauseRecordingFlipsStateBeforeAwaitReturns() async throws {
        let (store, _) = makeBlockingAppStore(tempDir: tempDir)

        await store.startRecording(preset: .micOnly)
        try await waitForState(store, expected: .recording)

        // Capture state synchronously right after calling pause — it must
        // already be .paused by the time we next read it from the main actor.
        let pauseTask = Task {
            try await store.pauseRecording()
        }

        // Spin until state flips or deadline.
        let deadline = Date().addingTimeInterval(2.0)
        var flippedBeforeReturn = false
        while Date() < deadline {
            let state = await MainActor.run { store.sessionState }
            if state == .paused {
                flippedBeforeReturn = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        try await pauseTask.value

        XCTAssertTrue(flippedBeforeReturn,
                      "sessionState must flip to .paused before session.pause() returns")
        XCTAssertEqual(store.sessionState, .paused)
    }

    /// `resumeRecording()` must flip `sessionState` to `.recording` BEFORE
    /// `await session.resume()` returns.
    func testResumeRecordingFlipsStateBeforeAwaitReturns() async throws {
        let (store, builder) = makeBlockingAppStore(tempDir: tempDir)

        await store.startRecording(preset: .micOnly)
        try await waitForState(store, expected: .recording)

        // Pause first so we can resume.
        try await store.pauseRecording()
        try await waitForState(store, expected: .paused)

        let resumeTask = Task {
            try await store.resumeRecording()
        }

        // Spin until state flips back to .recording or deadline.
        let deadline = Date().addingTimeInterval(2.0)
        var flippedBeforeReturn = false
        while Date() < deadline {
            let state = await MainActor.run { store.sessionState }
            if state == .recording {
                flippedBeforeReturn = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        try await resumeTask.value

        XCTAssertTrue(flippedBeforeReturn,
                      "sessionState must flip to .recording before session.resume() returns")
        XCTAssertEqual(store.sessionState, .recording)

        // Clean up: release the blocking emitter and stop.
        let emitter = try XCTUnwrap(builder.lastEmitter)
        emitter.release()
        await store.stopRecording()
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
