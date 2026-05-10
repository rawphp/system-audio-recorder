import XCTest
import AVFoundation
@testable import SystemAudioRecorder

/// Unit tests for `SignalLevelAggregator` — REQ-046 / UR-004.
final class SignalLevelAggregatorTests: XCTestCase {

    private static let format: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
    }()

    /// Build a buffer of the requested frame count, filled with the given
    /// constant amplitude (same value per sample, all channels).
    private func buffer(frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        if let p = b.floatChannelData {
            for c in 0..<Int(Self.format.channelCount) {
                for f in 0..<frames { p[c][f] = amplitude }
            }
        }
        return b
    }

    // MARK: - testSilentBuffersEscalateAfterWindow (REQ-046)
    //
    // 100 zero-amplitude buffers spread across 4 simulated 1-second windows.
    // Each window emits buffers, then ticks — so the silence streak grows
    // tick-by-tick. Exactly one silent_source info entry must appear (the
    // flag dedupes subsequent ticks until audible buffers arrive).
    func testSilentBuffersEscalateAfterWindow() {
        let logger = CapturingSignalLogger()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let agg = SignalLevelAggregator(
            id: "src-1",
            logger: logger,
            sessionStart: start,
            silenceWindowSeconds: 3.0
        )

        // Interleave: 25 zero-amp buffers per second, then tick at the end of
        // each second. 100 total buffers across 4 ticks.
        for tickSec in 1...4 {
            for j in 0..<25 {
                let t = start.addingTimeInterval(
                    Double(tickSec - 1) + Double(j) * 0.04
                )
                agg.recordBuffer(buffer(frames: 480, amplitude: 0.0), at: t)
            }
            agg.tick(now: start.addingTimeInterval(Double(tickSec)))
        }

        // Exactly one silent_source line — escalation fires on the 3rd tick
        // (3-second silenceWindow), the 4th tick is dedup'd by the flag.
        let silent = logger.infoLines.filter { $0.contains("silent_source") }
        XCTAssertEqual(silent.count, 1,
            "Expected exactly one silent_source line; got \(logger.infoLines)")
        XCTAssertTrue(silent.first?.contains("id=src-1") ?? false,
            "silent_source line should reference source id")

        // Per-second debug summaries: one per tick = 4.
        let sourceLines = logger.debugLines.filter { $0.contains("source=src-1") }
        XCTAssertEqual(sourceLines.count, 4)
    }

    // MARK: - testStarvationEscalatesAfterWindow (REQ-046)
    //
    // No buffers ever arrive. After 3 simulated seconds the no_buffers info
    // entry must fire exactly once (de-duplicated until a buffer arrives).
    // A subsequent buffer + new starvation window must produce a fresh entry.
    func testStarvationEscalatesAfterWindow() {
        let logger = CapturingSignalLogger()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let agg = SignalLevelAggregator(
            id: "src-2",
            logger: logger,
            sessionStart: start,
            starvationWindowSeconds: 3.0
        )

        // Tick at 1s, 2s, 3s, 4s with no buffers — first no_buffers expected
        // at the 3s tick.
        for tickSec in 1...4 {
            agg.tick(now: start.addingTimeInterval(Double(tickSec)))
        }

        var starved = logger.infoLines.filter { $0.contains("no_buffers") }
        XCTAssertEqual(starved.count, 1,
            "Expected exactly one no_buffers line on first starvation; got \(logger.infoLines)")
        XCTAssertTrue(starved[0].contains("id=src-2"))

        // A buffer arrives at 5s — should clear the starved flag.
        agg.recordBuffer(
            buffer(frames: 480, amplitude: 0.5),
            at: start.addingTimeInterval(5.0)
        )
        agg.tick(now: start.addingTimeInterval(5.0))

        // No new starvation entry yet (just had a buffer).
        starved = logger.infoLines.filter { $0.contains("no_buffers") }
        XCTAssertEqual(starved.count, 1)

        // Now starve again until 9s.
        for tickSec in 6...9 {
            agg.tick(now: start.addingTimeInterval(Double(tickSec)))
        }

        starved = logger.infoLines.filter { $0.contains("no_buffers") }
        XCTAssertEqual(starved.count, 2,
            "After a buffer + new starvation window, no_buffers should re-emit")
    }

    // MARK: - testAudibleBuffersDoNotTriggerSilentSource (REQ-046)
    //
    // Buffers above the silence threshold must never produce a silent_source
    // entry, no matter how long the session runs.
    func testAudibleBuffersDoNotTriggerSilentSource() {
        let logger = CapturingSignalLogger()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let agg = SignalLevelAggregator(
            id: "src-3",
            logger: logger,
            sessionStart: start,
            silenceWindowSeconds: 3.0
        )

        // Loud buffers (amplitude 0.5 → ~-6 dBFS, well above -80) — 100 per
        // second, interleaved with ticks.
        for tickSec in 1...4 {
            for j in 0..<100 {
                let t = start.addingTimeInterval(
                    Double(tickSec - 1) + Double(j) * 0.01
                )
                agg.recordBuffer(buffer(frames: 480, amplitude: 0.5), at: t)
            }
            agg.tick(now: start.addingTimeInterval(Double(tickSec)))
        }

        let silent = logger.infoLines.filter { $0.contains("silent_source") }
        XCTAssertTrue(silent.isEmpty,
            "Audible buffers must not trigger silent_source; got \(silent)")
    }

    // MARK: - testMeanDBFSFormat (REQ-046)
    //
    // Per-second debug line must contain a numeric `meanLvl=<dB>` value when
    // any non-zero samples were seen, and `meanLvl=-inf` when the interval
    // produced no buffers (or only zero-amplitude samples).
    func testMeanDBFSFormat() {
        let logger = CapturingSignalLogger()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let agg = SignalLevelAggregator(
            id: "src-4",
            logger: logger,
            sessionStart: start
        )

        // Tick 1: nothing → -inf.
        agg.tick(now: start.addingTimeInterval(1.0))
        XCTAssertTrue(logger.debugLines.last?.contains("meanLvl=-inf") == true,
            "Empty interval must produce meanLvl=-inf; got \(logger.debugLines.last ?? "")")

        // Tick 2: half-amplitude buffers → ~-6 dB.
        agg.recordBuffer(
            buffer(frames: 480, amplitude: 0.5),
            at: start.addingTimeInterval(1.5)
        )
        agg.tick(now: start.addingTimeInterval(2.0))

        let line = logger.debugLines.last ?? ""
        XCTAssertTrue(line.contains("source=src-4"))
        XCTAssertTrue(line.contains("bufs=1"))
        // Expect a numeric value (not -inf) somewhere around -6.
        let pattern = "meanLvl=-?[0-9]+\\.[0-9]"
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression),
            "Expected numeric meanLvl in: \(line)")
    }
}
