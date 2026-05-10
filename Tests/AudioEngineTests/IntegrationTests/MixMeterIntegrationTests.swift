import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - REQ-061: Mix-bus level meter integration tests
//
// Verifies that during an active recording the mix-bus RMS feeds
// `MeterPublisher.meters["mix"]` with finite dBFS values, and that the
// meter clears when the session stops.
//
// All sources are `MockAudioSource`s — no real audio device opened.

final class MixMeterIntegrationTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixMeterIntTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
    }

    /// Drives a `MockAudioSource` continuously in the background until cancelled
    /// or the source is stopped. Real-time pace (~10 ms per buffer).
    private func driveSourceContinuous(_ src: MockAudioSource) -> Task<Void, Never> {
        Task.detached {
            let bufferDuration = TimeInterval(src.framesPerBuffer) / src.sampleRate
            while !Task.isCancelled {
                guard src.emit() else { return }
                try? await Task.sleep(nanoseconds: UInt64(bufferDuration * 1_000_000_000))
            }
        }
    }

    /// Wait up to `timeout` seconds for `predicate()` to return true, polling
    /// every `pollMillis` ms. Returns the final value of the predicate.
    private func waitFor(
        timeout: TimeInterval,
        pollMillis: UInt64 = 20,
        _ predicate: @Sendable @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) { return true }
            try? await Task.sleep(nanoseconds: pollMillis * 1_000_000)
        }
        return await MainActor.run(body: predicate)
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // AC: Mix meter populates during recording with finite dBFS > -60.
    // ─────────────────────────────────────────────────────────────────────
    @MainActor
    func testMixMeterPopulatesDuringRecording() async throws {
        let publisher = MeterPublisher()
        let ring = MeterRingBuffer(capacity: 64)
        publisher.register(sourceID: MeterMath.mixSourceID, ring: ring)
        publisher.start()
        defer {
            publisher.unregister(sourceID: MeterMath.mixSourceID)
            publisher.stop()
        }

        let session = RecordingSession()
        // 440 Hz sine at -12 dBFS — should produce a clearly non-silent RMS.
        let src = MockAudioSource.defaultSine(id: "sine-meter")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "sine-meter", emitter: src)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-10T10-00-00",
            mixMeterSink: { dbfs in
                ring.write(dbfs)
            }
        )

        try await session.start(config: cfg)
        let driver = driveSourceContinuous(src)

        // Within ~1 s the publisher should have drained at least one finite
        // dBFS value > -60 into meters["mix"].
        let populated = await waitFor(timeout: 1.5) {
            guard let v = publisher.meters[MeterMath.mixSourceID] else { return false }
            return v.isFinite && v > -60.0
        }

        driver.cancel()
        src.stop()
        _ = await session.stop()

        XCTAssertTrue(
            populated,
            "Mix meter should report a finite dBFS > -60 within 1.5s of starting; " +
            "got \(publisher.meters[MeterMath.mixSourceID].map(String.init(describing:)) ?? "nil")"
        )
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // AC: After stop, the publisher no longer holds a "mix" entry.
    // ─────────────────────────────────────────────────────────────────────
    @MainActor
    func testMixMeterClearsOnStop() async throws {
        let publisher = MeterPublisher()
        let ring = MeterRingBuffer(capacity: 64)
        publisher.register(sourceID: MeterMath.mixSourceID, ring: ring)
        publisher.start()

        let session = RecordingSession()
        let src = MockAudioSource.defaultSine(id: "sine-clear")

        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "sine-clear", emitter: src)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-10T10-00-01",
            mixMeterSink: { dbfs in
                ring.write(dbfs)
            }
        )

        try await session.start(config: cfg)
        let driver = driveSourceContinuous(src)

        // Wait until populated, then stop.
        _ = await waitFor(timeout: 1.5) {
            (publisher.meters[MeterMath.mixSourceID] ?? -.infinity).isFinite
        }

        driver.cancel()
        src.stop()
        _ = await session.stop()

        // AppStore-style teardown: caller unregisters and stops the publisher.
        publisher.unregister(sourceID: MeterMath.mixSourceID)

        // unregister hops to the main queue; give it a tick to drain.
        let cleared = await waitFor(timeout: 1.0) {
            publisher.meters[MeterMath.mixSourceID] == nil
        }
        publisher.stop()

        XCTAssertTrue(cleared, "publisher.meters[mix] should be cleared after unregister")
    }

    // MARK: ─────────────────────────────────────────────────────────────────
    // AC: Meter and silence detector co-exist on the same mix-bus stream.
    // Both must continue working when configured together.
    // ─────────────────────────────────────────────────────────────────────
    @MainActor
    func testMixMeterAndSilenceDetectorCoexist() async throws {
        let publisher = MeterPublisher()
        let ring = MeterRingBuffer(capacity: 64)
        publisher.register(sourceID: MeterMath.mixSourceID, ring: ring)
        publisher.start()
        defer {
            publisher.unregister(sourceID: MeterMath.mixSourceID)
            publisher.stop()
        }

        let session = RecordingSession()
        let src = MockAudioSource.defaultSine(id: "sine-coexist")

        // Configure BOTH the silence detector AND the mix-meter sink.
        let cfg = SessionConfig(
            sources: [SessionConfig.Source(id: "sine-coexist", emitter: src)],
            outputMode: .mixed,
            outputFolder: tmpDir,
            timestamp: "2026-05-10T10-00-02",
            autoStopSilenceSeconds: 30.0, // long enough not to trigger
            mixMeterSink: { dbfs in
                ring.write(dbfs)
            }
        )

        try await session.start(config: cfg)
        let driver = driveSourceContinuous(src)

        let populated = await waitFor(timeout: 1.5) {
            guard let v = publisher.meters[MeterMath.mixSourceID] else { return false }
            return v.isFinite && v > -60.0
        }

        driver.cancel()
        src.stop()
        _ = await session.stop()

        XCTAssertTrue(
            populated,
            "Mix meter should still populate when silence detector is also enabled"
        )
    }
}
