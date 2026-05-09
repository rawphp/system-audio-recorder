import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

// MARK: - FolderPicker (protocol / test seam)

/// Abstracts `NSOpenPanel` directory selection for testability.
///
/// The production implementation presents the real `NSOpenPanel`; tests inject a
/// `StubFolderPicker` that returns a pre-configured URL without touching AppKit.
public protocol FolderPicker {
    /// Display a folder-selection dialog and return the chosen URL.
    /// Returns `nil` if the user cancels.
    func pickFolder() -> URL?
}

// MARK: - NSOpenPanelFolderPicker (production)

/// Production `FolderPicker` that presents an `NSOpenPanel` configured for
/// directory selection only (no files, no multiple selection).
public final class NSOpenPanelFolderPicker: FolderPicker {
    public init() {}

    public func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Select Output Folder"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - OutputSettingsViewModel

/// Staging view-model for `OutputSettingsView`.
///
/// Holds a *staging copy* of all editable settings so that changes can be
/// discarded (Cancel) or committed (Done) atomically.
///
/// ## Pattern
/// 1. `init(settings:)` snapshots every editable key into `stage*` properties.
/// 2. The view binds controls to `stage*` properties — no live writes to `AppSettings`.
/// 3. `cancel()` is a no-op; staging copies are simply abandoned.
/// 4. `done()` writes every staging value back to `AppSettings`.
///
/// ## Folder picker
/// `selectFolder()` invokes the injected `FolderPicker`. If the user picks a URL
/// it is stored in `stagePendingFolderURL`. `done()` calls
/// `settings.setOutputFolder(_:)` with the pending URL before writing the other
/// staging values.
@Observable
@MainActor
public final class OutputSettingsViewModel {

    // MARK: - Output section

    /// Staged output folder URL chosen by the user (nil = no change pending).
    public var stagePendingFolderURL: URL?

    /// Staged output mode (mixed / separate).
    public var stageOutputMode: AppOutputMode

    /// Staged keep-WAV toggle.
    public var stageKeepWAV: Bool

    // MARK: - Encoding section

    /// Staged bitrate in kbps.
    public var stageBitrate: Int

    /// Staged bitrate mode (VBR / CBR).
    public var stageBitrateMode: BitrateMode

    // MARK: - Auto-stop section

    /// Whether the duration-based auto-stop is enabled.
    public var stageAutoStopDurationEnabled: Bool

    /// Duration in seconds for auto-stop. Preserved even when the toggle is off.
    public var stageAutoStopDuration: Double

    /// Whether the silence-based auto-stop is enabled.
    public var stageAutoStopSilenceEnabled: Bool

    /// Silence duration in seconds for auto-stop. Preserved even when the toggle is off.
    public var stageAutoStopSilence: Double

    // MARK: - App section

    /// Whether the app shows in the Dock.
    public var stageShowInDock: Bool

    // MARK: - Private

    private let settings: AppSettings
    private let folderPicker: FolderPicker

    // MARK: - Initialisers

    /// Production initialiser.
    public convenience init(settings: AppSettings) {
        self.init(settings: settings, folderPicker: NSOpenPanelFolderPicker())
    }

    /// Designated initialiser with injectable seam for testing.
    ///
    /// - Parameters:
    ///   - settings: The settings store to snapshot and later commit to.
    ///   - folderPicker: Provide a `StubFolderPicker` in tests to avoid AppKit panels.
    public init(settings: AppSettings, folderPicker: FolderPicker) {
        self.settings = settings
        self.folderPicker = folderPicker

        // Snapshot all editable keys from settings into stage.
        self.stageBitrate = settings.bitrate
        self.stageBitrateMode = settings.bitrateMode
        self.stageOutputMode = settings.outputMode
        self.stageKeepWAV = settings.keepWAVAfterEncode
        self.stageShowInDock = settings.showInDock

        // Auto-stop: use the stored value (or a friendly default) as the text-field
        // value regardless of the enabled state.
        if let duration = settings.autoStopDurationSeconds {
            self.stageAutoStopDurationEnabled = true
            self.stageAutoStopDuration = duration
        } else {
            self.stageAutoStopDurationEnabled = false
            self.stageAutoStopDuration = 30.0   // friendly default shown in text field
        }

        if let silence = settings.autoStopSilenceSeconds {
            self.stageAutoStopSilenceEnabled = true
            self.stageAutoStopSilence = silence
        } else {
            self.stageAutoStopSilenceEnabled = false
            self.stageAutoStopSilence = 30.0    // friendly default shown in text field
        }
    }

    // MARK: - Public actions

    /// Present the folder picker and store the chosen URL as pending.
    ///
    /// The URL is committed to `AppSettings` only when the user taps Done.
    public func selectFolder() {
        if let url = folderPicker.pickFolder() {
            stagePendingFolderURL = url
        }
    }

    /// Discard all staging changes. The settings store is not mutated.
    public func cancel() {
        // No-op: staging copies are abandoned when the view is dismissed.
    }

