import AppKit
import SwiftUI
import Observation

// MARK: - EncodingQueueObservable

/// Protocol that exposes the minimal `EncodingQueue` surface needed by
/// `SaveToastViewModel`. Conforming to a protocol rather than subclassing
/// lets tests inject a lightweight `MockEncodingQueue` without spinning up
/// the real encoder.
@MainActor
public protocol EncodingQueueObservable: AnyObject {
    var pending: [EncodingJob] { get }
    var running: [EncodingJob] { get }
    var completed: [EncodingJob] { get }
    var failed: [EncodingJob] { get }
    /// Cancel all pending and running jobs. Used by `EncodingJobsViewModel.cancel(jobID:)`.
    func cancelAllJobs() async
}

// Make the real EncodingQueue conform so it can be used directly.
extension EncodingQueue: EncodingQueueObservable {
    public func cancelAllJobs() async {
        await cancelAll()
    }
}

// MARK: - ToastState

/// The four display states the toast can be in at any moment.
public enum ToastState: Equatable {
    /// No toast visible.
    case hidden
    /// A job is encoding — show a spinner with "Encoding…"
    case encoding(jobID: UUID)
    /// Encoding succeeded — show the MP3 path and a Reveal button.
    case saved(mp3URL: URL)
    /// Encoding failed — show the WAV path and a Reveal button. Stays until
    /// the user manually dismisses.
    case failed(wavURL: URL, error: Error)

    public static func == (lhs: ToastState, rhs: ToastState) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden):                                   return true
        case (.encoding(let a), .encoding(let b)):                 return a == b
        case (.saved(let a), .saved(let b)):                       return a == b
        case (.failed(let a, _), .failed(let b, _)):               return a == b
        default:                                                   return false
        }
    }
}

// MARK: - SaveToastViewModel

/// `@Observable @MainActor` view-model that drives the post-stop toast.
///
/// Lifecycle
/// - Caller calls `handleQueueChange()` whenever the encoding queue mutates.
/// - When a job appears in `running`, toast transitions to `.encoding`.
/// - When that job moves to `completed`, toast transitions to `.saved` and
///   starts a 5-second auto-dismiss timer.
/// - When a job appears in `failed`, toast transitions to `.failed` with no
///   auto-dismiss.
/// - `keepOpen()` cancels any pending dismiss timer.
/// - `dismiss()` hides the toast unconditionally.
/// - `revealFile()` invokes the injected `revealInFinder` closure with the
///   current file URL (mp3 on success, wav on failure).
@Observable
@MainActor
public final class SaveToastViewModel {

    // MARK: - Public state

    /// The current display state for the toast.
    public private(set) var toastState: ToastState = .hidden

    // MARK: - Private

    private let queue: any EncodingQueueObservable
    private let dismissAfter: TimeInterval
    private let revealInFinder: (URL) -> Void

    /// Tracks which job the toast is currently showing, to guard against
    /// stale updates from older jobs.
    private var activeJobID: UUID?

    /// Handle to the pending auto-dismiss task so we can cancel it.
    private var dismissTask: Task<Void, Never>?

    // MARK: - Init

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - queue:          The encoding queue to observe (real or mock).
    ///   - dismissAfter:   Seconds before a `.saved` toast auto-dismisses.
    ///                     Defaults to 5 s; tests pass a short value for speed.
    ///   - revealInFinder: Closure called with the file URL when the user
    ///                     taps "Reveal in Finder". Production wires this to
    ///                     `NSWorkspace.shared.activateFileViewerSelecting`.
    public init(
        queue: any EncodingQueueObservable,
        dismissAfter: TimeInterval = 5,
        revealInFinder: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.queue = queue
        self.dismissAfter = dismissAfter
        self.revealInFinder = revealInFinder
    }

    // MARK: - Queue observation hook

