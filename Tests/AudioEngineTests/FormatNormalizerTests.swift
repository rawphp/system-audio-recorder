import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioToMP3

// MARK: - Helpers

/// Generates a mono or stereo 1 kHz sine wave into an `AVAudioPCMBuffer`
/// using `pcmFormatFloat32` (non-interleaved).
private func sineBuffer(
    frequency: Double,
    sampleRate: Double,
    channels: AVAudioChannelCount,
    frameCount: AVAudioFrameCount
) -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ) else { fatalError("Could not create AVAudioFormat") }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        fatalError("Could not allocate AVAudioPCMBuffer")
    }
    buffer.frameLength = frameCount

    let angularFreq = 2.0 * Double.pi * frequency / sampleRate
    for ch in 0..<Int(channels) {
        guard let ptr = buffer.floatChannelData?[ch] else { continue }
        for i in 0..<Int(frameCount) {
            ptr[i] = Float(sin(angularFreq * Double(i)))
        }
    }
    return buffer
}

/// Returns the peak frequency (Hz) of the first channel of `buffer` using a real FFT.
private func peakFrequency(in buffer: AVAudioPCMBuffer) -> Double {
    guard let ptr = buffer.floatChannelData?[0] else { return 0 }
    let n = Int(buffer.frameLength)
    let sampleRate = buffer.format.sampleRate

    // Round down to nearest power of 2 for vDSP.
    var log2n = 0
    var size = 1
    while size < n { size <<= 1; log2n += 1 }
    // Back off one step so size <= n.
    if size > n { size >>= 1; log2n -= 1 }

    guard log2n > 0 else { return 0 }

    // Copy samples into padded real array (half-complex split form).
    var reals = [Float](repeating: 0, count: size / 2)
    var imags = [Float](repeating: 0, count: size / 2)

    // Interpret the input as pairs (even=real, odd=imag) for vDSP_fft_zrip.
    // Copy from the source buffer.
    var inputCopy = [Float](repeating: 0, count: size)
    for i in 0..<size { inputCopy[i] = ptr[i] }

    reals.withUnsafeMutableBufferPointer { rPtr in
        imags.withUnsafeMutableBufferPointer { iPtr in
            var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
            inputCopy.withUnsafeBytes { rawBytes in
                let typed = rawBytes.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(typed.baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
            }

            let log2nLen = vDSP_Length(log2n)
            guard let fftSetup = vDSP_create_fftsetup(log2nLen, FFTRadix(FFT_RADIX2)) else { return }
            defer { vDSP_destroy_fftsetup(fftSetup) }
            vDSP_fft_zrip(fftSetup, &split, 1, log2nLen, FFTDirection(FFT_FORWARD))

            var magnitudes = [Float](repeating: 0, count: size / 2)
            vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))

            // Ignore DC (bin 0), find peak.
            var peakMag: Float = 0
            var peakBin = 1
            for bin in 1..<(size / 2) {
                if magnitudes[bin] > peakMag {
                    peakMag = magnitudes[bin]
                    peakBin = bin
                }
            }
            let freq = Double(peakBin) * sampleRate / Double(size)
            _ = freq // captured below via closure capture of peakBin
            // Store in thread-local via a somewhat ugly but correct approach:
            // We use a captured var that we set here.
            _peakBinResult = peakBin
            _sizeResult = size
        }
    }
    let freq = Double(_peakBinResult) * sampleRate / Double(_sizeResult)
    return freq
}

// Thread-unsafe helper vars — fine for single-threaded XCTest.
private var _peakBinResult = 0
private var _sizeResult = 1

// MARK: - FormatNormalizerTests

final class FormatNormalizerTests: XCTestCase {

    // MARK: Helpers

    private func assertCanonicalFormat(_ buffer: AVAudioPCMBuffer, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(buffer.format.sampleRate, 48_000, "sampleRate must be 48 kHz", file: file, line: line)
        XCTAssertEqual(buffer.format.channelCount, 2, "channelCount must be 2", file: file, line: line)
        XCTAssertEqual(buffer.format.commonFormat.rawValue,
                       AVAudioCommonFormat.pcmFormatFloat32.rawValue,
                       "commonFormat must be pcmFormatFloat32", file: file, line: line)
        XCTAssertFalse(buffer.format.isInterleaved, "must be non-interleaved", file: file, line: line)
    }

