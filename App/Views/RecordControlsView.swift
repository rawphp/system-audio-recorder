import Foundation
import Observation
import SwiftUI

// MARK: - RecordControlsState

/// The three visual states the control surface can be in.
/// Used as the `value:` parameter for `.animation(…, value:)` so SwiftUI
/// can animate between them with a 150 ms ease-in-out.
public enum RecordControlsState: Equatable, Sendable {
    /// No active session — show the big "● Start Recording" button.
    case idle
    /// Session is recording — show Pause + Stop + live elapsed time.
    case recording(elapsed: TimeInterval)
    /// Session is paused — show Resume + Stop + frozen elapsed time.
    case paused(elapsed: TimeInterval)
}

// MARK: - RecordControlsViewModel

/// `@Observable` view model for `RecordControlsView`.
///
/// Responsible for:
/// - Mapping `SessionState` → `RecordControlsState`
/// - Tracking elapsed recording time with a deterministic clock
/// - Delegating actions to `AppStore` via injected closures
///
/// The `clock` dependency lets tests inject a fixed date for deterministic
/// elapsed-time assertions without spinning a real timer.
@Observable
@MainActor
public final class RecordControlsViewModel {

    // MARK: - Public observable state

    /// The derived visual state for the controls. Drives the SwiftUI view.
    public private(set) var controlsState: RecordControlsState = .idle

    // MARK: - Private elapsed-time accounting

    /// Wall-clock instant when the *current recording segment* started.
    /// Reset each time recording (re)starts after pause.
    private var segmentStart: Date? = nil

    /// Accumulated elapsed time from all previously-completed recording segments.
    private var accumulatedElapsed: TimeInterval = 0

    /// Injected clock — returns the current date. Overridden in tests.
    private let clock: () -> Date

    // MARK: - Action closures (injected — no direct AppStore reference)

    private let startAction: () async -> Void
    private let pauseAction: () async -> Void
    private let resumeAction: () async -> Void
    private let stopAction: () async -> Void

    /// Reads the current `SessionState` from the store. Used during `update`
    /// so the view model stays in sync even if called without a parameter.
    private let sessionStateProvider: () -> SessionState

    // MARK: - Init

    public init(
        startAction: @escaping () async -> Void,
        pauseAction: @escaping () async -> Void,
        resumeAction: @escaping () async -> Void,
        stopAction: @escaping () async -> Void,
        sessionStateProvider: @escaping () -> SessionState,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.startAction = startAction
        self.pauseAction = pauseAction
        self.resumeAction = resumeAction
        self.stopAction = stopAction
        self.sessionStateProvider = sessionStateProvider
        self.clock = clock
    }

    // MARK: - State update (called from view's .onChange / .task)

    /// Synchronise the view model's state with the current `SessionState`.
    /// Called by the SwiftUI view whenever `appStore.sessionState` changes.
    public func update(sessionState: SessionState) {
        switch sessionState {
        case .idle, .stopped, .failed:
            // Reset all elapsed-time accounting
            segmentStart = nil
            accumulatedElapsed = 0
            controlsState = .idle

        case .recording:
            if segmentStart == nil {
                // Either fresh start or resuming from pause — capture segment start
                segmentStart = clock()
            }
            // Compute current elapsed and update state
            let elapsed = currentElapsed()
            controlsState = .recording(elapsed: elapsed)

        case .paused:
            // Freeze the clock: snapshot accumulated + current segment length
            if let start = segmentStart {
                accumulatedElapsed += clock().timeIntervalSince(start)
                segmentStart = nil
            }
            controlsState = .paused(elapsed: accumulatedElapsed)
        }
    }

    // MARK: - Timer tick (called by the 1 Hz Timer in the view while recording)

    /// Advance the displayed elapsed time. Should be called every ~1 s while recording.
    /// No-op while idle or paused.
    public func tick() {
        switch controlsState {
        case .recording:
            controlsState = .recording(elapsed: currentElapsed())
        case .idle, .paused:
            break
        }
    }

