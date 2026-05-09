import XCTest
import AVFoundation
@testable import SystemAudioToMP3

// MARK: - Inline test double

/// In-test buffer emitter that conforms to `RecordingSourceEmitter`.
/// Pushes buffers into its `stream` until `stop()` is called or `finish()` is invoked manually.
private final class FakeEmitter: RecordingSourceEmitter, @unchecked Sendable {
    let id: String
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let cont: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var stopped = false
    private let lock = NSLock()

    init(id: String) {
        self.id = id
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.cont = c
    }

    /// Yield one canonical-format silence buffer.
    func push(frameCount: AVAudioFrameCount = 480) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buf.frameLength = frameCount
        for ch in 0..<Int(fmt.channelCount) {
            if let p = buf.floatChannelData?[ch] {
                for i in 0..<Int(frameCount) {
                    p[i] = 0.1 * Float(sin(Double(i) * 0.05))
                }
            }
        }
        cont.yield(buf)
    }

    func finishStream() {
        lock.lock(); defer { lock.unlock() }
        cont.finish()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        cont.finish()
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

// MARK: - Tests

final class RecordingSessionTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
    }

    // MARK: helpers

    private func makeConfig(
        sources: [(String, RecordingSourceEmitter)],
        mode: SessionConfig.OutputMode = .mixed
    ) -> SessionConfig {
        SessionConfig(
            sources: sources.map { SessionConfig.Source(id: $0.0, emitter: $0.1) },
            outputMode: mode,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00"
        )
    }

    /// Pushes `count` buffers spaced ~10 ms apart on every emitter, yielding to the actor.
    private func driveBuffers(_ emitters: [FakeEmitter], count: Int) async {
        for _ in 0..<count {
            for e in emitters { e.push() }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Wait for all emitters to receive a buffer downstream by polling for files of a min size.
    private func waitForFileGrowth(at url: URL, minBytes: Int, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size >= minBytes {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: - State transition tests

    func testInitialStateIsIdle() async {
        let session = RecordingSession()
        let s = await session.state
        XCTAssertEqual(s, .idle)
    }

    func testStartFromIdleEntersRecording() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        let s1 = await session.state
        XCTAssertEqual(s1, .recording)
        _ = await session.stop()
    }

    func testStartWithNoSourcesThrows() async {
        let session = RecordingSession()
        let cfg = SessionConfig(
            sources: [],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00"
        )
        do {
            try await session.start(config: cfg)
            XCTFail("expected throw")
        } catch let err as SessionError {
            switch err {
            case .noSourcesConfigured: break
            default: XCTFail("wrong err: \(err)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testStartWhileRecordingThrowsInvalidTransition() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        do {
            try await session.start(config: makeConfig(sources: [("app1", FakeEmitter(id: "app1"))]))
            XCTFail("expected throw")
        } catch let err as SessionError {
            switch err {
            case .invalidTransition: break
            default: XCTFail("wrong err: \(err)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        _ = await session.stop()
    }

    func testResumeFromIdleThrows() async {
        let session = RecordingSession()
        do {
            try await session.resume()
            XCTFail("expected throw")
        } catch let err as SessionError {
            switch err {
            case .invalidTransition: break
            default: XCTFail("wrong err: \(err)")
            }
        } catch { XCTFail("unexpected error type") }
    }

    func testPauseFromIdleThrows() async {
        let session = RecordingSession()
        do {
            try await session.pause()
            XCTFail("expected throw")
        } catch let err as SessionError {
            switch err {
            case .invalidTransition: break
            default: XCTFail("wrong err: \(err)")
            }
        } catch { XCTFail("unexpected error type") }
    }

    func testPauseFromStoppedThrows() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        _ = await session.stop()
        do {
            try await session.pause()
            XCTFail("expected throw")
        } catch let err as SessionError {
            switch err {
            case .invalidTransition: break
            default: XCTFail("wrong err: \(err)")
            }
        } catch { XCTFail("unexpected error type") }
    }

    func testFullLifecycleStartPauseResumeStop() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        let s1 = await session.state; XCTAssertEqual(s1, .recording)

        await driveBuffers([e], count: 30)
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await session.pause()
        let s2 = await session.state; XCTAssertEqual(s2, .paused)

        // Buffers pushed during pause should NOT be written
        await driveBuffers([e], count: 20)
        try? await Task.sleep(nanoseconds: 100_000_000)

        try await session.resume()
        let s3 = await session.state; XCTAssertEqual(s3, .recording)

        await driveBuffers([e], count: 30)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let urls = await session.stop()
        let s4 = await session.state; XCTAssertEqual(s4, .stopped)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertTrue(e.isStopped, "emitter should have been stopped by session.stop()")
    }

    // MARK: - Source-combination tests (acceptance #2)

    func testSingleAppProducesNonEmptyStream() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        await driveBuffers([e], count: 50)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        XCTAssertEqual(urls.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: urls[0].path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000, "WAV should contain audio (got \(size) bytes)")
    }

    func testMultipleAppsProduceNonEmptyStream() async throws {
        let session = RecordingSession()
        let e1 = FakeEmitter(id: "app1")
        let e2 = FakeEmitter(id: "app2")
        try await session.start(config: makeConfig(sources: [("app1", e1), ("app2", e2)]))
        await driveBuffers([e1, e2], count: 50)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        XCTAssertEqual(urls.count, 1)
        let size = (try FileManager.default.attributesOfItem(atPath: urls[0].path))[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    func testMicOnlyProducesNonEmptyStream() async throws {
        let session = RecordingSession()
        let mic = FakeEmitter(id: "mic")
        try await session.start(config: makeConfig(sources: [("mic", mic)]))
        await driveBuffers([mic], count: 50)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        XCTAssertEqual(urls.count, 1)
        let size = (try FileManager.default.attributesOfItem(atPath: urls[0].path))[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    func testMultipleAppsPlusMicProducesNonEmptyStream() async throws {
        let session = RecordingSession()
        let e1 = FakeEmitter(id: "app1")
        let e2 = FakeEmitter(id: "app2")
        let mic = FakeEmitter(id: "mic")
        try await session.start(config: makeConfig(sources: [("app1", e1), ("app2", e2), ("mic", mic)]))
        await driveBuffers([e1, e2, mic], count: 50)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        XCTAssertEqual(urls.count, 1)
        let size = (try FileManager.default.attributesOfItem(atPath: urls[0].path))[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    // MARK: - Separate mode

    func testSeparateModeProducesNPlusOneFiles() async throws {
        let session = RecordingSession()
        let e1 = FakeEmitter(id: "app1")
        let e2 = FakeEmitter(id: "app2")
        try await session.start(
            config: makeConfig(
                sources: [("app1", e1), ("app2", e2)],
                mode: .separate
            )
        )
        await driveBuffers([e1, e2], count: 30)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        XCTAssertEqual(urls.count, 3, "expected 2 sources + 1 mix file, got \(urls.map(\.lastPathComponent))")
    }

    // MARK: - stop returns URLs and tears down

    func testStopReturnsURLsAndStopsAllEmitters() async throws {
        let session = RecordingSession()
        let e1 = FakeEmitter(id: "app1")
        let e2 = FakeEmitter(id: "app2")
        try await session.start(config: makeConfig(sources: [("app1", e1), ("app2", e2)]))
        await driveBuffers([e1, e2], count: 20)

        let urls = await session.stop()
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(e1.isStopped)
        XCTAssertTrue(e2.isStopped)
    }

    // MARK: - Idempotent stop

    func testStopIsIdempotent() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")
        try await session.start(config: makeConfig(sources: [("app1", e)]))
        await driveBuffers([e], count: 10)
        let first = await session.stop()
        let second = await session.stop()
        XCTAssertEqual(first.count, second.count)
        let s = await session.state; XCTAssertEqual(s, .stopped)
    }

    // MARK: - Error stream

    func testErrorStreamExists() {
        let session = RecordingSession()
        let stream = session.errorStream
        // Just confirm non-nil access; we don't assert anything is delivered.
        _ = stream
    }
}
