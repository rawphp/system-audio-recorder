import AppKit
import Observation
import SwiftUI

// MARK: - PickerItem

/// The five items in the source dropdown per spec §4.2.
public enum PickerItem: String, CaseIterable, Equatable, Sendable {
    case everything        = "Everything"
    case everythingPlusMic = "EverythingPlusMic"
    case micOnly           = "MicOnly"
    case specificApp       = "SpecificApp"
    case advanced          = "Advanced"

    public var label: String {
        switch self {
        case .everything:        return "Everything"
        case .everythingPlusMic: return "Everything + Mic"
        case .micOnly:           return "Microphone only"
        case .specificApp:       return "Specific app\u{2026}"
        case .advanced:          return "Advanced\u{2026}"
        }
    }

    /// Returns true if this item involves the microphone.
    var involvesMic: Bool {
        self == .everythingPlusMic || self == .micOnly
    }

    /// Returns true if this item needs the audio tap (everything except mic-only).
    var needsAudioTap: Bool {
        self != .micOnly
    }
}

// MARK: - SourcePickerViewModel

/// `@Observable` view model for `SourcePickerView`.
///
/// Encapsulates all business logic so the SwiftUI view is a thin shell and
/// tests can exercise the model without rendering any UI.
///
/// ## Test seam
/// `overrideAudioTapAvailable`: when non-nil, the model uses this value instead
/// of reading `permissionManager.audioTapStatus`. This lets unit tests control
/// tap availability without needing the real Core Audio probe.
@Observable
@MainActor
public final class SourcePickerViewModel {

    // MARK: - State

    /// The settings key string of the currently selected preset.
    public private(set) var selectedPresetKey: String

    /// Whether the "Specific app…" sheet is presented.
    public var showAppPicker: Bool = false

    /// Whether the "Advanced…" (MixerPanel) sheet is presented.
    public var showMixerPanel: Bool = false

    // MARK: - Available items (fixed order per spec §4.2)

    public let availableItems: [PickerItem] = PickerItem.allCases

    // MARK: - Test seam

    /// When non-nil, overrides `permissionManager.audioTapStatus` for disabled-state
    /// computation. Set this in tests to avoid the real Core Audio probe.
    public var overrideAudioTapAvailable: Bool? = nil

    // MARK: - Dependencies

    private let settings: AppSettings
    private let permissionManager: PermissionManager
    public let sourceCatalog: AudioSourceCatalog

    // MARK: - Init

    public init(
        settings: AppSettings,
        permissionManager: PermissionManager,
        sourceCatalog: AudioSourceCatalog
    ) {
        self.settings = settings
        self.permissionManager = permissionManager
        self.sourceCatalog = sourceCatalog
        self.selectedPresetKey = settings.lastSourcePreset
    }

    // MARK: - Selection

    /// Select a standard picker item (not specific app).
    public func select(_ item: PickerItem) {
        guard item != .specificApp && item != .advanced else { return }
        let key = item.rawValue
        settings.lastSourcePreset = key
        selectedPresetKey = key
    }

    /// Select a specific app process by PID.
    public func selectProcess(pid: pid_t) {
        let key = "SpecificApp:\(pid)"
        settings.lastSourcePreset = key
        selectedPresetKey = key
        showAppPicker = false
    }

    // MARK: - Sheet triggers

    public func openAppPicker() {
        sourceCatalog.refresh()
        showAppPicker = true
    }

    public func openMixerPanel() {
        showMixerPanel = true
    }

    // MARK: - Disabled state

    /// Returns true when the given item should be greyed out / disabled.
    public func isDisabled(_ item: PickerItem) -> Bool {
        let micDenied = permissionManager.microphoneStatus == .denied
            || permissionManager.microphoneStatus == .restricted

        let tapAvailable: Bool
        if let override = overrideAudioTapAvailable {
            tapAvailable = override
        } else {
            tapAvailable = permissionManager.audioTapStatus == .available
        }

        // Items that involve the mic are greyed when mic is denied.
        if item.involvesMic && micDenied { return true }

        // Items that need the audio tap are greyed when tap is unavailable.
        if item.needsAudioTap && !tapAvailable { return true }

        return false
    }

    // MARK: - Mic-denied affordance

    /// Returns true when the inline "Mic access denied — Open Settings" affordance
    /// should be shown for the given item.
    public func showMicDeniedAffordance(for item: PickerItem) -> Bool {
        guard item.involvesMic else { return false }
        return permissionManager.microphoneStatus == .denied
            || permissionManager.microphoneStatus == .restricted
    }

    // MARK: - Open System Settings for microphone

    public func openMicrophoneSettings() {
        NSWorkspace.shared.open(PermissionDeepLink.microphoneSettingsURL)
    }

    // MARK: - Display label for current selection

