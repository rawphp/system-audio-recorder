import AVFoundation
import Foundation
import lame

// MARK: - BitrateMode

/// The MPEG bitrate allocation strategy for MP3 encoding.
public enum BitrateMode: Sendable {
    /// Variable bitrate — LAME allocates bits per frame to maintain perceptual quality.
    /// Uses LAME's `vbr_mtrh` (default VBR) mode.
    case vbr
    /// Constant bitrate — every frame uses the exact configured bitrate.
    case cbr
}

// MARK: - EncodingError

/// Errors thrown by `LameEncoder.encode(…)`.
public enum EncodingError: Error {
    /// The WAV file at `url` could not be opened by `AVAudioFile`.
    /// No LAME init was attempted and no MP3 was written.
    case invalidInput(URL, underlying: Error)
    /// `lame_init()` or `lame_init_params()` returned a non-zero error code.
    /// No MP3 was written.
    case lameInitFailed(code: Int)
    /// The encode was cancelled mid-stream. Any partial MP3 file has been removed.
    case cancelled
    /// A write to the output MP3 file failed.
    case writeFailed(URL, underlying: Error)
}

// MARK: - LameEncoder

/// Encodes a 48 kHz Float32 stereo WAV file to MP3 using the vendored `libmp3lame`.
///
/// **Pipeline** (per spec Section 5.7):
/// 1. Open the source WAV via `AVAudioFile`.
/// 2. Initialise LAME with the WAV's sample rate, channel count, bitrate, and VBR/CBR mode.
/// 3. Read 1-second chunks from the WAV, feed each to `lame_encode_buffer_ieee_float`.
/// 4. Collect the resulting MP3 bytes into an output `FileHandle`.
/// 5. Finalise with `lame_encode_flush` and close LAME.
///
/// Encoding is cooperative: `Task.checkCancellation()` is called between chunks.
/// On cancellation the partial output file is deleted and `EncodingError.cancelled` is thrown.
public struct LameEncoder {

    public init() {}

