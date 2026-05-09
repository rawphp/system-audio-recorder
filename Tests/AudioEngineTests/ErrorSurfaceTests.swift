import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - ErrorSurfaceTests

@MainActor
final class ErrorSurfaceTests: XCTestCase {

    // MARK: - Fatal alert from background thread

    /// report(.permissionRevoked) from a background queue → asserts currentAlert is set on main.
    func testFatalErrorFromBackgroundSetsAlert() async throws {
        let surface = ErrorSurface()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task.detached {
                await surface.report(CaptureError.permissionRevoked, severity: .fatal)
                continuation.resume()
            }
        }

        XCTAssertNotNil(surface.currentAlert)
        XCTAssertEqual(surface.currentAlert?.title, "Permission Revoked")
        XCTAssertTrue(
            surface.currentAlert?.message.contains("Microphone permission was revoked") ?? false,
            "message should mention microphone permission"
        )
        XCTAssertEqual(surface.currentAlert?.primaryButton, "Try Again")
        XCTAssertEqual(surface.currentAlert?.secondaryButton, "Open System Settings")
        XCTAssertEqual(surface.currentAlert?.secondaryAction, .microphone)
    }

    // MARK: - dismissAlert clears the alert

    func testDismissAlertClearsCurrentAlert() async {
        let surface = ErrorSurface()
        await surface.report(CaptureError.permissionRevoked, severity: .fatal)
        XCTAssertNotNil(surface.currentAlert)
        surface.dismissAlert()
        XCTAssertNil(surface.currentAlert)
    }

    // MARK: - Non-fatal banner

    func testNonFatalBannerAppearsForSessionErrorNoSources() async {
        let surface = ErrorSurface()
        await surface.report(SessionError.noSourcesConfigured, severity: .nonFatal)
        XCTAssertFalse(surface.banners.isEmpty)
        XCTAssertTrue(
            surface.banners[0].message.contains("Pick at least one audio source") ||
            surface.banners[0].message.contains("audio source"),
            "banner should prompt user to pick an audio source"
        )
        XCTAssertTrue(surface.banners[0].dismissible)
    }

    // MARK: - Background toast (non-fatal via mapping)

    func testBackgroundEncodingInvalidInputProducesToast() async {
        let surface = ErrorSurface()
        let fakeURL = URL(fileURLWithPath: "/tmp/fake.wav")
        let fakeUnderlying = NSError(domain: "Test", code: 1)
        await surface.report(
            EncodingError.invalidInput(fakeURL, underlying: fakeUnderlying),
            severity: .background
        )
        // Background severity → toast banner (dismissible = false)
        XCTAssertFalse(surface.banners.isEmpty)
        XCTAssertTrue(
            surface.banners[0].message.contains("Encoding failed") ||
            surface.banners[0].message.contains("WAV could not be opened"),
            "toast should mention encoding failure"
        )
    }

    // MARK: - Stack 5 non-fatal banners → cap at 3, collapsedCount == 2

    func testBannerStackCapsAtThreeWithCollapsedCount() async {
        let surface = ErrorSurface()
        for _ in 0..<5 {
            await surface.report(SessionError.noSourcesConfigured, severity: .nonFatal)
        }
        XCTAssertEqual(surface.banners.count, 3,
                       "visible banners must be capped at 3")
        XCTAssertEqual(surface.collapsedCount, 2,
                       "collapsed count must reflect the 2 hidden banners")
    }

    // MARK: - dismiss(banner:) removes the correct banner

    func testDismissBannerRemovesCorrectEntry() async {
        let surface = ErrorSurface()
        await surface.report(SessionError.noSourcesConfigured, severity: .nonFatal)
        await surface.report(SessionError.noSourcesConfigured, severity: .nonFatal)
        XCTAssertEqual(surface.banners.count, 2)

        let idToRemove = surface.banners[0].id
        surface.dismiss(banner: idToRemove)

        XCTAssertEqual(surface.banners.count, 1)
        XCTAssertFalse(surface.banners.contains { $0.id == idToRemove })
    }

    // MARK: - EncodingError.lameInitFailed → fatal alert

    func testLameInitFailedProducesFatalAlert() async {
        let surface = ErrorSurface()
        await surface.report(EncodingError.lameInitFailed(code: -1), severity: .fatal)
        XCTAssertNotNil(surface.currentAlert)
        XCTAssertTrue(
            surface.currentAlert?.message.contains("encoder") ?? false ||
            surface.currentAlert?.message.contains("initialize") ?? false,
            "fatal alert should mention encoder initialization"
        )
    }

    // MARK: - SettingsError.outputFolderUnavailable → non-fatal banner

    func testSettingsErrorOutputFolderUnavailableProducesBanner() async {
        let surface = ErrorSurface()
        await surface.report(SettingsError.outputFolderUnavailable, severity: .nonFatal)
        XCTAssertFalse(surface.banners.isEmpty)
        XCTAssertTrue(
            surface.banners[0].message.contains("Output folder") ||
            surface.banners[0].message.contains("folder"),
            "banner should mention the output folder"
        )
    }

    // MARK: - Unknown error → background toast with localizedDescription

    func testUnknownErrorProducesBackgroundToastWithLocalizedDescription() async {
        let surface = ErrorSurface()
        let customError = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )
        await surface.report(customError, severity: .background)
        XCTAssertFalse(surface.banners.isEmpty)
        XCTAssertTrue(
            surface.banners[0].message.contains("Something went wrong"),
            "toast should contain localizedDescription"
        )
    }

    // MARK: - AppStore integration: errorSurface property exists

    func testAppStoreHasErrorSurface() async throws {
        let suiteName = "com.test.ErrorSurfaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: InMemoryBookmarkProvider(),
            folderCreator: NoOpFolderCreator()
        )
        let store = AppStore(
            settings: settings,
            sourceCatalog: AudioSourceCatalog(provider: ESEmptyProcessListProvider()),
            permissionManager: PermissionManager(
                micProvider: AlwaysAuthorizedMicProvider()
            ),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: NullSessionConfigBuilder()
        )
        XCTAssertNotNil(store.errorSurface)
    }
}

// MARK: - Test doubles

private final class InMemoryBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        let str = String(data: data, encoding: .utf8) ?? ""
        return URL(string: str) ?? URL(fileURLWithPath: "/tmp")
    }
}

private struct NoOpFolderCreator: FolderCreating {
    func createDirectory(at url: URL) throws {}
}

private struct ESEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

private final class AlwaysAuthorizedMicProvider: MicrophoneAuthorizationProvider {
    var status: AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

private final class NullSessionConfigBuilder: SessionConfigBuilder {
    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        let emitter = NullEmitter(id: "null")
        return SessionConfig(
            sources: [SessionConfig.Source(id: "null", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()),
            timestamp: "20260510-000000"
        )
    }
}

private final class NullEmitter: RecordingSourceEmitter, @unchecked Sendable {
    let id: String
    let stream: AsyncStream<AVAudioPCMBuffer>
    init(id: String) {
        self.id = id
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream { c = $0 }
        _ = c
    }
    func stop() {}
}
