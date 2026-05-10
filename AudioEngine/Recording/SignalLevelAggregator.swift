import AVFoundation
import Foundation
import OSLog

// MARK: - SignalLogger

/// Test seam for `SignalLevelAggregator`. Production wraps `os.Logger`; tests
/// inject `CapturingSignalLogger` to assert on emitted lines.
public protocol SignalLogger: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
}

/// Production logger — funnels into the existing
/// `com.tomkaczocha.SystemAudioRecorder` subsystem under the chosen category.
public struct OSLogSignalLogger: SignalLogger {
    private let log: Logger

    public init(category: String = "RecordingSession") {
        self.log = Logger(
            subsystem: "com.tomkaczocha.SystemAudioRecorder",
            category: category
        )
    }

    public func debug(_ message: String) {
        log.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        log.info("\(message, privacy: .public)")
    }
}

/// Test logger — captures every emitted line so unit tests can assert on
/// the per-second summaries and silent_source / no_buffers escalations.
public final class CapturingSignalLogger: SignalLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _debugLines: [String] = []
    private var _infoLines: [String] = []

    public init() {}

    public func debug(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _debugLines.append(message)
    }

    public func info(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _infoLines.append(message)
    }

    public var debugLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _debugLines
    }

    public var infoLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _infoLines
    }
}

// MARK: - SignalLevelAggregator

/// Per-source diagnostic aggregator (REQ-046 / UR-004).
///
/// Tracks buffer count and RMS amplitude over rolling 1-second windows,
/// emits a `[REC] source=<id> bufs=<n> meanLvl=<dB>` debug line every
/// `tick(now:)`, and escalates to info-level when a source is silent
/// (sub-threshold mean amplitude) or starved (no buffers received).
///
/// Locking model: a single `NSLock` guards all mutable state. The audio-side
/// callers invoke `recordBuffer(_:at:)` once per buffer (off the audio render
/// thread); the timer-side caller invokes `tick(now:)` ~1 Hz. Both are
/// non-blocking and contention-free in practice.
public final class SignalLevelAggregator: @unchecked Sendable {

    public let id: String
    public let logger: SignalLogger
    public let silenceThresholdDBFS: Float
    public let silenceWindowSeconds: TimeInterval
    public let starvationWindowSeconds: TimeInterval

    private let lock = NSLock()
    private let sessionStart: Date

    // Counters reset each tick.
    private var bufferCount: Int = 0
    private var sumSquared: Double = 0
    private var sampleCount: Int = 0

    // Liveness state — persists across ticks.
    private var lastBufferTime: Date?
    private var silenceStreakSeconds: TimeInterval = 0
    private var silentFlagged: Bool = false
    private var starvedFlagged: Bool = false

    public init(
        id: String,
        logger: SignalLogger,
        sessionStart: Date,
        silenceThresholdDBFS: Float = -80,
        silenceWindowSeconds: TimeInterval = 3.0,
        starvationWindowSeconds: TimeInterval = 3.0
    ) {
        self.id = id
        self.logger = logger
        self.sessionStart = sessionStart
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceWindowSeconds = silenceWindowSeconds
        self.starvationWindowSeconds = starvationWindowSeconds
    }

    /// Record a normalised PCM buffer for accounting. Safe to call from any
    /// thread; locks for the duration of the sample-sum accumulation.
    public func recordBuffer(_ buffer: AVAudioPCMBuffer, at time: Date) {
        guard buffer.frameLength > 0 else { return }

        lock.lock(); defer { lock.unlock() }
        bufferCount += 1
        lastBufferTime = time
        // A buffer arrived — clear starvation flag so a future starvation
        // re-emits its own info-level entry.
        starvedFlagged = false

        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            let p = channelData[c]
            for f in 0..<frames {
                let s = Double(p[f])
                sumSquared += s * s
                sampleCount += 1
            }
        }
    }

    /// Periodic tick — called once per wall-clock second by the production
    /// timer task, or directly by tests with synthetic timestamps.
    /// Emits the rolling summary plus any silent_source / no_buffers escalations.
    public func tick(now: Date) {
        lock.lock()
        let bufs = bufferCount
        let mean = computeMeanDBFS_locked()
        let lastBuf = lastBufferTime
        bufferCount = 0
        sumSquared = 0
        sampleCount = 0
        lock.unlock()

        // Format the mean as either a one-decimal dB value or the literal
        // "-inf" when no non-zero samples were observed in the interval.
        let meanString = mean.isFinite ? String(format: "%.1f", mean) : "-inf"
        logger.debug("[REC] source=\(id) bufs=\(bufs) meanLvl=\(meanString)")

        // silent_source detection: rolling silence streak ≥ silenceWindowSeconds
        // while the session has been live for at least the same window.
        let elapsedSession = now.timeIntervalSince(sessionStart)
        if bufs > 0, mean < Double(silenceThresholdDBFS) {
            // This tick was silent — extend the streak by ~1 s (the tick cadence).
            lock.lock()
            silenceStreakSeconds += 1.0
            let streak = silenceStreakSeconds
            let alreadyFlagged = silentFlagged
            lock.unlock()

            if elapsedSession >= silenceWindowSeconds,
               streak >= silenceWindowSeconds,
               !alreadyFlagged
            {
                logger.info("[REC] silent_source id=\(id)")
                lock.lock(); silentFlagged = true; lock.unlock()
            }
        } else if bufs > 0 {
            // Audible buffers — reset streak + flag so a new silent run will
            // re-escalate.
            lock.lock()
            silenceStreakSeconds = 0
            silentFlagged = false
            lock.unlock()
        }

        // no_buffers detection: window of starvationWindowSeconds with no
        // recorded buffers. Compares either against the last-buffer time or,
        // if none ever arrived, against session start.
        let referenceTime = lastBuf ?? sessionStart
        let elapsedSinceBuffer = now.timeIntervalSince(referenceTime)
        if bufs == 0,
           elapsedSinceBuffer >= starvationWindowSeconds
        {
            lock.lock()
            let alreadyFlagged = starvedFlagged
            if !alreadyFlagged { starvedFlagged = true }
            lock.unlock()

            if !alreadyFlagged {
                logger.info("[REC] no_buffers id=\(id)")
            }
        }
    }

    // MARK: - Helpers (caller-locked)

    private func computeMeanDBFS_locked() -> Double {
        guard sampleCount > 0 else { return -.infinity }
        let meanSq = sumSquared / Double(sampleCount)
        guard meanSq > 0 else { return -.infinity }
        let rms = sqrt(meanSq)
        return 20.0 * log10(rms)
    }
}
