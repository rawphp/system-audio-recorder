import XCTest
import AVFoundation
import CoreAudio
@testable import SystemAudioRecorder

// MARK: - Mock infrastructure

/// A fake emitter that pushes synthetic 1 kHz sine buffers on a background
/// dispatch queue at ~100 buffers/sec. Used to validate ProcessTapCapture's
/// stream wiring without touching Core Audio.
final class MockProcessEmitter: PerProcessEmitter {

    let pid: pid_t
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private(set) var torndown = false
    private(set) var terminationError: CaptureError?

    /// If set, after this many emitted buffers the emitter will terminate
    /// itself with the given error — simulates mid-stream process death.
    let dieAfterBuffers: Int?

    private var buffersEmitted = 0
    private let format: AVAudioFormat

    init(pid: pid_t, dieAfterBuffers: Int? = nil) {
        self.pid = pid
        self.dieAfterBuffers = dieAfterBuffers
        self.queue = DispatchQueue(label: "MockProcessEmitter.\(pid)")

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            fatalError("Could not build PCM format")
        }
        self.format = fmt

        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream<AVAudioPCMBuffer> { c in cont = c }
        self.continuation = cont
    }

    /// Begins emitting synthetic 1 kHz sine buffers (~100 bufs/sec).
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
        timer.setEventHandler { [weak self] in
            self?.emitBuffer()
        }
        timer.resume()
        self.timer = timer
    }

    private func emitBuffer() {
        guard !torndown else { return }
        let frameCount: AVAudioFrameCount = 480 // 10 ms @ 48 kHz
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        // Fill with 1 kHz sine — value isn't load-bearing for the count test
        if let channelData = buffer.floatChannelData {
            let sampleRate = Float(format.sampleRate)
            let phaseIncrement = 2.0 * Float.pi * 1000.0 / sampleRate
            for c in 0..<Int(format.channelCount) {
                for f in 0..<Int(frameCount) {
                    channelData[c][f] = sin(phaseIncrement * Float(f))
                }
            }
        }

        continuation.yield(buffer)
        buffersEmitted += 1

        if let dieAfter = dieAfterBuffers, buffersEmitted >= dieAfter {
            terminate(with: .processTerminated(pid))
            teardown()
        }
    }

    func terminate(with error: CaptureError) {
        terminationError = error
        continuation.finish()
    }

    func teardown() {
        torndown = true
        timer?.cancel()
        timer = nil
        continuation.finish()
    }
}

/// Factory that produces `MockProcessEmitter`s and starts them ticking.
final class MockEmitterFactory: PerProcessEmitterFactory {
    let dieAfterBuffersByPID: [pid_t: Int]
    private(set) var createdEmitters: [pid_t: MockProcessEmitter] = [:]

    init(dieAfterBuffersByPID: [pid_t: Int] = [:]) {
        self.dieAfterBuffersByPID = dieAfterBuffersByPID
    }

    func makeEmitter(for pid: pid_t) throws -> PerProcessEmitter {
        let dieAfter = dieAfterBuffersByPID[pid]
        let emitter = MockProcessEmitter(pid: pid, dieAfterBuffers: dieAfter)
        createdEmitters[pid] = emitter
        emitter.start()
        return emitter
    }
}

// MARK: - Tests

final class ProcessTapCaptureTests: XCTestCase {

    // MARK: testInitWithMockEmitter
    //
    // Build a ProcessTapCapture wired to MockEmitterFactory; assert ≥100
    // buffers arrive within 5 s and that their format is non-interleaved
    // Float32.
    func testInitWithMockEmitter() async throws {
        let factory = MockEmitterFactory()
        let capture = try ProcessTapCapture(
            pids: [42],
            factory: factory,
            alivenessCheck: { _ in true } // pid 42 doesn't exist; pretend alive
        )
        defer { capture.stop() }

        guard let stream = capture.streams[42] else {
            XCTFail("Expected stream for pid 42")
            return
        }

        var count = 0
        var sawCorrectFormat = false
        let deadline = Date().addingTimeInterval(5.0)

        for await buffer in stream {
            count += 1
            if buffer.format.commonFormat == .pcmFormatFloat32,
               !buffer.format.isInterleaved {
                sawCorrectFormat = true
            }
            if count >= 100 { break }
            if Date() > deadline { break }
        }

        XCTAssertGreaterThanOrEqual(count, 100, "Expected ≥100 buffers within 5s, got \(count)")
        XCTAssertTrue(sawCorrectFormat, "Expected at least one Float32 non-interleaved buffer")
    }