    // MARK: testPassThroughFor48kHzF32Stereo
    //
    // 48 kHz Float32 stereo input must pass through and remain canonical.
    func testPassThroughFor48kHzF32Stereo() throws {
        let normalizer = FormatNormalizer()
        let inputBuffer = sineBuffer(frequency: 1000, sampleRate: 48_000, channels: 2, frameCount: 4800)
        let outputBuffers = try normalizer.normalize(inputBuffer)
        XCTAssertFalse(outputBuffers.isEmpty, "Should produce ≥1 output buffer")
        for buf in outputBuffers { assertCanonicalFormat(buf) }
    }

    // MARK: testUpsampleFrom44kHzMonoTo48kHzStereo
    //
    // 44.1 kHz mono input must be upsampled to 48 kHz and expanded to stereo.
    // The peak frequency in the output FFT must be 1 kHz ± 5 Hz.
    func testUpsampleFrom44kHzMonoTo48kHzStereo() throws {
        let normalizer = FormatNormalizer()

        // 1 second at 44.1 kHz.
        let inputBuffer = sineBuffer(frequency: 1000, sampleRate: 44_100, channels: 1, frameCount: 44_100)
        let outputBuffers = try normalizer.normalize(inputBuffer)

        XCTAssertFalse(outputBuffers.isEmpty, "Should produce ≥1 output buffer")
        let firstOut = outputBuffers[0]
        assertCanonicalFormat(firstOut)

        // Frequency analysis: the 1 kHz tone must survive resampling.
        let peak = peakFrequency(in: firstOut)
        XCTAssertEqual(peak, 1000, accuracy: 5, "Peak frequency must be 1 kHz ± 5 Hz, got \(peak) Hz")
    }

    // MARK: testOutputFormat88kHzStereo
    //
    // 88.2 kHz stereo input must be downsampled to canonical 48 kHz stereo.
    func testOutputFormat88kHzStereo() throws {
        let normalizer = FormatNormalizer()
        let inputBuffer = sineBuffer(frequency: 1000, sampleRate: 88_200, channels: 2, frameCount: 88_200)
        let outputBuffers = try normalizer.normalize(inputBuffer)
        XCTAssertFalse(outputBuffers.isEmpty)
        for buf in outputBuffers { assertCanonicalFormat(buf) }
    }

    // MARK: testOutputFormat96kHzStereo
    //
    // 96 kHz stereo input must be downsampled to canonical 48 kHz stereo.
    func testOutputFormat96kHzStereo() throws {
        let normalizer = FormatNormalizer()
        let inputBuffer = sineBuffer(frequency: 1000, sampleRate: 96_000, channels: 2, frameCount: 96_000)
        let outputBuffers = try normalizer.normalize(inputBuffer)
        XCTAssertFalse(outputBuffers.isEmpty)
        for buf in outputBuffers { assertCanonicalFormat(buf) }
    }

    // MARK: testMidStreamFormatChangeRecreatesConverter
    //
    // Changing the input format between calls must recreate the converter.
    // After at most one dropped buffer, all subsequent output must be canonical.
    func testMidStreamFormatChangeRecreatesConverter() throws {
        let normalizer = FormatNormalizer()

        // Phase 1: 48 kHz stereo.
        let buf48 = sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, frameCount: 4800)
        let out48 = try normalizer.normalize(buf48)
        XCTAssertFalse(out48.isEmpty, "Phase-1 output must not be empty")
        for buf in out48 { assertCanonicalFormat(buf) }

        // Phase 2: switch to 96 kHz stereo mid-stream.
        let buf96 = sineBuffer(frequency: 440, sampleRate: 96_000, channels: 2, frameCount: 9600)

        // First call after format change: may return [] (one buffer drop allowed).
        let out96a = try normalizer.normalize(buf96)
        // Second call must produce output.
        let out96b = try normalizer.normalize(buf96)

        let total = out96a.count + out96b.count
        XCTAssertGreaterThan(total, 0, "Within two calls after format change, output must appear")

