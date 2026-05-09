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
}

// MARK: - Catalog

/// Enumerates running processes registered with Core Audio.
///
/// Use `refresh()` to repopulate `processes`. The call is cheap and idempotent.
/// Filtered list: excludes `coreaudiod` and any process without a bundle identifier.
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

            // NSRunningApplication lookup may return nil if the process died
            // between the HAL query and this call — that's safe.
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier
            let displayName = app?.localizedName ?? app?.executableURL?.lastPathComponent ?? "Unknown"
            let icon = app?.icon

            // Filter 1: must have a bundle ID (hides raw daemons like coreaudiod)
            guard let bundleID else { continue }

            // Filter 2: explicitly drop coreaudiod even if it somehow has a bundle ID
            guard !displayName.lowercased().contains("coreaudiod") else { continue }

            result.append(AudioProcess(pid: pid, bundleID: bundleID, displayName: displayName, icon: icon))
        }

        processes = result
    }
}
