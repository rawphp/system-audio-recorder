import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioToMP3

// MARK: - Helpers

/// Canonical 48 kHz Float32 stereo format.
private let canonicalFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48000,
    channels: 2,
    interleaved: false
)!

/// Generates a canonical 48 kHz Float32 stereo buffer with a sine at `frequency` Hz.
private func sineBuffer(
    frequency: Double,
    frameCount: AVAudioFrameCount = 480,   // 10 ms at 48 kHz
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    guard let buf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frameCount) else {
        fatalError("Cannot allocate sineBuffer")
    }
    buf.frameLength = frameCount
    let sr = canonicalFormat.sampleRate
    let w  = 2.0 * Double.pi * frequency / sr
    for ch in 0..<Int(canonicalFormat.channelCount) {
        guard let ptr = buf.floatChannelData?[ch] else { continue }
        for i in 0..<Int(frameCount) {
            ptr[i] = amplitude * Float(sin(w * Double(i)))
        }
    }
    return buf
}

/// Returns the dominant FFT peak frequency (Hz) in the first channel of `buffer`.
private func peakFrequency(in buffer: AVAudioPCMBuffer) -> Double {
    guard let ptr = buffer.floatChannelData?[0] else { return 0 }
    let n = Int(buffer.frameLength)
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
    return Double(peakBin) * canonicalFormat.sampleRate / Double(size)
}

/// Reads a WAV file and returns its `AVAudioPCMBuffer` (entire file).
private func readWAV(at url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    guard let buf = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else {
        throw NSError(domain: "WAVWriterTests", code: -1)
    }
    try file.read(into: buf)
    return buf
}

/// Builds an `AsyncStream` that emits `bufferCount` buffers then finishes.
private func makeFiniteStream(
    frequency: Double,
    bufferCount: Int,
    frameCount: AVAudioFrameCount = 480
) -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { cont in
        DispatchQueue(label: "WAVWriterTests-\(frequency)").async {
            for _ in 0..<bufferCount {
                cont.yield(sineBuffer(frequency: frequency, frameCount: frameCount))
                Thread.sleep(forTimeInterval: 0.01) // 10 ms
            }
            cont.finish()
        }
    }
}

// MARK: - WAVWriterTests

