import XCTest
@testable import SystemAudioToMP3

// MARK: - EncodingJobsViewTests

/// Unit tests for `EncodingJobsViewModel` (REQ-030).
///
/// Strategy:
/// - Drive the `MockEncodingQueue` (from SaveToastTests scope — re-declared in
///   this file as `MockEncodingQueueForJobs` to avoid duplicate-symbol issues in
///   the same test target).
/// - Use an injectable `ClockNow` closure for time so the 5-second done-flash
///   timer can be exercised without real sleeping.

@MainActor
final class EncodingJobsViewTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: - Helpers
    // -----------------------------------------------------------------------

    private func makeVM(
        nowProvider: @escaping () -> Date = { Date() },
        flashDuration: TimeInterval = 5
    ) -> (EncodingJobsViewModel, MockEncodingQueueForJobs) {
        let mock = MockEncodingQueueForJobs()
        let vm = EncodingJobsViewModel(
            queue: mock,
            flashDuration: flashDuration,
            nowProvider: nowProvider
        )
        return (vm, mock)
    }

    private func makeJob(fileName: String = "rec.wav") -> EncodingJob {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        return EncodingJob(
            wavURL: tmp.appendingPathComponent(fileName),
            mp3URL: tmp.appendingPathComponent((fileName as NSString).deletingPathExtension + ".mp3"),
            bitrate: 192,
            mode: .vbr
        )
    }

    // -----------------------------------------------------------------------
    // MARK: - AC #1 — list populates from pending + running
    // -----------------------------------------------------------------------

    func testDisplayedJobsContainsPendingJobs() {
        let (vm, mock) = makeVM()
        let job = makeJob(fileName: "a.wav")
        mock.pending = [job]
        vm.refresh()

        XCTAssertEqual(vm.displayedJobs.count, 1)
        XCTAssertEqual(vm.displayedJobs.first?.id, job.id)
        XCTAssertEqual(vm.displayedJobs.first?.fileName, "a.wav")
        if case .pending = vm.displayedJobs.first?.state { /* ok */ } else {
            XCTFail("Expected .pending, got \(String(describing: vm.displayedJobs.first?.state))")
        }
    }

    func testDisplayedJobsContainsRunningJobs() {
        let (vm, mock) = makeVM()
        var job = makeJob(fileName: "b.wav")
        job.progress = 0.4
        mock.running = [job]
        vm.refresh()

        XCTAssertEqual(vm.displayedJobs.count, 1)
        if case .encoding = vm.displayedJobs.first?.state { /* ok */ } else {
            XCTFail("Expected .encoding, got \(String(describing: vm.displayedJobs.first?.state))")
        }
        XCTAssertEqual(vm.displayedJobs.first?.progress ?? -1, 0.4, accuracy: 0.001)
    }

    // -----------------------------------------------------------------------
    // MARK: - Completed jobs become doneFlash (within 5s)
    // -----------------------------------------------------------------------

    func testCompletedJobWithinFlashWindowIsDoneFlash() {
        let now = Date()
        var fakeClock = now
        let (vm, mock) = makeVM(nowProvider: { fakeClock }, flashDuration: 5)

        let job = makeJob(fileName: "c.wav")
        // Simulate job completing: move to completed, set appearedAt timestamp
        mock.completed = [job]
        vm.markCompleted(jobID: job.id, at: now)
        vm.refresh()

        XCTAssertEqual(vm.displayedJobs.count, 1)
        if case .doneFlash = vm.displayedJobs.first?.state { /* ok */ } else {
            XCTFail("Expected .doneFlash, got \(String(describing: vm.displayedJobs.first?.state))")
        }

        // Advance clock past the flash window
        fakeClock = now.addingTimeInterval(5.1)
        vm.refresh()

        // Now it should be gone
        XCTAssertTrue(vm.displayedJobs.isEmpty, "Job should disappear after flash window")
    }

    // -----------------------------------------------------------------------
    // MARK: - Failed jobs are sticky
    // -----------------------------------------------------------------------

    func testFailedJobIsSticky() {
        let (vm, mock) = makeVM()
        let job = makeJob(fileName: "d.wav")
        var failedJob = job
        failedJob.error = TestJobError.oops
        mock.failed = [failedJob]
        vm.refresh()

        XCTAssertEqual(vm.displayedJobs.count, 1)
        if case .failed = vm.displayedJobs.first?.state { /* ok */ } else {
            XCTFail("Expected .failed, got \(String(describing: vm.displayedJobs.first?.state))")
        }
    }

    func testFailedJobDoesNotAutoRemove() {
        var fakeClock = Date()
        let (vm, mock) = makeVM(nowProvider: { fakeClock }, flashDuration: 5)
        let job = makeJob(fileName: "e.wav")
        var failedJob = job
        failedJob.error = TestJobError.oops
        mock.failed = [failedJob]
        vm.refresh()

        // Advance clock far in the future
        fakeClock = fakeClock.addingTimeInterval(1000)
        vm.refresh()

        // Failed job must still be present
        XCTAssertEqual(vm.displayedJobs.count, 1)
        if case .failed = vm.displayedJobs.first?.state { /* ok */ } else {
            XCTFail("Expected .failed to persist, got \(String(describing: vm.displayedJobs.first?.state))")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - dismiss(jobID:) removes a failed job
    // -----------------------------------------------------------------------

    func testDismissRemovesFailedJob() {
        let (vm, mock) = makeVM()
        let job = makeJob(fileName: "f.wav")
        var failedJob = job
        failedJob.error = TestJobError.oops
        mock.failed = [failedJob]
        vm.refresh()
        XCTAssertEqual(vm.displayedJobs.count, 1)

        vm.dismiss(jobID: job.id)
        XCTAssertTrue(vm.displayedJobs.isEmpty)
    }

    // -----------------------------------------------------------------------
    // MARK: - cancel(jobID:) delegates to queue when sole running/pending job
    // -----------------------------------------------------------------------

    func testCancelCallsCancelAllWhenSoleJob() async {
        let (vm, mock) = makeVM()
        let job = makeJob(fileName: "g.wav")
        mock.running = [job]
        vm.refresh()

        await vm.cancel(jobID: job.id)
        XCTAssertTrue(mock.cancelAllCalled, "cancelAll() should have been invoked for the sole running job")
    }

    func testCancelIsNoOpWhenMultipleJobs() async {
        let (vm, mock) = makeVM()
        let job1 = makeJob(fileName: "h1.wav")
        let job2 = makeJob(fileName: "h2.wav")
        mock.running = [job1, job2]
        vm.refresh()

        // Cancel job1 but job2 is also running — should be a no-op per limitation
        await vm.cancel(jobID: job1.id)
        XCTAssertFalse(mock.cancelAllCalled, "cancelAll() must NOT be called when multiple jobs are in flight")
    }

    // -----------------------------------------------------------------------
    // MARK: - isQueueEmpty returns true when no displayed jobs
    // -----------------------------------------------------------------------

    func testIsQueueEmptyWhenNoJobs() {
        let (vm, _) = makeVM()
        vm.refresh()
        XCTAssertTrue(vm.isQueueEmpty)
    }

    func testIsQueueEmptyFalseWhenJobsPresent() {
        let (vm, mock) = makeVM()
        mock.pending = [makeJob()]
        vm.refresh()
        XCTAssertFalse(vm.isQueueEmpty)
    }

    // -----------------------------------------------------------------------
    // MARK: - runningCount reflects queue.running.count
    // -----------------------------------------------------------------------

    func testRunningCountReflectsRunningJobs() {
        let (vm, mock) = makeVM()
        mock.running = [makeJob(fileName: "i1.wav"), makeJob(fileName: "i2.wav")]
        vm.refresh()
        XCTAssertEqual(vm.runningCount, 2)
    }
}

// MARK: - MockEncodingQueueForJobs

/// Separate mock for REQ-030 tests — avoids symbol collision with the one defined
/// in SaveToastTests.swift (Swift test targets share the same module, so we
/// use a distinct type name).
@Observable
@MainActor
final class MockEncodingQueueForJobs: EncodingQueueObservable {
    var pending: [EncodingJob] = []
    var running: [EncodingJob] = []
    var completed: [EncodingJob] = []
    var failed: [EncodingJob] = []

    var cancelAllCalled = false

    func cancelAllJobs() async {
        cancelAllCalled = true
        running.removeAll()
        pending.removeAll()
    }

}

// MARK: - TestJobError

private enum TestJobError: Error {
    case oops
}
