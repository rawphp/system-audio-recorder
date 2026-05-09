import XCTest
@testable import SystemAudioRecorder

// MARK: - MenuBarRendererRecording (test double)

/// Records every render call for assertion in tests.
/// Does NOT touch `NSStatusItem` or any real AppKit menu machinery.
@MainActor
private final class RecordingMenuBarRenderer: MenuBarRenderer {

    struct RenderCall: Equatable {
        let iconState: MenuBarIconState
        let menuDescriptor: MenuDescriptor
    }

    private(set) var renderCalls: [RenderCall] = []

    func render(iconState: MenuBarIconState, menuDescriptor: MenuDescriptor) {
        renderCalls.append(RenderCall(iconState: iconState, menuDescriptor: menuDescriptor))
    }

    var lastCall: RenderCall? { renderCalls.last }
}

// MARK: - MenuBarControllerTests

@MainActor
final class MenuBarControllerTests: XCTestCase {

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Builds a `MenuBarController` wired to a fake renderer, and the fake
    /// renderer itself. The `sessionState` starts at `.idle`.
    private func makeController(
        sessionState: SessionState = .idle
    ) -> (MenuBarController, RecordingMenuBarRenderer) {
        let store = MenuBarTestStore(sessionState: sessionState)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        return (controller, renderer)
    }

    // -----------------------------------------------------------------------
    // AC #2: Icon updates to reflect session state
    // -----------------------------------------------------------------------

