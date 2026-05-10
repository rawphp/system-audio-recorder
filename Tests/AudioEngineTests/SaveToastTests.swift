import XCTest
@testable import SystemAudioRecorder

// MARK: - SaveToastTests

/// Unit tests for `SaveToastViewModel` (REQ-027).
///
/// Strategy:
/// - `SaveToastViewModel` is injected with a mock `EncodingQueueObservable` protocol
///   so we can drive queue state changes without touching the real `EncodingQueue`.
/// - The auto-dismiss timer is injectable; tests use a zero-duration (`immediately`)
///   override so they don't need to wait 5 s in CI.

@MainActor
final class SaveToastTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: - Helpers
    // -----------------------------------------------------------------------

    /// Build a view-model wired to a fresh mock queue.
    private func makeVM(
        dismissAfter: TimeInterval = 0.05,
        onReveal: ((URL) -> Void)? = nil
    ) -> (SaveToastViewModel, MockEncodingQueue) {
        let mock = MockEncodingQueue()
        let vm = SaveToastViewModel(
            queue: mock,
            dismissAfter: dismissAfter,
            revealInFinder: onReveal ?? { _ in }
        )
        return (vm, mock)
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #3 — initial state is .hidden
    // -----------------------------------------------------------------------

    func testInitialStateIsHidden() {
        let (vm, _) = makeVM()
        if case .hidden = vm.toastState {
            // pass
        } else {
            XCTFail("Expected .hidden initially, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #3 — job moves to running → toast shows .encoding
    // -----------------------------------------------------------------------

    func testJobRunningTransitionsToEncoding() async {
        let (vm, mock) = makeVM()
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        if case .encoding(let id) = vm.toastState {
            XCTAssertEqual(id, job.id)
        } else {
            XCTFail("Expected .encoding, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #2 — job moves to completed → toast shows .saved(mp3URL)
    // -----------------------------------------------------------------------

    func testJobCompletedTransitionsToSaved() async throws {
        let (vm, mock) = makeVM(dismissAfter: 60) // don't auto-dismiss during test
        let job = makeJob()

        // Put job in running first (same job ID)
        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        // Now complete the job
        mock.simulateCompleted(job: job)
        vm.handleQueueChange()

        if case .saved(let url) = vm.toastState {
            XCTAssertEqual(url, job.mp3URL)
        } else {
            XCTFail("Expected .saved, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #6 — job failure → toast shows .failed(wavURL) and stays
    // -----------------------------------------------------------------------

    func testJobFailedTransitionsToFailedState() async {
        let (vm, mock) = makeVM()
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        mock.simulateFailed(job: job, error: TestEncodingError.synthetic)
        vm.handleQueueChange()

        if case .failed(let wavURL, _) = vm.toastState {
            XCTAssertEqual(wavURL, job.wavURL)
        } else {
            XCTFail("Expected .failed, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #5 — saved toast auto-dismisses after delay
    // -----------------------------------------------------------------------

    func testSavedToastAutoDismissesAfterDelay() async throws {
        let (vm, mock) = makeVM(dismissAfter: 0.1) // 100 ms for CI speed
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()
        mock.simulateCompleted(job: job)
        vm.handleQueueChange()

        // Should be .saved immediately
        if case .saved = vm.toastState { /* ok */ } else {
            XCTFail("Expected .saved before dismiss, got \(vm.toastState)")
        }

        // Wait for dismiss timer
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        if case .hidden = vm.toastState {
            // pass
        } else {
            XCTFail("Expected .hidden after auto-dismiss, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #5 — clicking toast cancels auto-dismiss timer
    // -----------------------------------------------------------------------

    func testTouchCancelsAutoDismiss() async throws {
        let (vm, mock) = makeVM(dismissAfter: 0.15)
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()
        mock.simulateCompleted(job: job)
        vm.handleQueueChange()

        // Simulate user tapping the toast before the 150 ms timer fires
        vm.keepOpen()

        // Wait past the original dismiss deadline
        try await Task.sleep(nanoseconds: 300_000_000)

        // Toast should still be visible because keepOpen() was called
        if case .hidden = vm.toastState {
            XCTFail("Toast should still be visible after keepOpen(), got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #6 — failed toast does NOT auto-dismiss
    // -----------------------------------------------------------------------

    func testFailedToastDoesNotAutoDismiss() async throws {
        let (vm, mock) = makeVM(dismissAfter: 0.1)
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()
        mock.simulateFailed(job: job, error: TestEncodingError.synthetic)
        vm.handleQueueChange()

        // Wait past the dismiss delay
        try await Task.sleep(nanoseconds: 300_000_000)

        if case .failed = vm.toastState {
            // pass — stays failed
        } else {
            XCTFail("Expected .failed to persist (no auto-dismiss), got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - dismiss() hides the toast manually
    // -----------------------------------------------------------------------

    func testManualDismissHidesToast() {
        let (vm, mock) = makeVM()
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()
        mock.simulateFailed(job: job, error: TestEncodingError.synthetic)
        vm.handleQueueChange()

        vm.dismiss()

        if case .hidden = vm.toastState {
            // pass
        } else {
            XCTFail("Expected .hidden after dismiss(), got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Toast does NOT stack (same job id morphs in place)
    // -----------------------------------------------------------------------

    func testToastMorphsInPlaceNotStacks() async {
        let (vm, mock) = makeVM(dismissAfter: 60)
        let job = makeJob()

        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        // Should be encoding
        guard case .encoding = vm.toastState else {
            XCTFail("Expected .encoding")
            return
        }

        // Complete the same job
        mock.simulateCompleted(job: job)
        vm.handleQueueChange()

        // Should morph to saved (same position, not a second toast)
        if case .saved(let url) = vm.toastState {
            XCTAssertEqual(url, job.mp3URL, "Saved URL must match job's mp3URL")
        } else {
            XCTFail("Expected .saved, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - REQ-058: observeQueue() on SaveToastViewModel responds to queue changes
    // -----------------------------------------------------------------------

    /// Verifies that `SaveToastViewModel.observeQueue()` wires the observer to
    /// the *queue* arrays (running / completed / failed), not to the toast's own
    /// state.  With the broken observer the toast stays `.hidden` no matter what
    /// the queue does.  With the fix it transitions to `.encoding` as soon as a
    /// job appears in `queue.running`.
    func testObserveQueueTransitionsToEncodingWhenJobStarts() async throws {
        let (vm, mock) = makeVM()
        let job = makeJob()

        // Start the observer in a child task so it runs concurrently.
        let observerTask = Task { @MainActor in
            await vm.observeQueue()
        }
        // Yield so the observer can install its first withObservationTracking registration.
        await Task.yield()
        await Task.yield()

        // Mutate the queue — a job has started encoding.
        mock.simulateRunning(job: job)

        // Give the observation loop one runloop turn to wake and call handleQueueChange().
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        observerTask.cancel()

        if case .encoding(let id) = vm.toastState {
            XCTAssertEqual(id, job.id, "Encoding state should carry the running job's ID")
        } else {
            XCTFail("Expected .encoding after queue mutation, got \(vm.toastState)")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Reveal in Finder calls the injected closure with mp3URL
    // -----------------------------------------------------------------------

    func testRevealInFinderCallsClosureWithMP3URL() async {
        var revealedURL: URL?
        let (vm, mock) = makeVM(
            dismissAfter: 60,
            onReveal: { url in revealedURL = url }
        )
        let job = makeJob()

        mock.simulateCompleted(job: job)
        vm.handleQueueChange()

        vm.revealFile()

        XCTAssertEqual(revealedURL, job.mp3URL)
    }

    // -----------------------------------------------------------------------
    // MARK: - REQ-063: finishingRecording state transitions
    // -----------------------------------------------------------------------

    /// hidden → finishingRecording when isFinishingRecording = true
    func testFinishingRecordingAppearsWhenSignalTrue() {
        let (vm, _) = makeVM()
        vm.handleFinishingChange(isFinishing: true)
        if case .finishingRecording = vm.toastState {
            // pass
        } else {
            XCTFail("Expected .finishingRecording when signal is true, got \(vm.toastState)")
        }
    }

    /// finishingRecording → hidden when signal flips false and no encoding job is running
    func testFinishingRecordingHidesWhenSignalFalseAndNoJob() {
        let (vm, _) = makeVM()
        vm.handleFinishingChange(isFinishing: true)
        vm.handleFinishingChange(isFinishing: false)
        if case .hidden = vm.toastState {
            // pass
        } else {
            XCTFail("Expected .hidden when signal false with no job, got \(vm.toastState)")
        }
    }

    /// finishingRecording → encoding (no .hidden flicker) when signal flips false
    /// and a job is already in running.
    func testFinishingRecordingHandsOffToEncodingWithoutFlicker() {
        let (vm, mock) = makeVM()
        vm.handleFinishingChange(isFinishing: true)

        // A job starts running while we are still finishing.
        let job = makeJob()
        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        // Signal goes false — should go directly to .encoding, NOT .hidden.
        vm.handleFinishingChange(isFinishing: false)

        if case .encoding(let id) = vm.toastState {
            XCTAssertEqual(id, job.id)
        } else {
            XCTFail("Expected .encoding after handoff (no flicker through .hidden), got \(vm.toastState)")
        }
    }

    /// Full happy path: hidden → finishingRecording → encoding → saved
    func testFullHappyPath_finishingToEncodingToSaved() {
        let (vm, mock) = makeVM(dismissAfter: 60)
        let job = makeJob()

        // 1. Stop clicked — finishing toast appears
        vm.handleFinishingChange(isFinishing: true)
        if case .finishingRecording = vm.toastState { /* ok */ }
        else { XCTFail("Step 1: expected .finishingRecording, got \(vm.toastState)") }

        // 2. Encoding job starts running while still finishing
        mock.simulateRunning(job: job)
        vm.handleQueueChange()

        // 3. Session.stop() returns — signal goes false, toast should be .encoding
        vm.handleFinishingChange(isFinishing: false)
        if case .encoding(let id) = vm.toastState { XCTAssertEqual(id, job.id) }
        else { XCTFail("Step 3: expected .encoding, got \(vm.toastState)") }

        // 4. Encoding completes
        mock.simulateCompleted(job: job)
        vm.handleQueueChange()
        if case .saved(let url) = vm.toastState { XCTAssertEqual(url, job.mp3URL) }
        else { XCTFail("Step 4: expected .saved, got \(vm.toastState)") }
    }

    /// AC #5: No auto-dismiss timer fires while in .finishingRecording
    func testNoAutoDismissWhileFinishingRecording() async throws {
        let (vm, _) = makeVM(dismissAfter: 0.05) // very short dismiss
        vm.handleFinishingChange(isFinishing: true)

        // Wait past any timer that could have been scheduled
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Should still be finishingRecording, not dismissed
        if case .finishingRecording = vm.toastState { /* pass */ }
        else { XCTFail("Expected .finishingRecording (no auto-dismiss), got \(vm.toastState)") }
    }

    // -----------------------------------------------------------------------
    // MARK: - Private helpers
    // -----------------------------------------------------------------------

    private func makeJob() -> EncodingJob {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        return EncodingJob(
            wavURL: tmp.appendingPathComponent("test.wav"),
            mp3URL: tmp.appendingPathComponent("test.mp3"),
            bitrate: 192,
            mode: .vbr
        )
    }
}

// MARK: - MockEncodingQueue

/// A simple mock that exposes the same observable surface `SaveToastViewModel` needs.
@Observable
@MainActor
final class MockEncodingQueue: EncodingQueueObservable {
    var pending: [EncodingJob] = []
    var running: [EncodingJob] = []
    var completed: [EncodingJob] = []
    var failed: [EncodingJob] = []

    func simulateRunning(job: EncodingJob) {
        running.append(job)
        completed.removeAll { $0.id == job.id }
        failed.removeAll { $0.id == job.id }
    }

    func simulateCompleted(job: EncodingJob) {
        running.removeAll { $0.id == job.id }
        completed.append(job)
    }

    func simulateFailed(job: EncodingJob, error: Error) {
        running.removeAll { $0.id == job.id }
        var failedJob = job
        failedJob.error = error
        failed.append(failedJob)
    }

    func cancelAllJobs() async {
        running.removeAll()
        pending.removeAll()
    }
}

// MARK: - TestEncodingError

private enum TestEncodingError: Error {
    case synthetic
}