        for buf in out96a + out96b { assertCanonicalFormat(buf) }
    }

    // MARK: testUnsupportedInputFormatThrowsNormalizerError
    //
    // When `_injectNextConverterError` is set to NormalizerError.unsupportedInputFormat,
    // normalize() must throw that error and emit no buffers.
    // After the error clears, the next valid call must succeed.
    func testUnsupportedInputFormatThrowsNormalizerError() throws {
        let normalizer = FormatNormalizer()

        // Inject a converter error for the next call.
        let fakeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        normalizer._injectNextConverterError = NormalizerError.unsupportedInputFormat(fakeFormat)

        let buf = sineBuffer(frequency: 440, sampleRate: 44_100, channels: 1, frameCount: 4410)
        XCTAssertThrowsError(try normalizer.normalize(buf)) { error in
            guard case NormalizerError.unsupportedInputFormat = error else {
                XCTFail("Expected NormalizerError.unsupportedInputFormat, got \(error)")
                return
            }
        }

        // After the injected error, the normalizer should recover on a valid 48 kHz buffer.
        let validBuf = sineBuffer(frequency: 440, sampleRate: 48_000, channels: 2, frameCount: 4800)
        let recovered = try normalizer.normalize(validBuf)
        XCTAssertFalse(recovered.isEmpty, "Normalizer must recover after injected error")
    }

    // MARK: testNormalizerErrorForTestingReturnsNil
    //
    // Without injected errors, `normalizerErrorForTesting()` returns nil.
    func testNormalizerErrorForTestingReturnsNil() {
        let normalizer = FormatNormalizer()
        XCTAssertNil(normalizer.normalizerErrorForTesting())
    }

    // MARK: testNoAliasingWhen96kHzDownsampledTo48kHz (REQ-039 scenario b)
    //
    // 96 kHz stereo → 48 kHz stereo: the 1 kHz test tone must survive and
    // no spurious energy above 20 kHz (half the output Nyquist) must exceed
    // the signal peak by less than 40 dB (i.e. spurious peaks < signal - 40 dB).
    // This verifies AVAudioConverter applies the anti-aliasing filter required
    // by spec Section 5.4.
    func testNoAliasingWhen96kHzDownsampledTo48kHz() throws {
        let normalizer = FormatNormalizer()

        // 0.5 s at 96 kHz (48000 output frames after downsample).
        let inputBuffer = sineBuffer(frequency: 1000, sampleRate: 96_000, channels: 2, frameCount: 48_000)
        let outputBuffers = try normalizer.normalize(inputBuffer)
        XCTAssertFalse(outputBuffers.isEmpty, "Should produce ≥1 output buffer")

        let out = outputBuffers[0]
        assertCanonicalFormat(out)

        // Verify 1 kHz tone is preserved.
        let signal1kHz = peakFrequency(in: out)
        XCTAssertEqual(signal1kHz, 1000, accuracy: 20,
                       "1 kHz tone must survive downsampling, got \(signal1kHz) Hz")

        // Verify no aliasing: compute per-bin magnitudes and confirm all bins
        // above 20 kHz have magnitude well below the 1 kHz bin.
        guard let ptr = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        var log2n = 0
        var size = 1
        while size < n { size <<= 1; log2n += 1 }
        if size > n { size >>= 1; log2n -= 1 }
        guard log2n > 0 else { return }

        var reals = [Float](repeating: 0, count: size / 2)
        var imags = [Float](repeating: 0, count: size / 2)
        var inputCopy = [Float](repeating: 0, count: size)
        for i in 0..<size { inputCopy[i] = ptr[i] }

        var signalBinMag: Float = 0
        var maxAliasBinMag: Float = 0

        reals.withUnsafeMutableBufferPointer { rPtr in
            imags.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                inputCopy.withUnsafeBytes { rawBytes in
                    let typed = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(typed.baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                let log2nLen = vDSP_Length(log2n)
                guard let fftSetup = vDSP_create_fftsetup(log2nLen, FFTRadix(FFT_RADIX2)) else { return }
                defer { vDSP_destroy_fftsetup(fftSetup) }
                vDSP_fft_zrip(fftSetup, &split, 1, log2nLen, FFTDirection(FFT_FORWARD))

                var magnitudes = [Float](repeating: 0, count: size / 2)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))

                // Find the 1 kHz bin magnitude.
                let binWidth = 48_000.0 / Double(size)
                let signal1kBin = Int((1000.0 / binWidth).rounded())
                if signal1kBin < magnitudes.count {
                    signalBinMag = magnitudes[signal1kBin]
                }

                // Find maximum magnitude in bins above 20 kHz (above 20 kHz / binWidth).
                let aliasStartBin = Int((20_000.0 / binWidth).rounded())
                for bin in aliasStartBin..<(size / 2) {
                    if magnitudes[bin] > maxAliasBinMag {
                        maxAliasBinMag = magnitudes[bin]
                    }
                }
            }
        }

        // Signal must be present.
        XCTAssertGreaterThan(signalBinMag, 0, "1 kHz bin must have non-zero magnitude")

        // Alias energy above 20 kHz must be at least 40 dB below the signal bin.
        // This is the standard anti-aliasing filter requirement.
        if signalBinMag > 0 && maxAliasBinMag > 0 {
            let aliasdB = 20.0 * log10(Double(maxAliasBinMag) / Double(signalBinMag))
            XCTAssertLessThan(aliasdB, -40.0,
                              "Aliasing above 20 kHz must be < signal - 40 dB; got \(aliasdB) dB relative")
        }
    }
}
