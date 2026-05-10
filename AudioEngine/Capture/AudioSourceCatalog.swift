import CoreAudio
import AppKit
import Observation

// MARK: - Data Model

/// A snapshot of a running process that has registered with Core Audio.
public struct AudioProcess: Equatable {
    public let pid: pid_t
    public let bundleID: String?
    public let displayName: String
    public let icon: NSImage?

    public static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

// MARK: - Provider Protocol (enables dependency injection for unit tests)

/// Abstracts the Core Audio HAL queries so tests can inject a mock.
public protocol ProcessListProvider {
    /// Returns the AudioObjectIDs for all audio-registered processes.
    func audioProcessObjectIDs() -> [AudioObjectID]
    /// Returns the PID for a given AudioObjectID, or nil on failure.
    func pid(for objectID: AudioObjectID) -> pid_t?
    /// Returns the bundle identifier (`kAudioProcessPropertyBundleID`) for a
    /// given audio process object, or nil on HAL error / when the property is
    /// unavailable. Sourcing bundle ID from Core Audio (rather than NSWorkspace)
    /// is what lets the catalog include audio-emitting helper PIDs that
    /// `NSRunningApplication(processIdentifier:)` does not resolve — see UR-004.
    func bundleID(for objectID: AudioObjectID) -> String?
    /// Returns a human-readable executable name for the audio process object,
    /// or nil when none is available. Used as a display-name fallback when
    /// NSRunningApplication has no entry for the pid. Core Audio does not
    /// currently expose an exec-name property, so the real HAL implementation
    /// returns nil and the catalog falls back to the bundle ID's last component.
    func executableName(for objectID: AudioObjectID) -> String?
}

// Default-nil implementations let pre-existing test mocks satisfy the
// protocol without modification — the catalog falls back to NSRunningApplication
// when these return nil.
public extension ProcessListProvider {
    func bundleID(for objectID: AudioObjectID) -> String? { nil }
    func executableName(for objectID: AudioObjectID) -> String? { nil }
}

// MARK: - Real HAL Implementation

public struct HALProcessListProvider: ProcessListProvider {

    public init() {}

    public func audioProcessObjectIDs() -> [AudioObjectID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &objectIDs
        )

        guard status == noErr else { return [] }
        return objectIDs
    }

    public func pid(for objectID: AudioObjectID) -> pid_t? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)

        let status = AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &pid
        )

        return status == noErr ? pid : nil
    }

    public func bundleID(for objectID: AudioObjectID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfString: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &cfString
        )

        guard status == noErr, let cfString = cfString?.takeRetainedValue() else { return nil }
        let result = cfString as String
        return result.isEmpty ? nil : result
    }

    // Core Audio does not expose an executable-name property; return nil and
    // let the catalog fall back to other display-name sources.
    public func executableName(for objectID: AudioObjectID) -> String? { nil }
}

// MARK: - Catalog

/// Enumerates running processes registered with Core Audio.
///
/// Use `refresh()` to repopulate `processes`. The call is cheap and idempotent.
/// Filtered list: excludes `coreaudiod` and any process without a bundle identifier.
///
/// Bundle ID resolution prefers the HAL (`kAudioProcessPropertyBundleID`) over
/// `NSRunningApplication` so audio-emitting helper PIDs (e.g. Chromium renderer
/// helpers) that NSWorkspace does not surface are still included — see UR-004.
@Observable
public final class AudioSourceCatalog {

    public var processes: [AudioProcess] = []

    private let provider: ProcessListProvider

    /// Designated init. Uses the real HAL provider by default.
    public init(provider: ProcessListProvider = HALProcessListProvider()) {
        self.provider = provider
    }

    /// Queries the HAL for the current process list and updates `processes`.
    public func refresh() {
        let objectIDs = provider.audioProcessObjectIDs()

        var result: [AudioProcess] = []
        result.reserveCapacity(objectIDs.count)

        for objectID in objectIDs {
            guard let pid = provider.pid(for: objectID) else { continue }

            // NSRunningApplication is best-effort enrichment for localizedName
            // and icon. Its absence (common for Chromium helper PIDs) MUST NOT
            // drop the process — bundle ID and display name fall back through
            // HAL-sourced values below.
            let app = NSRunningApplication(processIdentifier: pid)

            // Effective bundle ID: HAL first, NSRunningApplication as fallback.
            // Drop the process only if both are nil/empty — preserves the
            // coreaudiod / raw-daemon filter while admitting helper PIDs.
            let halBundleID = provider.bundleID(for: objectID)
            let nsBundleID = app?.bundleIdentifier
            guard let bundleID = halBundleID ?? nsBundleID, !bundleID.isEmpty else { continue }

            // Display-name fallback chain:
            //   1. NSRunningApplication.localizedName  (best UX when available)
            //   2. HAL executable name                  (may be nil today)
            //   3. bundle ID's last `.`-separated component
            //   4. "Process <pid>"                      (last resort)
            let halExecName = provider.executableName(for: objectID)
            let displayName: String =
                app?.localizedName
                ?? halExecName
                ?? bundleID.split(separator: ".").last.map(String.init)
                ?? "Process \(pid)"

            // coreaudiod filter: by bundle ID (canonical) and by display-name
            // substring (belt-and-braces, in case Apple ever ships a different
            // bundle for the same daemon).
            if bundleID == "com.apple.audio.coreaudiod" { continue }
            if displayName.lowercased().contains("coreaudiod") { continue }

            result.append(AudioProcess(
                pid: pid,
                bundleID: bundleID,
                displayName: displayName,
                icon: app?.icon
            ))
        }

        processes = result
    }
}
