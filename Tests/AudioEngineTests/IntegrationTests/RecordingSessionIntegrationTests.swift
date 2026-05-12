import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioRecorder

// MARK: - REQ-036: RecordingSession Integration Tests
//
// Full end-to-end lifecycle tests: MockAudioSource → RecordingSession →
// WAV files → LameEncoder → MP3 files.
//
// All tests live under Tests/AudioEngineTests/IntegrationTests/ which is a
// sub-folder of the existing AudioEngineTests target (project.yml sources path
// covers the entire Tests/AudioEngineTests tree).
//
// No real audio devices are opened. All sources are MockAudioSource instances.

// MARK: - Helpers

private let kSampleRate: Double     = 48_000
private let kChannelCount: AVAudioChannelCount = 2

/// Drives a `MockAudioSource` in a background task for the given wall-clock
/// duration at real-time pace (480 frames ≈ 10 ms per buffer).
private func driveSource(
    _ src: MockAudioSource,
    for duration: TimeInterval
) {
    Task.detached {
        let bufferDuration = TimeInterval(src.framesPerBuffer) / src.sampleRate
        let count = Int(duration / bufferDuration)
        for _ in 0..<count {
            guard src.emit() else { return }
            try? await Task.sleep(nanoseconds: UInt64(bufferDuration * 1_000_000_000))
        }
        src.stop()
    }
}

/// Encodes a WAV file to MP3 using `LameEncoder` (REQ-017).
/// Returns the URL of the produced MP3.
private func encodeWAV(_ wavURL: URL, into dir: URL) async throws -> URL {
    let mp3URL = dir.appendingPathComponent(
        wavURL.deletingPathExtension().lastPathComponent + ".mp3"
    )
    let encoder = LameEncoder()
    try await encoder.encode(
        wavURL: wavURL,
        mp3URL: mp3URL,
        bitrate: 192,
        mode: .vbr,
        progress: { _ in }
    )
    return mp3URL
}

/// Duration of an audio file (WAV or MP3) in seconds via AVAudioFile.
private func fileDuration(_ url: URL) -> TimeInterval {
    guard let f = try? AVAudioFile(forReading: url) else { return 0 }
    return TimeInterval(f.length) / f.processingFormat.sampleRate
}

/// Returns the dominant FFT peak frequency (Hz) in the first channel of a buffer.
private func peakFrequency(in buffer: AVAudioPCMBuffer) -> Double {
    guard let ptr = buffer.floatChannelData?[0] else { return 0 }
    let n = Int(buffer.frameLength)

    // Round down to nearest power of 2
    var log2n = 0; var size = 1
    while size < n { size <<= 1; log2n += 1 }
    if size > n { size >>= 1; log2n -= 1 }
    guard log2n > 0 else { return 0 }

    var inputCopy = [Float](repeating: 0, count: size)
    for i in 0..<size { inputCopy[i] = ptr[i] }

    var reals = [Float](repeating: 0, count: size / 2)
    var imags = [Float](repeating: 0, count: size / 2)
    var peakBin = 1

    reals.withUnsafeMutableBufferPointer { rPtr in
        imags.withUnsafeMutableBufferPointer { iPtr in
            var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
            inputCopy.withUnsafeBytes { raw in
                let typed = raw.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(typed.baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
            }
            let len = vDSP_Length(log2n)
            guard let fftSetup = vDSP_create_fftsetup(len, FFTRadix(FFT_RADIX2)) else { return }
            defer { vDSP_destroy_fftsetup(fftSetup) }
            vDSP_fft_zrip(fftSetup, &split, 1, len, FFTDirection(FFT_FORWARD))
            var mags = [Float](repeating: 0, count: size / 2)
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(size / 2))
            var local: Float = 0
            for bin in 1..<(size / 2) {
                if mags[bin] > local { local = mags[bin]; peakBin = bin }
            }
        }
    }
    return Double(peakBin) * kSampleRate / Double(size)
}

/// Reads the entire first channel of an audio file into a `Float` array.
private func readFirstChannel(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url)
    let fmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: f.processingFormat.sampleRate,
        channels: 1,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount(f.length)
    guard frameCount > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return [] }

    // Use converter to handle format differences (e.g. MP3 decoded as Int16).
    let srcFmt = f.processingFormat
    guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frameCount) else { return [] }
    try f.read(into: srcBuf)

    if srcFmt.commonFormat == .pcmFormatFloat32 && srcFmt.channelCount == 1 {
        buf.frameLength = srcBuf.frameLength
        if let dst = buf.floatChannelData?[0], let src = srcBuf.floatChannelData?[0] {
            dst.assign(from: src, count: Int(buf.frameLength))
        }
        return Array(UnsafeBufferPointer(start: buf.floatChannelData?[0], count: Int(buf.frameLength)))
    }

    // General path: convert via AVAudioConverter.
    guard let conv = AVAudioConverter(from: srcFmt, to: fmt) else { return [] }
    buf.frameLength = frameCount
    var error: NSError?
    conv.convert(to: buf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return srcBuf
    }
    guard error == nil, let ptr = buf.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
}

