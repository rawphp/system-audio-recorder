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
                    NSWorkspace.shared.open(UserGuide.url)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open User Guide")
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
        // Banner stack (REQ-033) — overlaid at the top of the window.
        .overlay(alignment: .top) {
            if let store = appStore {
                BannerStackView(errorSurface: store.errorSurface)
                    .padding(.top, 4)
            }
        }
        // Fatal alert (REQ-033) — modal when errorSurface.currentAlert is non-nil.
        .alert(
            appStore?.errorSurface.currentAlert?.title ?? "",
            isPresented: Binding(
                get: { appStore?.errorSurface.currentAlert != nil },
                set: { if !$0 { appStore?.errorSurface.dismissAlert() } }
            )
        ) {
            if let alert = appStore?.errorSurface.currentAlert {
                Button(alert.primaryButton, role: .cancel) {
                    appStore?.errorSurface.dismissAlert()
                }
                if let secondary = alert.secondaryButton, let pane = alert.secondaryAction {
                    Button(secondary) {
                        NSWorkspace.shared.open(pane.url)
                        appStore?.errorSurface.dismissAlert()
                    }
                }
            }
        } message: {
            if let msg = appStore?.errorSurface.currentAlert?.message {
                Text(msg)
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
                // Build SaveToastViewModel wired to the store's encodingQueue
                // and immediately start its observer — observation must not depend
                // on SaveToast's view lifecycle because that `.task` does not fire
                // when toastState == .hidden (body resolves to EmptyView).
                let tvm = SaveToastViewModel(queue: store.encodingQueue)
                tvm.start()
                toastVM = tvm
                // Build EncodingJobsViewModel wired to the store's encodingQueue.
                jobsVM = EncodingJobsViewModel(queue: store.encodingQueue)
            }
        }
    }
}

// MARK: - BannerStackView (REQ-033)

/// Renders up to 3 non-fatal / background banners from `ErrorSurface.banners`.
/// A "+N more" label is shown when `collapsedCount > 0`.
public struct BannerStackView: View {
    var errorSurface: ErrorSurface

    public var body: some View {
        VStack(spacing: 4) {
            ForEach(errorSurface.banners) { banner in
                BannerRow(banner: banner, errorSurface: errorSurface)
            }
            if errorSurface.collapsedCount > 0 {
                Text("+\(errorSurface.collapsedCount) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// A single banner row with an optional dismiss X button.
private struct BannerRow: View {
    let banner: AppBanner
    var errorSurface: ErrorSurface

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(banner.message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if banner.dismissible {
                Button {
                    errorSurface.dismiss(banner: banner.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

#Preview {
    ContentView()
}
