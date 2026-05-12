import Foundation
import Observation

// MARK: - EncodingJob

/// A single WAV → MP3 encoding job submitted to `EncodingQueue`.
public struct EncodingJob: Identifiable, Sendable {
    public let id: UUID
    public let wavURL: URL
    public let mp3URL: URL
    public let bitrate: Int
    public let mode: BitrateMode

    /// Encoding progress [0…1]. Updated on the main actor while the job is running.
    public internal(set) var progress: Double = 0.0

    /// The error that caused this job to fail, if any.
    public internal(set) var error: Error?

    public init(
        id: UUID = UUID(),
        wavURL: URL,
        mp3URL: URL,
        bitrate: Int,
        mode: BitrateMode
    ) {
        self.id = id
        self.wavURL = wavURL
        self.mp3URL = mp3URL
        self.bitrate = bitrate
        self.mode = mode
    }
}

// MARK: - EncodingQueue

/// Background OperationQueue that drains `EncodingJob`s (WAV → MP3) with at most 2 concurrent
/// jobs. All observable state (`pending`, `running`, `completed`, `failed`,
/// `recentlyCompletedJob`) is updated on the main actor so SwiftUI `@Observable` bindings work.
///
/// Usage:
/// ```swift
/// let queue = EncodingQueue()
/// await queue.enqueue(job: job, keepWAV: false)
/// ```
@Observable
@MainActor
public final class EncodingQueue {

    // MARK: - Observable state

    /// Jobs waiting to start.
    public private(set) var pending: [EncodingJob] = []
    /// Jobs currently encoding.
    public private(set) var running: [EncodingJob] = []
    /// Successfully encoded jobs.
    public private(set) var completed: [EncodingJob] = []
    /// Jobs that failed to encode.
    public private(set) var failed: [EncodingJob] = []
    /// Set to the most-recently completed job when one finishes (REQ-027 hook).
    public var recentlyCompletedJob: EncodingJob?

    // MARK: - Private internals

    private let maxConcurrentJobs = 2

    /// Tracks cancellable tasks for each running job so we can cancel by id.
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    /// Keep-WAV preference for jobs that are still pending.
    private var pendingKeepWAV: [UUID: Bool] = [:]
    /// Job IDs cancelled by `cancelAll`; terminal callbacks from those tasks are ignored.
    private var cancelledJobIDs: Set<UUID> = []

    public init() {}

    #if DEBUG
    internal var cancelledJobIDCountForTesting: Int {
        cancelledJobIDs.count
    }
    #endif

    // MARK: - Public API

    /// Appends `job` to the queue and returns immediately (< 5 ms).
    ///
    /// - Parameters:
    ///   - job:     The job to encode.
    ///   - keepWAV: When `false`, the source WAV is deleted after a successful encode.
    ///              On failure the WAV is always preserved regardless of this value.
    public func enqueue(job: EncodingJob, keepWAV: Bool) async {
        cancelledJobIDs.remove(job.id)
        pending.append(job)
        pendingKeepWAV[job.id] = keepWAV
        drainQueue()
    }

    /// Cancels all pending and running jobs; removes any partial MP3 files.
    public func cancelAll() async {
        // Only running jobs can emit terminal callbacks after cancellation.
        cancelledJobIDs.formUnion(running.map(\.id))
        for task in runningTasks.values {
            task.cancel()
        }
        runningTasks.removeAll()
        pendingKeepWAV.removeAll()

        // Remove partial MP3s for jobs that were pending (never started)
        for job in pending {
            try? FileManager.default.removeItem(at: job.mp3URL)
        }
        // Remove partial MP3s for jobs that were in the running list
        for job in running {
            try? FileManager.default.removeItem(at: job.mp3URL)
        }

        pending.removeAll()
        running.removeAll()
    }

    // MARK: - Private

    private func drainQueue() {
        while running.count < maxConcurrentJobs, !pending.isEmpty {
            let job = pending.removeFirst()
            let keepWAV = pendingKeepWAV.removeValue(forKey: job.id) ?? true
            startJob(job, keepWAV: keepWAV)
        }
    }

    private func startJob(_ job: EncodingJob, keepWAV: Bool) {
        var runningJob = job
        running.append(runningJob)

        let task = Task {
            let encoder = LameEncoder()
            do {
                try await encoder.encode(
                    wavURL: job.wavURL,
                    mp3URL: job.mp3URL,
                    bitrate: job.bitrate,
                    mode: job.mode,
                    progress: { [weak self] p in
                        guard let self else { return }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let idx = self.running.firstIndex(where: { $0.id == job.id }) {
                                self.running[idx].progress = p
                            }
                        }
                    }
                )
                // Success — optionally delete WAV.
                if !keepWAV {
                    try? FileManager.default.removeItem(at: job.wavURL)
                }
                await MainActor.run {
                    if self.cancelledJobIDs.remove(job.id) != nil {
                        try? FileManager.default.removeItem(at: job.mp3URL)
                        self.runningTasks.removeValue(forKey: job.id)
                        self.running.removeAll { $0.id == job.id }
                        self.drainQueue()
                        return
                    }
                    self.runningTasks.removeValue(forKey: job.id)
                    self.running.removeAll { $0.id == job.id }
                    runningJob.progress = 1.0
                    self.completed.append(runningJob)
                    self.recentlyCompletedJob = runningJob
                    self.drainQueue()
                }
            } catch {
                // Failure — always preserve WAV; remove partial MP3 if present.
                try? FileManager.default.removeItem(at: job.mp3URL)
                var failedJob = job
                failedJob.error = error
                await MainActor.run {
                    if self.cancelledJobIDs.remove(job.id) != nil {
                        self.runningTasks.removeValue(forKey: job.id)
                        self.running.removeAll { $0.id == job.id }
                        self.drainQueue()
                        return
                    }
                    self.runningTasks.removeValue(forKey: job.id)
                    self.running.removeAll { $0.id == job.id }
                    self.failed.append(failedJob)
                    self.drainQueue()
                }
            }
        }

        runningTasks[job.id] = task
    }
}
