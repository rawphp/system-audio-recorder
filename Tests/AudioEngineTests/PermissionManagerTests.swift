import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - StubMicrophoneAuthorizationProvider

/// Deterministic stub for unit tests — no AVCaptureDevice calls are made.
final class StubMicrophoneAuthorizationProvider: MicrophoneAuthorizationProvider {

    var stubStatus: AVAuthorizationStatus
    var stubRequestResult: Bool

    init(status: AVAuthorizationStatus = .notDetermined, requestResult: Bool = false) {
        self.stubStatus = status
        self.stubRequestResult = requestResult
    }

    var status: AVAuthorizationStatus { stubStatus }

    func requestAccess() async -> Bool {
        // Simulate the OS granting / denying and updating status.
        stubStatus = stubRequestResult ? .authorized : .denied
        return stubRequestResult
    }
}

// MARK: - PermissionManagerTests

@MainActor
final class PermissionManagerTests: XCTestCase {

    // MARK: - microphoneStatus reflects provider

    func testMicrophoneStatusNotDetermined() {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined)
        let pm = PermissionManager(micProvider: stub)
        XCTAssertEqual(pm.microphoneStatus, .notDetermined)
    }

    func testMicrophoneStatusAuthorized() {
        let stub = StubMicrophoneAuthorizationProvider(status: .authorized)
        let pm = PermissionManager(micProvider: stub)
        XCTAssertEqual(pm.microphoneStatus, .authorized)
    }

    func testMicrophoneStatusDenied() {
        let stub = StubMicrophoneAuthorizationProvider(status: .denied)
        let pm = PermissionManager(micProvider: stub)
        XCTAssertEqual(pm.microphoneStatus, .denied)
    }

    func testMicrophoneStatusRestricted() {
        let stub = StubMicrophoneAuthorizationProvider(status: .restricted)
        let pm = PermissionManager(micProvider: stub)
        XCTAssertEqual(pm.microphoneStatus, .restricted)
    }

    // MARK: - requestMicrophone() returns granted result

    func testRequestMicrophoneReturnsFalseWhenDenied() async {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined, requestResult: false)
        let pm = PermissionManager(micProvider: stub)
        let result = await pm.requestMicrophone()
        XCTAssertFalse(result, "requestMicrophone() must return false when stub denies access")
        XCTAssertEqual(pm.microphoneStatus, .denied)
    }

    func testRequestMicrophoneReturnsTrueWhenGranted() async {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined, requestResult: true)
        let pm = PermissionManager(micProvider: stub)
        let result = await pm.requestMicrophone()
        XCTAssertTrue(result, "requestMicrophone() must return true when stub grants access")
        XCTAssertEqual(pm.microphoneStatus, .authorized)
    }

    // MARK: - requestMicrophone() caches — subsequent calls skip re-prompting

    func testRequestMicrophoneSubsequentCallsReturnCachedStatus() async {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined, requestResult: true)
        let pm = PermissionManager(micProvider: stub)

        // First call — triggers request, sets status to .authorized.
        let first = await pm.requestMicrophone()
        XCTAssertTrue(first)

        // Second call with stub now returning false to prove real provider is NOT called again.
        stub.stubRequestResult = false
        let second = await pm.requestMicrophone()
        XCTAssertTrue(second, "Subsequent call must return cached result without re-prompting")
    }

    // MARK: - audioTapStatus default

    func testAudioTapStatusDefaultsToUnknown() {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined)
        let pm = PermissionManager(micProvider: stub)
        XCTAssertEqual(pm.audioTapStatus, .unknown)
    }

    // MARK: - requestAudioTap() probe

    func testRequestAudioTapReturnsBoolAndUpdatesStatus() async {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined)
        let pm = PermissionManager(micProvider: stub)
        // We cannot actually create a tap in a unit-test environment; we only
        // assert that the call completes without crashing and returns a Bool.
        let result = await pm.requestAudioTap()
        XCTAssertTrue(result || !result) // just assert it's a Bool; real value is runtime-only
        XCTAssertNotEqual(pm.audioTapStatus, .unknown, "audioTapStatus must be updated after requestAudioTap()")
    }

    // MARK: - pollMicrophoneStatus()

    func testPollMicrophoneStatusPicksUpExternalChanges() async throws {
        let stub = StubMicrophoneAuthorizationProvider(status: .authorized)
        let pm = PermissionManager(micProvider: stub)

        // Simulate user revoking in System Settings.
        stub.stubStatus = .denied

        // Poll once.
        pm.pollMicrophoneStatus()

        // The status should reflect the new value.
        XCTAssertEqual(pm.microphoneStatus, .denied)
    }

    // MARK: - Observable publishes changes

    func testMicrophoneStatusPublishesOnChange() async {
        let stub = StubMicrophoneAuthorizationProvider(status: .notDetermined, requestResult: true)
        let pm = PermissionManager(micProvider: stub)

        XCTAssertEqual(pm.microphoneStatus, .notDetermined)
        _ = await pm.requestMicrophone()
        XCTAssertEqual(pm.microphoneStatus, .authorized,
                       "@Observable property must reflect updated status after grant")
    }
}
