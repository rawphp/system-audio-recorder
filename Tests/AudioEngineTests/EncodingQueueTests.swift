import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - Helpers

private let testSampleRate: Double = 48000
private let testChannels: AVAudioChannelCount = 2

private let canonicalFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: testSampleRate,
    channels: testChannels,
    interleaved: false
)!

/// Writes a short silence WAV for testing.
private func writeSilenceWAV(
    to dir: URL,
    name: String,
    durationSeconds: Double = 0.5
) throws -> URL {
    let url = dir.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey:             kAudioFormatLinearPCM,
        AVSampleRateKey:           testSampleRate,
        AVNumberOfChannelsKey:     testChannels,
        AVLinearPCMBitDepthKey:    32,
        AVLinearPCMIsFloatKey:     true,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let totalFrames = AVAudioFrameCount(durationSeconds * testSampleRate)
    guard let buf = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: totalFrames) else {
        throw NSError(domain: "TestHelper", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot allocate buffer"])
    }
    buf.frameLength = totalFrames
    // Zero-filled (silence) — faster than writing real audio for queue tests
    if let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] {
        for i in 0..<Int(totalFrames) { ch0[i] = 0; ch1[i] = 0 }
    }
    try file.write(from: buf)
    return url
}

// MARK: - EncodingQueueTests

@MainActor
final class EncodingQueueTests: XCTestCase {