    /// Commit all staging values back to `AppSettings`.
    ///
    /// - If a folder was picked during the session, it is stored as a
    ///   security-scoped bookmark first.
    /// - Auto-stop values are written as `Double?` based on their toggle state.
    public func done() {
        // Folder
        if let url = stagePendingFolderURL {
            settings.setOutputFolder(url)
        }

        // Output section
        settings.outputMode = stageOutputMode
        settings.keepWAVAfterEncode = stageKeepWAV

        // Encoding section
        settings.bitrate = stageBitrate
        settings.bitrateMode = stageBitrateMode

        // Auto-stop section
        settings.autoStopDurationSeconds = stageAutoStopDurationEnabled ? stageAutoStopDuration : nil
        settings.autoStopSilenceSeconds = stageAutoStopSilenceEnabled ? stageAutoStopSilence : nil

        // App section
        settings.showInDock = stageShowInDock
    }
}

// MARK: - OutputSettingsView

/// Settings sheet covering folder, bitrate, output mode, hotkey, auto-stop, and app prefs.
///
/// Replaces the placeholder stub created in REQ-023. The sheet is opened by the
/// cog icon in `ContentView` and (later) by "Settings…" in the menu-bar status
/// menu (REQ-031).
///
/// ## Staging pattern
/// All controls bind to `OutputSettingsViewModel`'s `stage*` properties. No
/// change is written to `AppSettings` until the user taps Done.
public struct OutputSettingsView: View {

    @Binding var isPresented: Bool

    @State private var viewModel: OutputSettingsViewModel

    /// Convenience initialiser for ContentView (production path).
    public init(isPresented: Binding<Bool>, settings: AppSettings) {
        self._isPresented = isPresented
        self._viewModel = State(
            initialValue: OutputSettingsViewModel(settings: settings)
        )
    }

    /// Designated initialiser with an injectable view-model (for testing or preview).
    public init(isPresented: Binding<Bool>, viewModel: OutputSettingsViewModel) {
        self._isPresented = isPresented
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {

            // ── Sheet title bar ────────────────────────────────────────────
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Output section ─────────────────────────────────────
                    outputSection

                    Divider()

                    // ── Encoding section ───────────────────────────────────
                    encodingSection

                    Divider()

                    // ── Hotkey section ─────────────────────────────────────
                    hotkeySection

                    Divider()

                    // ── Auto-stop section ──────────────────────────────────
                    autoStopSection

                    Divider()

                    // ── App section ────────────────────────────────────────
                    appSection
                }
                .padding(20)
            }

            Divider()

            // ── Done / Cancel button row ───────────────────────────────────
            HStack {
                Button("Cancel") {
                    viewModel.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") {
                    viewModel.done()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 600)
    }

    // MARK: - Sections

    @ViewBuilder
    private var outputSection: some View {
        SectionHeader("Output")

        // Folder picker row
        HStack {
            Text("Output Folder")
                .frame(width: 120, alignment: .trailing)
            Button(action: { viewModel.selectFolder() }) {
                Text("Choose…")
            }
        }

        // Output mode picker
        HStack {
            Text("Output Mode")
                .frame(width: 120, alignment: .trailing)
            Picker("", selection: $viewModel.stageOutputMode) {
                Text("Mixed").tag(AppOutputMode.mixed)
                Text("Separate").tag(AppOutputMode.separate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Keep WAV toggle
        HStack {
            Text("Keep WAV")
                .frame(width: 120, alignment: .trailing)
            Toggle("Keep source WAV file after encoding", isOn: $viewModel.stageKeepWAV)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var encodingSection: some View {
        SectionHeader("Encoding")

        // Bitrate picker
        HStack {
            Text("Bitrate")
                .frame(width: 120, alignment: .trailing)
            Picker("", selection: $viewModel.stageBitrate) {
                Text("128 kbps").tag(128)
                Text("192 kbps").tag(192)
                Text("256 kbps").tag(256)
                Text("320 kbps").tag(320)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Mode picker
        HStack {
            Text("Mode")
                .frame(width: 120, alignment: .trailing)
            Picker("", selection: $viewModel.stageBitrateMode) {
                Text("VBR").tag(BitrateMode.vbr)
                Text("CBR").tag(BitrateMode.cbr)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
        SectionHeader("Hotkey")

        HStack {
            Text("Toggle Recording")
                .frame(width: 120, alignment: .trailing)
            HotkeyManager.recorder()
        }
    }

    @ViewBuilder
    private var autoStopSection: some View {
        SectionHeader("Auto-Stop")

        // Duration
        HStack {
            Toggle("Duration", isOn: $viewModel.stageAutoStopDurationEnabled)
                .frame(width: 120, alignment: .trailing)
                .toggleStyle(.checkbox)
            TextField(
                "seconds",
                value: $viewModel.stageAutoStopDuration,
                format: .number
            )
            .frame(width: 80)
            .disabled(!viewModel.stageAutoStopDurationEnabled)
            Text("seconds")
                .foregroundStyle(.secondary)
        }

        // Silence threshold
        HStack {
            Toggle("Silence", isOn: $viewModel.stageAutoStopSilenceEnabled)
                .frame(width: 120, alignment: .trailing)
                .toggleStyle(.checkbox)
            TextField(
                "seconds",
                value: $viewModel.stageAutoStopSilence,
                format: .number
            )
            .frame(width: 80)
            .disabled(!viewModel.stageAutoStopSilenceEnabled)
            Text("seconds of silence")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var appSection: some View {
        SectionHeader("App")

        HStack {
            Text("Show in Dock")
                .frame(width: 120, alignment: .trailing)
            Toggle("Show app in the Dock while running", isOn: $viewModel.stageShowInDock)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }
}

// MARK: - SectionHeader

/// Small helper that renders a left-aligned bold section title.
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

// MARK: - Preview

#Preview {
    let defaults = UserDefaults(suiteName: "com.preview.OSV.\(UUID().uuidString)")!
    let settings = AppSettings(
        defaults: defaults,
        bookmarkProvider: SecurityScopedBookmarkProvider()
    )
    var isPresented = true
    let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
    return OutputSettingsView(isPresented: binding, settings: settings)
}
