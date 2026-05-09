import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - Public API

/// Errors thrown by the capture pipeline.
public enum CaptureError: Error, Equatable {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case audioUnitFailed(OSStatus)
    case processTerminated(pid_t)
    case permissionRevoked
    case pidTranslationFailed(pid_t)
}

/// Public surface contract: per-pid `AsyncStream` of PCM buffers + a `stop()`.
public protocol AudioBufferEmitter: AnyObject {
    var streams: [pid_t: AsyncStream<AVAudioPCMBuffer>] { get }
    func stop()
}

// MARK: - Per-PID Emitter Protocol (mockable seam)

/// One emitter handles one pid. The factory creates these so tests can inject
/// a deterministic synthetic source instead of the real Core Audio Tap path.
public protocol PerProcessEmitter: AnyObject {
    var pid: pid_t { get }
    var stream: AsyncStream<AVAudioPCMBuffer> { get }
    /// Forwards a termination error and closes the continuation.
    func terminate(with error: CaptureError)
    /// Tear down audio resources. Idempotent.
    func teardown()
}

/// Factory that produces a `PerProcessEmitter` for a given pid.
/// `RealEmitterFactory` is the default; tests inject a mock.
public protocol PerProcessEmitterFactory {
    func makeEmitter(for pid: pid_t) throws -> PerProcessEmitter
}

// MARK: - ProcessTapCapture

/// Wires Core Audio Process Taps to per-pid `AsyncStream<AVAudioPCMBuffer>`.
///
/// Default behavior (production) uses `RealEmitterFactory`, which builds a
/// `CATapDescription` → process tap → private aggregate device → AUHAL chain
/// for each pid.
///
/// Tests inject a custom `PerProcessEmitterFactory` to bypass Core Audio.
public final class ProcessTapCapture: AudioBufferEmitter {

    public private(set) var streams: [pid_t: AsyncStream<AVAudioPCMBuffer>] = [:]

    private var emitters: [pid_t: PerProcessEmitter] = [:]
    private let factory: PerProcessEmitterFactory
    private var alivenessTimer: DispatchSourceTimer?
    private let alivenessQueue = DispatchQueue(label: "com.tomkaczocha.ProcessTapCapture.aliveness")
    private let alivenessCheck: (pid_t) -> Bool
    private var stopped = false

    /// Designated init.
    /// - Parameters:
    ///   - pids: PIDs to tap.
    ///   - factory: Emitter factory; defaults to real Core Audio path.
    ///   - alivenessCheck: Predicate that returns `true` if a pid is still alive.
    ///                     Defaults to `kill(pid, 0) == 0`.
    public init(
        pids: [pid_t],
        factory: PerProcessEmitterFactory = RealEmitterFactory(),
        alivenessCheck: @escaping (pid_t) -> Bool = ProcessTapCapture.defaultAlivenessCheck
    ) throws {
        self.factory = factory
        self.alivenessCheck = alivenessCheck

        for pid in pids {
            let emitter = try factory.makeEmitter(for: pid)
            emitters[pid] = emitter
            streams[pid] = emitter.stream
        }

        startAlivenessPolling()
    }

    deinit {
        stop()
    }

    // MARK: Aliveness polling

    /// 1 Hz timer that fires `processTerminated` for any pid whose process has
    /// died, while leaving sibling streams open.
    private func startAlivenessPolling() {
        let timer = DispatchSource.makeTimerSource(queue: alivenessQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkAliveness()
        }
        timer.resume()
        alivenessTimer = timer
    }

    private func checkAliveness() {
        let snapshot = emitters
        for (pid, emitter) in snapshot {
            if !alivenessCheck(pid) {
                emitter.terminate(with: .processTerminated(pid))
                emitter.teardown()
                emitters.removeValue(forKey: pid)
                streams.removeValue(forKey: pid)
            }
        }
    }

    /// Default aliveness check: signal 0 to the pid. Returns true if process exists.
    public static func defaultAlivenessCheck(_ pid: pid_t) -> Bool {
        // kill(pid, 0): doesn't send a signal but performs error checking.
        // Returns 0 if process exists & we have permission to signal it.
        kill(pid, 0) == 0
    }

    // MARK: Teardown

    /// Tears down every emitter (audio unit, aggregate device, tap) in reverse
    /// order, cancels the aliveness timer, and clears the stream map.
    public func stop() {
        guard !stopped else { return }
        stopped = true

        alivenessTimer?.cancel()
        alivenessTimer = nil

        // Tear down in insertion-reverse order to mirror construction order.
        for (pid, emitter) in emitters.reversed() {
            emitter.teardown()
            streams.removeValue(forKey: pid)
        }
        emitters.removeAll()
    }
}

// MARK: - Real Emitter (Core Audio Tap → Aggregate Device → AUHAL)

/// Builds the real Core Audio capture chain.
public final class RealEmitterFactory: PerProcessEmitterFactory {
    public init() {}

    public func makeEmitter(for pid: pid_t) throws -> PerProcessEmitter {
        try RealProcessTapEmitter(pid: pid)
    }
}

/// Heap-allocated context handed to the C render callback as a void*.
/// Stores the unit handle (set after AudioComponentInstanceNew) so the
/// callback can call `AudioUnitRender`, plus the `AsyncStream` continuation
/// it yields buffers into.
final class RenderContext {
    let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let format: AVAudioFormat
    var unit: AudioUnit?

    init(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        format: AVAudioFormat
    ) {
        self.continuation = continuation
        self.format = format
    }
}

/// Real Core Audio Tap implementation. Owns one tap, one aggregate device,
/// and one AUHAL audio unit per pid.
///
/// The render callback runs on the audio thread and yields `AVAudioPCMBuffer`s
/// into the `AsyncStream` continuation. Buffers are non-interleaved Float32
/// at the device's native sample rate.
final class RealProcessTapEmitter: PerProcessEmitter {

