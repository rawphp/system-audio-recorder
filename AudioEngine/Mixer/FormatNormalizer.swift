import AVFoundation

// MARK: - NormalizerError

/// Errors thrown by `FormatNormalizer`.
public enum NormalizerError: Error {
    /// The input format cannot be converted to the canonical format.
    /// The normalizer emits no buffers for this source until a compatible
    /// format arrives.
    case unsupportedInputFormat(AVAudioFormat)
}

// MARK: - FormatNormalizer

/// Converts `AVAudioPCMBuffer`s at any sample rate / channel count to the
/// canonical format: **48 kHz, Float32, stereo, non-interleaved**.
///
/// Uses `AVAudioConverter` internally. If the input format changes mid-stream,
/// the converter is recreated automatically; at most one buffer worth of audio
/// (~10 ms) is dropped at the transition.
///
/// Usage:
/// ```swift
/// let normalizer = FormatNormalizer()
/// for rawBuffer in source {
///     let canonical = try normalizer.normalize(rawBuffer)
///     // canonical is [AVAudioPCMBuffer] at 48 kHz Float32 stereo
/// }
/// ```
///
/// Thread-safety: `FormatNormalizer` is **not** thread-safe. Call from a
/// single dedicated audio thread.
public final class FormatNormalizer {

    // MARK: Canonical output format

    /// The single canonical format all sources are converted to before mixing.
    public static let canonicalFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            fatalError("FormatNormalizer: failed to create canonical 48 kHz Float32 stereo format")
        }
        return fmt
    }()

    // MARK: Private state

    /// The active converter. Nil if no input has been seen yet.
    private var converter: AVAudioConverter?

    /// The input format the current converter was created for.
    private var currentInputFormat: AVAudioFormat?

    /// Test seam: if non-nil, the next call to `normalize()` throws this error
    /// and clears the value (one-shot).
    public var _injectNextConverterError: Error?

    // MARK: Initialisation

    public init() {}

    // MARK: normalize(_:)

    /// Converts `inputBuffer` to the canonical format.
    ///
    /// - Parameter inputBuffer: a PCM buffer at any supported sample rate and
    ///   channel count.
    /// - Returns: an array of canonical `AVAudioPCMBuffer`s. Normally one
    ///   element; may be empty if the converter is still priming after a
    ///   format change; may contain multiple elements for very large inputs.
    /// - Throws: `NormalizerError.unsupportedInputFormat` when
    ///   `AVAudioConverter` cannot be initialised for the input format.
    public func normalize(_ inputBuffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {

        // --- Test seam: injected error ---
        if let injected = _injectNextConverterError {
            _injectNextConverterError = nil
            // Also tear down the cached converter so the next valid call
            // recreates it cleanly.
            converter = nil
            currentInputFormat = nil
            throw injected
        }

        let inputFormat = inputBuffer.format

        // --- Pass-through: input is already canonical ---
        if inputFormat == FormatNormalizer.canonicalFormat {
            return [inputBuffer]
        }

        // --- Recreate converter when input format changes ---
        if converter == nil || currentInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(
                from: inputFormat,
                to: FormatNormalizer.canonicalFormat
            ) else {
                // Tear down stale state so the next call can retry a fresh format.
                converter = nil
                currentInputFormat = nil
                throw NormalizerError.unsupportedInputFormat(inputFormat)
            }
            converter = newConverter
            currentInputFormat = inputFormat
        }

        guard let conv = converter else {
            throw NormalizerError.unsupportedInputFormat(inputFormat)
        }

        return try convertBuffer(inputBuffer, using: conv)
    }

    // MARK: normalizerErrorForTesting()

    /// Returns the injected error if present, or nil. Used by tests to verify
    /// the error-injection seam without consuming it.
    public func normalizerErrorForTesting() -> Error? {
        return _injectNextConverterError
    }

    // MARK: Private conversion

    /// Performs the actual `AVAudioConverter` conversion.
    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using conv: AVAudioConverter
    ) throws -> [AVAudioPCMBuffer] {

        let inputFormat = inputBuffer.format
        let outputFormat = FormatNormalizer.canonicalFormat

        // Calculate output frame capacity based on sample-rate ratio.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio) + 1
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw NormalizerError.unsupportedInputFormat(inputFormat)
        }

        // `AVAudioConverter` uses a provider block that supplies input buffers.
        var inputConsumed = false

        var convError: NSError?
        let status = conv.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let err = convError {
            // Recreate converter on next call so we don't get stuck.
            converter = nil
            currentInputFormat = nil
            throw err
        }

        switch status {
        case .error:
            converter = nil
            currentInputFormat = nil
            throw NormalizerError.unsupportedInputFormat(inputFormat)
        case .haveData, .inputRanDry, .endOfStream:
            break
        @unknown default:
            break
        }

        if outputBuffer.frameLength == 0 {
            // Converter is still priming — return empty; next call will produce output.
            return []
        }

        return [outputBuffer]
    }
}

// MARK: - AVAudioFormat Equality

// `AVAudioFormat` conforms to `Equatable` in its Objective-C implementation
// via `isEqual:`, which checks all format fields. The `==` operator on
// `AVAudioFormat` uses this, so direct comparison is correct.
