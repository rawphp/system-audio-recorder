import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - REQ-035 MockAudioSource Tests

final class MockAudioSourceTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockAudioSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
    }

    // MARK: - Helpers

    /// dBFS of a linear amplitude value (amplitude → dBFS).
    private func linearToDBFS(_ linear: Float) -> Float {
        return 20.0 * log10f(linear)
    }

    /// Peak amplitude of a buffer (max absolute value across all channels and frames).
    private func peakAmplitude(of buf: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        let n = Int(buf.frameLength)
        for ch in 0..<Int(buf.format.channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<n {
                let v = abs(ptr[i])
                if v > peak { peak = v }
            }
        }
        return peak
    }

    /// RMS amplitude of a buffer (all channels combined).
    private func rmsAmplitude(of buf: AVAudioPCMBuffer) -> Float {
        let n = Int(buf.frameLength)
        var sumSq: Float = 0
        var count = 0
        for ch in 0..<Int(buf.format.channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<n {
                sumSq += ptr[i] * ptr[i]
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sqrtf(sumSq / Float(count))
    }

    // MARK: - REQ-035 Verification Step 1: sine preset amplitude

    /// Unit test: `MockAudioSource(.sine(440, -12 dBFS))` emits buffers with peak
    /// amplitude matching −12 dBFS ± 0.5 dB.
    func testSinePeakAmplitudeMatchesTargetDBFS() {
        let targetDBFS: Float = -12.0
        let targetLinear = Float(pow(10.0, Double(targetDBFS) / 20.0))
        let src = MockAudioSource(
            id: "sine-test",
            preset: .sine(frequency: 440, level: targetLinear)
        )

        // Emit several buffers so the sine completes at least one full cycle.
        var collectedBuffers: [AVAudioPCMBuffer] = []
        for _ in 0..<20 { // 20 × 480 frames = 9600 frames ≈ 200 ms at 48 kHz
            var buf: AVAudioPCMBuffer?
            let task = Task { src.emit() }
            // Drain one buffer from the stream.
            let exp = expectation(description: "buffer received")
            Task {
                for await b in src.stream {
                    buf = b
                    exp.fulfill()
                    break
                }
            }
            _ = task
            wait(for: [exp], timeout: 2.0)
            if let b = buf { collectedBuffers.append(b) }
        }
        src.stop()

        XCTAssertFalse(collectedBuffers.isEmpty, "should have received at least one buffer")

        // The peak of a full-amplitude sine buffer equals exactly `level`; pick the
        // buffer with the highest peak across the collected set (ensures we sample a
        // crest, not a zero-crossing transition).
        let maxPeak = collectedBuffers.map { peakAmplitude(of: $0) }.max() ?? 0
        let measuredDBFS = linearToDBFS(maxPeak)

        XCTAssertGreaterThan(maxPeak, 0, "sine should produce non-zero samples")
        XCTAssertEqual(
            measuredDBFS,
            targetDBFS,
            accuracy: 0.5,
            "sine peak (\(measuredDBFS) dBFS) should be within ±0.5 dB of \(targetDBFS) dBFS"
        )
    }

    // MARK: - Sine: cleaner alternative using direct emit()

    func testSinePeakAmplitudeDirect() {
        let targetDBFS: Float = -12.0
        let targetLinear = Float(pow(10.0, Double(targetDBFS) / 20.0))
        let src = MockAudioSource(
            id: "sine-direct",
            preset: .sine(frequency: 440, level: targetLinear),
            framesPerBuffer: 4800  // 100 ms = exactly 4.4 cycles at 440 Hz @ 48 kHz
        )

        // Collect buffers directly by calling emit() and pulling from the stream.
        var maxPeak: Float = 0
        let collectCount = 10

        for _ in 0..<collectCount { src.emit() }
        src.stop()

        let exp = expectation(description: "collect buffers")
        var collected = 0
        Task {
            for await buf in src.stream {
                let p = peakAmplitude(of: buf)
                if p > maxPeak { maxPeak = p }
                collected += 1
                if collected >= collectCount { break }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertGreaterThan(maxPeak, 0)
        let measuredDBFS = linearToDBFS(maxPeak)
        XCTAssertEqual(
            measuredDBFS,
            targetDBFS,
            accuracy: 0.5,
            "sine peak \(measuredDBFS) dBFS should be within ±0.5 dB of \(targetDBFS) dBFS"
        )
    }

    // MARK: - Silence preset

    func testSilenceEmitsZeroSamples() {
        let src = MockAudioSource(id: "silence-test", preset: .silence)

        for _ in 0..<5 { src.emit() }
        src.stop()

        let exp = expectation(description: "collect silence buffers")
        var maxAbsValue: Float = 0
        Task {
            for await buf in src.stream {
                let p = peakAmplitude(of: buf)
                if p > maxAbsValue { maxAbsValue = p }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(maxAbsValue, 0.0, accuracy: 1e-7, "silence preset should emit all-zero buffers")
    }

    // MARK: - White noise preset

    func testWhiteNoiseEmitsNonZeroSamples() {
        let level: Float = 0.5
        let src = MockAudioSource(id: "noise-test", preset: .whiteNoise(level: level))

        for _ in 0..<5 { src.emit() }
        src.stop()

        let exp = expectation(description: "collect noise buffers")
        var maxPeak: Float = 0
        Task {
            for await buf in src.stream {
                let p = peakAmplitude(of: buf)
                if p > maxPeak { maxPeak = p }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertGreaterThan(maxPeak, 0, "white noise should produce non-zero samples")
        XCTAssertLessThanOrEqual(maxPeak, level + 0.001, "noise should not exceed configured level")
    }

    // MARK: - Buffer format

    func testBufferFormatMatchesConfiguration() {
        let src = MockAudioSource(
            id: "fmt-test",
            preset: .silence,
            sampleRate: 44100,
            channelCount: 2,
            framesPerBuffer: 256
        )

        src.emit()
        src.stop()

        let exp = expectation(description: "receive one buffer")
        Task {
            for await buf in src.stream {
                XCTAssertEqual(buf.format.sampleRate, 44100)
                XCTAssertEqual(buf.format.channelCount, 2)
                XCTAssertEqual(buf.frameLength, 256)
                XCTAssertFalse(buf.format.isInterleaved)
                XCTAssertEqual(buf.format.commonFormat, .pcmFormatFloat32)
                exp.fulfill()
                break
            }
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - Mid-stream preset switching

    func testMidStreamPresetSwitch() {
        let src = MockAudioSource(
            id: "switch-test",
            preset: .silence,
            framesPerBuffer: 480
        )

        // Emit silence buffers first.
        for _ in 0..<5 { src.emit() }

        // Switch to sine mid-stream.
        let sineLevel: Float = Float(pow(10.0, -6.0 / 20.0))  // -6 dBFS
        src.setPreset(.sine(frequency: 1000, level: sineLevel))

        // Emit sine buffers.
        for _ in 0..<10 { src.emit() }
        src.stop()

        let exp = expectation(description: "observe both silence and sine")
        var silentCount = 0
        var sineCount = 0
        var bufIdx = 0
        Task {
            for await buf in src.stream {
                let p = peakAmplitude(of: buf)
                if bufIdx < 5 {
                    if p < 1e-7 { silentCount += 1 }
                } else {
                    if p > 0.01 { sineCount += 1 }
                }
                bufIdx += 1
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertEqual(silentCount, 5, "first 5 buffers should be silent")
        XCTAssertGreaterThan(sineCount, 0, "buffers after preset switch should contain audio")
    }

    // MARK: - stop() is idempotent

    func testStopIsIdempotent() {
        let src = MockAudioSource(id: "stop-test", preset: .silence)
        src.stop()
        src.stop()  // Should not crash or deadlock.
    }

    // MARK: - driveAsync produces expected buffer count

    func testDriveAsyncProducesBuffers() {
        let src = MockAudioSource(id: "drive-test", preset: .silence)
        let count = 30
        src.driveAsync(count: count)

        let exp = expectation(description: "all buffers received")
        var received = 0
        Task {
            for await _ in src.stream {
                received += 1
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(received, count, "driveAsync should emit exactly \(count) buffers then stop")
    }

    // MARK: - REQ-035 Verification Step 2: RecordingSession with MockAudioSource

    /// AC#1 + AC#2 integration: `RecordingSession.start → stop` with `MockAudioSource`
    /// sources runs to completion without involving any real audio device (no
    /// `AVAudioEngine` for capture is instantiated — `MockAudioSource` bypasses all
    /// hardware access entirely). The test asserts:
    ///   - State transitions are valid (idle → recording → stopped).
    ///   - At least one WAV file URL is returned.
    ///   - The WAV file exists on disk.
    ///
    /// Note on "no real audio device opened": `RecordingSession` opens
    /// `AVAudioEngine` only inside `ProcessTapSourceEmitter` / `MicrophoneSourceEmitter`
    /// adapters (REQ-007 / REQ-008). When sources are `MockAudioSource` instances,
    /// those adapters are never constructed — the session receives a plain
    /// `RecordingSourceEmitter` stream.  Therefore, by construction, zero hardware
    /// audio devices are opened in this test. No instrumentation seam is needed.
    func testRecordingSessionRoundTripWithMockAudioSource() async throws {
        let session = RecordingSession()
        let s0 = await session.state
        XCTAssertEqual(s0, .idle)

        let src1 = MockAudioSource.defaultSine(id: "sine-src")
        let src2 = MockAudioSource.defaultNoise(id: "noise-src")

        let config = SessionConfig(
            sources: [
                SessionConfig.Source(id: "sine-src", emitter: src1),
                SessionConfig.Source(id: "noise-src", emitter: src2),
            ],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T12-00-00"
        )

        try await session.start(config: config)
        let s1 = await session.state
        XCTAssertEqual(s1, .recording, "session should be recording after start")

        // Drive both sources for ~50 buffers to produce audible content.
        src1.driveAsync(count: 50)
        src2.driveAsync(count: 50)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let urls = await session.stop()
        let s2 = await session.state
        XCTAssertEqual(s2, .stopped)
        XCTAssertEqual(urls.count, 1, "mixed mode should produce exactly 1 WAV file")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: urls[0].path),
            "WAV file should exist on disk: \(urls[0].path)"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: urls[0].path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 44, "WAV file should contain more than just the header")
    }

    // MARK: - Separate mode with MockAudioSource

    func testRecordingSessionSeparateModeWithMockSource() async throws {
        let session = RecordingSession()
        let src = MockAudioSource.defaultSine(id: "sine-sep")

        let config = SessionConfig(
            sources: [SessionConfig.Source(id: "sine-sep", emitter: src)],
            outputMode: .separate,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T12-01-00"
        )

        try await session.start(config: config)
        src.driveAsync(count: 30)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let urls = await session.stop()
        // Separate mode with 1 source = 1 source file + 1 mix file = 2 files.
        XCTAssertEqual(urls.count, 2, "separate mode with 1 source should yield 2 WAV files")
    }

    // MARK: - AudioBufferEmitter typealias is accessible

    func testAudioBufferEmitterTypealiasIsAvailable() {
        // This test compiles only if the typealias `AudioBufferEmitter = RecordingSourceEmitter`
        // is visible in the test target. It verifies AC#1's alias contract.
        let src = MockAudioSource.defaultSilence(id: "alias-test")
        let emitter: any AudioBufferEmitter = src  // must compile
        _ = emitter
    }

    // MARK: - Convenience factory methods

    func testDefaultSineFactory() {
        let src = MockAudioSource.defaultSine()
        XCTAssertEqual(src.id, "mock-sine")
    }

    func testDefaultNoiseFactory() {
        let src = MockAudioSource.defaultNoise()
        XCTAssertEqual(src.id, "mock-noise")
    }

    func testDefaultSilenceFactory() {
        let src = MockAudioSource.defaultSilence()
        XCTAssertEqual(src.id, "mock-silence")
    }
}
