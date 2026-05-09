import AVFoundation
import Accelerate

// MARK: - MeterTap
//
// Stateless helper that computes a single dBFS RMS value from an
// `AVAudioPCMBuffer`.  Designed to be called from the audio thread inside an
// `installTap(onBus:)` callback.
//
// **No allocation** — all arithmetic is in-register or on the stack via vDSP.
// **No locking** — pure stateless function on immutable buffer data.

public enum MeterTap {

    // MARK: - dBFS floor

    /// Minimum representable level (-160 dBFS).
    public static let silenceDBFS: Float = -160.0

    // MARK: - computeRMS

    /// Computes the windowed RMS of `buffer` across all channels, averaged,
    /// and converts it to dBFS.
    ///
    /// Returns `silenceDBFS` when the buffer is silent or empty.
    ///
    /// - Parameter buffer: A canonical (48 kHz Float32 stereo) or any
    ///   `AVAudioPCMBuffer` whose `floatChannelData` is non-nil.
    /// - Returns: RMS level in dBFS.
    public static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0,
              let channelData = buffer.floatChannelData else {
            return silenceDBFS
        }

        var sumRMS: Float = 0.0

        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            var meanSquare: Float = 0.0
            // vDSP_measqv computes the mean of the squared samples.
            vDSP_measqv(ptr, 1, &meanSquare, vDSP_Length(frameCount))
            sumRMS += sqrt(meanSquare)
        }

        let rms = sumRMS / Float(channelCount)

        guard rms > 0 else { return silenceDBFS }
        let dbfs = 20.0 * log10(rms)
        return max(silenceDBFS, dbfs)
    }
}
