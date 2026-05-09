import SwiftUI
import Observation

// MARK: - EncodingJobDisplayState

/// The display state for a single job row in `EncodingJobsView`.
public enum EncodingJobDisplayState {
    /// Waiting in the queue; not yet running.
    case pending
    /// Actively encoding — progress value available from `EncodingJobDisplay.progress`.
    case encoding
    /// Encoding just finished; stays visible for the flash window (5 s by default).
    case doneFlash
    /// Encoding failed; stays until the user manually dismisses.
    case failed(Error)
}

// MARK: - EncodingJobDisplay

/// Value type that represents one row in `EncodingJobsView`.
public struct EncodingJobDisplay: Identifiable {
    public let id: UUID
    /// Last path component of the WAV URL (e.g. "recording-2026-05-10.wav").
    public let fileName: String
    /// Encoding progress in [0…1]. Meaningful only when `state == .encoding`.
    public let progress: Double
    /// Current display state for this row.
    public let state: EncodingJobDisplayState
    /// When this row first appeared; used to expire `.doneFlash` rows.
    public let appearedAt: Date
}

// MARK: - EncodingJobsViewModel

/// `@Observable @MainActor` view-model that drives `EncodingJobsView`.
///
/// Derives `displayedJobs` from the queue's `pending`, `running`,
/// recently-completed (≤ flashDuration s), and failed arrays.
///
/// - Completed jobs become `.doneFlash` for `flashDuration` seconds, then
///   disappear from the list.
/// - Failed jobs are sticky; call `dismiss(jobID:)` to remove them.
/// - `cancel(jobID:)` delegates to `cancelAllJobs()` only when the target job
///   is the sole running/pending job; otherwise it is a no-op (per-job cancel
///   API not yet available in `EncodingQueue` — needs EncodingQueue v2).
@Observable
@MainActor
public final class EncodingJobsViewModel {

    // MARK: - Public state

    /// The merged, ordered list of jobs to display.
    public private(set) var displayedJobs: [EncodingJobDisplay] = []

    /// Convenience: true when `displayedJobs` is empty.
    public var isQueueEmpty: Bool { displayedJobs.isEmpty }

    /// Number of jobs currently encoding (derived from the queue directly).
    public var runningCount: Int { queue.running.count }

    // MARK: - Private

    private let queue: any EncodingQueueObservable
    /// How long a completed job stays in the `.doneFlash` state before being removed.
    private let flashDuration: TimeInterval
    /// Injectable clock; defaults to `{ Date() }` in production.
    private let nowProvider: () -> Date

    /// Tracks when each completed job first appeared in the flash state.
    /// Key: job id, Value: completion timestamp.
    private var completedAt: [UUID: Date] = [:]

    /// Manually dismissed failed-job IDs; these are never re-shown.
    private var dismissedIDs: Set<UUID> = []

    // MARK: - Init

    /// - Parameters:
    ///   - queue:         Observable encoding queue (real or mock).
    ///   - flashDuration: How long completed jobs stay in `.doneFlash`. Default 5 s.
    ///   - nowProvider:   Injectable clock for testing. Default `{ Date() }`.
    public init(
        queue: any EncodingQueueObservable,
        flashDuration: TimeInterval = 5,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.queue = queue
        self.flashDuration = flashDuration
        self.nowProvider = nowProvider
    }

    // MARK: - Public API

