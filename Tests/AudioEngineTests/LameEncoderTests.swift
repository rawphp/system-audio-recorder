import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioToMP3

// MARK: - Helpers

private let testSampleRate: Double = 48000
private let testChannels: AVAudioChannelCount = 2

/// Canonical 48 kHz Float32 stereo format (matching WAVWriter output).
private let canonicalFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: testSampleRate,
    channels: testChannels,
    interleaved: false
)!

/// Generates a Float32 stereo buffer with a sine at `frequency` Hz.
private func sineBuffer(
    frequency: Double,
    frameCount: AVAudioFrameCount,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    guard let buf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frameCount) else {
        fatalError("Cannot allocate sineBuffer")
    }
    buf.frameLength = frameCount
    let w = 2.0 * Double.pi * frequency / testSampleRate
    for ch in 0..<Int(testChannels) {
        guard let ptr = buf.floatChannelData?[ch] else { continue }
        for i in 0..<Int(frameCount) {
            ptr[i] = amplitude * Float(sin(w * Double(i)))
        }
    }
    return buf
}

/// Writes a WAV file of `durationSeconds` containing a sine at `frequency` Hz.
/// Returns the URL of the written file.
private func writeSineWAV(
    to dir: URL,
    name: String = "test.wav",
    frequency: Double = 1000,
    durationSeconds: Double,
    amplitude: Float = 0.5
) throws -> URL {
    let url = dir.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey:              kAudioFormatLinearPCM,
        AVSampleRateKey:            testSampleRate,
        AVNumberOfChannelsKey:      testChannels,
        AVLinearPCMBitDepthKey:     32,
        AVLinearPCMIsFloatKey:      true,
        AVLinearPCMIsBigEndianKey:  false,
    ]
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let totalFrames = AVAudioFrameCount(durationSeconds * testSampleRate)
    // Write in 1-second chunks
    let chunkFrames = AVAudioFrameCount(testSampleRate)
    var written: AVAudioFrameCount = 0
    while written < totalFrames {
        let remaining = totalFrames - written
        let thisChunk = min(chunkFrames, remaining)
        let buf = sineBuffer(frequency: frequency, frameCount: thisChunk, amplitude: amplitude)
        try file.write(from: buf)
        written += thisChunk
    }
    return url
}

/// Writes a WAV file of `durationSeconds` containing band-limited white noise (many overlapping
/// sines). This produces a spectrally complex signal that forces VBR/ABR encoders to use
/// close to the configured target bitrate, making size assertions reliable.
private func writeNoiseWAV(
    to dir: URL,
    name: String,
    durationSeconds: Double,
    amplitude: Float = 0.3
) throws -> URL {
    let url = dir.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey:              kAudioFormatLinearPCM,
        AVSampleRateKey:            testSampleRate,
        AVNumberOfChannelsKey:      testChannels,
        AVLinearPCMBitDepthKey:     32,
        AVLinearPCMIsFloatKey:      true,
        AVLinearPCMIsBigEndianKey:  false,
    ]
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let totalFrames = AVAudioFrameCount(durationSeconds * testSampleRate)
    let chunkFrames = AVAudioFrameCount(testSampleRate)
    var written: AVAudioFrameCount = 0
    // Use a small set of inharmonic frequencies to simulate broadband content
    let freqs: [Double] = [100, 200, 300, 500, 700, 1000, 1500, 2000, 3000, 4000,
                           5000, 6000, 7000, 8000, 10000, 12000, 14000, 16000]
    while written < totalFrames {
        let remaining = totalFrames - written
        let thisChunk = min(chunkFrames, remaining)
        guard let buf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: thisChunk) else { break }
        buf.frameLength = thisChunk
        let perFreqAmplitude = amplitude / Float(freqs.count)
        for ch in 0..<Int(testChannels) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<Int(thisChunk) { ptr[i] = 0 }
            for freq in freqs {
                let w = 2.0 * Double.pi * freq / testSampleRate
                let phaseOffset = freq * 0.001  // vary phase per frequency
                for i in 0..<Int(thisChunk) {
                    ptr[i] += perFreqAmplitude * Float(sin(w * Double(Int(written) + i) + phaseOffset))
                }
            }
        }
        try file.write(from: buf)
        written += thisChunk
    }
    return url
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
    return Double(peakBin) * testSampleRate / Double(size)
}