    // MARK: testStopTearsDownAllResources
    //
    // Start with 2 mock pids, call stop(), assert streams[pid] is nil for both
    // and that emitters report torndown == true.
    func testStopTearsDownAllResources() throws {
        let factory = MockEmitterFactory()
        let capture = try ProcessTapCapture(
            pids: [101, 202],
            factory: factory,
            alivenessCheck: { _ in true }
        )

        XCTAssertNotNil(capture.streams[101])
        XCTAssertNotNil(capture.streams[202])

        capture.stop()

        XCTAssertNil(capture.streams[101], "stop() must remove pid 101 stream")
        XCTAssertNil(capture.streams[202], "stop() must remove pid 202 stream")
        XCTAssertTrue(factory.createdEmitters[101]?.torndown == true)
        XCTAssertTrue(factory.createdEmitters[202]?.torndown == true)
    }

    // MARK: testStopIsIdempotent
    //
    // Calling stop() twice must not crash and must leave the capture in a
    // teardown state.
    func testStopIsIdempotent() throws {
        let factory = MockEmitterFactory()
        let capture = try ProcessTapCapture(
            pids: [1],
            factory: factory,
            alivenessCheck: { _ in true }
        )
        capture.stop()
        XCTAssertNoThrow(capture.stop())
        XCTAssertTrue(capture.streams.isEmpty)
    }

    // MARK: testProcessDeathEmitsTerminationSignal
    //
    // Two mock pids — one configured to "die" after 5 buffers. Assert:
    //   * the dying stream finishes
    //   * the surviving stream keeps producing buffers
    func testProcessDeathEmitsTerminationSignal() async throws {
        let factory = MockEmitterFactory(dieAfterBuffersByPID: [501: 5])
        let capture = try ProcessTapCapture(
            pids: [501, 502],
            factory: factory,
            alivenessCheck: { _ in true }
        )
        defer { capture.stop() }

        guard let dyingStream = capture.streams[501],
              let survivingStream = capture.streams[502] else {
            XCTFail("Both streams must exist at start")
            return
        }

        // Drain the dying stream — it should finish naturally
        var dyingCount = 0
        for await _ in dyingStream {
            dyingCount += 1
            if dyingCount > 50 { break } // safety cap
        }
        XCTAssertLessThanOrEqual(dyingCount, 50, "Dying stream should finish")
        XCTAssertNotNil(factory.createdEmitters[501]?.terminationError,
                        "Dying emitter should have recorded a termination error")

        // The surviving stream should still be producing
        var survivingCount = 0
        let deadline = Date().addingTimeInterval(2.0)
        for await _ in survivingStream {
            survivingCount += 1
            if survivingCount >= 20 { break }
            if Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(survivingCount, 20,
            "Surviving stream should keep producing after sibling dies")
    }

    // MARK: testAlivenessTimerKillsDeadProcessStream
    //
    // Inject a custom alivenessCheck that flips to false after a delay.
    // Assert the corresponding stream gets removed from streams[].
    func testAlivenessTimerKillsDeadProcessStream() throws {
        let factory = MockEmitterFactory()
        let killSwitch = AlivenessKillSwitch()

        let capture = try ProcessTapCapture(
            pids: [777],
            factory: factory,
            alivenessCheck: { _ in killSwitch.alive }
        )
        defer { capture.stop() }

        XCTAssertNotNil(capture.streams[777])

        // Flip the kill switch and wait > 1s for the timer to notice
        killSwitch.alive = false

        let removalExpect = expectation(description: "stream removed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
            if capture.streams[777] == nil {
                removalExpect.fulfill()
            }
        }
        wait(for: [removalExpect], timeout: 5.0)

        XCTAssertNil(capture.streams[777], "Aliveness timer should have removed dead pid stream")
    }

    // MARK: testUnmutedModeIsDefaultInRealEmitter
    //
    // We can't build a real CATapDescription here (would require Core Audio
    // permissions), but we verify by source inspection that the muteBehavior
    // is set to .unmuted. This test is purely a guard — if the source ever
    // gets edited to use a different mode, this test will need updating.
    //
    // We do this by reading the source file and asserting the expected line.
    func testUnmutedModeIsDefaultInRealEmitter() throws {
        let candidates = [
            "AudioEngine/Capture/ProcessTapCapture.swift",
            "../../AudioEngine/Capture/ProcessTapCapture.swift"
        ]
        var sourceContents: String?
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let s = try? String(contentsOfFile: path, encoding: .utf8) {
                sourceContents = s
                break
            }
        }

        // Bundle-relative fallback for `xcodebuild test` runners
        if sourceContents == nil {
            // Walk up from CWD looking for the file
            var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("AudioEngine/Capture/ProcessTapCapture.swift")
                if FileManager.default.fileExists(atPath: candidate.path),
                   let s = try? String(contentsOf: candidate, encoding: .utf8) {
                    sourceContents = s
                    break
                }
                dir.deleteLastPathComponent()
            }
        }

