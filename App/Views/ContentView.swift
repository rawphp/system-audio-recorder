import AppKit
import SwiftUI

// MARK: - ContentViewModel

/// Lightweight view-model that owns UI-only state for ContentView.
/// Separating this from AppStore makes the settings-cog state easily testable
/// without needing a full SwiftUI render cycle.
@Observable
@MainActor
public final class ContentViewModel {
    /// Constant title shown in the title bar.
    public let title = "System Audio Recorder"

    /// Whether the OutputSettingsView sheet is presented.
    public var showSettings: Bool = false

    public init() {}

    /// Called by the settings-cog button; flips `showSettings` to true.
    public func openSettings() {
        showSettings = true
    }
}

// MARK: - Placeholder stub views
// Each stub is a minimal SwiftUI view that satisfies ContentView's layout
// requirements today. The stub is replaced by the real implementation in the
// REQ indicated by the TODO comment.

// NOTE: SourcePickerView is now the real implementation in App/Views/SourcePickerView.swift (REQ-024).


// MixLevelMeterView is now defined in App/Views/MixLevelMeterView.swift (REQ-026).


// MARK: - ContentView

/// Default screen per spec §4.1.
///
/// Layout (480 × 320 pt, non-resizable):
/// ```
/// ┌──────────────────────────────────────────┐
/// │  System Audio Recorder              ⚙︎   │
/// │                                          │
/// │  Recording from:  Everything       ⌄     │
/// │                                          │
/// │       ┌──────────────────────────┐       │
/// │       │  ●  Start Recording      │       │
/// │       └──────────────────────────┘       │
/// │                                          │
/// │  ▁▂▃▄▅▆ ───────────────  -∞ dB           │
/// └──────────────────────────────────────────┘
/// ```
///
/// Does NOT call any permission API — permissions are requested lazily on first
/// record attempt (spec §4.7). The settings cog opens `OutputSettingsView` as a
/// cancellable sheet via `ContentViewModel.showSettings`.
public struct ContentView: View {
    @Environment(\.appStore) private var appStore

    /// UI-only state owned by the view-model (testable without rendering).
    @State private var viewModel = ContentViewModel()

    /// Source picker view model — built lazily from appStore the first time the
    /// view renders. Falls back to a minimal dummy store if no store is injected
    /// (e.g. in #Preview or unit-test contexts that don't inject AppStore).
    @State private var sourcePickerVM: SourcePickerViewModel? = nil

    /// Toast view-model — nil until appStore is available.
    @State private var toastVM: SaveToastViewModel? = nil

    /// Encoding jobs view-model — nil until appStore is available.
    @State private var jobsVM: EncodingJobsViewModel? = nil

    /// Controls the encoding-jobs popover.
    @State private var showJobsPopover: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            // ── Title bar row ────────────────────────────────────────────
            HStack {
                Text(viewModel.title)
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // ── Source picker (REQ-024) ───────────────────────────────────
            if let spVM = sourcePickerVM {
                SourcePickerView(viewModel: spVM)
            }

            // ── Record controls (REQ-025) ─────────────────────────────────
            RecordControlsView()

            Spacer()

            // ── Level meter placeholder ───────────────────────────────────
            MixLevelMeterView()

            // ── Encoding jobs footer badge (REQ-030) ─────────────────────
            if let jvm = jobsVM, !jvm.isQueueEmpty {
                HStack {
                    Button {
                        showJobsPopover.toggle()
                    } label: {
                        Label(
                            "\(jvm.runningCount) encoding\(jvm.runningCount == 1 ? "" : "s")…",
                            systemImage: "waveform.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showJobsPopover, arrowEdge: .bottom) {
                        EncodingJobsView(viewModel: jvm)
                            .frame(minWidth: 320)
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }

            Spacer()
                .frame(height: 4)
        }
        .frame(width: 480, height: 320)
        // Sheet: OutputSettingsView (REQ-029).
        // Also opened by MenuBarController via AppStore._shouldShowSettings (REQ-031).
        .sheet(isPresented: $viewModel.showSettings) {
            if let store = appStore {
                OutputSettingsView(isPresented: $viewModel.showSettings, settings: store.settings)
                    .onDisappear {
                        // Reset the menu-bar flag when the sheet is dismissed.
                        store._shouldShowSettings = false
                    }
            }
        }
        // Mirror AppStore._shouldShowSettings → viewModel.showSettings so the
        // menu-bar "Settings…" action can open the sheet.
        .onChange(of: appStore?._shouldShowSettings) { _, newValue in
            if newValue == true {
                viewModel.showSettings = true
            }
        }
        // Post-stop toast (REQ-027) — overlaid at the bottom of the window.
        .overlay(alignment: .bottom) {
            if let tvm = toastVM {
                SaveToast(viewModel: tvm)
            }
        }
        .task {
            // Build the SourcePickerViewModel once when the view appears.
            // We use .task so it runs on the MainActor when the view is
            // first displayed and whenever appStore changes.
            if let store = appStore {
                sourcePickerVM = SourcePickerViewModel(
                    settings: store.settings,
                    permissionManager: store.permissionManager,
                    sourceCatalog: store.sourceCatalog
                )
                // Build SaveToastViewModel wired to the store's encodingQueue.
                toastVM = SaveToastViewModel(queue: store.encodingQueue)
                // Build EncodingJobsViewModel wired to the store's encodingQueue.
                jobsVM = EncodingJobsViewModel(queue: store.encodingQueue)
            }
        }
    }
}

#Preview {
    ContentView()
}
