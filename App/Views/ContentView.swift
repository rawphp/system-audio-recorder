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

/// Placeholder for the big record/pause/stop button (REQ-025 replaces this).
// TODO: REQ-025 replaces this
struct RecordControlsView: View {
    var body: some View {
        Button {
            // TODO: REQ-025 wires toggleRecording()
        } label: {
            Label("Start Recording", systemImage: "record.circle")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 40)
    }
}

/// Placeholder for the unified mix-level meter + dB readout (REQ-026 replaces this).
// TODO: REQ-026 replaces this
struct MixLevelMeterView: View {
    var body: some View {
        HStack {
            // Simulated idle bar graphic
            ForEach(1...8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 6, height: CGFloat(i * 4))
            }
            Spacer()
            Text("-∞ dB")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

/// Placeholder for the output-settings sheet (REQ-029 replaces this).
// TODO: REQ-029 replaces this
struct OutputSettingsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Output Settings")
                .font(.headline)
            Text("Settings UI coming in REQ-029.")
                .foregroundStyle(.secondary)
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}

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

            // ── Record controls placeholder ───────────────────────────────
            RecordControlsView() // TODO: REQ-025 replaces this

            Spacer()

            // ── Level meter placeholder ───────────────────────────────────
            MixLevelMeterView() // TODO: REQ-026 replaces this

            Spacer()
                .frame(height: 4)
        }
        .frame(width: 480, height: 320)
        // Sheet: OutputSettingsView (REQ-029 replaces placeholder)
        .sheet(isPresented: $viewModel.showSettings) {
            OutputSettingsView(isPresented: $viewModel.showSettings)
                // TODO: REQ-029 replaces OutputSettingsView placeholder
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
            }
        }
    }
}

#Preview {
    ContentView()
}