    let pid: pid_t
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var audioUnit: AudioUnit?
    private var renderContext: RenderContext?
    private var renderContextRetained: Unmanaged<RenderContext>?
    private var torndown = false

    init(pid: pid_t) throws {
        self.pid = pid

        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream<AVAudioPCMBuffer> { cont in
            continuation = cont
        }
        self.continuation = continuation

        // 1. Translate pid → AudioObjectID
        let processObjectID = try Self.translatePIDToAudioObjectID(pid)

        // 2. Build a CATapDescription (stereo mix, unmuted)
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.muteBehavior = .unmuted
        description.name = "SystemAudioToMP3.Tap.\(pid)"

        // 3. Create the process tap
        var tap: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            continuation.finish()
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        self.tapID = tap

        // 4. Get the tap's UID (needed for aggregate device sub-tap list)
        let tapUID: String
        do {
            tapUID = try Self.tapUID(for: tap)
        } catch {
            continuation.finish()
            _ = AudioHardwareDestroyProcessTap(tap)
            self.tapID = kAudioObjectUnknown
            throw error
        }

        // 5. Create a private aggregate device with the tap as a sub-device
        let aggregateUID = "com.tomkaczocha.SystemAudioToMP3.Aggregate.\(pid).\(UUID().uuidString)"
        let aggregateName = "SystemAudioToMP3.Aggregate.\(pid)"

        let subTapDict: [String: Any] = [
            "uid": tapUID,
            kAudioSubTapDriftCompensationKey: 0
        ]

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [subTapDict]
        ]

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard aggStatus == noErr else {
            continuation.finish()
            _ = AudioHardwareDestroyProcessTap(tap)
            self.tapID = kAudioObjectUnknown
            throw CaptureError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggregateDeviceID = aggregateID

        // 6. Create an AUHAL output unit and bind it to the aggregate device
        do {
            let (unit, context, retained) = try Self.createAUHAL(
                deviceID: aggregateID,
                continuation: continuation
            )
            self.audioUnit = unit
            self.renderContext = context
            self.renderContextRetained = retained
        } catch {
            continuation.finish()
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            self.aggregateDeviceID = kAudioObjectUnknown
            _ = AudioHardwareDestroyProcessTap(tap)
            self.tapID = kAudioObjectUnknown
            throw error
        }
    }

    // MARK: PerProcessEmitter

    func terminate(with error: CaptureError) {
        continuation.finish()
    }

    func teardown() {
        guard !torndown else { return }
        torndown = true

        if let unit = audioUnit {
            _ = AudioOutputUnitStop(unit)
            _ = AudioUnitUninitialize(unit)
            _ = AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        // Release the retained render context AFTER the unit is fully disposed
        // — guarantees the audio thread can no longer call into it.
        renderContextRetained?.release()
        renderContextRetained = nil
        renderContext = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        continuation.finish()
    }

    // MARK: Helpers

    private static func translatePIDToAudioObjectID(_ pid: pid_t) throws -> AudioObjectID {
        var pidVar: pid_t = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var processObjectID: AudioObjectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &pidVar) { qualifierPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                qualifierPtr,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw CaptureError.pidTranslationFailed(pid)
        }
        return processObjectID
    }

    private static func tapUID(for tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &uid)
        guard status == noErr, let uid = uid?.takeRetainedValue() else {
            throw CaptureError.tapCreationFailed(status)
        }
        return uid as String
    }

    /// Creates an AUHAL output unit configured for input from the aggregate
    /// device, sets its render callback, and starts it.
    /// Returns the unit, its render context, and the unmanaged retain to
    /// the context (callers MUST release this in teardown).
    private static func createAUHAL(
        deviceID: AudioObjectID,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) throws -> (AudioUnit, RenderContext, Unmanaged<RenderContext>) {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw CaptureError.audioUnitFailed(-1)
        }

        var unitOpt: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unitOpt)
        guard status == noErr, let unit = unitOpt else {
            throw CaptureError.audioUnitFailed(status)
        }

        // Enable input, disable output
        var enable: UInt32 = 1
        var disable: UInt32 = 0

        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        // Bind to the aggregate device
        var deviceID = deviceID
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        // Inherit the device's native sample rate
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1,
            &deviceFormat, &formatSize
        )
        let sampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000

        // Float32 non-interleaved stereo at the device's sample rate
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1,
            &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(-1)
        }

        let context = RenderContext(continuation: continuation, format: pcmFormat)
        context.unit = unit
        let retained = Unmanaged.passRetained(context)

        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: retained.toOpaque()
        )

        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0,
            &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            retained.release()
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            retained.release()
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            retained.release()
            AudioComponentInstanceDispose(unit)
            throw CaptureError.audioUnitFailed(status)
        }

        return (unit, context, retained)
    }
}

// MARK: - C render callback

/// C-compatible render callback. Runs on the audio thread.
///
/// `AsyncStream.Continuation.yield` is wait-free, so the audio thread does not
/// block. We allocate one `AVAudioPCMBuffer` per call — small, fast, and the
/// simplest correct approach. If profiling later shows priority inversion,
/// swap to a TPCircularBuffer-backed pool.
private let renderCallback: AURenderCallback = {
    inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ -> OSStatus in

    let context = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = context.unit else { return noErr }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: context.format, frameCapacity: inNumberFrames) else {
        return noErr
    }
    buffer.frameLength = inNumberFrames

    let status = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        buffer.mutableAudioBufferList
    )

    if status == noErr {
        context.continuation.yield(buffer)
    }

    return noErr
}
