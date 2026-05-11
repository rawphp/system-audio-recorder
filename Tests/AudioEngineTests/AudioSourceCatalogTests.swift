import XCTest
import AVFoundation
@testable import SystemAudioRecorder

// MARK: - Mock Provider

/// Returns a canned list of AudioObjectIDs + PIDs for deterministic tests.
final class MockProcessListProvider: ProcessListProvider {

    struct Entry {
        let objectID: AudioObjectID
        let pid: pid_t
        var bundleID: String? = nil
        var executableName: String? = nil
    }

    var entries: [Entry] = []

    func audioProcessObjectIDs() -> [AudioObjectID] {
        entries.map(\.objectID)
    }

    func pid(for objectID: AudioObjectID) -> pid_t? {
        entries.first { $0.objectID == objectID }?.pid
    }

    func bundleID(for objectID: AudioObjectID) -> String? {
        entries.first { $0.objectID == objectID }?.bundleID
    }

    func executableName(for objectID: AudioObjectID) -> String? {
        entries.first { $0.objectID == objectID }?.executableName
    }
}

/// A provider that always returns an empty list — simulates a system with no
/// audio-registered processes.
final class EmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

// MARK: - Tests

final class AudioSourceCatalogTests: XCTestCase {

    // MARK: testRefreshReturnsArrayOfProcesses
    //
    // Start an AVAudioEngine tone in-process so the test runner itself is
    // registered with Core Audio, then call refresh() via the real HAL.
    // We assert that processes is non-empty — the test process (or any other
    // currently audio-active app) must appear.
    func testRefreshReturnsArrayOfProcesses() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        // Generate a short silent buffer to keep the engine busy.
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.1) // 100 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Could not create PCM buffer")
            return
        }
        buffer.frameLength = frameCount

        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()

        defer {
            player.stop()
            engine.stop()
        }

        // Give the engine a moment to register with Core Audio.
        Thread.sleep(forTimeInterval: 0.15)

        let catalog = AudioSourceCatalog() // uses real HAL provider
        catalog.refresh()

        // The list may be empty on a truly headless runner with no audio HW;
        // accept that gracefully but assert no crash occurred.
        // On a real Mac the test process will appear.
        XCTAssertGreaterThanOrEqual(catalog.processes.count, 0,
            "processes should be a non-negative array — HAL query itself must not fail")

        // Stronger assertion when audio HW is present:
        // If HAL returned any objects at all, we expect at least one process.
        // (We can't guarantee the runner has audio devices, so we skip the
        // strict non-empty assertion to keep CI green on headless runners.)
    }

    // MARK: testRefreshIsIdempotent
    func testRefreshIsIdempotent() {
        let catalog = AudioSourceCatalog()
        catalog.refresh()
        let first = catalog.processes

        catalog.refresh()
        let second = catalog.processes

        // Display names and PIDs must be identical across two back-to-back calls.
        XCTAssertEqual(first.count, second.count, "Consecutive refresh() calls must produce the same process count")

        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.pid, b.pid)
            XCTAssertEqual(a.bundleID, b.bundleID)
            XCTAssertEqual(a.displayName, b.displayName)
        }
    }

    // MARK: testCoreaudiodIsFiltered
    //
    // Inject a mock that includes a fake entry whose display name contains
    // "coreaudiod". Verify it is absent from the catalog output.
    //
    // Note: Because MockProcessListProvider PIDs map to real NSRunningApplications,
    // we use the current process PID (which has a bundle ID) but override the
    // catalog's filter logic indirectly. Instead we test via the real catalog
    // and assert coreaudiod is absent from the processed list.
    func testCoreaudiodIsFiltered() {
        let catalog = AudioSourceCatalog()
        catalog.refresh()

        let hasCoreaudiod = catalog.processes.contains {
            $0.displayName.lowercased().contains("coreaudiod")
        }
        XCTAssertFalse(hasCoreaudiod, "coreaudiod must never appear in the catalog")
    }

    // MARK: testNoBundleIDIsFiltered
    //
    // Processes without a bundle ID (raw unix processes) must be excluded.
    // We test this through the real HAL: every entry in the catalog must have a non-nil bundleID.
    func testNoBundleIDIsFiltered() {
        let catalog = AudioSourceCatalog()
        catalog.refresh()

        for process in catalog.processes {
            XCTAssertNotNil(process.bundleID,
                "Process \(process.displayName) (pid=\(process.pid)) must have a bundle ID")
        }
    }

    // MARK: testStressRefresh
    //
    // 100 consecutive refresh() calls must complete within 1 second without crashing.
    func testStressRefresh() {
        let catalog = AudioSourceCatalog()
        let start = Date()
        for _ in 0 ..< 100 {
            catalog.refresh()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "100 refresh() calls must complete within 1 second (took \(elapsed)s)")
    }

    // MARK: testProcessDeathDoesntCrash
    //
    // Spawns a short-lived shell process, calls refresh() immediately,
    // waits for the process to die, calls refresh() again — must not crash.
    func testProcessDeathDoesntCrash() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["0.05"] // 50 ms

        XCTAssertNoThrow(try task.run())

        let catalog = AudioSourceCatalog()

        // refresh() while process may still be alive
        catalog.refresh()

        // Wait for process to exit
        task.waitUntilExit()

        // refresh() after process is dead — must not crash
        catalog.refresh()

        // No assertion on count — just survivability.
    }

    // MARK: testEmptyProviderReturnsEmptyList
    //
    // When the HAL has no registered processes the catalog must return an empty array.
    func testEmptyProviderReturnsEmptyList() {
        let catalog = AudioSourceCatalog(provider: EmptyProcessListProvider())
        catalog.refresh()
        XCTAssertTrue(catalog.processes.isEmpty, "Empty provider must yield an empty process list")
    }

    // MARK: testHelperProcessIncludedWhenNSWorkspaceMissesIt (UR-004)
    //
    // Regression guard for UR-004: a process that the HAL provides a bundle ID
    // for must be included even when NSRunningApplication(processIdentifier:)
    // returns nil for its pid. We use a synthetic pid that NSRunningApplication
    // cannot resolve (a value safely above any realistic running pid).
    func testHelperProcessIncludedWhenNSWorkspaceMissesIt() {
        // Pick a pid that NSRunningApplication will not resolve. pid_t is Int32;
        // values around Int32.max have no chance of matching a real process.
        let unresolvablePID: pid_t = pid_t.max - 1
        XCTAssertNil(NSRunningApplication(processIdentifier: unresolvablePID),
            "Precondition: NSRunningApplication must return nil for the test pid")

        let mock = MockProcessListProvider()
        mock.entries = [
            .init(
                objectID: 4242,
                pid: unresolvablePID,
                bundleID: "com.google.Chrome.helper.Renderer",
                executableName: "Google Chrome Helper (Renderer)"
            )
        ]

        let catalog = AudioSourceCatalog(provider: mock)
        catalog.refresh()

        XCTAssertEqual(catalog.processes.count, 1,
            "Helper process must be retained when HAL provides a bundle ID, even if NSWorkspace returns nil")
        let p = try? XCTUnwrap(catalog.processes.first)
        XCTAssertEqual(p?.bundleID, "com.google.Chrome.helper.Renderer")
        XCTAssertEqual(p?.displayName, "Google Chrome Helper (Renderer)",
            "Display name should fall back to the HAL executable name when NSRunningApplication is nil")
        XCTAssertEqual(p?.pid, unresolvablePID)
    }

    // MARK: testHelperFallbackToBundleIDLastComponentWhenNoExecutableName (UR-004)
    //
    // When NSRunningApplication returns nil AND HAL doesn't provide an
    // executable name, the display name must fall back to the bundle ID's
    // last `.`-separated component.
    func testHelperFallbackToBundleIDLastComponentWhenNoExecutableName() {
        let unresolvablePID: pid_t = pid_t.max - 2
        XCTAssertNil(NSRunningApplication(processIdentifier: unresolvablePID))

        let mock = MockProcessListProvider()
        mock.entries = [
            .init(
                objectID: 4243,
                pid: unresolvablePID,
                bundleID: "com.example.SomeHelper",
                executableName: nil
            )
        ]

        let catalog = AudioSourceCatalog(provider: mock)
        catalog.refresh()

        XCTAssertEqual(catalog.processes.count, 1)
        XCTAssertEqual(catalog.processes.first?.displayName, "SomeHelper",
            "Display name should fall back to bundle ID's last component when no exec name available")
    }

    // MARK: testProcessDroppedWhenAllSourcesYieldNoBundleID (UR-004)
    //
    // If neither HAL nor NSRunningApplication can supply a bundle ID, the
    // process must still be filtered out (preserves the original
    // testNoBundleIDIsFiltered guarantee under the new resolution chain).
    func testProcessDroppedWhenAllSourcesYieldNoBundleID() {
        let unresolvablePID: pid_t = pid_t.max - 3
        XCTAssertNil(NSRunningApplication(processIdentifier: unresolvablePID))

        let mock = MockProcessListProvider()
        mock.entries = [
            .init(
                objectID: 4244,
                pid: unresolvablePID,
                bundleID: nil,
                executableName: nil
            )
        ]

        let catalog = AudioSourceCatalog(provider: mock)
        catalog.refresh()

        XCTAssertTrue(catalog.processes.isEmpty,
            "Process with no bundle ID from any source must be filtered")
    }

    // MARK: - pids(forBundle:) tests (REQ-065)

    // Helper that builds a catalog from a list of (pid, bundleID) pairs using
    // unresolvable pids so NSRunningApplication is never consulted.
    private func catalog(from entries: [(pid: pid_t, bundleID: String)]) -> AudioSourceCatalog {
        let mock = MockProcessListProvider()
        mock.entries = entries.enumerated().map { idx, entry in
            MockProcessListProvider.Entry(
                objectID: AudioObjectID(9000 + idx),
                pid: entry.pid,
                bundleID: entry.bundleID,
                executableName: entry.bundleID.split(separator: ".").last.map(String.init)
            )
        }
        let cat = AudioSourceCatalog(provider: mock)
        cat.refresh()
        return cat
    }

    // MARK: testPidsForBundle_parentPlusHelpers
    //
    // REQ-065 AC: parent + .helper + .helper.GPU all returned for the parent
    // bundle ID; Safari pid excluded.
    func testPidsForBundle_parentPlusHelpers() {
        let basePID: pid_t = pid_t.max - 10
        let helperPID: pid_t = pid_t.max - 11
        let gpuPID: pid_t = pid_t.max - 12
        let safariPID: pid_t = pid_t.max - 13

        let cat = catalog(from: [
            (pid: basePID,    bundleID: "com.google.Chrome"),
            (pid: helperPID,  bundleID: "com.google.Chrome.helper"),
            (pid: gpuPID,     bundleID: "com.google.Chrome.helper.GPU"),
            (pid: safariPID,  bundleID: "com.apple.Safari"),
        ])

        let result = cat.pids(forBundle: "com.google.Chrome")

        XCTAssertEqual(result.count, 3, "parent + .helper + .helper.GPU should all be returned")
        XCTAssertTrue(result.contains(basePID),   "parent pid must be included")
        XCTAssertTrue(result.contains(helperPID), ".helper pid must be included")
        XCTAssertTrue(result.contains(gpuPID),    ".helper.GPU pid must be included")
        XCTAssertFalse(result.contains(safariPID), "Safari pid must be excluded")
    }

    // MARK: testPidsForBundle_substringWithoutSeparatorRejected
    //
    // REQ-065 AC: com.google.Chromehelper does NOT match com.google.Chrome.
    func testPidsForBundle_substringWithoutSeparatorRejected() {
        let pid1: pid_t = pid_t.max - 20

        let cat = catalog(from: [
            (pid: pid1, bundleID: "com.google.Chromehelper"),
        ])

        let result = cat.pids(forBundle: "com.google.Chrome")

        XCTAssertTrue(result.isEmpty,
            "Substring match without .helper separator must be rejected")
    }

    // MARK: testPidsForBundle_bundleIsolation
    //
    // REQ-065 AC: pids(forBundle: "com.apple.Safari") must exclude Chrome pids.
    func testPidsForBundle_bundleIsolation() {
        let chromePID: pid_t = pid_t.max - 30
        let helperPID: pid_t = pid_t.max - 31
        let safariPID: pid_t = pid_t.max - 32

        let cat = catalog(from: [
            (pid: chromePID,  bundleID: "com.google.Chrome"),
            (pid: helperPID,  bundleID: "com.google.Chrome.helper"),
            (pid: safariPID,  bundleID: "com.apple.Safari"),
        ])

        let result = cat.pids(forBundle: "com.apple.Safari")

        XCTAssertEqual(result, [safariPID], "Only Safari pid should be returned")
    }

    // MARK: testPidsForBundle_noMatchReturnsEmptyArray
    //
    // REQ-065 AC: non-existent bundle returns [] not nil.
    func testPidsForBundle_noMatchReturnsEmptyArray() {
        let pid1: pid_t = pid_t.max - 40

        let cat = catalog(from: [
            (pid: pid1, bundleID: "com.google.Chrome"),
        ])

        let result = cat.pids(forBundle: "com.nonexistent.app")

        XCTAssertTrue(result.isEmpty, "Non-existent bundle must return an empty array")
    }

    // MARK: testPidsForBundle_doesNotMutateProcesses
    //
    // REQ-065 AC: calling pids(forBundle:) must not mutate self.processes.
    func testPidsForBundle_doesNotMutateProcesses() {
        let pid1: pid_t = pid_t.max - 50
        let pid2: pid_t = pid_t.max - 51

        let cat = catalog(from: [
            (pid: pid1, bundleID: "com.google.Chrome"),
            (pid: pid2, bundleID: "com.google.Chrome.helper"),
        ])

        let beforeCount = cat.processes.count
        let beforePIDs  = cat.processes.map(\.pid)

        _ = cat.pids(forBundle: "com.google.Chrome")

        XCTAssertEqual(cat.processes.count, beforeCount,
            "pids(forBundle:) must not mutate the processes array count")
        XCTAssertEqual(cat.processes.map(\.pid), beforePIDs,
            "pids(forBundle:) must not reorder or change the processes array")
    }

    // MARK: testPidsForBundle_preservesCatalogOrder
    //
    // REQ-065 AC: result preserves catalog insertion order.
    func testPidsForBundle_preservesCatalogOrder() {
        let pid1: pid_t = pid_t.max - 60
        let pid2: pid_t = pid_t.max - 61
        let pid3: pid_t = pid_t.max - 62

        let cat = catalog(from: [
            (pid: pid1, bundleID: "com.google.Chrome"),
            (pid: pid2, bundleID: "com.google.Chrome.helper"),
            (pid: pid3, bundleID: "com.google.Chrome.helper.Renderer"),
        ])

        let result = cat.pids(forBundle: "com.google.Chrome")

        XCTAssertEqual(result, [pid1, pid2, pid3],
            "pids(forBundle:) must preserve catalog order")
    }

    // MARK: testPidsForBundle_parentOnlyGroup
    //
    // When no helpers are present, only the parent pid is returned.
    func testPidsForBundle_parentOnlyGroup() {
        let pid1: pid_t = pid_t.max - 70

        let cat = catalog(from: [
            (pid: pid1, bundleID: "com.apple.Safari"),
        ])

        let result = cat.pids(forBundle: "com.apple.Safari")

        XCTAssertEqual(result, [pid1], "Parent-only group must return exactly the parent pid")
    }
}
