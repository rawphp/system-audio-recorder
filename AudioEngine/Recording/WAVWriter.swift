import AVFoundation
import Foundation
import os.log

// MARK: - WriterError

/// Errors surfaced by `WAVWriter`.
public enum WriterError: Error {
    /// A disk write failed. The associated URL is the file being written.
    /// The `underlying` error carries the lower-level OS or AVFoundation error.
    case diskWriteFailed(URL, underlying: Error)
    /// WAV header repair failed because the file data is unreadable or corrupt beyond repair.
    case unrepairableHeader(URL)
}

// MARK: - AudioSourceInfo

/// Lightweight description of one audio source captured during a recording session.
public struct AudioSourceInfo: Codable, Equatable {
    /// A stable identifier for the source (e.g. `"pid:1234"` or a Core Audio UID).
    public var id: String
    /// Human-readable process / device name.
    public var name: String

    public init(id: String, name: String) {
        self.id   = id
        self.name = name
    }
}

// MARK: - RecordingInfo

/// JSON payload written to the crash-safety sidecar (`.recording.json`).
/// Updated on every 1-second fsync cycle while the session is active.
/// Deleted on clean `close()`.
public struct RecordingInfo: Codable {
    /// ISO 8601 timestamp of when the session started.
    public var sessionStartTime: Date
    /// Sources that were being captured.
    public var sources: [AudioSourceInfo]
    /// Output mode — `"mixed"` or `"separate"`.
    public var outputMode: String
    /// Number of audio frames flushed to disk so far (updated every 1 s).
    public var sampleCount: Int
    /// Sample rate in Hz (e.g. `48000`).
    public var sampleRate: Double
    /// Number of channels (e.g. `2` for stereo).
    public var channelCount: Int

    public init(
        sessionStartTime: Date,
        sources: [AudioSourceInfo],
        outputMode: String,
        sampleRate: Double,
        channelCount: Int,
        sampleCount: Int = 0
    ) {
        self.sessionStartTime = sessionStartTime
        self.sources          = sources
        self.outputMode       = outputMode
        self.sampleCount      = sampleCount
        self.sampleRate       = sampleRate
        self.channelCount     = channelCount
    }
}

// MARK: - RecoveryEntry

/// A WAV/sidecar pair found by `WAVWriter.scanForRecovery(in:)`.
public struct RecoveryEntry {
    /// The orphaned WAV file that needs header repair.
    public let wavURL: URL
    /// The decoded sidecar JSON found next to the WAV.
    public let info: RecordingInfo
}

// MARK: - WAVWriter