final class WAVWriterTests: XCTestCase {

    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - testMixedModeWritesValidWAV
    //
    // Write 5 seconds of a 1 kHz tone in mixed mode.
    // Assert:
    //   • Exactly one file URL returned.
    //   • WAV has 48 kHz sample rate, 2 channels.
    //   • Duration is 5.0 s ± 0.1 s.
    //   • Dominant FFT peak is 1 kHz ± 30 Hz (32768 frames ≈ 0.68 s window).
    func testMixedModeWritesValidWAV() async throws {
        // 5 s = 500 buffers × 480 frames at 48 kHz
        let bufferCount = 500
        let stream = makeFiniteStream(frequency: 1000, bufferCount: bufferCount)

        let writer = WAVWriter(outputFolder: tmpDir, timestamp: "2026-01-01T00-00-00")
        let urls = try await writer.runMixed(stream: stream)

        XCTAssertEqual(urls.count, 1, "Mixed mode must produce exactly one file")
        guard let url = urls.first else { return }

        // File must exist on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let buf = try readWAV(at: url)
        let sampleRate = buf.format.sampleRate
        let channels   = buf.format.channelCount

        XCTAssertEqual(sampleRate, 48000, accuracy: 1, "Sample rate must be 48 kHz")
        XCTAssertEqual(channels, 2, "Must be stereo")

        let expectedFrames = Double(bufferCount) * 480.0
        let actualFrames   = Double(buf.frameLength)
        let durationDiff   = abs(actualFrames - expectedFrames) / sampleRate
        XCTAssertLessThanOrEqual(durationDiff, 0.1, "Duration must be within 0.1 s of 5 s")

        // FFT on a representative window
        let windowSize: AVAudioFrameCount = 32768
        guard let window = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: windowSize) else {
            XCTFail("Cannot create window buffer"); return
        }
        window.frameLength = min(windowSize, buf.frameLength)
        if let src = buf.floatChannelData?[0], let dst = window.floatChannelData?[0] {
            dst.assign(from: src, count: Int(window.frameLength))
        }
        let peak = peakFrequency(in: window)
        XCTAssertEqual(peak, 1000, accuracy: 30, "Dominant FFT peak must be 1 kHz ± 30 Hz")
    }

    // MARK: - testPauseRemovesGapFromFile
    //
    // Write 3 s, pause 2 s, resume, write 3 s, close.
    // The resulting file must be 6.0 s ± 0.1 s (not 8 s).
    func testPauseRemovesGapFromFile() async throws {
        // 3 s = 300 buffers × 480 frames at 48 kHz
        let framesPerBuffer = AVAudioFrameCount(480)
        let buffersPerPhase = 300

        // Build a controllable stream using a continuation
        var writeCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let stream = AsyncStream<AVAudioPCMBuffer> { writeCont = $0 }

        let writer = WAVWriter(outputFolder: tmpDir, timestamp: "2026-01-01T00-00-01")

        // Start writing asynchronously
        let writeTask = Task {
            try await writer.runMixed(stream: stream)
        }

        // Phase 1: write 3 s
        for _ in 0..<buffersPerPhase {
            writeCont.yield(sineBuffer(frequency: 440, frameCount: framesPerBuffer))
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Pause — freeze the write cursor
        await writer.pause()

        // Simulate 2-second gap (no buffers consumed)
        Thread.sleep(forTimeInterval: 2.0)

        // Resume then write phase 2
        await writer.resume()

        for _ in 0..<buffersPerPhase {
            writeCont.yield(sineBuffer(frequency: 440, frameCount: framesPerBuffer))
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Close the stream
        writeCont.finish()

        let urls = try await writeTask.value
        guard let url = urls.first else {
            XCTFail("No file returned"); return
        }

        let buf = try readWAV(at: url)
        let expectedFrames = Double(buffersPerPhase * 2) * Double(framesPerBuffer)   // 6 s
        let actualFrames   = Double(buf.frameLength)
        let durationDiff   = abs(actualFrames - expectedFrames) / buf.format.sampleRate
        XCTAssertLessThanOrEqual(durationDiff, 0.1,
            "File must be 6.0 s ± 0.1 s; got \(actualFrames / buf.format.sampleRate) s")
    }

    // MARK: - testSeparateModeWritesNPlusOneFiles
    //
    // Separate mode with 2 sources must produce 3 files:
    // source0 file, source1 file, and a Mix file.
    func testSeparateModeWritesNPlusOneFiles() async throws {
        let bufferCount = 50
        let sources: [(String, AsyncStream<AVAudioPCMBuffer>)] = [
            ("Source0", makeFiniteStream(frequency: 440, bufferCount: bufferCount)),
            ("Source1", makeFiniteStream(frequency: 880, bufferCount: bufferCount)),
        ]
        let mixStream = makeFiniteStream(frequency: 660, bufferCount: bufferCount)

        let writer = WAVWriter(outputFolder: tmpDir, timestamp: "2026-01-01T00-00-02")
        let urls = try await writer.runSeparate(sources: sources, mixStream: mixStream)

        XCTAssertEqual(urls.count, 3, "Separate mode must produce N+1 files (2 sources + mix)")

        let names = urls.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains { $0.hasSuffix("- Source0.wav") }, "Must have Source0 file")
        XCTAssertTrue(names.contains { $0.hasSuffix("- Source1.wav") }, "Must have Source1 file")
        XCTAssertTrue(names.contains { $0.hasSuffix("- Mix.wav") }, "Must have Mix file")

        // All files must exist on disk
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) missing")
        }
    }

    // MARK: - testFileNamingConvention
    //
    // Mixed mode: file is named `<timestamp>.wav`.
    // Separate mode: files are named `<timestamp> - <SourceName>.wav` and `<timestamp> - Mix.wav`.
    func testFileNamingConvention() async throws {
        let timestamp = "2026-01-01T12-34-56"
        let bufferCount = 10

        // Mixed
        let mixWriter = WAVWriter(outputFolder: tmpDir, timestamp: timestamp)
        let mixURLs = try await mixWriter.runMixed(
            stream: makeFiniteStream(frequency: 440, bufferCount: bufferCount)
        )
        XCTAssertEqual(mixURLs.first?.lastPathComponent, "\(timestamp).wav")

        // Separate
        let sepWriter = WAVWriter(outputFolder: tmpDir, timestamp: timestamp + "-sep")
        let sources: [(String, AsyncStream<AVAudioPCMBuffer>)] = [
            ("SystemAudio", makeFiniteStream(frequency: 440, bufferCount: bufferCount)),
        ]
        let sepURLs = try await sepWriter.runSeparate(
            sources: sources,
            mixStream: makeFiniteStream(frequency: 440, bufferCount: bufferCount)
        )
        let names = sepURLs.map { $0.lastPathComponent }
        XCTAssertTrue(names.contains("\(timestamp)-sep - SystemAudio.wav"))
        XCTAssertTrue(names.contains("\(timestamp)-sep - Mix.wav"))
    }

    // MARK: - testDiskWriteFailureEmitsError
    //
    // Point the writer at a nonexistent directory (simulating permission denied).
    // `runMixed` must throw `WriterError.diskWriteFailed`.
    func testDiskWriteFailureEmitsError() async throws {
        let badDir = URL(fileURLWithPath: "/nonexistent/deeply/nested/path")
        let writer = WAVWriter(outputFolder: badDir, timestamp: "2026-01-01T00-00-03")
        let stream = makeFiniteStream(frequency: 440, bufferCount: 5)

        do {
            _ = try await writer.runMixed(stream: stream)
            XCTFail("Expected WriterError.diskWriteFailed but no error was thrown")
        } catch let error as WriterError {
            switch error {
            case .diskWriteFailed:
                break  // expected
            }
        } catch {
            XCTFail("Expected WriterError.diskWriteFailed, got \(error)")
        }
    }
}
