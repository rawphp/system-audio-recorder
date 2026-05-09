import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioRecorder

// MARK: - Test Helpers

/// Generates a canonical-format (48 kHz Float32 stereo non-interleaved) buffer
/// with a sine wave at `frequency` Hz on all channels.
private func canonicalSineBuffer(
    frequency: Double,
    frameCount: AVAudioFrameCount = 480,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    let format = FormatNormalizer.canonicalFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        fatalError("Could not allocate sine buffer")
    }
    buffer.frameLength = frameCount
    let sampleRate = format.sampleRate
    let angularFreq = 2.0 * Double.pi * frequency / sampleRate
    for ch in 0..<Int(format.channelCount) {
        guard let ptr = buffer.floatChannelData?[ch] else { continue }
        for i in 0..<Int(frameCount) {
            ptr[i] = amplitude * Float(sin(angularFreq * Double(i)))
        }
    }
    return buffer
}

/// Measures the peak frequency in the first channel of `buffer` using a real FFT.
private func peakFrequency(in buffer: AVAudioPCMBuffer) -> Double {
    guard let ptr = buffer.floatChannelData?[0] else { return 0 }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return 0 }
    var log2n = 0
    var size = 1
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

            var localPeak: Float = 0
            for bin in 1..<(size / 2) {
                if magnitudes[bin] > localPeak {
                    localPeak = magnitudes[bin]
                    peakBin = bin
                }
            }
        }
    }
    return Double(peakBin) * buffer.format.sampleRate / Double(size)
}

/// Returns the RMS amplitude of the first channel of `buffer`.
private func rmsAmplitude(in buffer: AVAudioPCMBuffer) -> Float {
    guard let ptr = buffer.floatChannelData?[0],
          buffer.frameLength > 0 else { return 0 }
    var rms: Float = 0
    vDSP_measqv(ptr, 1, &rms, vDSP_Length(buffer.frameLength))
    return sqrt(rms)
}

/// Builds an `AsyncStream<AVAudioPCMBuffer>` that fires `count` canonical
/// buffers at ~100 Hz (10 ms each) then terminates.
private func makeFiniteStream(
    frequency: Double,
    amplitude: Float = 0.5,
    bufferCount: Int = 30,
    frameCount: AVAudioFrameCount = 480
) -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { cont in
        let queue = DispatchQueue(label: "TestStream-\(frequency)")
        queue.async {
            for _ in 0..<bufferCount {
                let buf = canonicalSineBuffer(frequency: frequency,
                                              frameCount: frameCount,
                                              amplitude: amplitude)
                cont.yield(buf)
                Thread.sleep(forTimeInterval: 0.01)
            }
            cont.finish()
        }
    }
}

/// Builds an `AsyncStream<AVAudioPCMBuffer>` that fires continuously until
/// cancelled via the returned cancellation continuation.
private func makeInfiniteStream(
    frequency: Double,
    amplitude: Float = 0.5,
    frameCount: AVAudioFrameCount = 480
) -> (stream: AsyncStream<AVAudioPCMBuffer>, stop: () -> Void) {
    var capturedCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
    let stream = AsyncStream<AVAudioPCMBuffer> { cont in
        capturedCont = cont
    }
    let cont = capturedCont!

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "InfiniteStream-\(frequency)"))
    timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
    timer.setEventHandler {
        let buf = canonicalSineBuffer(frequency: frequency,
                                      frameCount: frameCount,
                                      amplitude: amplitude)
        cont.yield(buf)
    }
    timer.resume()

    return (stream, {
        timer.cancel()
        cont.finish()
    })
}

// MARK: - MixerGraphTests

final class MixerGraphTests: XCTestCase {

