import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - MenuBarIconState

/// The three visual states the menu-bar icon can be in.
public enum MenuBarIconState: Equatable, Sendable {
    /// App is idle — no active session.
    case idle
    /// App is actively recording audio.
    case recording
    /// App has a paused session.
    case paused
}

// MARK: - MenuDescriptor

/// A value-type description of the menu to render.
///
/// `MenuBarController` builds a fresh `MenuDescriptor` each time state changes
/// and passes it to the `MenuBarRenderer`. The renderer translates the descriptor
/// into real AppKit `NSMenu` / `NSMenuItem` objects. This separation means the
/// controller's logic is fully testable without touching `NSStatusItem`.
public struct MenuDescriptor: Equatable {

    /// A single item in the menu.
    public enum Item: Equatable {
        /// A disabled header row (e.g. elapsed time).
        case header(String)
        /// A separator line.
        case separator
        /// A clickable item with title and async action.
        case action(String, @MainActor @Sendable () async -> Void)
        /// A submenu with a title and child items.
        case submenu(String, [Item])

        // Equatable: compare by structure, ignoring closure identity.
        // Actions are considered equal if their titles match — sufficient for tests.
        public static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case (.header(let a), .header(let b)):   return a == b
            case (.separator, .separator):             return true
            case (.action(let a, _), .action(let b, _)): return a == b
            case (.submenu(let a, let ai), .submenu(let b, let bi)): return a == b && ai == bi
            default: return false
            }
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

// MARK: - MenuBarRenderer (protocol / test seam)

/// Owns the AppKit `NSStatusItem` and translates a `MenuDescriptor` into real
/// AppKit UI. Tests inject a recording stub instead.
@MainActor
public protocol MenuBarRenderer: AnyObject {
    /// Apply the given icon state and menu descriptor to the status item.
    func render(iconState: MenuBarIconState, menuDescriptor: MenuDescriptor)
}

// MARK: - MenuBarStoreProtocol (test seam for AppStore)

/// The slice of `AppStore` that `MenuBarController` depends on.
/// `AppStore` conforms to this protocol; tests inject a `MenuBarTestStore`.
///
/// `pauseRecording` and `resumeRecording` are declared `async throws` to match
/// the existing `AppStore` signatures — test doubles simply don't throw.
@MainActor
public protocol MenuBarStoreProtocol: AnyObject {
    var sessionState: SessionState { get }
    var shouldShowSettings: Bool { get set }
    func toggleRecording() async
    func pauseRecording() async throws
    func resumeRecording() async throws
    func stopRecording() async
}

// MARK: - AppStore conformance

extension AppStore: MenuBarStoreProtocol {
    /// Flag set by `MenuBarController`'s "Settings…" item so `ContentView` opens
    /// the `OutputSettingsView` sheet.
    ///
    /// Backed by `_shouldShowSettings` which is declared in the `@Observable`
    /// class body. The property is `public` so `ContentView` can observe it.
    public var shouldShowSettings: Bool {
        get { _shouldShowSettings }
        set { _shouldShowSettings = newValue }
    }
}

// MARK: - MenuBarController

/// Owns the logic for building a state-driven menu-bar icon and dropdown menu.
///
/// Designed around an injected `MenuBarRenderer` (production: `NSStatusItemRenderer`;
/// tests: `RecordingMenuBarRenderer`), so the controller is fully unit-testable.
///
/// ## Lifecycle
/// 1. `init(store:renderer:)` — wire dependencies.
/// 2. `start()` — install recursive observation loop via `withObservationTracking`.
/// 3. `stop()` — cancel the observation and any running timer.
///
/// `start()` and `stop()` are called by `SystemAudioToMP3App`.
@MainActor
public final class MenuBarController: NSObject {

    // MARK: - Properties

    private let store: any MenuBarStoreProtocol
    private let renderer: any MenuBarRenderer

    /// Timer that fires once per second while recording, to update the elapsed
    /// time header in the menu. `nil` when idle or paused.
    private var elapsedTimer: Timer?

    /// Tracks elapsed seconds when the timer is running.
    private var elapsedSeconds: TimeInterval = 0
    private var timerStartDate: Date?

    // MARK: - Init

    public init(
        store: any MenuBarStoreProtocol,
        renderer: any MenuBarRenderer
    ) {
        self.store = store
        self.renderer = renderer
        super.init()
    }

    // MARK: - Lifecycle

    /// Installs a recursive `withObservationTracking` loop so the menu and icon
    /// update automatically whenever `store.sessionState` changes.
    public func start() {
        observeState()
    }

    /// Tears down the observation loop and cancels any running timer.
    public func stop() {
        cancelTimer()
    }

    // MARK: - Observation (recursive)

    private func observeState() {
        withObservationTracking {
            // Access the tracked property inside the `apply` closure so Swift
            // knows which observable to watch.
            _ = self.store.sessionState
        } onChange: {
            // `onChange` is called from an unspecified thread — hop to MainActor.
            Task { @MainActor [weak self] in
                self?.renderCurrentState()
                self?.observeState()   // re-arm
            }
        }
        // Render immediately for the current state.
        renderCurrentState()
    }

    // MARK: - Render

    /// Builds the icon state and menu descriptor from current store state, then
    /// passes them to the renderer. Called on every state change and initially.
    ///
    /// `public` so tests can call it directly without `start()`.
    public func renderCurrentState() {
        let state = store.sessionState
        let iconState = iconState(for: state)
        let descriptor = menuDescriptor(for: state)
        renderer.render(iconState: iconState, menuDescriptor: descriptor)
        manageTimer(for: state)
    }

    // MARK: - Icon state

