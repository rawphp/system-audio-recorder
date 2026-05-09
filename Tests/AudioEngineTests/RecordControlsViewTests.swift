import XCTest
import AVFoundation
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - Test doubles

/// Fake AppStore for RecordControlsViewModel tests — tracks action calls.
@MainActor
private final class FakeControlsAppStore {
    var sessionState: SessionState = .idle
    var startRecordingCallCount = 0
    var pauseRecordingCallCount = 0
    var resumeRecordingCallCount = 0
    var stopRecordingCallCount = 0

    func startRecording() async {
        startRecordingCallCount += 1
        sessionState = .recording
    }

    func pauseRecording() async {
        pauseRecordingCallCount += 1
        sessionState = .paused
    }

    func resumeRecording() async {
        resumeRecordingCallCount += 1
        sessionState = .recording
    }

    func stopRecording() async {
        stopRecordingCallCount += 1
        sessionState = .idle
    }
}

// MARK: - RecordControlsViewModelTests

@MainActor
final class RecordControlsViewModelTests: XCTestCase {

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private func makeVM(
        state: SessionState = .idle,
        clock: @escaping () -> Date = { Date() }
    ) -> (RecordControlsViewModel, FakeControlsAppStore) {
        let fakeStore = FakeControlsAppStore()
        fakeStore.sessionState = state
        let vm = RecordControlsViewModel(
            startAction: { [weak fakeStore] in await fakeStore?.startRecording() },
            pauseAction: { [weak fakeStore] in await fakeStore?.pauseRecording() },
            resumeAction: { [weak fakeStore] in await fakeStore?.resumeRecording() },
            stopAction: { [weak fakeStore] in await fakeStore?.stopRecording() },
            sessionStateProvider: { [weak fakeStore] in fakeStore?.sessionState ?? .idle },
            clock: clock
        )
        return (vm, fakeStore)
    }

    // -----------------------------------------------------------------------
    // AC #1: Idle state → .idle controls state
    // -----------------------------------------------------------------------