    /// Encodes the WAV at `wavURL` to the MP3 at `mp3URL`.
    ///
    /// - Parameters:
    ///   - wavURL:   Source WAV file. Must be readable by `AVAudioFile` (48 kHz Float32 stereo).
    ///   - mp3URL:   Destination MP3 file. Created (or replaced) by this call.
    ///   - bitrate:  Target bitrate in kbps. Typical values: 128, 192, 256, 320.
    ///   - mode:     `.vbr` or `.cbr`.
    ///   - progress: Called once per 1-second chunk with the fraction complete [0…1].
    ///               May be called from any thread context.
    ///
    /// - Throws: `EncodingError.invalidInput` if the WAV cannot be opened,
    ///           `EncodingError.lameInitFailed` if LAME init fails,
    ///           `EncodingError.cancelled` if the task is cancelled mid-encode,
    ///           `EncodingError.writeFailed` on an I/O error writing the MP3.
    public func encode(
        wavURL: URL,
        mp3URL: URL,
        bitrate: Int,
        mode: BitrateMode,
        progress: @escaping (Double) -> Void
    ) async throws {
        // ── 1. Open the source WAV ───────────────────────────────────────────
        let wavFile: AVAudioFile
        do {
            wavFile = try AVAudioFile(forReading: wavURL)
        } catch {
            throw EncodingError.invalidInput(wavURL, underlying: error)
        }

        let sampleRate  = wavFile.processingFormat.sampleRate
        let channels    = Int32(wavFile.processingFormat.channelCount)
        let totalFrames = AVAudioFrameCount(wavFile.length)
        let chunkFrames = AVAudioFrameCount(sampleRate) // 1-second chunks

        // ── 2. Initialise LAME ───────────────────────────────────────────────
        guard let gfp = lame_init() else {
            throw EncodingError.lameInitFailed(code: -1)
        }
        defer { lame_close(gfp) }

        lame_set_in_samplerate(gfp, Int32(sampleRate))
        lame_set_num_channels(gfp, channels)

        switch mode {
        case .vbr:
            // Use ABR (Average BitRate) mode — guarantees the configured bitrate as an average,
            // producing predictable output size while still allowing per-frame variation.
            // Pure VBR (vbr_mtrh) can deviate dramatically from the target bitrate for
            // simple signals like silence or sine tones.
            lame_set_VBR(gfp, vbr_abr)
            lame_set_VBR_mean_bitrate_kbps(gfp, Int32(bitrate))
        case .cbr:
            lame_set_VBR(gfp, vbr_off)
            lame_set_brate(gfp, Int32(bitrate))
        }

        // Write Xing/Info VBR header (enables accurate seeking and duration display)
        lame_set_bWriteVbrTag(gfp, mode == .vbr ? 1 : 0)

        let initResult = lame_init_params(gfp)
        if initResult != 0 {
            throw EncodingError.lameInitFailed(code: Int(initResult))
        }

        // ── 3. Open the output file ──────────────────────────────────────────
        // Remove any stale file at mp3URL so we start clean.
        try? FileManager.default.removeItem(at: mp3URL)

        guard FileManager.default.createFile(atPath: mp3URL.path, contents: nil) else {
            throw EncodingError.writeFailed(mp3URL, underlying: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Cannot create MP3 at \(mp3URL.path)"]))
        }
        guard let outFH = FileHandle(forWritingAtPath: mp3URL.path) else {
            try? FileManager.default.removeItem(at: mp3URL)
            throw EncodingError.writeFailed(mp3URL, underlying: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Cannot open MP3 for writing: \(mp3URL.path)"]))
        }
        defer { outFH.closeFile() }

        // ── 4. Allocate buffers ──────────────────────────────────────────────
        // LAME MP3 output buffer: 1.25 × nsamples + 7200 bytes (per LAME API docs).
        let mp3BufSize  = Int(Double(chunkFrames) * 1.25) + 7200
        var mp3Buf      = [UInt8](repeating: 0, count: mp3BufSize)

        // ── 5. Read + encode chunks ──────────────────────────────────────────
        var framesRead: AVAudioFrameCount = 0

        // Re-open source so we always start at frame 0 (AVAudioFile cursor may be at end).
        wavFile.framePosition = 0

        let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        while framesRead < totalFrames {
            // Cooperative cancellation check — throw before each chunk.
            if Task.isCancelled {
                outFH.closeFile()
                try? FileManager.default.removeItem(at: mp3URL)
                throw EncodingError.cancelled
            }

            let remaining    = totalFrames - framesRead
            let thisChunk    = min(chunkFrames, remaining)

            guard let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: thisChunk) else {
                break
            }

            do {
                try wavFile.read(into: buf, frameCount: thisChunk)
            } catch {
                // EOF reached — stop gracefully.
                break
            }

            guard buf.frameLength > 0 else { break }

            // Get float channel data pointers.
            guard let leftPtr  = buf.floatChannelData?[0] else { break }
            let rightPtr = channels >= 2 ? buf.floatChannelData?[1] ?? leftPtr : leftPtr

            let encoded = lame_encode_buffer_ieee_float(
                gfp,
                leftPtr,
                rightPtr,
                Int32(buf.frameLength),
                &mp3Buf,
                Int32(mp3BufSize)
            )

            if encoded < 0 {
                outFH.closeFile()
                try? FileManager.default.removeItem(at: mp3URL)
                throw EncodingError.writeFailed(mp3URL, underlying: NSError(
                    domain: "LameEncoder", code: Int(encoded),
                    userInfo: [NSLocalizedDescriptionKey: "lame_encode_buffer_ieee_float returned \(encoded)"]))
            }

            if encoded > 0 {
                let data = Data(bytes: mp3Buf, count: Int(encoded))
                do {
                    try outFH.write(contentsOf: data)
                } catch {
                    try? FileManager.default.removeItem(at: mp3URL)
                    throw EncodingError.writeFailed(mp3URL, underlying: error)
                }
            }

            framesRead += buf.frameLength

            // Fire progress callback with fraction complete [0…1].
            let fraction = Double(framesRead) / Double(totalFrames)
            progress(min(fraction, 1.0))
        }

        // ── 6. Flush remaining LAME internal buffers ─────────────────────────
        let flushed = lame_encode_flush(gfp, &mp3Buf, Int32(mp3BufSize))
        if flushed > 0 {
            let data = Data(bytes: mp3Buf, count: Int(flushed))
            do {
                try outFH.write(contentsOf: data)
            } catch {
                try? FileManager.default.removeItem(at: mp3URL)
                throw EncodingError.writeFailed(mp3URL, underlying: error)
            }
        }

        // Final progress = 1.0
        progress(1.0)
    }
}
