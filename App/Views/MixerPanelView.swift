import AppKit
import Observation
import SwiftUI

// MARK: - MixerRow

/// State for a single row in the Advanced mixer panel.
///
/// Each row corresponds to either a running audio-emitting process (from
/// `AudioSourceCatalog`) or the synthetic microphone row added at the bottom.
public struct MixerRow: Identifiable {
    /// Stable identifier. Process rows use `"pid:<pid>"`; mic row uses `"mic"`.
    public let id: String
    /// Human-readable name shown in the row.
    public let name: String
    /// App icon (nil for the mic row or processes without an icon).
    public let icon: NSImage?
    /// Whether this source is included in the Advanced mix.
    public var selected: Bool
    /// Per-source gain in the range 0.0 – 2.0. Default is 1.0 (0 dBFS).
    public var gain: Float

    public init(id: String, name: String, icon: NSImage? = nil, selected: Bool = false, gain: Float = 1.0) {
        self.id = id
        self.name = name
        self.icon = icon
        self.selected = selected
        self.gain = gain
    }
}

// MARK: - MixerPanelViewModel

/// `@Observable` view model for the Advanced mixer panel.
///
/// Builds a flat list of `MixerRow`s from the current `AudioSourceCatalog`
/// entries plus a synthetic microphone row at the bottom.
///
/// **Apply / Cancel semantics:**
/// - `apply()` persists the current selection and gain values to `AppSettings`,
///   and sets `AppSettings.lastSourcePreset` to `"Advanced"`.
/// - `cancel()` discards in-panel changes; the previous preset remains in settings.
///
/// **Live gain propagation:**
/// `setGain(forID:to:)` updates `row.gain` immediately and, if a session is
/// actively recording, calls `appStore.currentSession?.mixer.setGain(...)` so
/// the change reaches the engine within one buffer (~10 ms).
@Observable
@MainActor
public final class MixerPanelViewModel {

    // MARK: - State

    /// All rows in display order: catalog processes first, mic row last.
    ///
    /// The array is mutable so SwiftUI bindings can toggle `selected` and update
    /// `gain` directly on each element. Use `setGain(forID:to:)` for live gain
    /// changes during a recording session — it also propagates to the engine.
    public var rows: [MixerRow]

    // MARK: - Dependencies

    private let appStore: AppStore
    private let settings: AppSettings

    // MARK: - Init

    public init(appStore: AppStore, settings: AppSettings) {
        self.appStore = appStore
        self.settings = settings
        self.rows = MixerPanelViewModel.buildRows(from: appStore.sourceCatalog.processes)
    }

    // MARK: - Row builder

    private static func buildRows(from processes: [AudioProcess]) -> [MixerRow] {
        var result: [MixerRow] = processes.map { proc in
            MixerRow(
                id: "pid:\(proc.pid)",
                name: proc.displayName,
                icon: proc.icon,
                selected: false,
                gain: 1.0
            )
        }
        result.append(MixerRow(id: "mic", name: "Microphone", icon: nil, selected: false, gain: 1.0))
        return result
    }

    // MARK: - Computed

    /// True when the mic row should be greyed out (permission denied / restricted).
    public var isMicRowGreyed: Bool {
        let status = appStore.permissionManager.microphoneStatus
        return status == .denied || status == .restricted
    }

    // MARK: - Gain

    /// Mutate the gain for a given row ID.
    ///
    /// If a recording session is active, the gain change is forwarded to the
    /// mixer engine immediately (~10 ms latency per REQ-010 spec §5.3).
    public func setGain(forID id: String, to gain: Float) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].gain = gain
        // Live gain propagation when recording
        // (REQ-010: MixerGraph.setGain is called via RecordingSession.mixer)
        // The session actor exposes setGain via a nonisolated wrapper; we
        // call it here for the ~10 ms AC requirement.
        Task {
            await appStore.currentSession?.setGain(forSource: id, gain: gain)
        }
    }

    // MARK: - Apply

    /// Persist selections and gains to `AppSettings`, then set the preset to "Advanced".
    public func apply() {
        let selectedIDs = rows.filter(\.selected).map(\.id)
        var gains: [String: Float] = [:]
        for row in rows {
            gains[row.id] = row.gain
        }

        settings.advancedSourceIDs = selectedIDs
        settings.advancedGains = gains
        settings.lastSourcePreset = "Advanced"
    }

    // MARK: - Cancel

    /// Discard in-panel changes. The previous preset remains in settings.
    public func cancel() {
        // No writes — the previous AppSettings values stay as-is.
    }
}

// MARK: - MixerPanelView

