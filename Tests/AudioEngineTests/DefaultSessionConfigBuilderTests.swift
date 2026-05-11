import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - Test Infrastructure

/// A `ProcessListProvider` that returns a fixed list of (objectID, pid, bundleID) triples.
/// Seeds `AudioSourceCatalog` with deterministic data for builder tests.
private final class FixedProcessListProvider: ProcessListProvider {

    struct Entry {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
    }

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    func audioProcessObjectIDs() -> [AudioObjectID] {
        entries.map(\.objectID)
    }

    func pid(for objectID: AudioObjectID) -> pid_t? {
        entries.first { $0.objectID == objectID }?.pid
    }

    func bundleID(for objectID: AudioObjectID) -> String? {
        entries.first { $0.objectID == objectID }?.bundleID
    }
}

/// Passthrough bookmark provider for builder tests.
private final class BuilderPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        guard let s = String(data: data, encoding: .utf8), let u = URL(string: s) else {
            throw NSError(domain: "BuilderTest", code: 1)
        }
        return u
    }
}

/// Builds an `AppSettings` wired to a temp folder so `resolvedOutputFolder()` succeeds.
@MainActor
private func makeBuilderSettings(tempDir: URL) -> AppSettings {
    let suiteName = "com.tomkaczocha.BuilderTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settings = AppSettings(
        defaults: defaults,
        bookmarkProvider: BuilderPassthroughBookmarkProvider(),
        folderCreator: FileManagerFolderCreator()
    )
    // Pre-seed the output folder so resolvedOutputFolder() returns tempDir.
    settings.setOutputFolder(tempDir)
    return settings
}

// MARK: - DefaultSessionConfigBuilderTests

@MainActor
final class DefaultSessionConfigBuilderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - REQ-066: .specificApp multi-pid tapping

    /// A catalog with parent + 2 helpers for com.google.Chrome produces 3 sources.
    func testSpecificAppThreePidsProducesThreeSources() throws {
        let pid1: pid_t = 1001
        let pid2: pid_t = 1002
        let pid3: pid_t = 1003

        let provider = FixedProcessListProvider(entries: [
            .init(objectID: 101, pid: pid1, bundleID: "com.google.Chrome"),
            .init(objectID: 102, pid: pid2, bundleID: "com.google.Chrome.helper"),
            .init(objectID: 103, pid: pid3, bundleID: "com.google.Chrome.helper.GPU"),
            .init(objectID: 104, pid: 2001,  bundleID: "com.apple.Safari"),
        ])
        let catalog = AudioSourceCatalog(provider: provider)

        let emitterFactory = MockEmitterFactory()
        let captureFactory: DefaultSessionConfigBuilder.CaptureFactory = { pids in
            try ProcessTapCapture(pids: pids, factory: emitterFactory, alivenessCheck: { _ in true })
        }

        let builder = DefaultSessionConfigBuilder(catalog: catalog, captureFactory: captureFactory)
        let settings = makeBuilderSettings(tempDir: tempDir)
        let config = try builder.build(preset: .specificApp(bundleID: "com.google.Chrome"), settings: settings)

        XCTAssertEqual(config.sources.count, 3, "Expected one source per bundle pid")

        let ids = Set(config.sources.map(\.id))
        XCTAssertTrue(ids.contains("app:\(pid1)"), "Missing source for parent pid \(pid1)")
        XCTAssertTrue(ids.contains("app:\(pid2)"), "Missing source for helper pid \(pid2)")
        XCTAssertTrue(ids.contains("app:\(pid3)"), "Missing source for sub-helper pid \(pid3)")
    }

    /// Empty bundle group throws `BuilderError.noAudibleProcesses`.
    func testSpecificAppEmptyBundleGroupThrowsNoAudibleProcesses() throws {
        let provider = FixedProcessListProvider(entries: [
            .init(objectID: 201, pid: 2001, bundleID: "com.apple.Safari"),
        ])
        let catalog = AudioSourceCatalog(provider: provider)

        let captureFactory: DefaultSessionConfigBuilder.CaptureFactory = { pids in
            try ProcessTapCapture(pids: pids, factory: MockEmitterFactory(), alivenessCheck: { _ in true })
        }

        let builder = DefaultSessionConfigBuilder(catalog: catalog, captureFactory: captureFactory)
        let settings = makeBuilderSettings(tempDir: tempDir)

        XCTAssertThrowsError(
            try builder.build(preset: .specificApp(bundleID: "com.nonexistent.app"), settings: settings)
        ) { error in
            XCTAssertEqual(error as? DefaultSessionConfigBuilder.BuilderError, .noAudibleProcesses,
                           "Expected noAudibleProcesses for empty bundle group")
        }
    }

    /// Per-pid emitter failures land in `SessionConfig.initialErrors` (REQ-045
    /// graceful-failure semantics). Partial failure does not throw.
    func testSpecificAppPerPidFailureLandsInInitialErrors() throws {
        let pid1: pid_t = 3001
        let pid2: pid_t = 3002
        let pid3: pid_t = 3003

        let provider = FixedProcessListProvider(entries: [
            .init(objectID: 301, pid: pid1, bundleID: "com.example.Electron"),
            .init(objectID: 302, pid: pid2, bundleID: "com.example.Electron.helper"),
            .init(objectID: 303, pid: pid3, bundleID: "com.example.Electron.helper.GPU"),
        ])
        let catalog = AudioSourceCatalog(provider: provider)

        // pid2 fails at emitter-construction time.
        let failingFactory = MockEmitterFactory(failByPID: [pid2: .tapCreationFailed(-50)])
        let captureFactory: DefaultSessionConfigBuilder.CaptureFactory = { pids in
            try ProcessTapCapture(pids: pids, factory: failingFactory, alivenessCheck: { _ in true })
        }

        let builder = DefaultSessionConfigBuilder(catalog: catalog, captureFactory: captureFactory)
        let settings = makeBuilderSettings(tempDir: tempDir)
        let config = try builder.build(preset: .specificApp(bundleID: "com.example.Electron"), settings: settings)

        XCTAssertEqual(config.sources.count, 2, "Surviving pids should produce 2 sources")
        XCTAssertEqual(config.initialErrors.count, 1, "Failed pid should appear in initialErrors")
        XCTAssertEqual(config.initialErrors.first?.pid, pid2)
    }

    /// Source IDs follow the "app:<pid>" convention matching the `.everything` case.
    func testSpecificAppSourceIdsFollowAppPidConvention() throws {
        let pid1: pid_t = 4001
        let pid2: pid_t = 4002

        let provider = FixedProcessListProvider(entries: [
            .init(objectID: 401, pid: pid1, bundleID: "com.tinyspeck.slackmacgap"),
            .init(objectID: 402, pid: pid2, bundleID: "com.tinyspeck.slackmacgap.helper"),
        ])
        let catalog = AudioSourceCatalog(provider: provider)

        let captureFactory: DefaultSessionConfigBuilder.CaptureFactory = { pids in
            try ProcessTapCapture(pids: pids, factory: MockEmitterFactory(), alivenessCheck: { _ in true })
        }

        let builder = DefaultSessionConfigBuilder(catalog: catalog, captureFactory: captureFactory)
        let settings = makeBuilderSettings(tempDir: tempDir)
        let config = try builder.build(preset: .specificApp(bundleID: "com.tinyspeck.slackmacgap"), settings: settings)

        for source in config.sources {
            XCTAssertTrue(source.id.hasPrefix("app:"),
                          "Source id '\(source.id)' must start with 'app:' prefix")
        }
    }
}
