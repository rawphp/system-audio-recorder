import XCTest
@testable import SystemAudioToMP3

// MARK: - Test Double

/// Records every `NSApplication.ActivationPolicy` passed to `set(_:)`.
final class SpyActivationPolicySetting: ActivationPolicySetting {
    private(set) var recorded: [NSApplication.ActivationPolicy] = []

    func set(_ policy: NSApplication.ActivationPolicy) {
        recorded.append(policy)
    }
}

// MARK: - DockPolicyControllerTests

@MainActor
final class DockPolicyControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettings(showInDock: Bool) -> AppSettings {
        let suiteName = "com.tomkaczocha.test.DockPolicy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(
            defaults: defaults,
            bookmarkProvider: StubBookmarkProvider()
        )
        settings.showInDock = showInDock
        return settings
    }

    // MARK: apply() with showInDock = true

    func testApplyWithShowInDockTrueSetsRegularPolicy() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: true)
        let controller = DockPolicyController(settings: settings, policy: spy)

        controller.apply()

        XCTAssertEqual(spy.recorded, [.regular],
                       "showInDock=true should set .regular activation policy")
    }

    // MARK: apply() with showInDock = false

    func testApplyWithShowInDockFalseSetsAccessoryPolicy() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: false)
        let controller = DockPolicyController(settings: settings, policy: spy)

        controller.apply()

        XCTAssertEqual(spy.recorded, [.accessory],
                       "showInDock=false should set .accessory activation policy")
    }

    // MARK: start() applies current setting immediately

    func testStartAppliesCurrentPolicyImmediately() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: false)
        let controller = DockPolicyController(settings: settings, policy: spy)

        controller.start()

        XCTAssertFalse(spy.recorded.isEmpty,
                       "start() should apply the current policy without waiting for a change")
        XCTAssertEqual(spy.recorded.first, .accessory,
                       "First call from start() with showInDock=false should be .accessory")
    }

    // MARK: Toggle true → false

    func testToggleTrueToFalseRecordsRegularThenAccessory() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: true)
        let controller = DockPolicyController(settings: settings, policy: spy)

        // Apply with showInDock = true → .regular
        controller.apply()
        // Mutate settings and apply again
        settings.showInDock = false
        controller.apply()

        XCTAssertEqual(spy.recorded, [.regular, .accessory],
                       "Toggling showInDock true→false should record .regular then .accessory")
    }

    // MARK: Toggle false → true

    func testToggleFalseToTrueRecordsAccessoryThenRegular() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: false)
        let controller = DockPolicyController(settings: settings, policy: spy)

        // Apply with showInDock = false → .accessory
        controller.apply()
        // Mutate settings and apply again
        settings.showInDock = true
        controller.apply()

        XCTAssertEqual(spy.recorded, [.accessory, .regular],
                       "Toggling showInDock false→true should record .accessory then .regular")
    }

    // MARK: Repeated same value doesn't duplicate

    func testApplySameValueTwiceRecordsTwice() {
        let spy = SpyActivationPolicySetting()
        let settings = makeSettings(showInDock: true)
        let controller = DockPolicyController(settings: settings, policy: spy)

        controller.apply()
        controller.apply()

        // We allow duplicates — the OS ignores redundant policy sets harmlessly.
        XCTAssertEqual(spy.recorded.count, 2)
        XCTAssertTrue(spy.recorded.allSatisfy { $0 == .regular })
    }
}