    func testInitialControlsStateIsIdle() {
        let (vm, _) = makeVM(state: .idle)
        vm.update(sessionState: .idle)
        if case .idle = vm.controlsState {
            // pass
        } else {
            XCTFail("Expected .idle, got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC #2: Recording state → .recording(elapsed:) with elapsed time
    // -----------------------------------------------------------------------

    func testRecordingStateProducesRecordingControlsState() {
        var now = Date(timeIntervalSinceReferenceDate: 1000)
        let (vm, _) = makeVM(state: .recording, clock: { now })

        // Simulate start() to capture the start time
        vm.update(sessionState: .recording)

        // Advance clock by 5 seconds
        now = Date(timeIntervalSinceReferenceDate: 1005)
        vm.tick()

        if case .recording(let elapsed) = vm.controlsState {
            XCTAssertEqual(elapsed, 5.0, accuracy: 0.01)
        } else {
            XCTFail("Expected .recording(elapsed:), got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC #2: Elapsed time updates on each tick
    // -----------------------------------------------------------------------

    func testElapsedTimeAdvancesOnTick() {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let (vm, _) = makeVM(state: .recording, clock: { now })
        vm.update(sessionState: .recording)

        now = Date(timeIntervalSinceReferenceDate: 3)
        vm.tick()

        if case .recording(let elapsed) = vm.controlsState {
            XCTAssertEqual(elapsed, 3.0, accuracy: 0.01)
        } else {
            XCTFail("Expected .recording(elapsed:), got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC #3: Paused state → .paused(elapsed:) with frozen elapsed time
    // -----------------------------------------------------------------------

    func testPausedStateFreezesClock() {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let (vm, _) = makeVM(state: .recording, clock: { now })
        vm.update(sessionState: .recording)

        // Record 10 seconds
        now = Date(timeIntervalSinceReferenceDate: 10)
        vm.tick()

        // Pause
        vm.update(sessionState: .paused)

        // Advance clock further — elapsed should not change while paused
        now = Date(timeIntervalSinceReferenceDate: 30)
        vm.tick()

        if case .paused(let elapsed) = vm.controlsState {
            XCTAssertEqual(elapsed, 10.0, accuracy: 0.01)
        } else {
            XCTFail("Expected .paused(elapsed:), got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC #3: Resume continues elapsed from accumulated time
    // -----------------------------------------------------------------------

    func testResumeAccumulatesElapsedTime() {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let (vm, _) = makeVM(state: .recording, clock: { now })
        vm.update(sessionState: .recording)

        // Record 10 seconds
        now = Date(timeIntervalSinceReferenceDate: 10)
        vm.tick()

        // Pause
        vm.update(sessionState: .paused)

        // Resume (clock is still at 10, but accumulated is 10)
        now = Date(timeIntervalSinceReferenceDate: 20) // 10s paused, then resume
        vm.update(sessionState: .recording)

        // Advance 5 more seconds after resume
        now = Date(timeIntervalSinceReferenceDate: 25)
        vm.tick()

        if case .recording(let elapsed) = vm.controlsState {
            // Should be 10 (before pause) + 5 (after resume) = 15
            XCTAssertEqual(elapsed, 15.0, accuracy: 0.01)
        } else {
            XCTFail("Expected .recording(elapsed:), got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC: Stopped/idle resets elapsed back to idle
    // -----------------------------------------------------------------------

    func testStopResetsToIdle() {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let (vm, _) = makeVM(state: .recording, clock: { now })
        vm.update(sessionState: .recording)

        now = Date(timeIntervalSinceReferenceDate: 10)
        vm.tick()

        vm.update(sessionState: .idle)

        if case .idle = vm.controlsState {
            // pass
        } else {
            XCTFail("Expected .idle, got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC: Action — start() delegates to startAction
    // -----------------------------------------------------------------------

    func testStartCallsStartAction() async {
        let (vm, store) = makeVM(state: .idle)
        await vm.start()
        XCTAssertEqual(store.startRecordingCallCount, 1)
    }

    // -----------------------------------------------------------------------
    // AC: Action — pause() delegates to pauseAction
    // -----------------------------------------------------------------------

    func testPauseCallsPauseAction() async {
        let (vm, store) = makeVM(state: .recording)
        await vm.pause()
        XCTAssertEqual(store.pauseRecordingCallCount, 1)
    }

    // -----------------------------------------------------------------------
    // AC: Action — resume() delegates to resumeAction
    // -----------------------------------------------------------------------

    func testResumeCallsResumeAction() async {
        let (vm, store) = makeVM(state: .paused)
        await vm.resume()
        XCTAssertEqual(store.resumeRecordingCallCount, 1)
    }

    // -----------------------------------------------------------------------
    // AC: Action — stop() delegates to stopAction
    // -----------------------------------------------------------------------

    func testStopCallsStopAction() async {
        let (vm, store) = makeVM(state: .recording)
        await vm.stop()
        XCTAssertEqual(store.stopRecordingCallCount, 1)
    }

    // -----------------------------------------------------------------------
    // AC: controlsState is equatable for animation value binding
    // -----------------------------------------------------------------------

    func testControlsStateEquality() {
        XCTAssertEqual(RecordControlsState.idle, RecordControlsState.idle)
        XCTAssertEqual(RecordControlsState.recording(elapsed: 5.0), RecordControlsState.recording(elapsed: 5.0))
        XCTAssertEqual(RecordControlsState.paused(elapsed: 10.0), RecordControlsState.paused(elapsed: 10.0))
        XCTAssertNotEqual(RecordControlsState.idle, RecordControlsState.recording(elapsed: 0.0))
        XCTAssertNotEqual(RecordControlsState.recording(elapsed: 1.0), RecordControlsState.paused(elapsed: 1.0))
    }

    // -----------------------------------------------------------------------
    // AC: Format elapsed time HH:MM:SS
    // -----------------------------------------------------------------------

    func testElapsedTimeFormatting() {
        XCTAssertEqual(RecordControlsViewModel.formatElapsed(0), "00:00:00")
        XCTAssertEqual(RecordControlsViewModel.formatElapsed(65), "00:01:05")
        XCTAssertEqual(RecordControlsViewModel.formatElapsed(3661), "01:01:01")
        XCTAssertEqual(RecordControlsViewModel.formatElapsed(3600), "01:00:00")
    }

    // -----------------------------------------------------------------------
    // AC: update from .stopped → idle controls state
    // -----------------------------------------------------------------------

    func testStoppedStateBecomesIdle() {
        let (vm, _) = makeVM(state: .idle)
        vm.update(sessionState: .stopped)
        if case .idle = vm.controlsState {
            // pass
        } else {
            XCTFail("Expected .idle for .stopped session, got \(vm.controlsState)")
        }
    }

    // -----------------------------------------------------------------------
    // AC: update from .failed → idle controls state
    // -----------------------------------------------------------------------

    func testFailedStateBecomesIdle() {
        let (vm, _) = makeVM(state: .idle)
        vm.update(sessionState: .failed)
        if case .idle = vm.controlsState {
            // pass
        } else {
            XCTFail("Expected .idle for .failed session, got \(vm.controlsState)")
        }
    }
}
