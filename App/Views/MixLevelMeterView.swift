import SwiftUI

// MARK: - MeterMath

/// Pure helpers for converting dBFS to visual and textual representations.
/// Extracted from MixLevelMeterView to keep the logic unit-testable.
public enum MeterMath {

    /// The source ID used by MixerGraph (REQ-010) / MeterPublisher (REQ-011)
    /// for the unified mix bus output tap.
    public static let mixSourceID = "mix"

    /// Maps a dBFS value linearly to a fill fraction in [0, 1].
    ///
    /// - Returns: 0.0 for `db <= -60` or `db == -.infinity`; 1.0 for `db >= 0`;
    ///   linear interpolation otherwise.
    public static func barFillFraction(forDBFS db: Double) -> Double {
        guard db.isFinite, db > -60.0 else { return 0.0 }
        if db >= 0.0 { return 1.0 }
        // Linear map from [-60, 0] → [0.0, 1.0]
        return (db + 60.0) / 60.0
    }

    /// Returns the SwiftUI `Color` appropriate for a given dBFS level.
    ///
    /// Colour bands (spec §4.1):
    /// - green  : `db <= -12`
    /// - yellow : `-12 < db < -3`
    /// - red    : `db >= -3`
    ///
    /// Edge cases: exactly -12 is green; exactly -3 is red.
    public static func meterColor(forDBFS db: Double) -> Color {
        if db >= -3.0 { return .red }
        if db > -12.0 { return .yellow }
        return .green
    }

    /// Returns the display string for a dBFS value.
    ///
    /// - Returns: `"-∞ dB"` when `db == -.infinity` or `db <= -60`;
    ///   otherwise `"\(rounded integer) dB"` (e.g. `"-12 dB"`).
    public static func displayString(forDBFS db: Double) -> String {
        guard db.isFinite, db > -60.0 else { return "-∞ dB" }
        let rounded = Int(db.rounded())
        return "\(rounded) dB"
    }
}

// MARK: - MixLevelMeterView

/// Unified mix-level meter: a horizontal colour-banded bar with a numeric dB
/// readout. Driven by `AppStore.meters["mix"]` at the MeterPublisher's 50 Hz
/// update rate.
///
/// **Idle rendering** (no active session or inactive session state):
/// Shows an empty bar and the text `"-∞ dB"`.
///
/// **Live rendering** (session is `.recording` or `.paused`):
/// Shows the bar filled proportionally to the current mix RMS level, coloured
/// green/yellow/red, and the rounded dB string to the right.
///
/// **Pause behaviour** (REQ-061): The meter stays *live* during pause —
/// underlying source emitters and the mixer keep running while paused (the
/// WAV writer drops buffers but the mix-bus stream continues to fan out to
/// the meter sink). This matches the "live during pause" contract documented
/// above; no special freeze state is required.
public struct MixLevelMeterView: View {

    @Environment(\.appStore) private var appStore

    public init() {}

    // MARK: - Derived state

    /// True when a session is actively capturing (recording or paused).
    private var isActive: Bool {
        guard let store = appStore else { return false }
        switch store.sessionState {
        case .recording, .paused: return true
        default:                  return false
        }
    }

    /// Current mix dBFS, or -∞ when idle / no data.
    private var currentDBFS: Double {
        guard isActive,
              let store = appStore,
              let raw = store.meters.meters[MeterMath.mixSourceID]
        else { return -.infinity }
        return Double(raw)
    }

    // MARK: - View

    public var body: some View {
        let db = currentDBFS
        let fraction = MeterMath.barFillFraction(forDBFS: db)
        let color    = MeterMath.meterColor(forDBFS: db)
        let label    = MeterMath.displayString(forDBFS: db)

        HStack(spacing: 8) {
            // Filled bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 10)

                    // Fill
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: proxy.size.width * fraction, height: 10)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            // Numeric readout
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal)
    }
}

#Preview {
    VStack(spacing: 16) {
        // Idle
        MixLevelMeterView()
        // (No live preview without an AppStore injection; idle state is shown)
    }
    .frame(width: 480)
    .padding()
}
