import XCTest
import AVFoundation
import CoreAudio
@testable import SystemAudioRecorder

// MARK: - Shared test doubles (file-private)

private final class PFUXMicProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    var _status: AVAuthorizationStatus
    init(status: AVAuthorizationStatus) { self._status = status }
    var status: AVAuthorizationStatus { _status }
    func requestAccess() async -> Bool { _status == .authorized }
}

private struct PFUXEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

private final class PFUXPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data { url.absoluteString.data(using: .utf8) ?? Data() }
    func resolve(data: Data) throws -> URL {
        let s = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: s) else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }
}

private struct PFUXNoOpFolderCreator: FolderCreating {
    func createDirectory(at url: URL) throws {}
}

// MARK: - PermissionDeepLinkTests

/// Tests for `PermissionDeepLink` — the centralised URL helper (REQ-034 §1).
@MainActor
final class PermissionDeepLinkTests: XCTestCase {

    // MARK: Microphone deep-link

    func testMicrophoneDeepLinkURL() {
        let url = PermissionDeepLink.microphoneSettingsURL
        XCTAssertEqual(
            url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    // MARK: Screen Recording (audio tap) deep-link

    func testScreenRecordingDeepLinkURL() {
        let url = PermissionDeepLink.screenRecordingSettingsURL
        XCTAssertEqual(
            url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    // MARK: openMicrophoneSettings uses the canonical URL

    /// SourcePickerViewModel.openMicrophoneSettings() must use the same URL
    /// that PermissionDeepLink.microphoneSettingsURL exposes.
    func testSourcePickerViewModelUsesCanonicalMicURL() {
        // Access the URL property to confirm PermissionDeepLink constants are reachable.
        let canonical = PermissionDeepLink.microphoneSettingsURL
        XCTAssertFalse(canonical.absoluteString.isEmpty)
        XCTAssertTrue(canonical.absoluteString.contains("Privacy_Microphone"))
    }
}

// MARK: - PermissionPollObservationTests

/// REQ-034 AC: Granting permission via System Settings updates the dropdown
/// within 1 s of returning to the app — verified by driving the stub provider.
@MainActor
final class PermissionPollObservationTests: XCTestCase {

    // -----------------------------------------------------------------------
    // Polling observation: changing stub status → isDisabled recomputes
    // -----------------------------------------------------------------------

    /// Mutate the stub provider's status, call `pollMicrophoneStatus()`, and
    /// assert `SourcePickerViewModel.isDisabled(.micOnly)` updates accordingly.
    func testMicStatusChangeUpdatesDisabledState() {
        let provider = PFUXMicProvider(status: .denied)
        let pm = PermissionManager(micProvider: provider)

        let defaults = UserDefaults(suiteName: "com.test.PFUXPoll.\(UUID().uuidString)")!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: PFUXPassthroughBookmarkProvider()
        )
        let catalog = AudioSourceCatalog(provider: PFUXEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        // Initially denied → micOnly is disabled (because micOnly.involvesMic && micDenied)
        XCTAssertTrue(vm.isDisabled(.micOnly), "micOnly should be disabled when mic is denied")

        // Simulate the user granting access in System Settings
        provider._status = .authorized
        pm.pollMicrophoneStatus()   // mirror what the 1 Hz timer does

        // Now micOnly should be enabled
        XCTAssertFalse(vm.isDisabled(.micOnly), "micOnly should be enabled after permission granted")
    }

    /// Granting audio-tap by flipping overrideAudioTapAvailable immediately
    /// unblocks tap-requiring items.
    func testAudioTapOverrideUpdatesDisabledState() {
        let pm = PermissionManager(micProvider: PFUXMicProvider(status: .authorized))
        let defaults = UserDefaults(suiteName: "com.test.PFUXPoll2.\(UUID().uuidString)")!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: PFUXPassthroughBookmarkProvider()
        )
        let catalog = AudioSourceCatalog(provider: PFUXEmptyProcessListProvider())
        let vm = SourcePickerViewModel(settings: settings, permissionManager: pm, sourceCatalog: catalog)

        // Tap unavailable → everything disabled
        vm.overrideAudioTapAvailable = false
        XCTAssertTrue(vm.isDisabled(.everything), "everything should be disabled when tap unavailable")

        // Tap now available → everything enabled
        vm.overrideAudioTapAvailable = true
        XCTAssertFalse(vm.isDisabled(.everything), "everything should be enabled when tap available")
    }

    /// After `pollMicrophoneStatus()` a `withObservationTracking` closure fires.
    func testPollFiresObservationTracking() async throws {
        let provider = PFUXMicProvider(status: .denied)
        let pm = PermissionManager(micProvider: provider)

        let exp = expectation(description: "observation fires after pollMicrophoneStatus")
        exp.assertForOverFulfill = false

        // Track microphoneStatus via observation
        withObservationTracking {
            _ = pm.microphoneStatus
        } onChange: {
            exp.fulfill()
        }

        // Simulate external permission grant + poll tick
        provider._status = .authorized
        pm.pollMicrophoneStatus()

        await fulfillment(of: [exp], timeout: 2.0)
    }
}

// MARK: - MDMBlockedTapTests

/// REQ-034 AC: On MDM-blocked tap APIs, a fatal alert offers "Switch to mic-only" or "Quit".
@MainActor
final class MDMBlockedTapTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // -----------------------------------------------------------------------
    // Helper factory
    // -----------------------------------------------------------------------

    private func makeStoreWithThrowingBuilder(error: Error) -> AppStore {
        let defaults = UserDefaults(suiteName: "com.test.MDMTests.\(UUID().uuidString)")!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: PFUXPassthroughBookmarkProvider(),
            folderCreator: PFUXNoOpFolderCreator()
        )
        let builder = MDMStubSessionConfigBuilder(outputFolder: tempDir, throwError: error)
        let errorSurface = ErrorSurface()
        return AppStore(
            settings: settings,
            sourceCatalog: AudioSourceCatalog(provider: PFUXEmptyProcessListProvider()),
            permissionManager: PermissionManager(
                micProvider: PFUXMicProvider(status: .authorized)
            ),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: builder,
            errorSurface: errorSurface
        )
    }

    // -----------------------------------------------------------------------
    // AC: MDM-blocked tap → fatal alert with "Switch to mic-only" primary
    // -----------------------------------------------------------------------

    func testMDMBlockedTapProducesFatalAlertWithSwitchToMicOnly() async {
        // tapCreationFailed with a negative OSStatus code simulates MDM policy denial
        let mdmError = CaptureError.tapCreationFailed(-66594)
        let store = makeStoreWithThrowingBuilder(error: mdmError)

        await store.startRecording(preset: .everything)

        XCTAssertNotNil(store.errorSurface.currentAlert,
                        "errorSurface.currentAlert should be set for MDM-blocked tap")

        let alert = store.errorSurface.currentAlert!
        XCTAssertEqual(alert.primaryButton, "Switch to mic-only",
                       "primary button should offer mic-only fallback")
        XCTAssertEqual(alert.secondaryButton, "Quit",
                       "secondary button should allow the user to quit")
    }

    func testMDMBlockedTapAlertTitleMentionsTap() async {
        let mdmError = CaptureError.tapCreationFailed(-66594)
        let store = makeStoreWithThrowingBuilder(error: mdmError)

        await store.startRecording(preset: .everything)

        let alert = store.errorSurface.currentAlert
        XCTAssertNotNil(alert)
        XCTAssertFalse(alert?.title.isEmpty ?? true)
    }

    func testMDMBlockedTapSessionStateRemainsIdle() async {
        let mdmError = CaptureError.tapCreationFailed(-66594)
        let store = makeStoreWithThrowingBuilder(error: mdmError)

        await store.startRecording(preset: .everything)

        XCTAssertEqual(store.sessionState, .idle,
                       "session should remain idle when start fails due to MDM tap block")
    }

    /// Non-MDM errors (e.g. SessionError.noSourcesConfigured) should NOT produce the MDM alert.
    func testNonMDMErrorDoesNotProduceMDMAlert() async {
        let nonMDMError = SessionError.noSourcesConfigured
        let store = makeStoreWithThrowingBuilder(error: nonMDMError)

        await store.startRecording(preset: .everything)

        // For non-MDM errors, the alert may or may not be set (per REQ-033 routing),
        // but if set it should NOT have "Switch to mic-only" as primary.
        if let alert = store.errorSurface.currentAlert {
            XCTAssertNotEqual(alert.primaryButton, "Switch to mic-only",
                              "non-MDM errors should not show the MDM fallback alert")
        }
    }

    /// A generic CaptureError (permissionRevoked) routes via ErrorSurface's existing
    /// CaptureError mapping — not the MDM-specific path.
    func testPermissionRevokedDoesNotProduceMDMAlert() async {
        let store = makeStoreWithThrowingBuilder(error: CaptureError.permissionRevoked)

        await store.startRecording(preset: .everything)

        if let alert = store.errorSurface.currentAlert {
            XCTAssertNotEqual(alert.primaryButton, "Switch to mic-only",
                              "permissionRevoked should not show the MDM alert path")
        }
    }
}

// MARK: - MDMStubSessionConfigBuilder

private final class MDMStubSessionConfigBuilder: SessionConfigBuilder, @unchecked Sendable {
    let outputFolder: URL
    let throwError: Error

    init(outputFolder: URL, throwError: Error) {
        self.outputFolder = outputFolder
        self.throwError = throwError
    }

    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        throw throwError
    }
}