    private func iconState(for state: SessionState) -> MenuBarIconState {
        switch state {
        case .recording:            return .recording
        case .paused:               return .paused
        default:                    return .idle
        }
    }

    // MARK: - Menu descriptor

    private func menuDescriptor(for state: SessionState) -> MenuDescriptor {
        var items: [MenuDescriptor.Item] = []

        switch state {
        case .recording:
            // Header: elapsed time
            let formatted = Self.formatElapsed(elapsedSeconds)
            items.append(.header("Recording: \(formatted)"))
            items.append(.separator)

            items.append(.action("Pause") { [weak self] in
                try? await self?.store.pauseRecording()
            })
            items.append(.action("Stop") { [weak self] in
                await self?.store.stopRecording()
            })
            items.append(.separator)

        case .paused:
            let formatted = Self.formatElapsed(elapsedSeconds)
            items.append(.header("Paused: \(formatted)"))
            items.append(.separator)

            items.append(.action("Resume") { [weak self] in
                try? await self?.store.resumeRecording()
            })
            items.append(.action("Stop") { [weak self] in
                await self?.store.stopRecording()
            })
            items.append(.separator)

        default:
            // Idle / stopped / failed
            items.append(.action("Start Recording") { [weak self] in
                await self?.store.toggleRecording()
            })
            items.append(.separator)
        }

        // Source preset submenu (mirrors REQ-024 items)
        let sourceItems: [MenuDescriptor.Item] = [
            .action("Everything") { },
            .action("Everything + Mic") { },
            .action("Microphone only") { },
            .action("Specific app\u{2026}") { },
            .action("Advanced\u{2026}") { },
        ]
        items.append(.submenu("Source: \(sourceLabel())", sourceItems))
        items.append(.separator)

        items.append(.action("Open Window\u{2026}") {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        })
        items.append(.action("Settings\u{2026}") { [weak self] in
            await MainActor.run {
                self?.store.shouldShowSettings = true
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        })
        items.append(.separator)
        items.append(.action("Quit") {
            await MainActor.run {
                NSApp.terminate(nil)
            }
        })

        return MenuDescriptor(items: items)
    }

    private func sourceLabel() -> String {
        // Future: read from store.selectedPreset; for now use a fixed label.
        return "Everything"
    }

    // MARK: - Elapsed timer

    private func manageTimer(for state: SessionState) {
        switch state {
        case .recording:
            if elapsedTimer == nil {
                timerStartDate = Date()
                elapsedTimer = Timer.scheduledTimer(
                    withTimeInterval: 1.0,
                    repeats: true
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.timerTick()
                    }
                }
            }
        case .paused:
            // Stop advancing but keep accumulated elapsed.
            cancelTimer()
        default:
            // Idle / stopped / failed: reset.
            cancelTimer()
            elapsedSeconds = 0
        }
    }

    private func timerTick() {
        guard let start = timerStartDate else { return }
        elapsedSeconds += Date().timeIntervalSince(start)
        timerStartDate = Date()
        renderCurrentState()
    }

    private func cancelTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        timerStartDate = nil
    }

    // MARK: - Formatting

    /// Format a `TimeInterval` as `HH:MM:SS`.
    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - NSStatusItemRenderer (production AppKit renderer)

/// The production `MenuBarRenderer`. Owns a single `NSStatusItem` and translates
/// `MenuDescriptor` → `NSMenu` every time `render(iconState:menuDescriptor:)` is called.
///
/// NOT used in tests — the test double `RecordingMenuBarRenderer` is injected instead.
@MainActor
public final class NSStatusItemRenderer: MenuBarRenderer {

    // MARK: - SF Symbol names

    private enum Icon {
        static let idle      = "waveform"
        static let recording = "record.circle.fill"
        static let paused    = "pause.circle"
    }

    private let statusItem: NSStatusItem
    private var actionStore: [String: @MainActor @Sendable () async -> Void] = [:]

    public init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    // MARK: - MenuBarRenderer

    public func render(iconState: MenuBarIconState, menuDescriptor: MenuDescriptor) {
        updateIcon(iconState)
        updateMenu(menuDescriptor)
    }

    // MARK: - Icon

    private func updateIcon(_ state: MenuBarIconState) {
        guard let button = statusItem.button else { return }
        let symbolName: String
        let tintColor: NSColor?

        switch state {
        case .idle:
            symbolName = Icon.idle
            tintColor = nil
        case .recording:
            symbolName = Icon.recording
            tintColor = .systemRed
        case .paused:
            symbolName = Icon.paused
            tintColor = nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        if var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image = image.withSymbolConfiguration(config) ?? image
            if let color = tintColor {
                // For the recording dot use a non-template colored image.
                image.isTemplate = false
                let colored = NSImage(size: image.size, flipped: false) { rect in
                    color.set()
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    return true
                }
                button.image = colored
            } else {
                image.isTemplate = true
                button.image = image
            }
        }
    }

    // MARK: - Menu

    private func updateMenu(_ descriptor: MenuDescriptor) {
        let menu = NSMenu()
        buildItems(descriptor.items, into: menu)
        statusItem.menu = menu
    }

    private func buildItems(_ items: [MenuDescriptor.Item], into menu: NSMenu) {
        for item in items {
            switch item {
            case .header(let title):
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)

            case .separator:
                menu.addItem(NSMenuItem.separator())

            case .action(let title, let handler):
                let mi = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
                mi.target = self
                // Store handler keyed by title (titles are unique within a menu context).
                actionStore[title] = handler
                mi.representedObject = title
                menu.addItem(mi)

            case .submenu(let title, let children):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: title)
                buildItems(children, into: sub)
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let handler = actionStore[key] else { return }
        Task { @MainActor in
            await handler()
        }
    }
}