    /// Human-readable description of the active preset for the Menu button label.
    public var currentSelectionLabel: String {
        let key = selectedPresetKey
        if key.hasPrefix("SpecificApp:") {
            let pidStr = String(key.dropFirst("SpecificApp:".count))
            if let pid = pid_t(pidStr),
               let process = sourceCatalog.processes.first(where: { $0.pid == pid }) {
                return process.displayName
            }
            return "Specific app"
        }
        switch key {
        case "Everything":         return "Everything"
        case "EverythingPlusMic":  return "Everything + Mic"
        case "MicOnly":            return "Microphone only"
        default:                   return "Everything"
        }
    }
}

// MARK: - AppPickerView (inline app selector)

/// Minimal app picker: lists catalog processes and lets the user pick one.
struct AppPickerView: View {
    @Binding var isPresented: Bool
    let catalog: AudioSourceCatalog
    let onSelect: (pid_t) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Choose an app")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if catalog.processes.isEmpty {
                VStack {
                    Spacer()
                    Text("No audio-emitting apps found.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(catalog.processes, id: \.pid) { process in
                    Button {
                        onSelect(process.pid)
                    } label: {
                        HStack {
                            if let icon = process.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            Text(process.displayName)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 300, height: 360)
    }
}

// MARK: - SourcePickerView

/// SwiftUI `Menu` that renders the source dropdown per spec §4.2.
///
/// This view is a thin shell over `SourcePickerViewModel`. All business logic
/// (disabled states, persistence, permission checks) lives in the view model.
///
/// REQ-023's stub `SourcePickerView` is replaced by this real implementation.
public struct SourcePickerView: View {
    @State private var viewModel: SourcePickerViewModel

    public init(viewModel: SourcePickerViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        HStack {
            Text("Recording from:")
                .foregroundStyle(.secondary)

            Menu(viewModel.currentSelectionLabel) {
                // 1. Everything
                everythingButton

                // 2. Everything + Mic
                everythingPlusMicButton

                // 3. Microphone only
                micOnlyButton

                Divider()

                // 4. Specific app…
                specificAppButton

                // 5. Advanced…
                advancedButton
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal)
        // Sheet: App picker (AC #5)
        .sheet(isPresented: $viewModel.showAppPicker) {
            AppPickerView(
                isPresented: $viewModel.showAppPicker,
                catalog: viewModel.sourceCatalog,
                onSelect: { pid in viewModel.selectProcess(pid: pid) }
            )
        }
        // Sheet: Mixer panel — REQ-028 stub (AC #6)
        .sheet(isPresented: $viewModel.showMixerPanel) {
            MixerPanelView(isPresented: $viewModel.showMixerPanel)
        }
    }

    // MARK: - Menu item helpers

    @ViewBuilder
    private var everythingButton: some View {
        let item = PickerItem.everything
        let disabled = viewModel.isDisabled(item)
        Button {
            viewModel.select(item)
        } label: {
            menuItemLabel(item)
        }
        .disabled(disabled)
    }

    @ViewBuilder
    private var everythingPlusMicButton: some View {
        let item = PickerItem.everythingPlusMic
        let disabled = viewModel.isDisabled(item)
        if viewModel.showMicDeniedAffordance(for: item) {
            // Show the inline "mic denied" affordance instead of the normal item
            micDeniedAffordanceButton(label: item.label)
        } else {
            Button {
                viewModel.select(item)
            } label: {
                menuItemLabel(item)
            }
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private var micOnlyButton: some View {
        let item = PickerItem.micOnly
        let disabled = viewModel.isDisabled(item)
        if viewModel.showMicDeniedAffordance(for: item) {
            micDeniedAffordanceButton(label: item.label)
        } else {
            Button {
                viewModel.select(item)
            } label: {
                menuItemLabel(item)
            }
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private var specificAppButton: some View {
        let item = PickerItem.specificApp
        let disabled = viewModel.isDisabled(item)
        Button {
            viewModel.openAppPicker()
        } label: {
            Text(item.label)
        }
        .disabled(disabled)
    }

    @ViewBuilder
    private var advancedButton: some View {
        Button {
            viewModel.openMixerPanel()
        } label: {
            Text(PickerItem.advanced.label)
        }
    }

    /// Renders a menu-item label with a leading checkmark when selected, plain text otherwise.
    /// Avoids passing an empty string to `Label(systemImage:)`, which logs a SwiftUI fault.
    @ViewBuilder
    private func menuItemLabel(_ item: PickerItem) -> some View {
        if viewModel.selectedPresetKey == selectedKeyForItem(item) {
            Label(item.label, systemImage: "checkmark")
        } else {
            Text(item.label)
        }
    }

    private func selectedKeyForItem(_ item: PickerItem) -> String {
        item.rawValue
    }

    @ViewBuilder
    private func micDeniedAffordanceButton(label: String) -> some View {
        Button {
            viewModel.openMicrophoneSettings()
        } label: {
            Label("\(label) — Mic access denied — Open Settings", systemImage: "exclamationmark.triangle")
        }
        .foregroundStyle(.secondary)
    }
}
