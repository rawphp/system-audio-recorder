import XCTest
import SwiftUI
@testable import SystemAudioRecorder

// MARK: - StubHotkeyRegistrar

/// Deterministic stub for `HotkeyRegistrar` — no KeyboardShortcuts calls are made.
final class StubHotkeyRegistrar: HotkeyRegistrar {

    // Track last registered handler so tests can fire it.
    var registeredHandler: (() -> Void)?

    // Track registration / unregistration calls.
    var registerCallCount = 0
    var unregisterCallCount = 0

    // Simulate a registration failure.
    var shouldFailRegistration = false

    func register(handler: @escaping () -> Void) throws {
        if shouldFailRegistration {
            throw HotkeyRegistrarError.registrationFailed("Stub: conflict detected")
        }
        registerCallCount += 1
        registeredHandler = handler
    }

    func unregister() {
        unregisterCallCount += 1
        registeredHandler = nil
    }

    /// Test helper — simulate the user pressing the bound shortcut.
    func simulateKeyDown() {
        registeredHandler?()
    }
}

// MARK: - HotkeyManagerTests

@MainActor
final class HotkeyManagerTests: XCTestCase {

    // MARK: - start(toggleHandler:) wires up the handler

    func testStartRegistersHandler() throws {
        let stub = StubHotkeyRegistrar()
        let manager = HotkeyManager(registrar: stub)

        var called = false
        try manager.start(toggleHandler: { called = true })

        XCTAssertEqual(stub.registerCallCount, 1, "start() must call register once")
        stub.simulateKeyDown()
        XCTAssertTrue(called, "Simulated key-down must invoke the toggleHandler")
    }

    func testStartHandlerIsInvokedEachPress() throws {
        let stub = StubHotkeyRegistrar()
        let manager = HotkeyManager(registrar: stub)

        var callCount = 0
        try manager.start(toggleHandler: { callCount += 1 })

        stub.simulateKeyDown()
        stub.simulateKeyDown()
        stub.simulateKeyDown()

        XCTAssertEqual(callCount, 3, "Each key-down simulation must invoke toggleHandler once")
    }

    // MARK: - Registration failure surfaces BindingError

    func testStartSetsLastBindingErrorOnFailure() {
        let stub = StubHotkeyRegistrar()
        stub.shouldFailRegistration = true
        let manager = HotkeyManager(registrar: stub)

        XCTAssertNil(manager.lastBindingError, "lastBindingError must be nil before start()")

        XCTAssertThrowsError(try manager.start(toggleHandler: {})) { error in
            guard let be = error as? BindingError else {
                XCTFail("Expected BindingError, got \(error)")
                return
            }
            if case .conflict(let msg) = be {
                XCTAssertTrue(msg.contains("conflict"), "Error message must mention conflict")
            } else {
                XCTFail("Expected .conflict case, got \(be)")
            }
        }

        XCTAssertNotNil(manager.lastBindingError, "lastBindingError must be set after registration failure")
    }

    func testLastBindingErrorIsNilOnSuccess() throws {
        let stub = StubHotkeyRegistrar()
        let manager = HotkeyManager(registrar: stub)

        try manager.start(toggleHandler: {})
        XCTAssertNil(manager.lastBindingError, "lastBindingError must remain nil on successful registration")
    }

    func testLastBindingErrorInitiallyNil() {
        let stub = StubHotkeyRegistrar()
        let manager = HotkeyManager(registrar: stub)
        XCTAssertNil(manager.lastBindingError, "lastBindingError must be nil before any call")
    }

    // MARK: - Default (no-seam) initialiser compiles and returns

    func testDefaultInitialiserExists() {
        // Verify that HotkeyManager() can be constructed without supplying a seam.
        // We don't call start() because the default registrar wraps KeyboardShortcuts
        // (requires event-tap permissions).
        let manager = HotkeyManager()
        XCTAssertNil(manager.lastBindingError)
    }

    // MARK: - recorder() factory returns a View

    func testRecorderFactoryReturnsView() {
        // Type-check: recorder() must return some View.
        // We can't render it in a unit test, but we can call it and hold the result.
        let view = HotkeyManager.recorder()
        // Confirm it conforms to View by using it as AnyView.
        let wrapped = AnyView(view)
        XCTAssertNotNil(wrapped)
    }

    // MARK: - Unregister on stop

    func testStopUnregisters() throws {
        let stub = StubHotkeyRegistrar()
        let manager = HotkeyManager(registrar: stub)

        try manager.start(toggleHandler: {})
        manager.stop()

        XCTAssertEqual(stub.unregisterCallCount, 1, "stop() must call unregister once")
        // Further key-down must be a no-op (handler was removed).
        stub.simulateKeyDown() // stub's handler is nil; no crash expected
    }
}