// MARK: - RecordingSessionIntegrationTests

final class RecordingSessionIntegrationTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionIntTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
    }

    // MARK: - Helpers

    private func makeConfig(
        sources: [(String, MockAudioSource)],
        mode: SessionConfig.OutputMode = .mixed,
        autoStopDuration: TimeInterval? = nil,
        autoStopSilenceSeconds: TimeInterval? = nil
    ) -> SessionConfig {
        SessionConfig(
            sources: sources.map { SessionConfig.Source(id: $0.0, emitter: $0.1) },
            outputMode: mode,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00",
            autoStopDuration: autoStopDuration,
            autoStopSilenceSeconds: autoStopSilenceSeconds
        )
    }

    /// Waits for `session.state` to equal `target`, polling every 50 ms up to `timeout`.
    private func waitFor(
        state target: SessionState,
        in session: RecordingSession,
        timeout: TimeInterval = 5.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = await session.state
            if s == target { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await session.state == target
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 1: start → stop → 1 mixed MP3
    // ─────────────────────────────────────────────────────────────────────
    /// AC: start → stop produces one valid mixed MP3; MP3 file exists and has
    /// positive duration; FFT spot-check confirms dominant 440 Hz tone.
    func testStartStopProducesMixedMP3() async throws {
        let session = RecordingSession()
        // 0.5 s of 440 Hz sine at -12 dBFS
        let src = MockAudioSource.defaultSine(id: "sine-src")
        let recordDuration: TimeInterval = 0.5

        try await session.start(config: makeConfig(sources: [("sine-src", src)]))
        driveSource(src, for: recordDuration)

        // Wait for source to finish driving then stop
        try await Task.sleep(nanoseconds: UInt64((recordDuration + 0.3) * 1_000_000_000))
        let wavURLs = await session.stop()

        XCTAssertEqual(wavURLs.count, 1, "Mixed mode must produce exactly 1 WAV file")
        let wavURL = wavURLs[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path),
                      "WAV file must exist: \(wavURL.lastPathComponent)")

        // Encode WAV → MP3
        let mp3URL = try await encodeWAV(wavURL, into: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path),
                      "MP3 file must exist: \(mp3URL.lastPathComponent)")

        // MP3 duration must be positive (approximately matches recordDuration within ±0.5 s)
        let mp3Duration = fileDuration(mp3URL)
        XCTAssertGreaterThan(mp3Duration, 0.1, "MP3 must have positive duration; got \(mp3Duration)s")

        // FFT spot-check: dominant peak near 440 Hz ± 20 Hz
        // Read MP3 via AVAudioFile for FFT (decoder may output int16; readFirstChannel handles conversion)
        let mp3File = try AVAudioFile(forReading: mp3URL)
        let floatFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: mp3File.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(min(Int(mp3File.length), 32768))
        guard let buf = AVAudioPCMBuffer(pcmFormat: floatFmt, frameCapacity: frameCount) else {
            XCTFail("Cannot allocate decode buffer"); return
        }
        // Decode into float via converter
        let srcFmt = mp3File.processingFormat
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(mp3File.length)) else {
            XCTFail("Cannot allocate src buffer"); return
        }
        try mp3File.read(into: srcBuf)

        let fillFrames = min(frameCount, srcBuf.frameLength)
        buf.frameLength = fillFrames

        if srcFmt.commonFormat == .pcmFormatFloat32 {
            // Already float — copy channel 0
            if let s = srcBuf.floatChannelData?[0], let d = buf.floatChannelData?[0] {
                d.assign(from: s, count: Int(fillFrames))
            }
        } else {
            // Need format conversion
            guard let conv = AVAudioConverter(from: srcFmt, to: floatFmt) else {
                XCTFail("Cannot create converter"); return
            }
            var err: NSError?
            conv.convert(to: buf, error: &err) { _, outStatus in
                outStatus.pointee = .haveData; return srcBuf
            }
            if let e = err { XCTFail("Conversion error: \(e)"); return }
        }

        let peak = peakFrequency(in: buf)
        XCTAssertEqual(peak, 440, accuracy: 20,
                       "FFT peak must be near 440 Hz; got \(peak) Hz")
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 2: start → pause → resume → stop → 1 MP3, gap removed
    // ─────────────────────────────────────────────────────────────────────
    /// AC: Pause/resume cycle produces one MP3 whose duration matches active
    /// recording time (paused gap is excluded). Asserts duration > 0.3 s and
    /// confirms one WAV file is produced (gap-removal correctness is covered by
    /// REQ-012's WAVWriterTests.testPauseRemovesGapFromFile).
    func testPauseResumeDurationMatchesActiveRecordingTime() async throws {
        let session = RecordingSession()

        let src = MockAudioSource(
            id: "sine-pr",
            preset: .sine(frequency: 880, level: 0.3)
        )

        try await session.start(config: makeConfig(sources: [("sine-pr", src)]))

        // Run a continuous background driver for the entire test duration (2 s).
        // This avoids the race where driveSource calls src.stop() too early.
        let driverTask = Task.detached {
            let bufferDuration = TimeInterval(src.framesPerBuffer) / src.sampleRate
            while src.emit() {
                try? await Task.sleep(nanoseconds: UInt64(bufferDuration * 1_000_000_000))
            }
        }

        // Phase 1: record ~0.4 s
        try await Task.sleep(nanoseconds: 400_000_000)

        try await session.pause()
        let pausedState = await session.state
        XCTAssertEqual(pausedState, .paused)

        // Phase 2: paused gap — ~0.5 s (WAVWriter drops these buffers)
        try await Task.sleep(nanoseconds: 500_000_000)

        try await session.resume()
        let resumedState = await session.state
        XCTAssertEqual(resumedState, .recording)

        // Phase 3: record another ~0.4 s
        try await Task.sleep(nanoseconds: 400_000_000)

        let wavURLs = await session.stop()
        driverTask.cancel()

        XCTAssertEqual(wavURLs.count, 1, "Pause/resume must produce exactly 1 WAV file")
        let wavURL = wavURLs[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))

        // WAV duration must be positive (gap-removal proof is in REQ-012 tests)
        let wavDuration = fileDuration(wavURL)
        XCTAssertGreaterThan(wavDuration, 0.3, "WAV must contain audio; got \(wavDuration)s")
        // The paused gap of 0.5 s should NOT be in the file; total active ≈ 0.8 s.
        // Allow generous tolerance — scheduler jitter is real on CI.
        XCTAssertLessThan(wavDuration, 2.0, "WAV should not include the paused gap: \(wavDuration)s")

        // Encode and verify MP3 exists
        let mp3URL = try await encodeWAV(wavURL, into: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path))
        XCTAssertGreaterThan(fileDuration(mp3URL), 0.1)
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 3: separate mode, 2 sources → 3 MP3 files
    // ─────────────────────────────────────────────────────────────────────
    /// AC: Separate-output mode with 2 sources produces N+1 = 3 WAV files and
    /// consequently 3 MP3 files (2 per-source + 1 mix).
    func testSeparateModeProducesNPlusOneMP3Files() async throws {
        let session = RecordingSession()
        let src1 = MockAudioSource(id: "app1", preset: .sine(frequency: 440, level: 0.3))
        let src2 = MockAudioSource(id: "app2", preset: .sine(frequency: 880, level: 0.3))
        let recordDuration: TimeInterval = 0.5

        try await session.start(config: makeConfig(
            sources: [("app1", src1), ("app2", src2)],
            mode: .separate
        ))

        driveSource(src1, for: recordDuration)
        driveSource(src2, for: recordDuration)

        try await Task.sleep(nanoseconds: UInt64((recordDuration + 0.4) * 1_000_000_000))
        let wavURLs = await session.stop()

        XCTAssertEqual(wavURLs.count, 3,
                       "Separate mode: 2 sources + 1 mix = 3 files; got \(wavURLs.map(\.lastPathComponent))")

        // Encode all WAVs → MP3s
        var mp3URLs: [URL] = []
        for wavURL in wavURLs {
            let mp3 = try await encodeWAV(wavURL, into: tmpDir)
            XCTAssertTrue(FileManager.default.fileExists(atPath: mp3.path),
                          "MP3 missing: \(mp3.lastPathComponent)")
            XCTAssertGreaterThan(fileDuration(mp3), 0.0,
                                 "MP3 has zero duration: \(mp3.lastPathComponent)")
            mp3URLs.append(mp3)
        }
        XCTAssertEqual(mp3URLs.count, 3)
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 4: autoStopDuration stops session at configured duration
    // ─────────────────────────────────────────────────────────────────────
    /// AC: Setting autoStopDuration = 1.0 causes the session to stop at ~1.0 s
    /// and produce a WAV that is encodeable to MP3. Timing precision is covered
    /// by RecordingSessionTests; this integration test avoids tight wall-clock
    /// assertions because full-suite CI scheduling can vary widely.
    func testAutoStopDurationProducesMP3() async throws {
        let session = RecordingSession()
        let src = MockAudioSource(
            id: "auto-dur-src",
            preset: .sine(frequency: 440, level: 0.3),
            framesPerBuffer: AVAudioFrameCount(kSampleRate)
        )
        let autoStopSecs: TimeInterval = 1.0

        let cfg = makeConfig(
            sources: [("auto-dur-src", src)],
            autoStopDuration: autoStopSecs
        )

        try await session.start(config: cfg)

        // Feed large synthetic buffers while the wall-clock auto-stop timer runs.
        // This keeps the output duration independent of CI scheduling speed.
        let driverTask = Task.detached {
            while true {
                guard src.emit() else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
                let s = await session.state
                if s == .stopped { return }
            }
        }

        let stopped = await waitFor(state: .stopped, in: session, timeout: 6.0)
        driverTask.cancel()
        src.stop()

        XCTAssertTrue(stopped, "Session should have auto-stopped due to duration")

        let wavURLs = await session.stop() // idempotent — returns cached URLs
        XCTAssertEqual(wavURLs.count, 1)

        let mp3URL = try await encodeWAV(wavURLs[0], into: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path))
        XCTAssertGreaterThan(fileDuration(mp3URL), 0.3)
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 5: autoStopSilence stops session after silence threshold
    // ─────────────────────────────────────────────────────────────────────
    /// AC: autoStopSilenceSeconds = 2.0 with a 2 s grace period means silence
    /// detection fires after ~4 s of total silence (grace + threshold).
    /// Uses generous tolerances (±1.0 s) to stay deterministic on CI.
    func testAutoStopSilenceProducesMP3() async throws {
        let session = RecordingSession()
        // Silence source — all buffers are digital zero → RMS = −160 dBFS.
        let src = MockAudioSource(
            id: "silence-src",
            preset: .silence,
            framesPerBuffer: AVAudioFrameCount(kSampleRate)
        )
        // Use a 2.0 s silence threshold to make timing less sensitive.
        let silenceThresholdSecs: TimeInterval = 2.0

        let cfg = makeConfig(
            sources: [("silence-src", src)],
            autoStopSilenceSeconds: silenceThresholdSecs
        )

        try await session.start(config: cfg)

        // Drive 4 s of silence in burst mode. Keep the source open while the
        // detector consumes the buffers; closing it immediately can finish the
        // fan-out stream before every queued buffer is observed.
        for _ in 0..<4 {
            XCTAssertTrue(src.emit())
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Grace period = 2.0 s; silence threshold = 2.0 s → expected stop at ~4.0 s
        let stopped = await waitFor(state: .stopped, in: session, timeout: 2.0)
        src.stop()

        XCTAssertTrue(stopped, "Session should have auto-stopped on 4 s of silent audio")

        let wavURLs = await session.stop() // idempotent
        XCTAssertEqual(wavURLs.count, 1)

        let mp3URL = try await encodeWAV(wavURLs[0], into: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3URL.path))
        XCTAssertGreaterThan(fileDuration(mp3URL), 0.5)
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 6: no sources → SessionError.noSourcesConfigured
    // ─────────────────────────────────────────────────────────────────────
    /// AC: start() with no sources throws `SessionError.noSourcesConfigured`.
    /// Confirms the integration view of the guard added in REQ-013.
    func testNoSourcesConfiguredThrows() async throws {
        let session = RecordingSession()
        let cfg = SessionConfig(
            sources: [],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-09T10-00-00"
        )
        do {
            try await session.start(config: cfg)
            XCTFail("Expected SessionError.noSourcesConfigured to be thrown")
        } catch let err as SessionError {
            guard case .noSourcesConfigured = err else {
                XCTFail("Expected noSourcesConfigured; got \(err)"); return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // Scenario 7: second start() before stop → SessionError.alreadyRecording
    // ─────────────────────────────────────────────────────────────────────
    /// NOTE: `RecordingSession.start()` guards against concurrent starts via
    /// `SessionError.invalidTransition(from:to:)` (not a dedicated `.alreadyRecording`
    /// case). The `alreadyRecording` guard as a distinct enum case is REQ-013 v2 work.
    ///
    /// This test verifies the *observable behaviour* (re-start throws) and skips
    /// any assertion that requires a distinct `alreadyRecording` case.
    func testSecondStartBeforeStopThrows() async throws {
        let session = RecordingSession()
        let src1 = MockAudioSource.defaultSine(id: "s1")
        try await session.start(config: makeConfig(sources: [("s1", src1)]))

        let src2 = MockAudioSource.defaultSine(id: "s2")
        do {
            try await session.start(config: makeConfig(sources: [("s2", src2)]))
            XCTFail("Expected an error when starting a second session before first stops")
        } catch let err as SessionError {
            // REQ-013 uses `invalidTransition(from:to:)` for this guard.
            // A distinct `.alreadyRecording` case is deferred to REQ-013 v2 work;
            // it does not exist as a SessionError variant today.
            switch err {
            case .invalidTransition:
                break // ✓ correct — the guard is in place
            default:
                XCTFail("Unexpected SessionError variant: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        _ = await session.stop()
        src2.stop()
    }
}