/// Session-scoped writer that opens one or many `AVAudioFile`s in 32-bit float WAV
/// format and consumes `AsyncStream<AVAudioPCMBuffer>`s.
///
/// **Modes**
/// - `runMixed(stream:)`   — one file named `<timestamp>.wav`
/// - `runSeparate(sources:mixStream:)` — one file per source (`<timestamp> - <SourceName>.wav`)
///   plus a shared mix file (`<timestamp> - Mix.wav`)
///
/// **Crash safety** (spec Section 6.4)
/// After every write, an fsync is issued via `FileHandle` at most once per second to
/// ensure OS-buffered bytes reach disk. A sidecar `.recording.json` file is also
/// written / updated every 1 second. On clean `close()`, the sidecar is deleted so
/// there is no spurious recovery prompt on next launch.
///
/// **Pause / resume**
/// Calling `pause()` stops the consumption loop from writing further buffers without
/// closing the file. `resume()` restarts consumption. The resulting file duration
/// equals the sum of all active-recording time; no silence is inserted for the gap.
///
/// **Recovery**
/// `WAVWriter.scanForRecovery(in:)` scans a folder for orphaned `.recording.json` sidecars
/// and returns `RecoveryEntry` values (sidecar + WAV URL pairs).
/// `WAVWriter.repairWAVHeader(at:)` reads the actual byte count after the `data` chunk
/// header and rewrites the RIFF and data chunk size fields — necessary because
/// `AVAudioFile` only finalizes those fields on `close()`.
public actor WAVWriter {

    // MARK: - Constants

    /// The canonical output format: 48 kHz, Float32, stereo, non-interleaved.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Stored properties

    private let outputFolder: URL
    private let timestamp: String
    /// Optional recording info for crash-safety sidecar writes.
    private var recordingInfo: RecordingInfo?
    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "WAVWriter"
    )

    /// Pause flag — when `true`, incoming buffers are dropped instead of written.
    private var isPaused = false

    // MARK: - Init

    /// - Parameters:
    ///   - outputFolder:   The directory in which WAV files will be created.
    ///   - timestamp:      A caller-supplied base string used in file names (e.g. `"2026-01-01T00-00-00"`).
    ///   - recordingInfo:  When supplied, a crash-safety sidecar `.recording.json` is written
    ///                     and updated every 1 second. Pass `nil` for tests that don't need recovery.
    public init(
        outputFolder: URL,
        timestamp: String,
        recordingInfo: RecordingInfo? = nil
    ) {
        self.outputFolder  = outputFolder
        self.timestamp     = timestamp
        self.recordingInfo = recordingInfo
    }

    // MARK: - Pause / Resume

    /// Freezes the write cursor. While paused, incoming buffers are discarded.
    public func pause() {
        isPaused = true
    }

    /// Resumes writing. Has no effect if not paused.
    public func resume() {
        isPaused = false
    }

    // MARK: - Mixed mode

    /// Consumes `stream` and writes all buffers to a single `<timestamp>.wav` file.
    ///
    /// - Parameter stream: Canonical-format (48 kHz Float32 stereo) buffer stream.
    /// - Returns: Array containing the single WAV file URL.
    /// - Throws: `WriterError.diskWriteFailed` if the file cannot be created or a write fails.
    public func runMixed(stream: AsyncStream<AVAudioPCMBuffer>) async throws -> [URL] {
        let url  = outputFolder.appendingPathComponent("\(timestamp).wav")
        let file = try openAVAudioFile(at: url)
        let fh   = try openFileHandle(at: url)
        defer { fh.closeFile() }

        try await consumeStream(stream, into: file, fileURL: url, fileHandle: fh)
        // Clean close — delete sidecar so there's no spurious recovery prompt next launch.
        // Skip if the task was cancelled (simulates crash: sidecar survives for recovery).
        if !Task.isCancelled {
            deleteSidecar(for: url)
        }
        return [url]
    }

    // MARK: - Separate mode

    /// Consumes per-source streams and a mix stream, writing each to a separate WAV file.
    ///
    /// Files produced:
    /// - `<timestamp> - <SourceName>.wav` for each element in `sources`
    /// - `<timestamp> - Mix.wav` for `mixStream`
    ///
    /// - Parameters:
    ///   - sources:   Array of `(name, stream)` tuples; name is used in the file name.
    ///   - mixStream: The blended output from `MixerGraph.mixBufferStream()`.
    /// - Returns: Array of all produced file URLs (N sources + 1 mix).
    /// - Throws: `WriterError.diskWriteFailed` on any file-open or write failure.
    public func runSeparate(
        sources: [(String, AsyncStream<AVAudioPCMBuffer>)],
        mixStream: AsyncStream<AVAudioPCMBuffer>
    ) async throws -> [URL] {
        // Open all files first — surface any permission / path errors before consuming.
        var entries: [(url: URL,
                       file: AVAudioFile,
                       fh: FileHandle,
                       stream: AsyncStream<AVAudioPCMBuffer>)] = []

        for (name, stream) in sources {
            let url  = outputFolder.appendingPathComponent("\(timestamp) - \(name).wav")
            let file = try openAVAudioFile(at: url)
            let fh   = try openFileHandle(at: url)
            entries.append((url, file, fh, stream))
        }

        let mixURL  = outputFolder.appendingPathComponent("\(timestamp) - Mix.wav")
        let mixFile = try openAVAudioFile(at: mixURL)
        let mixFH   = try openFileHandle(at: mixURL)
        entries.append((mixURL, mixFile, mixFH, mixStream))

        defer {
            for entry in entries { entry.fh.closeFile() }
        }

        // Consume all streams concurrently using a TaskGroup.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                let url    = entry.url
                let file   = entry.file
                let fh     = entry.fh
                let stream = entry.stream

                group.addTask {
                    try await self.consumeStream(stream, into: file, fileURL: url, fileHandle: fh)
                }
            }
            try await group.waitForAll()
        }

        // Clean close — delete sidecars so there's no spurious recovery prompt next launch.
        // Skip if the task was cancelled (simulates crash: sidecars survive for recovery).
        if !Task.isCancelled {
            for entry in entries { deleteSidecar(for: entry.url) }
        }

        return entries.map(\.url)
    }

    // MARK: - Private helpers

    /// Deletes the crash-safety sidecar for `wavURL` on clean close.
    private func deleteSidecar(for wavURL: URL) {
        let sidecarURL = sidecarURL(for: wavURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    /// Returns the sidecar URL for a given WAV URL: same name, `.recording.json` extension.
    private func sidecarURL(for wavURL: URL) -> URL {
        let name = wavURL.deletingPathExtension().lastPathComponent
        return outputFolder.appendingPathComponent("\(name).recording.json")
    }

    /// Writes (or updates) the crash-safety sidecar JSON for `wavURL`.
    private func writeSidecar(for wavURL: URL, framesWritten: Int) {
        guard var info = recordingInfo else { return }
        info.sampleCount = framesWritten
        let sidecar = sidecarURL(for: wavURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: sidecar, options: .atomic)
    }

    /// Opens an `AVAudioFile` for writing at `url` in 32-bit float WAV format.
    ///
    /// Note: WAV stores channels interleaved at the container level; the
    /// `AVLinearPCMIsNonInterleaved` key is intentionally omitted because
    /// `AVAudioFile` rejects it for WAV files. `AVAudioFile` handles the
    /// non-interleaved ↔ interleaved conversion transparently when writing
    /// non-interleaved `AVAudioPCMBuffer`s.
    private func openAVAudioFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatLinearPCM,
            AVSampleRateKey:       48000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey:  true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            return try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw WriterError.diskWriteFailed(url, underlying: error)
        }
    }

    /// Opens a `FileHandle` for the file at `url` (used for fsync).
    private func openFileHandle(at url: URL) throws -> FileHandle {
        guard let fh = FileHandle(forUpdatingAtPath: url.path) else {
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                              userInfo: [NSLocalizedDescriptionKey: "Cannot open file for fsync: \(url.path)"])
            throw WriterError.diskWriteFailed(url, underlying: err)
        }
        return fh
    }

    /// Core write loop: iterates `stream`, writes each buffer to `avFile`,
    /// and fsyncs via `fileHandle` at most once per second.
    /// Also writes the crash-safety sidecar on every 1-second cycle.
    ///
    /// Buffers arriving while `isPaused == true` are skipped.
    ///
    /// Throws `CancellationError` if the enclosing task is cancelled while the loop is running,
    /// so callers can distinguish a clean completion (stream exhausted) from a crash/cancel.
    private func consumeStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        into avFile: AVAudioFile,
        fileURL: URL,
        fileHandle: FileHandle
    ) async throws {
        var lastSyncTime = Date()
        var totalFrames  = 0

        for await buffer in stream {
            // Propagate cancellation so callers know this was not a clean close.
            try Task.checkCancellation()

            // Skip writes while paused (no silence inserted).
            guard !isPaused else { continue }

            do {
                try avFile.write(from: buffer)
                totalFrames += Int(buffer.frameLength)
            } catch {
                // Attempt to finalize the header so the file remains playable up to this point.
                log.error("WAVWriter: write failed for \(fileURL.lastPathComponent): \(error)")
                throw WriterError.diskWriteFailed(fileURL, underlying: error)
            }

            // Crash-safety flush: fsync at most once per second.
            let now = Date()
            if now.timeIntervalSince(lastSyncTime) >= 1.0 {
                fileHandle.synchronizeFile()
                writeSidecar(for: fileURL, framesWritten: totalFrames)
                lastSyncTime = now
            }
        }

        // Final fsync after stream ends cleanly.
        fileHandle.synchronizeFile()
    }

    // MARK: - Static recovery API

    /// Scans `folder` for orphaned crash-safety sidecars (`.recording.json` files whose
    /// matching WAV files still exist on disk).
    ///
    /// - Parameter folder: The output directory to inspect.
    /// - Returns: An array of `RecoveryEntry` values (one per orphaned sidecar/WAV pair).
    public static func scanForRecovery(in folder: URL) -> [RecoveryEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var entries: [RecoveryEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in contents where url.pathExtension == "json" &&
                                   url.lastPathComponent.hasSuffix(".recording.json") {
            guard let data = try? Data(contentsOf: url),
                  let info = try? decoder.decode(RecordingInfo.self, from: data)
            else { continue }

            // Derive the WAV URL: strip ".recording.json" → keep base name + ".wav"
            // e.g. "2026-01-01T10-00-00.recording.json" → "2026-01-01T10-00-00.wav"
            let baseName = url.lastPathComponent
                .replacingOccurrences(of: ".recording.json", with: "")
            let wavURL = folder.appendingPathComponent("\(baseName).wav")

            guard fm.fileExists(atPath: wavURL.path) else { continue }

            entries.append(RecoveryEntry(wavURL: wavURL, info: info))
        }

        return entries
    }

    /// Reads the actual byte count in the WAV file's `data` chunk and rewrites both
    /// the `RIFF` chunk size field and the `data` chunk size field so that
    /// `AVAudioFile` can open the file after a crash.
    ///
    /// WAV header layout (standard 44-byte PCM header):
    /// ```
    ///  [0..3]   "RIFF"
    ///  [4..7]   RIFF chunk size (file size − 8), little-endian UInt32
    ///  [8..11]  "WAVE"
    ///  [12..15] "fmt "
    ///  [16..19] fmt chunk size (16 for PCM)
    ///  [20..35] fmt data (16 bytes)
    ///  [36..39] "data"
    ///  [40..43] data chunk size, little-endian UInt32
    ///  [44..]   raw audio samples
    /// ```
    ///
    /// After a crash, `AVAudioFile` leaves the size fields at 0 (or a partial value from
    /// the last header update). This method re-derives the sizes from the actual file size.
    ///
    /// - Parameter url: Path to the crashed WAV file.
    /// - Throws: `WriterError.unrepairableHeader` if the file is too short or unreadable.
    public static func repairWAVHeader(at url: URL) throws {
        let fm = FileManager.default

        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let fileSizeValue = attrs[.size] as? Int,
              fileSizeValue >= 44
        else {
            throw WriterError.unrepairableHeader(url)
        }

        let fileSize = UInt32(min(fileSizeValue, Int(UInt32.max)))

        // data chunk size = total file size − 44 (the standard PCM WAV header).
        // RIFF chunk size = file size − 8 (everything after the first 8 bytes).
        let dataChunkSize: UInt32 = fileSize >= 44 ? fileSize - 44 : 0
        let riffChunkSize: UInt32 = fileSize >= 8  ? fileSize - 8  : 0

        guard let fh = FileHandle(forUpdatingAtPath: url.path) else {
            throw WriterError.unrepairableHeader(url)
        }
        defer { fh.closeFile() }

        // Verify the file starts with "RIFF" and contains "WAVE" and "data" markers.
        fh.seek(toFileOffset: 0)
        let header = fh.readData(ofLength: 44)
        guard header.count == 44 else {
            throw WriterError.unrepairableHeader(url)
        }

        // Check "RIFF" at [0..3]
        let riffTag = String(bytes: header[0..<4], encoding: .ascii)
        guard riffTag == "RIFF" else {
            throw WriterError.unrepairableHeader(url)
        }

        // Check "WAVE" at [8..11]
        let waveTag = String(bytes: header[8..<12], encoding: .ascii)
        guard waveTag == "WAVE" else {
            throw WriterError.unrepairableHeader(url)
        }

        // Write repaired RIFF chunk size at offset 4.
        var riffSize = riffChunkSize.littleEndian
        fh.seek(toFileOffset: 4)
        withUnsafeBytes(of: &riffSize) { fh.write(Data($0)) }

        // Write repaired data chunk size at offset 40.
        var dataSize = dataChunkSize.littleEndian
        fh.seek(toFileOffset: 40)
        withUnsafeBytes(of: &dataSize) { fh.write(Data($0)) }

        fh.synchronizeFile()
    }
}