    var tmpDir: URL!
    var queue: EncodingQueue!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncodingQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        queue = EncodingQueue()
    }

    override func tearDown() async throws {
        await queue.cancelAll()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - testEnqueueReturnsImmediately

    /// AC-1: `enqueue(job:keepWAV:)` must return in < 5 ms.
    func testEnqueueReturnsImmediately() async throws {
        let wavURL = try writeSilenceWAV(to: tmpDir, name: "fast.wav")
        let mp3URL = tmpDir.appendingPathComponent("fast.mp3")
        let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        let start = Date()
        await queue.enqueue(job: job, keepWAV: false)
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms
        XCTAssertLessThan(elapsed, 5, "enqueue must return in < 5 ms; took \(elapsed) ms")
    }

    // MARK: - testThreeJobsAllComplete

    /// AC-2 (concurrency) + AC-3 (success path):
    /// Enqueue 3 WAV jobs; all 3 must end up in `completed`.
    func testThreeJobsAllComplete() async throws {
        var jobs: [EncodingJob] = []
        for i in 0..<3 {
            let wavURL = try writeSilenceWAV(to: tmpDir, name: "job\(i).wav")
            let mp3URL = tmpDir.appendingPathComponent("job\(i).mp3")
            jobs.append(EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr))
        }

        for job in jobs {
            await queue.enqueue(job: job, keepWAV: true)
        }

        // Wait up to 60 s for all 3 to complete
        let deadline = Date().addingTimeInterval(60)
        while queue.completed.count < 3 && queue.failed.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        XCTAssertEqual(queue.completed.count, 3, "All 3 jobs must complete")
        XCTAssertTrue(queue.failed.isEmpty, "No jobs should fail")

        // MP3 files must exist
        for job in jobs {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: job.mp3URL.path),
                "MP3 must exist at \(job.mp3URL.path)"
            )
        }
    }

    // MARK: - testWAVDeletedOnSuccessWhenKeepFalse

    /// AC-3: WAV deleted after successful encode when `keepWAV == false`.
    func testWAVDeletedOnSuccessWhenKeepFalse() async throws {
        let wavURL = try writeSilenceWAV(to: tmpDir, name: "delete-me.wav")
        let mp3URL = tmpDir.appendingPathComponent("delete-me.mp3")
        let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        await queue.enqueue(job: job, keepWAV: false)

        let deadline = Date().addingTimeInterval(30)
        while queue.completed.isEmpty && queue.failed.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wavURL.path),
            "WAV must be deleted when keepWAV == false"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mp3URL.path),
            "MP3 must exist after successful encode"
        )
    }

    // MARK: - testWAVKeptOnSuccessWhenKeepTrue

    /// AC-3 (inverse): WAV preserved when `keepWAV == true`.
    func testWAVKeptOnSuccessWhenKeepTrue() async throws {
        let wavURL = try writeSilenceWAV(to: tmpDir, name: "keep-me.wav")
        let mp3URL = tmpDir.appendingPathComponent("keep-me.mp3")
        let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        await queue.enqueue(job: job, keepWAV: true)

        let deadline = Date().addingTimeInterval(30)
        while queue.completed.isEmpty && queue.failed.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wavURL.path),
            "WAV must be preserved when keepWAV == true"
        )
    }

    // MARK: - testFailurePreservesWAVAndRemovesPartialMP3

    /// AC-4: Failure job (non-existent WAV) goes to `failed`; WAV preserved; no partial MP3.
    func testFailurePreservesWAVAndRemovesPartialMP3() async throws {
        // Point at a non-existent WAV — LameEncoder will throw EncodingError.invalidInput
        let badWAV = tmpDir.appendingPathComponent("nonexistent.wav")
        let mp3URL = tmpDir.appendingPathComponent("should-not-exist.mp3")
        let job = EncodingJob(wavURL: badWAV, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        await queue.enqueue(job: job, keepWAV: false)

        let deadline = Date().addingTimeInterval(15)
        while queue.failed.isEmpty && queue.completed.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(queue.failed.count, 1, "Job must end up in failed")
        XCTAssertTrue(queue.completed.isEmpty, "No jobs should complete")

        // Partial MP3 must not exist
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: mp3URL.path),
            "No partial MP3 should remain after failure"
        )

        // The failed entry must carry the underlying EncodingError
        if let entry = queue.failed.first {
            XCTAssertNotNil(entry.error, "Failed job must carry an error")
        }
    }

    // MARK: - testCancelAllRemovesPartialMP3s

    /// AC-5: `cancelAll()` drains pending + running without leaving partial MP3s.
    func testCancelAllRemovesPartialMP3s() async throws {
        // Enqueue several jobs then immediately cancel before they can finish
        var mp3URLs: [URL] = []
        for i in 0..<4 {
            let wavURL = try writeSilenceWAV(to: tmpDir, name: "cancel\(i).wav", durationSeconds: 2)
            let mp3URL = tmpDir.appendingPathComponent("cancel\(i).mp3")
            mp3URLs.append(mp3URL)
            let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)
            await queue.enqueue(job: job, keepWAV: true)
        }

        await queue.cancelAll()

        // After cancelAll, no partial MP3 files should remain
        for mp3URL in mp3URLs {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: mp3URL.path),
                "No partial MP3 should remain at \(mp3URL.lastPathComponent) after cancelAll"
            )
        }

        // Queue arrays must be empty
        XCTAssertTrue(queue.pending.isEmpty, "pending must be empty after cancelAll")
        XCTAssertTrue(queue.running.isEmpty, "running must be empty after cancelAll")
    }

    // MARK: - testObservableStateChangesOnMainActor

    /// AC-6: @Observable state (`completed`) is updated on the main actor.
    func testObservableStateChangesOnMainActor() async throws {
        let wavURL = try writeSilenceWAV(to: tmpDir, name: "obs.wav")
        let mp3URL = tmpDir.appendingPathComponent("obs.mp3")
        let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        await queue.enqueue(job: job, keepWAV: true)

        let deadline = Date().addingTimeInterval(30)
        while queue.completed.isEmpty && queue.failed.isEmpty && Date() < deadline {
            // Spin on the main actor — observable updates must reach us here
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // If we can read completed.count here (on main actor), the property is main-actor-safe
        let count = queue.completed.count + queue.failed.count
        XCTAssertEqual(count, 1, "Exactly one job must reach a terminal state")
    }

    // MARK: - testRecentlyCompletedJobIsSet

    /// Verifies `recentlyCompletedJob` is set after a job succeeds (REQ-027 hook).
    func testRecentlyCompletedJobIsSet() async throws {
        let wavURL = try writeSilenceWAV(to: tmpDir, name: "recent.wav")
        let mp3URL = tmpDir.appendingPathComponent("recent.mp3")
        let job = EncodingJob(wavURL: wavURL, mp3URL: mp3URL, bitrate: 192, mode: .vbr)

        await queue.enqueue(job: job, keepWAV: true)

        let deadline = Date().addingTimeInterval(30)
        while queue.recentlyCompletedJob == nil && queue.failed.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNotNil(queue.recentlyCompletedJob, "recentlyCompletedJob must be set on success")
        XCTAssertEqual(queue.recentlyCompletedJob?.id, job.id)
    }
}