/// Advanced multi-source mixer panel opened when the user selects "Advanced…"
/// from the source dropdown.
///
/// Displays a vertical list of selectable audio sources (each with checkbox,
/// app icon, app name, per-source level meter, and a gain slider 0.0–2.0).
/// A microphone row is appended at the bottom and is greyed when mic permission
/// is denied (spec §4.6, §6.5).
///
/// All business logic lives in `MixerPanelViewModel`; this view is a thin shell.
public struct MixerPanelView: View {

    @Binding var isPresented: Bool
    @Environment(\.appStore) private var appStore

    @State private var viewModel: MixerPanelViewModel?

    public init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    public var body: some View {
        Group {
            if let vm = viewModel {
                panelContent(vm: vm)
            } else {
                ProgressView()
                    .padding(40)
            }
        }
        .task {
            guard let store = appStore else { return }
            // Refresh the catalog so rows are up-to-date
            store.sourceCatalog.refresh()
            viewModel = MixerPanelViewModel(appStore: store, settings: store.settings)
        }
    }

    // MARK: - Panel content

    @ViewBuilder
    private func panelContent(vm: MixerPanelViewModel) -> some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Advanced Mixer")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Source rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($viewModel.wrappedValue!.rows) { row in
                        sourceRow(vm: vm, row: row)
                        Divider()
                    }
                }
            }

            Divider()

            // OK / Cancel buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    vm.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    vm.apply()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 300)
    }

    // MARK: - Individual source row

    @ViewBuilder
    private func sourceRow(vm: MixerPanelViewModel, row: MixerRow) -> some View {
        let isMic = row.id == "mic"
        let isGreyed = isMic && vm.isMicRowGreyed

        HStack(spacing: 12) {
            // Checkbox
            Toggle(isOn: Binding(
                get: { vm.rows.first(where: { $0.id == row.id })?.selected ?? false },
                set: { newValue in
                    if let idx = vm.rows.firstIndex(where: { $0.id == row.id }) {
                        vm.rows[idx].selected = newValue
                    }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .disabled(isGreyed)

            // App icon
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else if isMic {
                Image(systemName: "mic.fill")
                    .frame(width: 20, height: 20)
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
            }

            // Name
            Text(row.name)
                .lineLimit(1)
                .frame(minWidth: 80, alignment: .leading)

            // Per-source level meter (reads from AppStore.meters)
            InlineMeterView(sourceID: row.id)

            // Gain slider
            VStack(alignment: .trailing, spacing: 2) {
                Slider(
                    value: Binding(
                        get: { Double(vm.rows.first(where: { $0.id == row.id })?.gain ?? 1.0) },
                        set: { vm.setGain(forID: row.id, to: Float($0)) }
                    ),
                    in: 0.0...2.0
                )
                .frame(width: 120)
                .disabled(isGreyed)

                // Numeric readout in dB (gain 1.0 == 0 dB; 2.0 == +6 dB; 0.0 == -∞)
                Text(gainLabel(for: vm.rows.first(where: { $0.id == row.id })?.gain ?? 1.0))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .opacity(isGreyed ? 0.4 : 1.0)
    }

    // MARK: - Gain label helper

    /// Converts a linear gain (0.0–2.0) to a human-readable dB string.
    ///
    /// - gain 0.0  → "-∞ dB"
    /// - gain 1.0  →  "0.0 dB"
    /// - gain 2.0  → "+6.0 dB"
    private func gainLabel(for gain: Float) -> String {
        guard gain > 0 else { return "-∞ dB" }
        let db = 20.0 * log10(Double(gain))
        let formatted = String(format: "%+.1f dB", db)
        return formatted
    }
}

// MARK: - InlineMeterView

/// A small inline level meter for a single source.
///
/// Reads the source's dBFS value from `AppStore.meters.meters[sourceID]`
/// and delegates to `MeterMath` for colour and fill (reusing REQ-026 helpers).
private struct InlineMeterView: View {

    let sourceID: String
    @Environment(\.appStore) private var appStore

    private var currentDBFS: Double {
        guard let store = appStore else { return -.infinity }
        switch store.sessionState {
        case .recording, .paused:
            return Double(store.meters.meters[sourceID] ?? -.infinity as Float)
        default:
            return -.infinity
        }
    }

    var body: some View {
        let db = currentDBFS
        let fraction = MeterMath.barFillFraction(forDBFS: db)
        let color = MeterMath.meterColor(forDBFS: db)

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 6)
                if fraction > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: proxy.size.width * fraction, height: 6)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 80, height: 10)
    }
}