        try XCTSkipIf(sourceContents == nil, "Source file not reachable from test runner CWD; verified by inspection elsewhere")
        XCTAssertTrue(sourceContents!.contains("muteBehavior = .unmuted"),
                      "RealProcessTapEmitter must set CATapDescription.muteBehavior = .unmuted")
    }

    // MARK: testFormatIsFloat32StereoAtNativeRate
    //
    // The MockProcessEmitter delivers Float32 non-interleaved stereo @ 48 kHz.
    // Pull one buffer and verify its format. (The real emitter inherits the
    // device sample rate; this test asserts the contract on the mock path.)
    func testFormatIsFloat32StereoAtNativeRate() async throws {
        let factory = MockEmitterFactory()
        let capture = try ProcessTapCapture(
            pids: [33],
            factory: factory,
            alivenessCheck: { _ in true }
        )
        defer { capture.stop() }

        guard let stream = capture.streams[33] else {
            XCTFail("Expected stream for pid 33")
            return
        }

        var iterator = stream.makeAsyncIterator()
        guard let buffer = await iterator.next() else {
            XCTFail("Expected at least one buffer")
            return
        }

        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(buffer.format.isInterleaved)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertGreaterThanOrEqual(buffer.format.sampleRate, 44_100)
    }

    // MARK: testRealEmitterFactoryRequiresEntitlement
    //
    // The real Core Audio Tap path requires the audio-input entitlement and
    // (on first run) interactive user permission. In CI / unentitled test
    // runners this throws either pidTranslationFailed or tapCreationFailed.
    // Either is acceptable — what matters is that the API symbols exist and
    // the call returns rather than crashing.
    func testRealEmitterFactoryRequiresEntitlement() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "Real Core Audio Tap requires entitled signed app; skipping in CI")

        let factory = RealEmitterFactory()
        // Use our own pid — we may or may not be Core Audio-registered.
        let ourPID = ProcessInfo.processInfo.processIdentifier

        // We expect this to throw OR return a working emitter. Either is
        // acceptable — the assertion is "no crash, well-typed error path".
        do {
            let emitter = try factory.makeEmitter(for: ourPID)
            emitter.teardown()
        } catch let error as CaptureError {
            switch error {
            case .pidTranslationFailed,
                 .tapCreationFailed,
                 .aggregateDeviceCreationFailed,
                 .audioUnitFailed:
                // All expected failure modes for an unentitled runner
                break
            default:
                XCTFail("Unexpected CaptureError: \(error)")
            }
        }
    }
}

// MARK: - Test helpers

/// Small box for the aliveness-toggle test.
final class AlivenessKillSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _alive = true
    var alive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _alive }
        set { lock.lock(); _alive = newValue; lock.unlock() }
    }
}