    func testIdleStateRendersIdleIcon() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        XCTAssertEqual(renderer.lastCall?.iconState, .idle)
    }

    func testRecordingStateRendersRecordingIcon() {
        let (controller, renderer) = makeController(sessionState: .recording)
        controller.renderCurrentState()
        XCTAssertEqual(renderer.lastCall?.iconState, .recording)
    }

    func testPausedStateRendersPausedIcon() {
        let (controller, renderer) = makeController(sessionState: .paused)
        controller.renderCurrentState()
        XCTAssertEqual(renderer.lastCall?.iconState, .paused)
    }

    // -----------------------------------------------------------------------
    // AC #3: Menu items invoke AppStore action methods
    // -----------------------------------------------------------------------

    func testIdleMenuDescriptorContainsStartRecording() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasStart = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Start Recording" }
            return false
        }
        XCTAssertTrue(hasStart, "Idle menu must contain 'Start Recording'")
    }

    func testIdleMenuDescriptorContainsOpenWindow() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasOpenWindow = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Open Window\u{2026}" }
            return false
        }
        XCTAssertTrue(hasOpenWindow, "Idle menu must contain 'Open Window\u{2026}'")
    }

    func testIdleMenuDescriptorContainsSettings() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasSettings = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Settings\u{2026}" }
            return false
        }
        XCTAssertTrue(hasSettings, "Idle menu must contain 'Settings\u{2026}'")
    }

    func testIdleMenuDescriptorContainsQuit() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasQuit = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Quit" }
            return false
        }
        XCTAssertTrue(hasQuit, "Idle menu must contain 'Quit'")
    }

    func testRecordingMenuDescriptorContainsPause() {
        let (controller, renderer) = makeController(sessionState: .recording)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasPause = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Pause" }
            return false
        }
        XCTAssertTrue(hasPause, "Recording menu must contain 'Pause'")
    }

    func testRecordingMenuDescriptorContainsStop() {
        let (controller, renderer) = makeController(sessionState: .recording)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasStop = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Stop" }
            return false
        }
        XCTAssertTrue(hasStop, "Recording menu must contain 'Stop'")
    }

    func testPausedMenuDescriptorContainsResume() {
        let (controller, renderer) = makeController(sessionState: .paused)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasResume = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Resume" }
            return false
        }
        XCTAssertTrue(hasResume, "Paused menu must contain 'Resume'")
    }

    func testPausedMenuDescriptorContainsStop() {
        let (controller, renderer) = makeController(sessionState: .paused)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasStop = descriptor.items.contains {
            if case .action(let title, _) = $0 { return title == "Stop" }
            return false
        }
        XCTAssertTrue(hasStop, "Paused menu must contain 'Stop'")
    }

    // -----------------------------------------------------------------------
    // AC #3: Action items fire the correct AppStore method
    // -----------------------------------------------------------------------

    func testStartRecordingActionCallsToggleRecording() async {
        let store = MenuBarTestStore(sessionState: .idle)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        controller.renderCurrentState()

        guard let startItem = renderer.lastCall?.menuDescriptor.items.first(where: {
            if case .action(let title, _) = $0 { return title == "Start Recording" }
            return false
        }),
        case .action(_, let handler) = startItem else {
            XCTFail("Could not find Start Recording item")
            return
        }

        await handler()
        XCTAssertEqual(store.toggleRecordingCallCount, 1)
    }

    func testPauseActionCallsPauseRecording() async {
        let store = MenuBarTestStore(sessionState: .recording)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        controller.renderCurrentState()

        guard let pauseItem = renderer.lastCall?.menuDescriptor.items.first(where: {
            if case .action(let title, _) = $0 { return title == "Pause" }
            return false
        }),
        case .action(_, let handler) = pauseItem else {
            XCTFail("Could not find Pause item")
            return
        }

        await handler()
        XCTAssertEqual(store.pauseRecordingCallCount, 1)
    }

    func testStopActionCallsStopRecording() async {
        let store = MenuBarTestStore(sessionState: .recording)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        controller.renderCurrentState()

        guard let stopItem = renderer.lastCall?.menuDescriptor.items.first(where: {
            if case .action(let title, _) = $0 { return title == "Stop" }
            return false
        }),
        case .action(_, let handler) = stopItem else {
            XCTFail("Could not find Stop item")
            return
        }

        await handler()
        XCTAssertEqual(store.stopRecordingCallCount, 1)
    }

    func testResumeActionCallsResumeRecording() async {
        let store = MenuBarTestStore(sessionState: .paused)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        controller.renderCurrentState()

        guard let resumeItem = renderer.lastCall?.menuDescriptor.items.first(where: {
            if case .action(let title, _) = $0 { return title == "Resume" }
            return false
        }),
        case .action(_, let handler) = resumeItem else {
            XCTFail("Could not find Resume item")
            return
        }

        await handler()
        XCTAssertEqual(store.resumeRecordingCallCount, 1)
    }

    // -----------------------------------------------------------------------
    // AC #5: Settings… sets shouldShowSettings = true on AppStore
    // -----------------------------------------------------------------------

    func testSettingsActionSetsShouldShowSettings() async {
        let store = MenuBarTestStore(sessionState: .idle)
        let renderer = RecordingMenuBarRenderer()
        let controller = MenuBarController(store: store, renderer: renderer)
        controller.renderCurrentState()

        guard let settingsItem = renderer.lastCall?.menuDescriptor.items.first(where: {
            if case .action(let title, _) = $0 { return title == "Settings\u{2026}" }
            return false
        }),
        case .action(_, let handler) = settingsItem else {
            XCTFail("Could not find Settings… item")
            return
        }

        await handler()
        XCTAssertTrue(store.shouldShowSettings)
    }

    // -----------------------------------------------------------------------
    // AC #6: Recording state menu has elapsed time header
    // -----------------------------------------------------------------------

    func testRecordingMenuDescriptorHasElapsedTimeHeader() {
        let (controller, renderer) = makeController(sessionState: .recording)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasHeader = descriptor.items.contains {
            if case .header = $0 { return true }
            return false
        }
        XCTAssertTrue(hasHeader, "Recording menu must have elapsed time header")
    }

    func testIdleMenuHasNoElapsedTimeHeader() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasHeader = descriptor.items.contains {
            if case .header = $0 { return true }
            return false
        }
        XCTAssertFalse(hasHeader, "Idle menu must not have elapsed time header")
    }

    // -----------------------------------------------------------------------
    // AC: Source preset submenu present in idle menu
    // -----------------------------------------------------------------------

    func testIdleMenuContainsSourcePresetSubmenu() {
        let (controller, renderer) = makeController(sessionState: .idle)
        controller.renderCurrentState()
        guard let descriptor = renderer.lastCall?.menuDescriptor else {
            XCTFail("No render call")
            return
        }
        let hasSubmenu = descriptor.items.contains {
            if case .submenu = $0 { return true }
            return false
        }
        XCTAssertTrue(hasSubmenu, "Idle menu must contain source preset submenu")
    }

    // -----------------------------------------------------------------------
    // AC: Elapsed time format matches HH:MM:SS
    // -----------------------------------------------------------------------

    func testFormatElapsedSeconds() {
        XCTAssertEqual(MenuBarController.formatElapsed(0), "00:00:00")
        XCTAssertEqual(MenuBarController.formatElapsed(65), "00:01:05")
        XCTAssertEqual(MenuBarController.formatElapsed(3661), "01:01:01")
        XCTAssertEqual(MenuBarController.formatElapsed(3600), "01:00:00")
    }
}

// MARK: - MenuBarTestStore (test double for AppStore-facing protocol)

/// Minimal fake store used in all MenuBarController tests.
/// Tracks call counts and `shouldShowSettings` without any real audio engine.
@MainActor
final class MenuBarTestStore: MenuBarStoreProtocol {

    var sessionState: SessionState
    var shouldShowSettings: Bool = false

    var toggleRecordingCallCount = 0
    var pauseRecordingCallCount = 0
    var resumeRecordingCallCount = 0
    var stopRecordingCallCount = 0

    init(sessionState: SessionState = .idle) {
        self.sessionState = sessionState
    }

    func toggleRecording() async {
        toggleRecordingCallCount += 1
    }

    func pauseRecording() async throws {
        pauseRecordingCallCount += 1
    }

    func resumeRecording() async throws {
        resumeRecordingCallCount += 1
    }

    func stopRecording() async {
        stopRecordingCallCount += 1
    }
}