    // MARK: - Action methods

    public func start() async {
        await startAction()
    }

    public func pause() async {
        await pauseAction()
    }

    public func resume() async {
        await resumeAction()
    }

    public func stop() async {
        await stopAction()
    }

    // MARK: - Elapsed time helpers

    /// Total elapsed time: accumulated segments + ongoing segment (if any).
    private func currentElapsed() -> TimeInterval {
        let ongoing = segmentStart.map { clock().timeIntervalSince($0) } ?? 0
        return accumulatedElapsed + ongoing
    }

    /// Format a `TimeInterval` as `HH:MM:SS` for display.
    public static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - RecordControlsView

/// The record/pause/stop button surface. Morphs between three layouts:
///
/// **Idle**
/// ```
/// ┌──────────────────────────────────────────┐
/// │             ●  Start Recording           │
/// └──────────────────────────────────────────┘
/// ```
///
/// **Recording**
/// ```
/// ┌─────────────────┐  ┌─────────────────────┐
/// │   ⏸  Pause      │  │     ■  Stop         │
/// └─────────────────┘  └─────────────────────┘
///             00:01:23
/// ```
///
/// **Paused**
/// ```
/// ┌─────────────────┐  ┌─────────────────────┐
/// │   ▶  Resume     │  │     ■  Stop         │
/// └─────────────────┘  └─────────────────────┘
///             00:01:23  (frozen)
/// ```
///
/// State transitions animate with a 150 ms ease-in-out (AC #4).
/// Permission surfacing is delegated to `RecordingSession` — this view just
/// calls `appStore.startRecording()` (AC #5).
public struct RecordControlsView: View {
    @Environment(\.appStore) private var appStore

    @State private var viewModel: RecordControlsViewModel? = nil

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                controls(vm: vm)
            } else {
                // Fallback while viewModel is being built (layout placeholder)
                idleButton {}
            }
        }
        .task {
            guard let store = appStore else { return }
            if viewModel == nil {
                viewModel = RecordControlsViewModel(
                    startAction: { await store.startRecording(preset: store.selectedPreset) },
                    pauseAction: { try? await store.pauseRecording() },
                    resumeAction: { try? await store.resumeRecording() },
                    stopAction: { await store.stopRecording() },
                    sessionStateProvider: { store.sessionState }
                )
                viewModel?.update(sessionState: store.sessionState)
            }
        }
        .onChange(of: appStore?.sessionState) { _, newState in
            guard let newState else { return }
            viewModel?.update(sessionState: newState)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func controls(vm: RecordControlsViewModel) -> some View {
        VStack(spacing: 8) {
            switch vm.controlsState {
            case .idle:
                idleButton {
                    Task { await vm.start() }
                }

            case .recording(let elapsed):
                HStack(spacing: 16) {
                    pauseButton {
                        Task { await vm.pause() }
                    }
                    stopButton {
                        Task { await vm.stop() }
                    }
                }
                .padding(.horizontal, 40)

                Text(RecordControlsViewModel.formatElapsed(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

            case .paused(let elapsed):
                HStack(spacing: 16) {
                    resumeButton {
                        Task { await vm.resume() }
                    }
                    stopButton {
                        Task { await vm.stop() }
                    }
                }
                .padding(.horizontal, 40)

                Text(RecordControlsViewModel.formatElapsed(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: vm.controlsState)
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            // Tick the elapsed timer while recording; no-op otherwise.
            if case .recording = vm.controlsState {
                vm.tick()
            }
        }
    }

    // MARK: - Leaf buttons

    private func idleButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 40)
    }

    private func pauseButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Pause", systemImage: "pause.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func resumeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Resume", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func stopButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Stop", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }
}

#Preview {
    RecordControlsView()
        .frame(width: 480, height: 120)
}