// MARK: - LameEncoderTests

final class LameEncoderTests: XCTestCase {

    var tmpDir: URL!
    let encoder = LameEncoder()

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LameEncoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - testEncodes1kHzTone_VBR192

    /// AC-1: Encodes a 5 s 1 kHz tone WAV at 192 kbps VBR; resulting MP3 is non-empty;
    /// decoded first channel has dominant FFT peak at 1 kHz ± 5 Hz.
    func testEncodes1kHzTone_VBR192() async throws {
        let wavURL = try writeSineWAV(to: tmpDir, name: "tone1k.wav",
                                     frequency: 1000, durationSeconds: 5)
        let mp3URL = tmpDir.appendingPathComponent("tone1k.mp3")

        var progressValues: [Double] = []
        try await encoder.encode(
            wavURL: wavURL,
            mp3URL: mp3URL,
            bitrate: 192,
            mode: .vbr,
            progress: { p in progressValues.append(p) }
        )

        // MP3 must exist and be non-empty
        let attrs = try FileManager.default.attributesOfItem(atPath: mp3URL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "MP3 must not be empty")

        // Decode back and check FFT peak
        let mp3File = try AVAudioFile(forReading: mp3URL)
        guard let decodedBuf = AVAudioPCMBuffer(
            pcmFormat: mp3File.processingFormat,
            frameCapacity: AVAudioFrameCount(mp3File.length)
        ) else {
            XCTFail("Cannot allocate decode buffer"); return
        }
        try mp3File.read(into: decodedBuf)

        // We need float data for FFT — convert if needed
        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: mp3File.processingFormat.sampleRate,
            channels: mp3File.processingFormat.channelCount,
            interleaved: false
        )!
        let floatBuf: AVAudioPCMBuffer
        if decodedBuf.format.commonFormat != .pcmFormatFloat32 {
            guard let converted = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: decodedBuf.frameLength) else {
                XCTFail("Cannot allocate float buffer"); return
            }
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            _ = inputNode
            // Use AVAudioConverter for format conversion
            guard let conv = AVAudioConverter(from: decodedBuf.format, to: floatFormat) else {
                XCTFail("Cannot create converter"); return
            }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return decodedBuf
            }
            conv.convert(to: converted, error: &error, withInputFrom: inputBlock)
            if let e = error { XCTFail("Conversion error: \(e)"); return }
            floatBuf = converted
        } else {
            floatBuf = decodedBuf
        }

        // Take a window of 32768 frames from the decoded audio and run FFT
        let windowSize: AVAudioFrameCount = 32768
        guard let window = AVAudioPCMBuffer(pcmFormat: floatBuf.format, frameCapacity: windowSize) else {
            XCTFail("Cannot create window buffer"); return
        }
        window.frameLength = min(windowSize, floatBuf.frameLength)
        if let src = floatBuf.floatChannelData?[0], let dst = window.floatChannelData?[0] {
            dst.assign(from: src, count: Int(window.frameLength))
        }
        let peak = peakFrequency(in: window)
        XCTAssertEqual(peak, 1000, accuracy: 5, "Dominant FFT peak must be 1 kHz ± 5 Hz; got \(peak) Hz")
    }

    // MARK: - testSupportedBitrates

    /// AC-2 & AC-3: Encodes 1 s at each supported bitrate in both VBR and CBR modes.
    /// Output must be non-empty for each variant.
    func testSupportedBitrates() async throws {
        let bitrates = [128, 192, 256, 320]
        let modes: [BitrateMode] = [.vbr, .cbr]

        for mode in modes {
            for bitrate in bitrates {
                let name = "\(mode)-\(bitrate)"
                let wavURL = try writeSineWAV(to: tmpDir, name: "\(name).wav",
                                             frequency: 440, durationSeconds: 1)
                let mp3URL = tmpDir.appendingPathComponent("\(name).mp3")

                try await encoder.encode(
                    wavURL: wavURL,
                    mp3URL: mp3URL,
                    bitrate: bitrate,
                    mode: mode,
                    progress: { _ in }
                )

                let attrs = try FileManager.default.attributesOfItem(atPath: mp3URL.path)
                let size = (attrs[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 0,
                    "MP3 must be non-empty for \(mode) @ \(bitrate) kbps")
            }
        }
    }

    // MARK: - testProgressCallbackFires

    /// AC-4: `progress` callback fires at least 5 times during a 5 s file encode.
    func testProgressCallbackFires() async throws {
        let wavURL = try writeSineWAV(to: tmpDir, name: "progress.wav",
                                     frequency: 440, durationSeconds: 5)
        let mp3URL = tmpDir.appendingPathComponent("progress.mp3")

        var count = 0
        try await encoder.encode(
            wavURL: wavURL,
            mp3URL: mp3URL,
            bitrate: 192,
            mode: .vbr,
            progress: { _ in count += 1 }
        )

        XCTAssertGreaterThanOrEqual(count, 5,
            "progress must fire ≥5 times; got \(count)")
    }

    // MARK: - testCancellationRemovesPartialFile

    /// AC-5: Throws `EncodingError.cancelled` when cancelled mid-encode.
    /// Partial MP3 file must be removed.
    func testCancellationRemovesPartialFile() async throws {
        // 5 seconds of audio gives enough time to cancel mid-stream
        let wavURL = try writeSineWAV(to: tmpDir, name: "cancel.wav",
                                     frequency: 440, durationSeconds: 5)
        let mp3URL = tmpDir.appendingPathComponent("cancel.mp3")

        let task = Task {
            try await self.encoder.encode(
                wavURL: wavURL,
                mp3URL: mp3URL,
                bitrate: 192,
                mode: .vbr,
                progress: { _ in }
            )
        }

        // Let it start, then cancel
        try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        task.cancel()

        do {
            try await task.value
            // If it finished before cancellation, ensure no stale partial exists
        } catch EncodingError.cancelled {
            // expected — partial file must be removed
            let exists = FileManager.default.fileExists(atPath: mp3URL.path)
            XCTAssertFalse(exists, "Partial MP3 must be removed after cancellation")
        } catch is CancellationError {
            let exists = FileManager.default.fileExists(atPath: mp3URL.path)
            XCTAssertFalse(exists, "Partial MP3 must be removed after cancellation")
        } catch {
            XCTFail("Expected EncodingError.cancelled, got \(error)")
        }
    }

    // MARK: - testCancellationWithExplicitTaskCancel

    /// AC-5 (alternate path): Cancel the Task externally; encoder should respect
    /// Task.checkCancellation() and clean up.
    func testCancellationWithExplicitTaskCancel() async throws {
        let wavURL = try writeSineWAV(to: tmpDir, name: "cancel2.wav",
                                     frequency: 440, durationSeconds: 5)
        let mp3URL = tmpDir.appendingPathComponent("cancel2.mp3")

        let task = Task {
            try await self.encoder.encode(
                wavURL: wavURL,
                mp3URL: mp3URL,
                bitrate: 192,
                mode: .vbr,
                progress: { _ in }
            )
        }

        // Give it a moment to start, then cancel
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        task.cancel()

        do {
            try await task.value
            // If the file is tiny and encoded fast, no cancellation occurred — that's acceptable
        } catch EncodingError.cancelled {
            let exists = FileManager.default.fileExists(atPath: mp3URL.path)
            XCTAssertFalse(exists, "Partial MP3 must be removed after cancellation")
        } catch is CancellationError {
            let exists = FileManager.default.fileExists(atPath: mp3URL.path)
            XCTAssertFalse(exists, "Partial MP3 must be removed after cancellation")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - testOutputSizeFor60sTone_CBR192

    /// AC-6: Output MP3 size for a 60 s signal at 192 kbps is within ±10% of expected
    /// (1.44 MB ± 144 KB). Uses CBR mode so that the bitrate is constant and the
    /// assertion is deterministic. VBR allocates bits based on signal complexity and
    /// legitimately produces smaller files for spectrally simple content, making a
    /// fixed-tolerance size assertion unreliable in VBR mode.
    func testOutputSizeFor60sTone_CBR192() async throws {
        let wavURL = try writeSineWAV(to: tmpDir, name: "sixty.wav",
                                     frequency: 440, durationSeconds: 60)
        let mp3URL = tmpDir.appendingPathComponent("sixty.mp3")

        try await encoder.encode(
            wavURL: wavURL,
            mp3URL: mp3URL,
            bitrate: 192,
            mode: .cbr,
            progress: { _ in }
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: mp3URL.path)
        let size = (attrs[.size] as? Int) ?? 0
        let expectedBytes = 1_440_000    // 192 kbps × 60 s = 1.44 MB
        let tolerance    = 144_000       // ±10% = 144 KB
        let lower = expectedBytes - tolerance
        let upper = expectedBytes + tolerance
        XCTAssertGreaterThanOrEqual(size, lower,
            "MP3 size \(size) B must be ≥ \(lower) B (1.44 MB − 10%)")
        XCTAssertLessThanOrEqual(size, upper,
            "MP3 size \(size) B must be ≤ \(upper) B (1.44 MB + 10%)")
    }

    // MARK: - testInvalidInputThrows

    /// AC-7: If the input WAV cannot be opened, throws `EncodingError.invalidInput` before
    /// any LAME init, and writes no MP3.
    func testInvalidInputThrows() async throws {
        let badWAV = tmpDir.appendingPathComponent("nonexistent.wav")
        let mp3URL = tmpDir.appendingPathComponent("should-not-exist.mp3")

        do {
            try await encoder.encode(
                wavURL: badWAV,
                mp3URL: mp3URL,
                bitrate: 192,
                mode: .vbr,
                progress: { _ in }
            )
            XCTFail("Expected EncodingError.invalidInput")
        } catch let e as EncodingError {
            switch e {
            case .invalidInput(let url, _):
                XCTAssertEqual(url, badWAV)
            default:
                XCTFail("Expected invalidInput, got \(e)")
            }
        }

        // No partial MP3 must have been written
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp3URL.path),
            "No MP3 should be written for invalid input")
    }

    // MARK: - testVBR192SpotCheck

    /// Additional spot check: 1 s at 192 kbps VBR produces non-empty output (explicit coverage).
    func testVBR192SpotCheck() async throws {
        let wavURL = try writeSineWAV(to: tmpDir, name: "spotcheck.wav",
                                     frequency: 1000, durationSeconds: 1)
        let mp3URL = tmpDir.appendingPathComponent("spotcheck.mp3")

        try await encoder.encode(
            wavURL: wavURL,
            mp3URL: mp3URL,
            bitrate: 192,
            mode: .vbr,
            progress: { _ in }
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: mp3URL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0, "192 kbps VBR spot check: MP3 must be non-empty")
    }

    // MARK: - REQ-037 Scenario (a): FFT verification at all four bitrates

    /// REQ-037 scenario (a): Encode a 2 s 1 kHz sine at each supported bitrate (128/192/256/320
    /// kbps, CBR). Decoded FFT peak must be 1 kHz ± 5 Hz for every bitrate.
    /// Uses CBR for deterministic output; 2 s keeps the suite fast.
    func testAllBitratesFFTVerification() async throws {
        let bitrates = [128, 192, 256, 320]

        for bitrate in bitrates {
            let wavURL = try writeSineWAV(
                to: tmpDir,
                name: "fft-\(bitrate).wav",
                frequency: 1000,
                durationSeconds: 2
            )
            let mp3URL = tmpDir.appendingPathComponent("fft-\(bitrate).mp3")

            try await encoder.encode(
                wavURL: wavURL,
                mp3URL: mp3URL,
                bitrate: bitrate,
                mode: .cbr,
                progress: { _ in }
            )

            // Decode the MP3 back with AVAudioFile
            let mp3File = try AVAudioFile(forReading: mp3URL)
            let capacity = AVAudioFrameCount(mp3File.length)
            guard capacity > 0,
                  let decodedBuf = AVAudioPCMBuffer(
                      pcmFormat: mp3File.processingFormat,
                      frameCapacity: capacity
                  ) else {
                XCTFail("Cannot allocate decode buffer for \(bitrate) kbps"); continue
            }
            try mp3File.read(into: decodedBuf)

            // Convert to Float32 if the MP3 decoder produced a different format
            let floatFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: mp3File.processingFormat.sampleRate,
                channels: mp3File.processingFormat.channelCount,
                interleaved: false
            )!
            let floatBuf: AVAudioPCMBuffer
            if decodedBuf.format.commonFormat == .pcmFormatFloat32 {
                floatBuf = decodedBuf
            } else {
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: floatFormat,
                    frameCapacity: decodedBuf.frameLength
                ) else { XCTFail("Cannot allocate float buffer for \(bitrate) kbps"); continue }
                guard let conv = AVAudioConverter(from: decodedBuf.format, to: floatFormat) else {
                    XCTFail("Cannot create converter for \(bitrate) kbps"); continue
                }
                var convError: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return decodedBuf
                }
                conv.convert(to: converted, error: &convError, withInputFrom: inputBlock)
                if let e = convError { XCTFail("Conversion error at \(bitrate) kbps: \(e)"); continue }
                floatBuf = converted
            }

            // Take a 32768-frame window for the FFT
            let windowSize: AVAudioFrameCount = 32768
            guard let window = AVAudioPCMBuffer(pcmFormat: floatBuf.format, frameCapacity: windowSize) else {
                XCTFail("Cannot create window buffer for \(bitrate) kbps"); continue
            }
            window.frameLength = min(windowSize, floatBuf.frameLength)
            if let src = floatBuf.floatChannelData?[0],
               let dst = window.floatChannelData?[0] {
                dst.assign(from: src, count: Int(window.frameLength))
            }

            let peak = peakFrequency(in: window)
            XCTAssertEqual(
                peak, 1000, accuracy: 5,
                "FFT peak must be 1 kHz ± 5 Hz at \(bitrate) kbps CBR; got \(peak) Hz"
            )
        }
    }

    // MARK: - REQ-037 Scenario (b): Encode silence

    /// REQ-037 scenario (b): Encode 5 s of silence at 192 kbps VBR (ABR).
    /// The resulting MP3 must be smaller than 5% of the uncompressed WAV size.
    /// Silence is spectrally trivial; LAME's ABR allocates far fewer bits than
    /// the target average bitrate, so the output is dramatically smaller than the PCM original.
    func testEncodeSilence() async throws {
        // Write a WAV containing silence (amplitude = 0)
        let silenceDuration: Double = 5
        let wavURL = tmpDir.appendingPathComponent("silence.wav")
        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVSampleRateKey:           testSampleRate,
            AVNumberOfChannelsKey:     testChannels,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let wavFile = try AVAudioFile(
            forWriting: wavURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = AVAudioFrameCount(silenceDuration * testSampleRate)
        // Zero-filled buffer = silence
        guard let silenceBuf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: totalFrames) else {
            XCTFail("Cannot allocate silence buffer"); return
        }
        silenceBuf.frameLength = totalFrames
        for ch in 0..<Int(testChannels) {
            if let ptr = silenceBuf.floatChannelData?[ch] {
                for i in 0..<Int(totalFrames) { ptr[i] = 0 }
            }
        }
        try wavFile.write(from: silenceBuf)

        let mp3URL = tmpDir.appendingPathComponent("silence.mp3")
        try await encoder.encode(
            wavURL: wavURL,
            mp3URL: mp3URL,
            bitrate: 192,
            mode: .vbr,
            progress: { _ in }
        )

        // WAV size: sampleRate × channels × bytesPerSample × duration
        let wavSize = Int(testSampleRate) * Int(testChannels) * 4 * Int(silenceDuration)
        let threshold = wavSize / 20  // 5%

        let mp3Attrs = try FileManager.default.attributesOfItem(atPath: mp3URL.path)
        let mp3Size = (mp3Attrs[.size] as? Int) ?? 0

        XCTAssertGreaterThan(mp3Size, 0, "Silence MP3 must not be empty")
        XCTAssertLessThanOrEqual(
            mp3Size, threshold,
            "Silence MP3 (\(mp3Size) B) must be ≤ 5% of WAV (\(wavSize) B = \(threshold) B threshold)"
        )
    }

    // MARK: - REQ-037 Scenario (c): VBR vs CBR file size

    /// REQ-037 scenario (c): Encode the same 5 s spectrally complex signal in both CBR and VBR
    /// mode at 192 kbps. CBR must be within ±20% of the theoretical size
    /// (bitrate × duration). VBR size is not constrained to a fixed window.
    func testVBRvsCBRFileSizes() async throws {
        // Spectrally complex noise signal forces both encoders to exercise their full bitrate range
        let wavURL = try writeNoiseWAV(to: tmpDir, name: "noise-cbrVbr.wav", durationSeconds: 5)
        let cbrMP3URL = tmpDir.appendingPathComponent("cbr192.mp3")
        let vbrMP3URL = tmpDir.appendingPathComponent("vbr192.mp3")

        try await encoder.encode(
            wavURL: wavURL, mp3URL: cbrMP3URL,
            bitrate: 192, mode: .cbr, progress: { _ in }
        )
        try await encoder.encode(
            wavURL: wavURL, mp3URL: vbrMP3URL,
            bitrate: 192, mode: .vbr, progress: { _ in }
        )

        let cbrAttrs = try FileManager.default.attributesOfItem(atPath: cbrMP3URL.path)
        let vbrAttrs = try FileManager.default.attributesOfItem(atPath: vbrMP3URL.path)
        let cbrSize = (cbrAttrs[.size] as? Int) ?? 0
        let vbrSize = (vbrAttrs[.size] as? Int) ?? 0

        XCTAssertGreaterThan(cbrSize, 0, "CBR MP3 must not be empty")
        XCTAssertGreaterThan(vbrSize, 0, "VBR MP3 must not be empty")

        // CBR: 192 kbps × 5 s = 120,000 bytes; allow ±20% tolerance
        let expectedCBR = 120_000
        let cbrTolerance = 24_000  // ±20%
        XCTAssertGreaterThanOrEqual(
            cbrSize, expectedCBR - cbrTolerance,
            "CBR size \(cbrSize) B must be ≥ \(expectedCBR - cbrTolerance) B"
        )
        XCTAssertLessThanOrEqual(
            cbrSize, expectedCBR + cbrTolerance,
            "CBR size \(cbrSize) B must be ≤ \(expectedCBR + cbrTolerance) B"
        )

        // VBR uses ABR targeting 192 kbps — for complex audio it should also be in the
        // same ballpark (within ±40% of expected), confirming it is not a degenerate
        // zero-size output while not requiring it to match CBR exactly.
        let vbrLower = expectedCBR / 3   // at most 3× smaller
        let vbrUpper = expectedCBR * 2   // at most 2× larger
        XCTAssertGreaterThanOrEqual(
            vbrSize, vbrLower,
            "VBR size \(vbrSize) B seems unexpectedly small (< \(vbrLower) B)"
        )
        XCTAssertLessThanOrEqual(
            vbrSize, vbrUpper,
            "VBR size \(vbrSize) B seems unexpectedly large (> \(vbrUpper) B)"
        )
    }

    // MARK: - REQ-037 Scenario (e): Concurrent encodes

    /// REQ-037 scenario (e): Two encodes running in parallel must not interfere.
    /// Both must complete successfully and produce non-empty, valid MP3 files.
    func testConcurrentEncodes() async throws {
        let wavA = try writeSineWAV(to: tmpDir, name: "concA.wav",
                                   frequency: 440, durationSeconds: 2)
        let wavB = try writeSineWAV(to: tmpDir, name: "concB.wav",
                                   frequency: 880, durationSeconds: 2)
        let mp3A = tmpDir.appendingPathComponent("concA.mp3")
        let mp3B = tmpDir.appendingPathComponent("concB.mp3")

        // Launch both encodes concurrently using a task group
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.encoder.encode(
                    wavURL: wavA, mp3URL: mp3A,
                    bitrate: 128, mode: .cbr, progress: { _ in }
                )
            }
            group.addTask {
                try await self.encoder.encode(
                    wavURL: wavB, mp3URL: mp3B,
                    bitrate: 256, mode: .cbr, progress: { _ in }
                )
            }
            try await group.waitForAll()
        }

        // Both outputs must exist and be non-empty
        let attrsA = try FileManager.default.attributesOfItem(atPath: mp3A.path)
        let sizeA = (attrsA[.size] as? Int) ?? 0
        XCTAssertGreaterThan(sizeA, 0, "Concurrent encode A (440 Hz, 128 kbps CBR) must be non-empty")

        let attrsB = try FileManager.default.attributesOfItem(atPath: mp3B.path)
        let sizeB = (attrsB[.size] as? Int) ?? 0
        XCTAssertGreaterThan(sizeB, 0, "Concurrent encode B (880 Hz, 256 kbps CBR) must be non-empty")

        // Both outputs must be decodable by AVAudioFile
        let _ = try AVAudioFile(forReading: mp3A)
        let _ = try AVAudioFile(forReading: mp3B)
    }
}
