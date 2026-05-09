import XCTest
import AVFoundation
import Accelerate
@testable import SystemAudioToMP3

// MARK: - LevelMeterTests
//
// REQ-011: Level meter taps — RMS values via lockless ring buffer.
//
// Tests:
//  1. testRMSCalibration          — -12 dBFS pure tone reads -12 ± 0.3 dBFS
//  2. testRingBufferDropsOldest   — UI stall drops oldest unread samples; audio thread never blocks
//  3. testMeterPublisherDrainsAtFiftyHz — MeterPublisher emits values at ~50 Hz from ring buffer
//  4. testRingBufferLockFree      — write/read without holding any lock per operation
//  5. testMeterPublisherStopIsIdempotent — stop() safe to call multiple times
//  6. testMeterPublisherMultipleSources  — two sources each get independent meter slots
//  7. testRingBufferSPSCCapacity  — buffer wraps correctly at capacity boundary
//  8. testRingBufferFullDropsOldest — when full, next write drops the oldest sample

final class LevelMeterTests: XCTestCase {

    // MARK: - Helpers

    /// Generates a canonical 48 kHz Float32 stereo buffer filled with a pure sine wave
    /// at the given linear amplitude for `frameCount` frames.
    private func sineBuffer(
        amplitude: Float,
        frequency: Double = 1000,
        frameCount: AVAudioFrameCount = 9600 // 200 ms at 48 kHz
    ) -> AVAudioPCMBuffer {
        let format = FormatNormalizer.canonicalFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("Could not allocate sine buffer")
        }
        buf.frameLength = frameCount
        let angularFreq = 2.0 * Double.pi * frequency / format.sampleRate
        for ch in 0..<Int(format.channelCount) {
            guard let ptr = buf.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frameCount) {
                ptr[i] = amplitude * Float(sin(angularFreq * Double(i)))
            }
        }
        return buf
    }

    /// Linear amplitude for a given dBFS level.
    private func linearAmplitude(dbfs: Float) -> Float {
        pow(10.0, dbfs / 20.0)
    }

    // MARK: - testRingBufferSPSCCapacity
    //
    // A `MeterRingBuffer` of capacity N can hold exactly N samples.
    // After N writes, a further write drops the oldest (oldest == first written).
    func testRingBufferSPSCCapacity() {
        let ring = MeterRingBuffer(capacity: 4)

        // Write 4 values — must succeed without dropping.
        for i in 0..<4 {
            ring.write(Float(i))
        }

        // Read all 4 — should get 0,1,2,3.
        var values: [Float] = []
        while let v = ring.read() { values.append(v) }
        XCTAssertEqual(values, [0, 1, 2, 3], "Ring should return values in FIFO order")
    }

    // MARK: - testRingBufferFullDropsOldest
    //
    // When the ring buffer is full, writing one more value drops the oldest sample.
    func testRingBufferFullDropsOldest() {
        let ring = MeterRingBuffer(capacity: 4)

        for i in 0..<4 { ring.write(Float(i)) } // fills: [0,1,2,3]
        ring.write(99)                             // drops 0, inserts 99 → [1,2,3,99]

        var values: [Float] = []
        while let v = ring.read() { values.append(v) }
        XCTAssertEqual(values, [1, 2, 3, 99], "Oldest sample should be dropped when ring is full")
    }

    // MARK: - testRingBufferDropsOldest
    //
    // When the UI consumer is stalled, the audio-thread writer continues writing
    // into the ring buffer, dropping old unread samples. The writer must not block.
    func testRingBufferDropsOldest() {
        let ring = MeterRingBuffer(capacity: 16)

        // Fill the buffer completely.
        for i in 0..<16 { ring.write(Float(i)) }

        // Record timestamps around further writes (no UI thread reading).
        var maxWriteNs: UInt64 = 0
        for i in 16..<32 {
            let start = DispatchTime.now().uptimeNanoseconds
            ring.write(Float(i))
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if elapsed > maxWriteNs { maxWriteNs = elapsed }
        }

        // Each write must complete in < 50 µs (well under a 10 ms audio buffer period).
        let limitNs: UInt64 = 50_000
        XCTAssertLessThan(maxWriteNs, limitNs,
            "Ring buffer write took \(maxWriteNs) ns; must be < \(limitNs) ns (lock-free requirement)")

        // After overwrite the ring holds the 16 most-recent values (16–31).
        var values: [Float] = []
        while let v = ring.read() { values.append(v) }
        XCTAssertEqual(values.count, 16, "Ring should hold exactly 16 samples")
        XCTAssertEqual(values.first, 16, "Oldest sample should be 16 (earliest unread)")
        XCTAssertEqual(values.last, 31, "Newest sample should be 31")
    }

    // MARK: - testRMSCalibration
    //
    // A -12 dBFS sine tone fed through `MeterTap.computeRMS(_:)` must read
    // -12 ± 0.3 dBFS.
    //
    // "dBFS" for an RMS meter is defined relative to full-scale RMS (0 dBFS =
    // an RMS of 1.0).  A sine wave with peak amplitude A has RMS = A/sqrt(2).
    // To get -12 dBFS RMS, we need amplitude = 10^(-12/20) x sqrt(2).
    func testRMSCalibration() {
        // We want the RMS of the signal to equal 10^(-12/20).
        // For a sine: RMS = amplitude / sqrt(2)  -> amplitude = RMS x sqrt(2).
        let targetRMS = linearAmplitude(dbfs: -12.0)       // 10^(-12/20)
        let amplitude = targetRMS * sqrt(2.0)               // peak that yields targetRMS
        let buf = sineBuffer(amplitude: amplitude)

        let dbfs = MeterTap.computeRMS(buf)

        XCTAssertEqual(dbfs, -12.0, accuracy: 0.3,
            "Expected -12 dBFS ± 0.3, got \(dbfs)")
    }

    // MARK: - testMeterPublisherMultipleSources
    //
    // Two sources registered with `MeterPublisher` each receive independent
    // dBFS values via their respective `MeterRingBuffer`s.
    func testMeterPublisherMultipleSources() async throws {
        let publisher = MeterPublisher()
        defer { publisher.stop() }

        let ring1 = MeterRingBuffer(capacity: 64)
        let ring2 = MeterRingBuffer(capacity: 64)

        publisher.register(sourceID: "src1", ring: ring1)
        publisher.register(sourceID: "src2", ring: ring2)

        // Simulate the audio thread writing different levels.
        ring1.write(-6.0)
        ring2.write(-24.0)

        // Start draining. Give it one tick (20 ms = 1 interval at 50 Hz).
        publisher.start()
        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms — at least 2 ticks

        // The publisher should have read the values.
        let meters = publisher.meters
        let level1 = meters["src1"]
        let level2 = meters["src2"]

        XCTAssertNotNil(level1, "src1 should have a meter value")
        XCTAssertNotNil(level2, "src2 should have a meter value")

        if let l1 = level1, let l2 = level2 {
            XCTAssertEqual(l1, -6.0, accuracy: 0.5, "src1 should read near -6 dBFS")
            XCTAssertEqual(l2, -24.0, accuracy: 0.5, "src2 should read near -24 dBFS")
        }
    }

    // MARK: - testMeterPublisherDrainsAtFiftyHz
    //
    // `MeterPublisher.start()` must update `meters` at ≥40 Hz over a 200 ms window
    // (allowing for 20 % jitter on a 50 Hz target).
    //
    // Strategy: a background timer continuously feeds values into the ring (simulating
    // the audio thread) so that every drain tick has something to consume.
    func testMeterPublisherDrainsAtFiftyHz() async throws {
        let publisher = MeterPublisher()
        defer { publisher.stop() }

        let ring = MeterRingBuffer(capacity: 256)
        publisher.register(sourceID: "freq-test", ring: ring)

        // Background writer: feed a value every 5 ms (200 Hz — faster than drain rate
        // so every 50 Hz drain tick has at least 4 fresh values to read).
        let writerTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "TestWriter", qos: .userInteractive))
        writerTimer.schedule(deadline: .now(), repeating: .milliseconds(5))
        var writerCounter: Int = 0
        writerTimer.setEventHandler {
            ring.write(Float(-20.0) + Float(writerCounter % 5))
            writerCounter += 1
        }
        writerTimer.resume()
        defer { writerTimer.cancel() }

        var updateCount = 0
        let observation = publisher.onUpdate { _ in
            updateCount += 1
        }
        defer { observation.cancel() }

        publisher.start()
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        publisher.stop()

        // At 50 Hz over 200 ms we expect ~10 ticks. Require >=8.
        XCTAssertGreaterThanOrEqual(updateCount, 8,
            "Expected >=8 meter updates in 200 ms at 50 Hz; got \(updateCount)")
    }

    // MARK: - testMeterPublisherStopIsIdempotent
    //
    // `stop()` must be safe to call multiple times without crashing.
    func testMeterPublisherStopIsIdempotent() {
        let publisher = MeterPublisher()
        publisher.start()
        publisher.stop()
        XCTAssertNoThrow(publisher.stop())
    }

    // MARK: - testAudioThreadNeverBlocks
    //
    // Simulates the stall scenario from the REQ: UI consumer (ring reader) is
    // stalled; audio-thread writer keeps writing. Measures max single-write
    // latency — must be below 50 us (lock-free requirement).
    //
    // This test is synchronous so we can precisely measure write latency without
    // async runtime overhead perturbing the timing.
    func testAudioThreadNeverBlocks() {
        let ring = MeterRingBuffer(capacity: 32)

        // Run 1000 writes on the calling thread with a full ring (no reader).
        for _ in 0..<32 { ring.write(-20.0) } // fill ring

        var maxLatencyNs: UInt64 = 0
        for _ in 0..<1000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            ring.write(-20.0)  // ring is always full; each write drops oldest
            let elapsed = DispatchTime.now().uptimeNanoseconds - t0
            if elapsed > maxLatencyNs { maxLatencyNs = elapsed }
        }

        let limitNs: UInt64 = 50_000 // 50 us
        XCTAssertLessThan(maxLatencyNs, limitNs,
            "Audio thread write latency was \(maxLatencyNs) ns; must be < \(limitNs) ns")
    }
}