    /// Recompute `displayedJobs` from the current queue state.
    ///
    /// Call this whenever the encoding queue changes (e.g. from `withObservationTracking`
    /// in the view's `.task` modifier, or directly in tests).
    public func refresh() {
        let now = nowProvider()
        var jobs: [EncodingJobDisplay] = []

        // 1. Pending
        for job in queue.pending {
            jobs.append(EncodingJobDisplay(
                id: job.id,
                fileName: job.wavURL.lastPathComponent,
                progress: 0,
                state: .pending,
                appearedAt: now
            ))
        }

        // 2. Running
        for job in queue.running {
            jobs.append(EncodingJobDisplay(
                id: job.id,
                fileName: job.wavURL.lastPathComponent,
                progress: job.progress,
                state: .encoding,
                appearedAt: now
            ))
        }

        // 3. Recently completed (doneFlash window still open)
        for job in queue.completed {
            guard !dismissedIDs.contains(job.id) else { continue }

            let timestamp = completedAt[job.id] ?? now
            if now.timeIntervalSince(timestamp) <= flashDuration {
                jobs.append(EncodingJobDisplay(
                    id: job.id,
                    fileName: job.wavURL.lastPathComponent,
                    progress: 1,
                    state: .doneFlash,
                    appearedAt: timestamp
                ))
            }
            // If the flash window has expired, simply don't include the job.
        }

        // 4. Failed (sticky, never auto-removed)
        for job in queue.failed {
            guard !dismissedIDs.contains(job.id) else { continue }
            jobs.append(EncodingJobDisplay(
                id: job.id,
                fileName: job.wavURL.lastPathComponent,
                progress: 0,
                state: .failed(job.error ?? UnknownJobError()),
                appearedAt: completedAt[job.id] ?? now
            ))
        }

        displayedJobs = jobs
    }

    /// Record that a job completed at a specific time.
    ///
    /// Production usage: call from the observation loop when a job moves to `completed`.
    /// Tests call this directly to inject a custom timestamp.
    public func markCompleted(jobID: UUID, at date: Date) {
        completedAt[jobID] = date
    }

    /// Manually remove a job from `displayedJobs` (intended for `.failed` rows).
    public func dismiss(jobID: UUID) {
        dismissedIDs.insert(jobID)
        displayedJobs.removeAll { $0.id == jobID }
    }

    /// Attempt to cancel a job.
    ///
    /// - Limitation: `EncodingQueue` exposes only `cancelAll()` via `cancelAllJobs()` on
    ///   the protocol (REQ-018). A per-job cancel API requires EncodingQueue v2.
    ///   As a safe approximation:
    ///   - If `jobID` is the only running/pending job, call `queue.cancelAllJobs()`.
    ///   - Otherwise this is a no-op (needs per-job cancel API in EncodingQueue v2).
    public func cancel(jobID: UUID) async {
        let allActive = queue.running.map(\.id) + queue.pending.map(\.id)
        if allActive.count == 1, allActive.first == jobID {
            // Safe to cancel all — there is only one job.
            await queue.cancelAllJobs()
        } else {
            // needs per-job cancel API in EncodingQueue v2
        }
    }
}

// MARK: - Sentinels

private struct UnknownJobError: Error {}

// MARK: - EncodingJobsView

/// Thin SwiftUI shell that renders a list of in-flight encoding jobs.
///
/// Hide/show this view based on `viewModel.isQueueEmpty` so there is no chrome
/// when the queue is empty.
public struct EncodingJobsView: View {

    @State private var viewModel: EncodingJobsViewModel

    public init(viewModel: EncodingJobsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if viewModel.displayedJobs.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.displayedJobs) { job in
                        jobRow(job)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.regularMaterial)
                        .shadow(radius: 4)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .task {
            await observeQueue()
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func jobRow(_ job: EncodingJobDisplay) -> some View {
        HStack(spacing: 10) {
            // Status icon
            Group {
                switch job.state {
                case .pending:
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                case .encoding:
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(.circular)
                case .doneFlash:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 20)

            // File name
            Text(job.fileName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Progress + status label
            switch job.state {
            case .encoding:
                Text("\(Int(job.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .doneFlash:
                Text("Done")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let error):
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            case .pending:
                Text("Pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Action button
            switch job.state {
            case .pending, .encoding:
                Button("Cancel") {
                    Task { await viewModel.cancel(jobID: job.id) }
                }
                .font(.callout)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            case .doneFlash:
                EmptyView()
            case .failed:
                Button {
                    viewModel.dismiss(jobID: job.id)
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Observation loop

    @MainActor
    private func observeQueue() async {
        let vm = viewModel
        while !Task.isCancelled {
            // Snapshot completed job IDs before tracking to detect new arrivals.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = vm.displayedJobs
                } onChange: {
                    cont.resume()
                }
            }
            vm.refresh()
            await Task.yield()
        }
    }
}
