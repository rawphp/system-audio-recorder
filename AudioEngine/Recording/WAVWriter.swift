import AVFoundation
import os.log

// MARK: - WriterError

/// Errors surfaced by `WAVWriter`.
public enum WriterError: Error {
    /// A disk write failed. The associated URL is the file being written.
    /// The `underlying` error carries the lower-level OS or AVFoundation error.
    case diskWriteFailed(URL, underlying: Error)
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
/// ensure OS-buffered bytes reach disk. The `AVAudioFile` is kept alive for the entire
/// session so the RIFF header is updated only on `close()`.
///
/// **Pause / resume**
/// Calling `pause()` stops the consumption loop from writing further buffers without
/// closing the file. `resume()` restarts consumption. The resulting file duration
/// equals the sum of all active-recording time; no silence is inserted for the gap.
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
    private let log = Logger(
        subsystem: "com.tomkaczocha.SystemAudioRecorder",
        category: "WAVWriter"
    )

    /// Pause flag — when `true`, incoming buffers are dropped instead of written.
    private var isPaused = false

    // MARK: - Init

    /// - Parameters:
    ///   - outputFolder: The directory in which WAV files will be created.
    ///   - timestamp:    A caller-supplied base string used in file names (e.g. `"2026-01-01T00-00-00"`).
    public init(outputFolder: URL, timestamp: String) {
        self.outputFolder = outputFolder
        self.timestamp = timestamp
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

        return entries.map(\.url)
    }

    // MARK: - Private helpers

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
    ///
    /// Buffers arriving while `isPaused == true` are skipped.
    private func consumeStream(
        _ stream: AsyncStream<AVAudioPCMBuffer>,
        into avFile: AVAudioFile,
        fileURL: URL,
        fileHandle: FileHandle
    ) async throws {
        var lastSyncTime = Date()

        for await buffer in stream {
            // Skip writes while paused (no silence inserted).
            guard !isPaused else { continue }

            do {
                try avFile.write(from: buffer)
            } catch {
                // Attempt to finalize the header so the file remains playable up to this point.
                log.error("WAVWriter: write failed for \(fileURL.lastPathComponent): \(error)")
                throw WriterError.diskWriteFailed(fileURL, underlying: error)
            }

            // Crash-safety flush: fsync at most once per second.
            let now = Date()
            if now.timeIntervalSince(lastSyncTime) >= 1.0 {
                fileHandle.synchronizeFile()
                lastSyncTime = now
            }
        }

        // Final fsync after stream ends.
        fileHandle.synchronizeFile()
    }
}
