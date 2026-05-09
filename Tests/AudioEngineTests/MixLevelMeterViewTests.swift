import XCTest
import SwiftUI
import AVFoundation
import CoreAudio
@testable import SystemAudioRecorder

// MARK: - MeterMath Tests

/// Tests for the pure helper functions in MeterMath.
/// No SwiftUI rendering — pure function coverage only.
final class MeterMathTests: XCTestCase {

    // MARK: barFillFraction

    func testBarFillFractionNegativeInfinity() {
        // -∞ dBFS → 0.0
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -.infinity), 0.0, accuracy: 1e-6)
    }

    func testBarFillFractionAtFloor() {
        // -60 dBFS → 0.0
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -60.0), 0.0, accuracy: 1e-6)
    }

    func testBarFillFractionBelowFloor() {
        // Below -60 → 0.0
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -80.0), 0.0, accuracy: 1e-6)
    }

    func testBarFillFractionAtCeiling() {
        // 0 dBFS → 1.0
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: 0.0), 1.0, accuracy: 1e-6)
    }

    func testBarFillFractionAboveCeiling() {
        // Above 0 dBFS → clamped to 1.0
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: 3.0), 1.0, accuracy: 1e-6)
    }

    func testBarFillFractionMidpoint() {
        // -30 dBFS → 0.5 (linear mapping: (-30 - (-60)) / (0 - (-60)) = 30/60)
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -30.0), 0.5, accuracy: 1e-6)
    }

    func testBarFillFractionAt12dBFS() {
        // -12 dBFS → (60 - 12) / 60 = 48/60 = 0.8
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -12.0), 0.8, accuracy: 1e-6)
    }

    func testBarFillFractionAt3dBFS() {
        // -3 dBFS → (60 - 3) / 60 = 57/60 = 0.95
        XCTAssertEqual(MeterMath.barFillFraction(forDBFS: -3.0), 0.95, accuracy: 1e-6)
    }

    // MARK: color

    func testColorAtMinus60IsGreen() {
        // -60 is below -12 → green
        XCTAssertEqual(MeterMath.meterColor(forDBFS: -60.0), .green)
    }

    func testColorAtMinus12IsGreen() {
        // Exactly -12 → green (boundary: pick green per spec)
        XCTAssertEqual(MeterMath.meterColor(forDBFS: -12.0), .green)
    }

    func testColorBetweenMinus12AndMinus3IsYellow() {
        // -6 is between -12 and -3 → yellow
        XCTAssertEqual(MeterMath.meterColor(forDBFS: -6.0), .yellow)
    }

    func testColorAtMinus3IsRed() {
        // Exactly -3 → red (boundary: pick red per spec)
        XCTAssertEqual(MeterMath.meterColor(forDBFS: -3.0), .red)
    }

    func testColorAt0IsRed() {
        // 0 dBFS → red
        XCTAssertEqual(MeterMath.meterColor(forDBFS: 0.0), .red)
    }

    func testColorAbove0IsRed() {
        // Clipped above 0 → red
        XCTAssertEqual(MeterMath.meterColor(forDBFS: 3.0), .red)
    }

    func testColorAtNegativeInfinityIsGreen() {
        // -∞ is treated like silence → green (no alarm)
        XCTAssertEqual(MeterMath.meterColor(forDBFS: -.infinity), .green)
    }

    // MARK: displayString

    func testDisplayStringNegativeInfinity() {
        XCTAssertEqual(MeterMath.displayString(forDBFS: -.infinity), "-∞ dB")
    }

    func testDisplayStringAtFloor() {
        // -60 → "-∞ dB" (floor treated as silence)
        XCTAssertEqual(MeterMath.displayString(forDBFS: -60.0), "-∞ dB")
    }

    func testDisplayStringBelowFloor() {
        // Below -60 → "-∞ dB"
        XCTAssertEqual(MeterMath.displayString(forDBFS: -80.0), "-∞ dB")
    }

    func testDisplayStringAt12dBFS() {
        // -12 dBFS → "-12 dB"
        XCTAssertEqual(MeterMath.displayString(forDBFS: -12.0), "-12 dB")
    }

    func testDisplayStringAt3dBFS() {
        // -3 dBFS → "-3 dB"
        XCTAssertEqual(MeterMath.displayString(forDBFS: -3.0), "-3 dB")
    }

    func testDisplayStringAt0dBFS() {
        // 0 dBFS → "0 dB"
        XCTAssertEqual(MeterMath.displayString(forDBFS: 0.0), "0 dB")
    }

    func testDisplayStringRoundsToNearestInteger() {
        // -12.4 → "-12 dB", -12.6 → "-13 dB"
        XCTAssertEqual(MeterMath.displayString(forDBFS: -12.4), "-12 dB")
        XCTAssertEqual(MeterMath.displayString(forDBFS: -12.6), "-13 dB")
    }
}

