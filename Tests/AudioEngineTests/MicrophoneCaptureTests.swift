import XCTest
import AVFoundation
import Darwin
@testable import SystemAudioRecorder

// MARK: - Mock MicInputNode

/// Synthetic mic input node. Starts a timer that calls the installed tap block
/// with synthetic Float32 stereo 48 kHz buffers at ~100 Hz, until the tap is
/// removed.
final class MockMicInputNode: MicInputNode {

    private var tapBlock: AVAudioNodeTapBlock?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "MockMicInputNode")

    let mockFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else { fatalError("Could not build mock format") }
        return fmt
    }()

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    ) {
        tapBlock = block
        startFiring()
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        stopFiring()
        tapBlock = nil
    }

    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
        mockFormat
    }

    private func startFiring() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in
            self?.fire()
        }
        t.resume()
        timer = t
    }

    private func stopFiring() {
        timer?.cancel()
        timer = nil
    }

    private func fire() {
        guard let block = tapBlock else { return }
        let frameCount: AVAudioFrameCount = 480 // 10 ms @ 48 kHz
        guard let buffer = AVAudioPCMBuffer(pcmFormat: mockFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let time = AVAudioTime(hostTime: mach_absolute_time())
        block(buffer, time)
    }
}

// MARK: - Mock MicAudioEngine

/// Mock engine — owns a `MockMicInputNode` and records start/stop calls.
final class MockMicEngine: MicAudioEngine {
    let _micInputNode: MockMicInputNode
    var micInputNode: MicInputNode { _micInputNode }

    private(set) var engineStarted = false
    private(set) var engineStopped = false
    var startShouldThrow: Error? = nil

    init(inputNode: MockMicInputNode = MockMicInputNode()) {
        self._micInputNode = inputNode
    }

    func startEngine() throws {
        if let err = startShouldThrow { throw err }
        engineStarted = true
    }

    func stopEngine() {
        engineStopped = true
    }
}

// MARK: - Tests

final class MicrophoneCaptureTests: XCTestCase {

    // MARK: testDefaultInitProducesStream
    //
    // Initialising with a mock engine must succeed and expose a stream.
    func testDefaultInitProducesStream() throws {
        let engine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: engine)
        defer { capture.stop() }
        _ = capture.stream
        XCTAssertTrue(engine.engineStarted)
    }

    // MARK: testStreamProducesBuffers
    //
    // After init, the mock node fires tap blocks; assert ≥100 Float32
    // non-interleaved buffers arrive within 5 seconds.
    func testStreamProducesBuffers() async throws {
        let engine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: engine)
        defer { capture.stop() }

        var count = 0
        let deadline = Date().addingTimeInterval(5.0)

        for await buffer in capture.stream {
            XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
            XCTAssertFalse(buffer.format.isInterleaved)
            count += 1
            if count >= 100 { break }
            if Date() > deadline { break }
        }

        XCTAssertGreaterThanOrEqual(count, 100, "Expected ≥100 buffers within 5s, got \(count)")
    }

    // MARK: testStopTearsDownEngineAndStream
    //
    // After stop() the mock engine's stopEngine() must have been called.
    func testStopTearsDownEngineAndStream() async throws {
        let mockEngine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: mockEngine)

        var preStopCount = 0
        let collectTask = Task {
            for await _ in capture.stream {
                preStopCount += 1
                if preStopCount >= 5 { break }
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        capture.stop()
        await collectTask.value

        XCTAssertTrue(mockEngine.engineStopped, "stop() must call engine.stopEngine()")
    }

    // MARK: testStopIsIdempotent
    //
    // Calling stop() twice must not crash.
    func testStopIsIdempotent() throws {
        let engine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: engine)
        capture.stop()
        XCTAssertNoThrow(capture.stop())
    }

    // MARK: testSetDeviceUnknownIDThrows
    //
    // Passing a deviceID that no AVCaptureDevice can resolve must throw
    // CaptureError.deviceUnavailable.
    func testSetDeviceUnknownIDThrows() throws {
        let engine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: engine)
        defer { capture.stop() }

        XCTAssertThrowsError(
            try capture.setDevice(deviceID: "com.no-such-device-\(UUID().uuidString)")
        ) { error in
            guard case CaptureError.deviceUnavailable = error else {
                XCTFail("Expected CaptureError.deviceUnavailable, got \(error)")
                return
            }
        }
    }

    // MARK: testEngineStartFailureIsRethrown
    //
    // If the engine fails to start, init must rethrow cleanly.
    func testEngineStartFailureIsRethrown() {
        struct FakeAudioError: Error {}
        let mockEngine = MockMicEngine()
        mockEngine.startShouldThrow = FakeAudioError()
        XCTAssertThrowsError(try MicrophoneCapture(engine: mockEngine))
    }

    // MARK: testPermissionRevokedClosesStream
    //
    // Simulate permission revocation via `_simulatePermissionRevoked()`;
    // assert the stream closes (async iteration terminates).
    func testPermissionRevokedClosesStream() async throws {
        let engine = MockMicEngine()
        let capture = try MicrophoneCapture(engine: engine)

        let streamClosed = expectation(description: "stream closed after permission revoked")
        let drainTask = Task {
            for await _ in capture.stream { }
            streamClosed.fulfill()
        }

        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        capture._simulatePermissionRevoked()

        await fulfillment(of: [streamClosed], timeout: 3.0)
        await drainTask.value
    }
}
