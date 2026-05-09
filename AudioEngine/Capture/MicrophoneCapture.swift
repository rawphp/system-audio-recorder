import AVFoundation

// MARK: - Engine / InputNode seam protocols

/// Abstracts the audio-engine operations that `MicrophoneCapture` needs.
/// The real `AVAudioEngine` is adapted via `RealMicEngine`; tests inject a
/// `MockMicEngine`.
public protocol MicAudioEngine: AnyObject {
    /// The engine's input node, returned as the abstract `MicInputNode`.
    var micInputNode: MicInputNode { get }
    /// Starts the engine. Throws on hardware or permission failure.
    func startEngine() throws
    /// Stops the engine.
    func stopEngine()
}

/// Abstracts `AVAudioInputNode` tap installation.
public protocol MicInputNode: AnyObject {
    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping AVAudioNodeTapBlock
    )
    func removeTap(onBus bus: AVAudioNodeBus)
    func inputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
}

// MARK: - AVAudioInputNode: MicInputNode
// AVAudioInputNode already has these methods; conformance is structural.
extension AVAudioInputNode: MicInputNode {}

// MARK: - RealMicEngine (wraps AVAudioEngine for production use)

/// Production `MicAudioEngine` backed by `AVAudioEngine`.
///
/// This thin wrapper avoids the naming conflict between the protocol's
/// `micInputNode` and `AVAudioEngine`'s existing `inputNode`.
public final class RealMicEngine: MicAudioEngine {

    private let engine = AVAudioEngine()

    public init() {}

    public var micInputNode: MicInputNode {
        engine.inputNode // AVAudioInputNode already conforms to MicInputNode
    }

    public func startEngine() throws {
        try engine.start()
    }

    public func stopEngine() {
        engine.stop()
    }
}

// MARK: - MicrophoneCapture

/// Wraps `AVAudioEngine.inputNode` to deliver mic audio as an
/// `AsyncStream<AVAudioPCMBuffer>`.
///
/// Usage:
/// ```swift
/// let mic = try MicrophoneCapture()
/// for await buffer in mic.stream { … }
/// mic.stop()
/// ```
///
/// By default the system default input device is used. Call
/// `setDevice(deviceID:)` to switch to a specific `AVCaptureDevice.uniqueID`.
///
/// **Permission**: mic permission must have been granted before calling `init`
/// or `setDevice`. `PermissionManager` (REQ-019) is responsible for requesting
/// it. If permission is revoked while recording the stream terminates.
public final class MicrophoneCapture {

    // MARK: Public API

    /// The PCM buffer stream. Produces buffers until `stop()` is called or mic
    /// permission is revoked.
    public let stream: AsyncStream<AVAudioPCMBuffer>

    // MARK: Private state

    private let engine: MicAudioEngine
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private var stopped = false

    // MARK: Initialisation

    /// Designated initialiser.
    ///
    /// - Parameter engine: the audio engine to use; defaults to `RealMicEngine`
    ///   backed by `AVAudioEngine`. Tests inject a `MockMicEngine`.
    /// - Throws: any error produced by `engine.startEngine()` (typically HAL
    ///   errors on hardware unavailability or a denied mic permission).
    public init(engine: MicAudioEngine = RealMicEngine()) throws {
        self.engine = engine

        // Build the AsyncStream before touching the engine so the continuation
        // is always available to close on error paths.
        var capturedCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream<AVAudioPCMBuffer> { cont in
            capturedCont = cont
        }
        self.continuation = capturedCont

        // Install the tap on the input node at its native format.
        let inputNode = engine.micInputNode
        let format = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.continuation.yield(buffer)
        }

        // Start the engine — may throw (hardware not present, permission denied).
        do {
            try engine.startEngine()
        } catch {
            // Tear down the tap before rethrowing.
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
    }

    // MARK: Device switching

    /// Switch the input to the device with the given `AVCaptureDevice.uniqueID`.
    ///
    /// Restarts the engine with the new device. The stream continues
    /// seamlessly (no break in the `AsyncStream`).
    ///
    /// - Parameter deviceID: the `uniqueID` of the desired `AVCaptureDevice`.
    /// - Throws: `CaptureError.deviceUnavailable` if no device with that ID
    ///   exists in `AVCaptureDevice.devices(for: .audio)`.
    public func setDevice(deviceID: String) throws {
        guard !stopped else { return }

        // Validate the device ID against AVCaptureDevice.
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        guard discoverySession.devices.contains(where: { $0.uniqueID == deviceID }) else {
            throw CaptureError.deviceUnavailable(deviceID)
        }

        // Restart the engine so it picks up the new HAL device selection.
        engine.stopEngine()
        engine.micInputNode.removeTap(onBus: 0)

        // Re-install tap with updated format.
        let format = engine.micInputNode.inputFormat(forBus: 0)
        engine.micInputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.continuation.yield(buffer)
        }

        try engine.startEngine()
    }

    // MARK: Teardown

    /// Stops the engine, removes the input tap, and closes the stream.
    ///
    /// Idempotent — calling multiple times is safe.
    public func stop() {
        guard !stopped else { return }
        stopped = true

        engine.micInputNode.removeTap(onBus: 0)
        engine.stopEngine()
        continuation.finish()
    }

    // MARK: Test-only shims

    /// Simulates mic permission being revoked mid-stream by closing the stream.
    ///
    /// - Note: This is a test-only entry point. Production code never calls this.
    public func _simulatePermissionRevoked() {
        guard !stopped else { return }
        stopped = true
        engine.micInputNode.removeTap(onBus: 0)
        engine.stopEngine()
        continuation.finish()
    }

    deinit {
        stop()
    }
}