// MARK: - MixLevelMeterView compile-time tests

/// Verifies that MixLevelMeterView compiles and can be instantiated.
/// No SwiftUI rendering — purely a type-check / compile-time contract.
@MainActor
final class MixLevelMeterViewTests: XCTestCase {

    func testMixLevelMeterViewInstantiatesWithAppStore() throws {
        let store = makeStore()
        let sut = MixLevelMeterView()
            .environment(\.appStore, store)
        _ = sut
        XCTAssert(true, "MixLevelMeterView instantiated without compiler error")
    }

    func testMixLevelMeterViewInstantiatesWithoutAppStore() throws {
        // Should compile and run even when no store is injected (nil environment)
        let sut = MixLevelMeterView()
        _ = sut
        XCTAssert(true, "MixLevelMeterView compiles with nil AppStore environment")
    }

    // MARK: - Helpers

    private func makeStore() -> AppStore {
        let suiteName = "com.tomkaczocha.MixLevelMeterViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: MLMPassthroughBookmarkProvider(),
            folderCreator: FileManagerFolderCreator()
        )
        return AppStore(
            settings: settings,
            sourceCatalog: AudioSourceCatalog(provider: MLMEmptyProcessListProvider()),
            permissionManager: PermissionManager(micProvider: MLMNoOpMicProvider()),
            encodingQueue: EncodingQueue(),
            meters: MeterPublisher(),
            sessionConfigBuilder: MLMNoOpSessionConfigBuilder()
        )
    }
}

// MARK: - Test doubles

private final class MLMNoOpMicProvider: MicrophoneAuthorizationProvider, @unchecked Sendable {
    let status: AVAuthorizationStatus = .authorized
    func requestAccess() async -> Bool { true }
}

private final class MLMPassthroughBookmarkProvider: BookmarkProvider {
    func store(url: URL) throws -> Data {
        url.absoluteString.data(using: .utf8) ?? Data()
    }
    func resolve(data: Data) throws -> URL {
        let str = String(decoding: data, as: UTF8.self)
        guard let url = URL(string: str) else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }
}

private struct MLMEmptyProcessListProvider: ProcessListProvider {
    func audioProcessObjectIDs() -> [AudioObjectID] { [] }
    func pid(for objectID: AudioObjectID) -> pid_t? { nil }
}

@MainActor
private final class MLMNoOpSessionConfigBuilder: SessionConfigBuilder {
    func build(preset: SourcePreset, settings: AppSettings) throws -> SessionConfig {
        let emitter = MLMNoOpEmitter(id: "noop")
        return SessionConfig(
            sources: [SessionConfig.Source(id: "noop", emitter: emitter)],
            outputMode: .mixed,
            outputFolder: URL(fileURLWithPath: NSTemporaryDirectory()),
            timestamp: "20260510-000000"
        )
    }
}

private final class MLMNoOpEmitter: RecordingSourceEmitter, @unchecked Sendable {
    let id: String
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let cont: AsyncStream<AVAudioPCMBuffer>.Continuation
    init(id: String) {
        self.id = id
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.cont = c
    }
    func stop() { cont.finish() }
}