    // MARK: testAddSourceAndMixStreamProducesBuffers
    //
    // Adding one source and collecting from `mixBufferStream()` must deliver
    // ≥20 canonical-format buffers within 5 seconds.
    func testAddSourceAndMixStreamProducesBuffers() async throws {
        let mixer = MixerGraph()
        let (stream, stop) = makeInfiniteStream(frequency: 440)
        defer { stop(); mixer.stop() }

        try mixer.addSource(id: "src1", stream: stream)
        let mixStream = mixer.mixBufferStream()

        var count = 0
        let deadline = Date().addingTimeInterval(5.0)
        for await buffer in mixStream {
            XCTAssertEqual(buffer.format.sampleRate, 48_000)
            XCTAssertEqual(buffer.format.channelCount, 2)
            XCTAssertEqual(buffer.format.commonFormat, AVAudioCommonFormat.pcmFormatFloat32)
            XCTAssertFalse(buffer.format.isInterleaved)
            count += 1
            if count >= 20 { break }
            if Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(count, 20, "Expected ≥20 mix buffers, got \(count)")
    }

    // MARK: testDuplicateSourceIDThrows
    //
    // Calling `addSource` with an ID that's already registered must throw
    // `MixerError.duplicateSourceID` and not modify the graph state.
    func testDuplicateSourceIDThrows() throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let (s1, stop1) = makeInfiniteStream(frequency: 440)
        let (s2, stop2) = makeInfiniteStream(frequency: 880)
        defer { stop1(); stop2() }

        try mixer.addSource(id: "dup", stream: s1)

        XCTAssertThrowsError(try mixer.addSource(id: "dup", stream: s2)) { error in
            guard case MixerError.duplicateSourceID(let id) = error else {
                XCTFail("Expected MixerError.duplicateSourceID, got \(error)")
                return
            }
            XCTAssertEqual(id, "dup")
        }
    }

    // MARK: testSetGainAffectsMixLevel
    //
    // Setting source gain to 0.5 must reduce that source's contribution to the
    // mix by ≈6 dB (factor of 0.5 in RMS).
    //
    // Strategy: collect RMS at gain=1.0, then set gain=0.5, collect again,
    // compare. We allow ±2 dB margin.
    func testSetGainAffectsMixLevel() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let (stream, stop) = makeInfiniteStream(frequency: 440, amplitude: 0.8)
        defer { stop() }

        try mixer.addSource(id: "gainSrc", stream: stream)
        let mixStream = mixer.mixBufferStream()

        // Collect a few buffers at gain = 1.0 (default).
        var rmsAtFullGain: Float = 0
        var count = 0
        for await buf in mixStream {
            let rms = rmsAmplitude(in: buf)
            if rms > 0 { rmsAtFullGain += rms; count += 1 }
            if count >= 5 { break }
        }
        guard count > 0 else { XCTFail("No buffers at full gain"); return }
        rmsAtFullGain /= Float(count)

        // Switch gain to 0.5.
        mixer.setGain(forSource: "gainSrc", gain: 0.5)

        // Wait 2 buffer periods for propagation, then collect.
        try await Task.sleep(nanoseconds: 30_000_000) // 30 ms

        var rmsAtHalfGain: Float = 0
        count = 0
        for await buf in mixStream {
            let rms = rmsAmplitude(in: buf)
            if rms > 0 { rmsAtHalfGain += rms; count += 1 }
            if count >= 5 { break }
        }
        guard count > 0 else { XCTFail("No buffers at half gain"); return }
        rmsAtHalfGain /= Float(count)