    /// Call this whenever the encoding queue arrays change (running / completed / failed).
    ///
    /// Production usage: wire via `withObservationTracking` inside the SwiftUI `.task`
    /// modifier on `SaveToast`. Tests call this directly after mutating the mock.
    public func handleQueueChange() {
        // 1. Check for a newly failed job
        if let failedJob = queue.failed.last {
            // Only switch if this is a new job or we were showing this job
            if activeJobID == nil || activeJobID == failedJob.id {
                activeJobID = failedJob.id
                dismissTask?.cancel()
                dismissTask = nil
                toastState = .failed(wavURL: failedJob.wavURL, error: failedJob.error ?? UnknownError())
                return
            }
        }

        // 2. Check for a newly completed job
        if let completedJob = queue.completed.last {
            if activeJobID == nil || activeJobID == completedJob.id {
                activeJobID = completedJob.id
                toastState = .saved(mp3URL: completedJob.mp3URL)
                scheduleDismiss()
                return
            }
        }

        // 3. Check for a running job (encoding started)
        if let runningJob = queue.running.last {
            if activeJobID == nil {
                // New job just started running
                activeJobID = runningJob.id
                dismissTask?.cancel()
                dismissTask = nil
                toastState = .encoding(jobID: runningJob.id)
            } else if activeJobID == runningJob.id {
                // Same job still running — just confirm encoding state
                if case .encoding = toastState { /* already correct */ } else {
                    toastState = .encoding(jobID: runningJob.id)
                }
            }
        }
    }

    // MARK: - Actions

    /// Cancel the auto-dismiss timer, keeping the toast visible until manually dismissed.
    public func keepOpen() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Hide the toast immediately, cancelling any pending dismiss timer.
    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        activeJobID = nil
        toastState = .hidden
    }

    /// Reveal the current file in Finder.
    /// - In `.saved` state: reveals the MP3 file.
    /// - In `.failed` state: reveals the WAV file.
    public func revealFile() {
        switch toastState {
        case .saved(let url):
            revealInFinder(url)
        case .failed(let url, _):
            revealInFinder(url)
        case .encoding, .hidden:
            break
        }
    }

    // MARK: - Private helpers

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let delay = dismissAfter
        dismissTask = Task { [weak self] in
            do {
                let ns = UInt64(delay * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.dismiss()
                }
            } catch {
                // Task cancelled — user tapped keepOpen() or dismiss()
            }
        }
    }
}

// MARK: - UnknownError (sentinel)

private struct UnknownError: Error {}

// MARK: - SaveToast (SwiftUI view)

/// Thin SwiftUI shell rendering the `SaveToastViewModel` state.
///
/// Embed in `ContentView` via `.safeAreaInset(edge: .bottom)` or
/// `.overlay(alignment: .bottom)`.
public struct SaveToast: View {

    @State private var viewModel: SaveToastViewModel

    public init(viewModel: SaveToastViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Group {
            switch viewModel.toastState {
            case .hidden:
                EmptyView()

            case .encoding:
                toastBackground {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(.circular)
                        Text("Encoding…")
                            .font(.callout)
                    }
                }

            case .saved(let mp3URL):
                toastBackground {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Saved → \(mp3URL.lastPathComponent)")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            viewModel.revealFile()
                        }
                        .font(.callout)
                        Button {
                            viewModel.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onTapGesture {
                    viewModel.keepOpen()
                }

            case .failed(let wavURL, _):
                toastBackground {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Encoding failed — WAV preserved at \(wavURL.lastPathComponent)")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            viewModel.revealFile()
                        }
                        .font(.callout)
                        Button {
                            viewModel.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.toastState)
        .task {
            // Observe encoding queue changes via withObservationTracking recursion.
            await observeQueue()
        }
    }

    // MARK: - Private helpers

    @ViewBuilder
    private func toastBackground<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .shadow(radius: 4)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }

    /// Long-lived observation loop: each iteration installs one
    /// `withObservationTracking` callback, which fires once when any tracked
    /// property changes, then re-installs itself.
    @MainActor
    private func observeQueue() async {
        // We need a reference-captured queue to observe it
        let vm = viewModel
        while !Task.isCancelled {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    // Access the tracked properties so the runtime registers them
                    _ = vm.toastState
                } onChange: {
                    continuation.resume()
                }
            }
            // Yield so the continuation fires on main actor
            await Task.yield()
        }
    }
}
