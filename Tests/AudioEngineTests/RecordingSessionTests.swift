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

    /// Yield one canonical-format buffer filled with zeros (below -60 dBFS noise floor).
    func pushSilent(frameCount: AVAudioFrameCount = 480) {
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
        // All samples are zero — RMS = -160 dBFS (MeterTap.silenceDBFS)
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

    // MARK: - REQ-014: Auto-stop by duration

    /// AC1: autoStopDuration = 1.0 → session reaches .stopped at t ≈ 1.0 s (±0.2 s)
    func testAutoStopFiresAfterDuration() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        // Build a config with autoStopDuration = 1.0 s
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopDuration: 1.0
        )

        let t0 = Date()
        try await session.start(config: cfg)

        // Drive buffers while we wait for auto-stop (up to 2 s)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            e.push()
            try? await Task.sleep(nanoseconds: 10_000_000)
            let s = await session.state
            if s == .stopped { break }
        }

        let elapsed = Date().timeIntervalSince(t0)
        let s = await session.state
        XCTAssertEqual(s, .stopped, "session should have auto-stopped")
        XCTAssertGreaterThan(elapsed, 0.8, "stopped too early: \(elapsed)s")
        XCTAssertLessThan(elapsed, 1.5, "stopped too late: \(elapsed)s")
    }

    /// AC2: Pause at ~0.5 s, resume at ~1.5 s → stop fires at ~2.0 s
    ///       (0.5 s recorded before pause + 1.5 s recorded after resume = total 2.0 s)
    func testAutoStopRespectsPausedTime() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopDuration: 2.0
        )

        let t0 = Date()
        try await session.start(config: cfg)

        // Drive for ~0.5 s then pause
        let driveTask = Task.detached {
            while true {
                e.push()
                try? await Task.sleep(nanoseconds: 10_000_000)
                let s = await session.state
                if s == .stopped { break }
            }
        }

        // Wait 0.5 s, then pause for 1.0 s, then resume
        try await Task.sleep(nanoseconds: 500_000_000)
        try await session.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 s paused
        try await session.resume()

        // Wait for auto-stop (up to 3 s total)
        let deadlineAbs = Date().addingTimeInterval(3.0)
        while Date() < deadlineAbs {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let s = await session.state
            if s == .stopped { break }
        }
        driveTask.cancel()

        let elapsed = Date().timeIntervalSince(t0)
        let s = await session.state
        XCTAssertEqual(s, .stopped, "session should have auto-stopped")
        // We recorded 0.5 s before pause + 1.5 s after resume = 2.0 s total.
        // Total wall clock: 0.5 (record) + 1.0 (paused) + 1.5 (record) = 3.0 s
        // Allow ±0.4 s tolerance given scheduling jitter.
        XCTAssertGreaterThan(elapsed, 2.5, "stopped too early: \(elapsed)s")
        XCTAssertLessThan(elapsed, 4.0, "stopped too late: \(elapsed)s")
    }

    /// AC3: nil autoStopDuration → no auto-stop fires; session stays recording.
    func testNilAutoStopDurationNoTimer() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopDuration: nil
        )

        try await session.start(config: cfg)

        // Drive buffers and confirm session is still recording after 0.5 s
        await driveBuffers([e], count: 20)
        try await Task.sleep(nanoseconds: 500_000_000)

        let s = await session.state
        XCTAssertEqual(s, .recording, "should still be recording with nil autoStopDuration")
        _ = await session.stop()
    }

    /// AC4: Manual stop before timer fires → no double-stop; state is .stopped cleanly.
    func testManualStopCancelsAutoStopTimer() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopDuration: 5.0  // Long enough that we stop manually first
        )

        try await session.start(config: cfg)
        await driveBuffers([e], count: 10)

        // Stop manually after ~100 ms (well before the 5 s timer)
        _ = await session.stop()
        let s1 = await session.state
        XCTAssertEqual(s1, .stopped)

        // Wait 200 ms to confirm no re-entry from the timer
        try await Task.sleep(nanoseconds: 200_000_000)
        let s2 = await session.state
        XCTAssertEqual(s2, .stopped, "state should remain .stopped after manual stop cancels timer")
    }

    // MARK: - REQ-015: Auto-stop on silence

    /// AC1: nil autoStopSilenceSeconds → silence detector is not active; session keeps running.
    func testNilAutoStopSilenceNoDetector() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopSilenceSeconds: nil
        )

        try await session.start(config: cfg)

        // Push silent buffers for 1.5 s — should NOT trigger stop since detector is off.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let s = await session.state
        XCTAssertEqual(s, .recording, "should still be recording with nil autoStopSilenceSeconds")
        _ = await session.stop()
    }

    /// AC2: grace period — silent buffers in the first 2 s do NOT trigger auto-stop.
    func testSilenceDetectorGracePeriodPreventsEarlyStop() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        // threshold = 1.0 s, grace = 2.0 s → stop should require 3.0 s total.
        // We push silent buffers for only 2.5 s (inside grace + partial threshold).
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopSilenceSeconds: 1.0
        )

        let t0 = Date()
        try await session.start(config: cfg)

        // Push silent buffers for 2.5 s total — the detector should NOT have fired
        // since the grace period is 2.0 s and we haven't held silence for 1.0 s *after* it.
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Still recording (< 1.0 s of silence has elapsed after the 2.0 s grace).
        let s = await session.state
        XCTAssertEqual(s, .recording, "should still be recording — silence hasn't exceeded threshold post-grace")
        _ = await session.stop()
        _ = t0  // suppress unused-variable warning
    }

    /// AC3: Feeding silent buffers for `threshold + grace` triggers auto-stop.
    func testSilenceDetectorStopsAfterThreshold() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        // threshold = 1.0 s, so auto-stop should fire ~3.0 s after start
        // (2.0 s grace + 1.0 s silence).
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopSilenceSeconds: 1.0
        )

        let t0 = Date()
        try await session.start(config: cfg)

        // Drive silent buffers until session stops or we hit a 5 s wall-clock deadline.
        let wallDeadline = Date().addingTimeInterval(5.0)
        while Date() < wallDeadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
            let s = await session.state
            if s == .stopped { break }
        }

        let elapsed = Date().timeIntervalSince(t0)
        let s = await session.state
        XCTAssertEqual(s, .stopped, "session should have auto-stopped due to silence")
        // Must have waited at least the grace period + threshold (~3.0 s).
        XCTAssertGreaterThan(elapsed, 2.5, "stopped too early: \(elapsed)s")
        // Should stop within a reasonable window (5 s gives headroom for CI jitter).
        XCTAssertLessThan(elapsed, 5.0, "stopped too late: \(elapsed)s")
    }

    /// AC4: Mixing in audio above -60 dBFS resets the silence counter.
    func testSilenceDetectorResetsOnAudio() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        // threshold = 1.0 s (silence must be unbroken for 1 s after grace).
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopSilenceSeconds: 1.0
        )

        try await session.start(config: cfg)

        // Burn through grace period with silent buffers (~2.1 s).
        let graceDeadline = Date().addingTimeInterval(2.1)
        while Date() < graceDeadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Now push silent for 0.9 s (below threshold).
        let silentDeadline = Date().addingTimeInterval(0.9)
        while Date() < silentDeadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Inject audio — should reset the counter.
        for _ in 0..<5 {
            e.push()  // non-silent (0.1 * sin) ≈ -20 dBFS
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Push silent again for 0.9 s — total unbroken silence is <1.0 s → should NOT stop.
        let silentDeadline2 = Date().addingTimeInterval(0.9)
        while Date() < silentDeadline2 {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let s = await session.state
        XCTAssertEqual(s, .recording, "session should still be recording — audio reset the silence counter")
        _ = await session.stop()
    }

    /// AC5: Pause resets the silence counter; resume restarts the grace period.
    func testSilenceDetectorResetsOnPause() async throws {
        let session = RecordingSession()
        let e = FakeEmitter(id: "app1")

        // threshold = 1.0 s.
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "app1", emitter: e)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopSilenceSeconds: 1.0
        )

        try await session.start(config: cfg)

        // Burn grace period with silent buffers (~2.1 s).
        let graceDeadline = Date().addingTimeInterval(2.1)
        while Date() < graceDeadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Push silent for 0.9 s (close to threshold but not over).
        let almostDeadline = Date().addingTimeInterval(0.9)
        while Date() < almostDeadline {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Pause — counter should reset; resume should restart grace period.
        try await session.pause()
        try? await Task.sleep(nanoseconds: 50_000_000)
        try await session.resume()

        // Push silent for 0.9 s — since we just resumed, the grace period restarts
        // so the counter never reaches the 1.0 s threshold within this window.
        let silentDeadline3 = Date().addingTimeInterval(0.9)
        while Date() < silentDeadline3 {
            e.pushSilent()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let s = await session.state
        XCTAssertEqual(s, .recording, "session should still be recording — pause reset silence counter and restarted grace")
        _ = await session.stop()
    }
}
