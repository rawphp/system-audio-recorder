import XCTest
import AVFoundation
@testable import SystemAudioToMP3

// MARK: - WAVWriterRecoveryTests
//
// Tests for REQ-016: crash-safety sidecar JSON and WAV header repair.
//
// Crash simulation strategy:
//   Open WAVWriter, write buffers via an indefinite stream, cancel the writer task
//   (Task.cancel()). Because the sidecar is only deleted on CLEAN completion of
//   consumeStream (not in defer), task cancellation leaves the sidecar on disk —
//   exactly what happens after a process kill.

final class WAVWriterRecoveryTests: XCTestCase {

    var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVWriterRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Shared format

    private static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 2,
        interleaved: false
    )!

    /// Builds a silent AVAudioPCMBuffer of 480 frames.
    private func silentBuffer() -> AVAudioPCMBuffer {
        let fmt = Self.canonicalFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        buf.frameLength = 480
        return buf
    }

    /// Returns a pair of (stream, continuation) backed by the canonical format.
    private func makeOpenStream()
        -> (stream: AsyncStream<AVAudioPCMBuffer>, cont: AsyncStream<AVAudioPCMBuffer>.Continuation)
    {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let stream = AsyncStream<AVAudioPCMBuffer> { cont = $0 }
        return (stream, cont)
    }

    // MARK: - testSidecarCreatedDuringSession
    //
    // The sidecar must appear on disk within 5 s of session start (after the first 1-s fsync).
    func testSidecarCreatedDuringSession() async throws {
        let timestamp = "2026-01-01T10-00-00"
        let info = RecordingInfo(
            sessionStartTime: Date(),
            sources: [AudioSourceInfo(id: "pid:1", name: "TestApp")],
            outputMode: "mixed",
            sampleRate: 48000,
            channelCount: 2
        )
        let sidecarURL = tmpDir.appendingPathComponent("\(timestamp).recording.json")

        let (stream, cont) = makeOpenStream()
        let writer = WAVWriter(outputFolder: tmpDir, timestamp: timestamp, recordingInfo: info)

        // Feed buffers at 1 ms intervals (fast, well above 1 s per fsync cycle).
        let feeder = Task.detached {
            while !Task.isCancelled {
                cont.yield(AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: 480).map {
                    $0.frameLength = 480; return $0
                }!)
                try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            }
        }

        // Run writer — ignore cancellation error thrown when we cancel it.
        let writerTask = Task {
            _ = try? await writer.runMixed(stream: stream)
        }

        // Poll up to 5 s for the sidecar to appear.
        var found = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                found = true
                break
            }
        }

        feeder.cancel()
        writerTask.cancel()
        cont.finish()

        XCTAssertTrue(found, "Sidecar .recording.json must appear within 5 s of session start")

        if found {
            let data = try Data(contentsOf: sidecarURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(RecordingInfo.self, from: data)
            XCTAssertEqual(decoded.outputMode, "mixed")
            XCTAssertEqual(decoded.sampleRate, 48000)
            XCTAssertEqual(decoded.channelCount, 2)
            XCTAssertFalse(decoded.sources.isEmpty)
        }
    }

    // MARK: - testSidecarDeletedOnCleanClose
    //
    // After a clean close (stream finishes naturally), the sidecar must be gone.
    func testSidecarDeletedOnCleanClose() async throws {
        let timestamp = "2026-01-01T10-00-01"
        let info = RecordingInfo(
            sessionStartTime: Date(),
            sources: [],
            outputMode: "mixed",
            sampleRate: 48000,
            channelCount: 2
        )
        let sidecarURL = tmpDir.appendingPathComponent("\(timestamp).recording.json")

        // Bounded stream (5 buffers, completes quickly — no fsync cycle will fire).
        let (stream, cont) = makeOpenStream()
        let writer = WAVWriter(outputFolder: tmpDir, timestamp: timestamp, recordingInfo: info)

        // Write a handful of buffers and finish.
        let writerTask = Task { try await writer.runMixed(stream: stream) }
        for _ in 0..<5 { cont.yield(silentBuffer()) }
        cont.finish()
        _ = try await writerTask.value

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "Sidecar must be deleted after clean close()"
        )
    }

    // MARK: - testScanForRecoveryFindsOrphanedSidecar
    //
    // Simulate crash: write audio, cancel the task (crash simulation) → sidecar survives.
    // scanForRecovery must find it.
    func testScanForRecoveryFindsOrphanedSidecar() async throws {
        let timestamp = "2026-01-01T10-00-02"
        let info = RecordingInfo(
            sessionStartTime: Date(),
            sources: [AudioSourceInfo(id: "pid:42", name: "CrashedApp")],
            outputMode: "mixed",
            sampleRate: 48000,
            channelCount: 2
        )
        let wavURL     = tmpDir.appendingPathComponent("\(timestamp).wav")
        let sidecarURL = tmpDir.appendingPathComponent("\(timestamp).recording.json")

        let (stream, cont) = makeOpenStream()
        let writer = WAVWriter(outputFolder: tmpDir, timestamp: timestamp, recordingInfo: info)

        // Feed buffers continuously so the 1-s fsync fires and the sidecar appears.
        let feeder = Task.detached {
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 2,
                interleaved: false
            )!
            while !Task.isCancelled {
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
                buf.frameLength = 480
                cont.yield(buf)
                try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            }
        }

        let writerTask = Task {
            _ = try? await writer.runMixed(stream: stream)
        }

        // Wait until sidecar appears (up to 5 s).
        var sidecarFound = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                sidecarFound = true
                break
            }
        }

        // Simulate crash: cancel writer task BEFORE finishing the stream.
        // This means consumeStream's `for await` is interrupted; deleteSidecar is never called.
        feeder.cancel()
        writerTask.cancel()
        // Give the tasks a moment to respond to cancellation.
        try await Task.sleep(nanoseconds: 200_000_000)
        cont.finish()

        guard sidecarFound else {
            XCTFail("Sidecar never appeared during session — cannot test scan")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                      "Sidecar must still exist after simulated crash (task cancel)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path),
                      "WAV must exist on disk after simulated crash")

        let entries = WAVWriter.scanForRecovery(in: tmpDir)
        XCTAssertEqual(entries.count, 1, "scanForRecovery must find exactly one orphaned entry")

        guard let entry = entries.first else { return }
        XCTAssertEqual(entry.wavURL.lastPathComponent, "\(timestamp).wav")
        XCTAssertEqual(entry.info.outputMode, "mixed")
        XCTAssertFalse(entry.info.sources.isEmpty)
        XCTAssertEqual(entry.info.sources.first?.name, "CrashedApp")
    }

    // MARK: - testWAVHeaderRepairAllowsAVAudioFileOpen
    //
    // After zeroing the RIFF/data chunk size fields (simulating a crash),
    // repairWAVHeader(at:) must restore them so AVAudioFile can open the file.
    func testWAVHeaderRepairAllowsAVAudioFileOpen() async throws {
        let timestamp = "2026-01-01T10-00-03"
        let info = RecordingInfo(
            sessionStartTime: Date(),
            sources: [],
            outputMode: "mixed",
            sampleRate: 48000,
            channelCount: 2
        )

        // Write 3 s of audio via a bounded stream (clean close so we get a valid file first).
        let (stream, cont) = makeOpenStream()
        let writer = WAVWriter(outputFolder: tmpDir, timestamp: timestamp, recordingInfo: info)
        let writerTask = Task { try await writer.runMixed(stream: stream) }

        // 300 buffers × 480 frames = 144_000 frames ≈ 3 s at 48 kHz
        for _ in 0..<300 {
            cont.yield(silentBuffer())
            try await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        cont.finish()
        _ = try await writerTask.value

        let wavURL = tmpDir.appendingPathComponent("\(timestamp).wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path), "WAV must exist")

        // Corrupt RIFF size fields to simulate a crash mid-session.
        try corruptWAVHeader(at: wavURL)

        // Verify corruption: AVAudioFile may fail or report wrong length.
        // (We don't assert the failure explicitly — some AVFoundation versions are lenient.)

        // Repair the header.
        try WAVWriter.repairWAVHeader(at: wavURL)

        // Post-repair: AVAudioFile must open and report a reasonable length.
        let repairedFile = try AVAudioFile(forReading: wavURL)
        let frameCount = repairedFile.length
        XCTAssertGreaterThan(frameCount, 0, "Repaired WAV must have non-zero frame count")

        // Allow ±10% tolerance (some frames may not flush before clean close).
        let expectedFrames = Int64(300 * 480)
        let tolerance = Int64(Double(expectedFrames) * 0.10)
        XCTAssertGreaterThanOrEqual(
            frameCount,
            expectedFrames - tolerance,
            "Repaired WAV duration must be ≥ 90% of 3 s (\(expectedFrames) frames), got \(frameCount)"
        )
    }

    // MARK: - testScanForRecoveryReturnsEmptyWhenNoSidecars
    //
    // A folder with only a plain WAV (no sidecar) must return an empty array.
    func testScanForRecoveryReturnsEmptyWhenNoSidecars() throws {
        let dummyURL = tmpDir.appendingPathComponent("normal.wav")
        try Data().write(to: dummyURL)

        let entries = WAVWriter.scanForRecovery(in: tmpDir)
        XCTAssertTrue(entries.isEmpty, "No sidecars → empty recovery list")
    }

    // MARK: - Helpers

    /// Zeros the RIFF size and data chunk size fields in a WAV header to simulate crash state.
    private func corruptWAVHeader(at url: URL) throws {
        guard let fh = FileHandle(forUpdatingAtPath: url.path) else {
            throw NSError(domain: "RecoveryTests", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open for corruption"])
        }
        defer { fh.closeFile() }
        var zero = UInt32(0).littleEndian
        // RIFF chunk size at offset 4
        fh.seek(toFileOffset: 4)
        withUnsafeBytes(of: &zero) { fh.write(Data($0)) }
        // data chunk size at offset 40
        fh.seek(toFileOffset: 40)
        withUnsafeBytes(of: &zero) { fh.write(Data($0)) }
        fh.synchronizeFile()
    }
}