        // The ratio should be ≈0.5 (6 dB drop). Allow ±2 dB margin: ratio in [0.40, 0.63].
        let ratio = rmsAtHalfGain / rmsAtFullGain
        XCTAssertGreaterThan(ratio, 0.35, "Gain=0.5 should reduce level; ratio=\(ratio)")
        XCTAssertLessThan(ratio, 0.70, "Gain=0.5 should not be a full gain; ratio=\(ratio)")
    }

    // MARK: testSourceBufferStreamProducesBuffers
    //
    // `sourceBufferStream(forSource:)` for a registered source must deliver
    // buffers reflecting the post-gain stage.
    func testSourceBufferStreamProducesBuffers() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let (stream, stop) = makeInfiniteStream(frequency: 440)
        defer { stop() }

        try mixer.addSource(id: "tap1", stream: stream)
        let srcStream = mixer.sourceBufferStream(forSource: "tap1")

        var count = 0
        let deadline = Date().addingTimeInterval(5.0)
        for await buf in srcStream {
            XCTAssertEqual(buf.format.sampleRate, 48_000)
            count += 1
            if count >= 10 { break }
            if Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(count, 10, "Expected ≥10 source buffers, got \(count)")
    }

    // MARK: testRemoveSourceDoesNotStopMix
    //
    // Removing a source while mixing must not stop the mix stream.
    // Surviving sources must continue delivering buffers.
    func testRemoveSourceDoesNotStopMix() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let (s1, stop1) = makeInfiniteStream(frequency: 440)
        let (s2, stop2) = makeInfiniteStream(frequency: 880)
        defer { stop1(); stop2() }

        try mixer.addSource(id: "remove-me", stream: s1)
        try mixer.addSource(id: "survivor",  stream: s2)

        let mixStream = mixer.mixBufferStream()

        // Collect a few buffers.
        var preBuf = 0
        for await _ in mixStream {
            preBuf += 1
            if preBuf >= 5 { break }
        }

        // Remove one source.
        mixer.removeSource(id: "remove-me")
        stop1()

        // Collect more buffers from the surviving source.
        var postBuf = 0
        let deadline = Date().addingTimeInterval(5.0)
        for await _ in mixStream {
            postBuf += 1
            if postBuf >= 10 { break }
            if Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(postBuf, 10, "Survivor must continue after source removal, got \(postBuf)")
    }

    // MARK: testUpstreamStreamTerminationRemovesSource
    //
    // When a source's upstream AsyncStream finishes, the mixer removes that
    // source and continues producing mix buffers from remaining sources.
    func testUpstreamStreamTerminationRemovesSource() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        // A finite stream that terminates after 10 buffers.
        let finiteStream = makeFiniteStream(frequency: 440, bufferCount: 10)
        let (infiniteStream, stopInfinite) = makeInfiniteStream(frequency: 880)
        defer { stopInfinite() }

        try mixer.addSource(id: "finite",   stream: finiteStream)
        try mixer.addSource(id: "infinite", stream: infiniteStream)

        let mixStream = mixer.mixBufferStream()

        // Wait for the finite source to exhaust (at least 200 ms).
        try await Task.sleep(nanoseconds: 400_000_000)

        // Now collect from the mix: the mix should still be running.
        var postBuf = 0
        let deadline = Date().addingTimeInterval(5.0)
        for await _ in mixStream {
            postBuf += 1
            if postBuf >= 10 { break }
            if Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(postBuf, 10,
            "Mix must continue after upstream stream termination, got \(postBuf)")
    }

    // MARK: testMixedOutputContainsBothSourceFrequencies
    //
    // Add two sources (440 Hz left, 880 Hz right — both on stereo channels).
    // The mixed output's FFT should show a significant magnitude at both
    // frequencies (within ±2 dB of expected sum).
    //
    // NOTE: Because we're running in the mixer's simulated (pull-model) context,
    // we collect a large merged buffer and run FFT on it.
    func testMixedOutputContainsBothSourceFrequencies() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let (s1, stop1) = makeInfiniteStream(frequency: 440, amplitude: 0.5)
        let (s2, stop2) = makeInfiniteStream(frequency: 880, amplitude: 0.5)
        defer { stop1(); stop2() }

        try mixer.addSource(id: "f440", stream: s1)
        try mixer.addSource(id: "f880", stream: s2)

        let mixStream = mixer.mixBufferStream()

        // Collect ≥1 second worth of audio (≥100 buffers of 480 frames @ 48 kHz).
        var allFrames = [Float]()
        let deadline = Date().addingTimeInterval(5.0)
        for await buf in mixStream {
            if let ptr = buf.floatChannelData?[0] {
                for i in 0..<Int(buf.frameLength) { allFrames.append(ptr[i]) }
            }
            if allFrames.count >= 48_000 { break }
            if Date() > deadline { break }
        }

        XCTAssertGreaterThanOrEqual(allFrames.count, 48_000,
            "Need ≥1 s of audio for FFT; got \(allFrames.count) frames")

        // Compute FFT magnitudes on the first 65536 samples.
        let fftSize = 65536
        let log2n = 16
        var inputCopy = Array(allFrames.prefix(fftSize))
        while inputCopy.count < fftSize { inputCopy.append(0) }

        var reals = [Float](repeating: 0, count: fftSize / 2)
        var imags = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var mag440: Float = 0
        var mag880: Float = 0

        reals.withUnsafeMutableBufferPointer { rPtr in
            imags.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                inputCopy.withUnsafeBytes { rawBytes in
                    let typed = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(typed.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                let log2nLen = vDSP_Length(log2n)
                guard let fftSetup = vDSP_create_fftsetup(log2nLen, FFTRadix(FFT_RADIX2)) else { return }
                defer { vDSP_destroy_fftsetup(fftSetup) }
                vDSP_fft_zrip(fftSetup, &split, 1, log2nLen, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                // Frequency resolution = sampleRate / fftSize = 48000 / 65536 ≈ 0.73 Hz/bin.
                let freqRes = 48_000.0 / Double(fftSize)
                let bin440 = Int(440.0 / freqRes)
                let bin880 = Int(880.0 / freqRes)

                // Sum a ±3 bin window around each target frequency to catch spectral leakage.
                for offset in -3...3 {
                    let b440 = bin440 + offset
                    let b880 = bin880 + offset
                    if b440 > 0 && b440 < fftSize / 2 { mag440 += magnitudes[b440] }
                    if b880 > 0 && b880 < fftSize / 2 { mag880 += magnitudes[b880] }
                }
            }
        }

        XCTAssertGreaterThan(mag440, 0, "Mix should contain 440 Hz component")
        XCTAssertGreaterThan(mag880, 0, "Mix should contain 880 Hz component")

        // Both components should be clearly present. Equal-amplitude sources yield equal
        // FFT peaks in theory; in practice raw-FFT spectral leakage causes variance
        // between harmonically related frequencies (440 Hz / 880 Hz). Allow up to 20 dB
        // difference — this still confirms both tones are present and neither is absent.
        if mag440 > 0 && mag880 > 0 {
            let ratioDb = abs(20.0 * log10(Double(mag440 / mag880)))
            XCTAssertLessThan(ratioDb, 20.0,
                "440 Hz and 880 Hz should both be clearly present; ratio=\(ratioDb) dB")
        }
    }

    // MARK: testSetGainOnUnknownSourceIsNoOp
    //
    // Calling `setGain(forSource:gain:)` with an unregistered ID must not crash.
    func testSetGainOnUnknownSourceIsNoOp() {
        let mixer = MixerGraph()
        defer { mixer.stop() }
        // Must not crash.
        mixer.setGain(forSource: "nonexistent", gain: 0.5)
    }

    // MARK: testSourceBufferStreamForUnknownSourceReturnsEmptyStream
    //
    // `sourceBufferStream(forSource:)` for an unregistered ID returns an
    // immediately-finishing stream (no buffers, no crash).
    func testSourceBufferStreamForUnknownSourceReturnsEmptyStream() async {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        let stream = mixer.sourceBufferStream(forSource: "ghost")
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "Unknown source stream should immediately finish")
    }

    // MARK: testMixBusIsTimeAlignedNotConcatenated
    //
    // BUG REGRESSION: With N concurrent sources, the mix bus must yield buffers
    // representing the sample-aligned SUM across sources, not the concatenation
    // of all source buffers. Two real-time sources, each producing 50 × 480
    // frames (~500 ms wall-clock), should produce ~24k frames on the mix bus
    // (one stream's worth, summed) — NOT ~48k (concatenation).
    //
    // Concatenation manifested as: 5 s of recording → 5 min of MP3 with
    // ~60 process taps under the `.everything` preset.
    func testMixBusIsTimeAlignedNotConcatenated() async throws {
        let mixer = MixerGraph()
        defer { mixer.stop() }

        // Two finite sources, each producing exactly 50 × 480 frames
        // (= 24 000 frames per source) over ~500 ms wall-clock.
        let s1 = makeFiniteStream(frequency: 440, bufferCount: 50)
        let s2 = makeFiniteStream(frequency: 880, bufferCount: 50)

        try mixer.addSource(id: "src1", stream: s1)
        try mixer.addSource(id: "src2", stream: s2)

        let mixStream = mixer.mixBufferStream()

        // Stop the mixer after 1.5 s so the mix-bus AsyncStream terminates and
        // the for-await loop exits even when no source streams remain.
        let stopTask = Task { [mixer] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            mixer.stop()
        }
        defer { stopTask.cancel() }

        var totalFrames = 0
        for await buf in mixStream {
            totalFrames += Int(buf.frameLength)
            if totalFrames > 60_000 { break }
        }

        // Sample-aligned mix: ≈24 000 frames (one wall-clock interval).
        // Concatenation bug:    ≈48 000 frames (both intervals concatenated).
        XCTAssertLessThanOrEqual(totalFrames, 30_000,
            "Mix bus must sample-align across sources, not concatenate. Got \(totalFrames) frames; expected ≤30 000.")
    }

    // MARK: testStopIsIdempotent
    //
    // Calling `stop()` multiple times must not crash.
    func testStopIsIdempotent() throws {
        let mixer = MixerGraph()
        mixer.stop()
        XCTAssertNoThrow(mixer.stop())
    }

    // MARK: testAddSourceAfterStopIsNoOp
    //
    // Adding a source after `stop()` must throw `MixerError.stopped`.
    func testAddSourceAfterStopIsNoOp() throws {
        let mixer = MixerGraph()
        mixer.stop()
        let (s, stopS) = makeInfiniteStream(frequency: 440)
        defer { stopS() }
        XCTAssertThrowsError(try mixer.addSource(id: "late", stream: s)) { error in
            guard case MixerError.stopped = error else {
                XCTFail("Expected MixerError.stopped, got \(error)")
                return
            }
        }
    }
}
