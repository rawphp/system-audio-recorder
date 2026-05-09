import KeyboardShortcuts
import Observation
import SwiftUI

// MARK: - KeyboardShortcuts.Name extension

extension KeyboardShortcuts.Name {
    /// The global shortcut that toggles recording on/off.
    static let toggleRecording = Self("toggleRecording")
}

// MARK: - BindingError

/// Errors surfaced when shortcut registration fails.
///
/// Consumed by `HotkeyManager.lastBindingError`; future REQ-033 (ErrorSurface)
/// will observe this property to display a non-fatal banner.
public enum BindingError: Error, Equatable {
    /// Another process has claimed the requested key combination.
    case conflict(String)
}

// MARK: - HotkeyRegistrarError

/// Errors thrown by `HotkeyRegistrar.register(handler:)`.
public enum HotkeyRegistrarError: Error {
    /// macOS rejected the registration (e.g. another app owns the combination).
    case registrationFailed(String)
}

// MARK: - HotkeyRegistrar (protocol / test seam)

/// Abstracts the global-shortcut registration mechanism for testability.
///
/// The production implementation wraps `KeyboardShortcuts`; tests inject a
/// `StubHotkeyRegistrar` with deterministic behaviour.
public protocol HotkeyRegistrar: AnyObject {
    /// Register a handler that is called each time the user presses the bound shortcut.
    /// - Throws: `HotkeyRegistrarError.registrationFailed` when macOS rejects the binding.
    func register(handler: @escaping () -> Void) throws
    /// Deregister the previously registered handler.
    func unregister()
}

// MARK: - KeyboardShortcutsRegistrar (production)

/// Production implementation of `HotkeyRegistrar` wrapping the `KeyboardShortcuts` SPM package.
public final class KeyboardShortcutsRegistrar: HotkeyRegistrar {
    public init() {}

    public func register(handler: @escaping () -> Void) throws {
        // KeyboardShortcuts does not throw on conflict — it silently replaces.
        // The framework itself persists the key binding in UserDefaults.
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            handler()
        }
    }

    public func unregister() {
        KeyboardShortcuts.disable(.toggleRecording)
    }
}

// MARK: - HotkeyManager

/// `@Observable` manager for the global toggle-recording hotkey.
///
/// ## Lifecycle
/// 1. Create one `HotkeyManager` instance (typically owned by `AppStore`).
/// 2. Call `start(toggleHandler:)` after the app has finished launching; pass
///    the closure that should be executed when the user presses the bound
///    shortcut (e.g. `AppStore.toggleRecording`).
/// 3. Optionally call `stop()` to deregister the shortcut (e.g. on quit).
///
/// ## Settings UI
/// Use `HotkeyManager.recorder()` to get the SwiftUI binding recorder widget
/// for embedding in the Settings view.
///
/// ## Error surface
/// If registration fails (e.g. shortcut conflict), `lastBindingError` is set.
/// REQ-033 (`ErrorSurface`) will observe this property to present a banner.
@Observable
@MainActor
public final class HotkeyManager {

    // MARK: - Public state

    /// Set when shortcut registration fails. `nil` when there is no error.
    ///
    /// Future REQ-033 (ErrorSurface) will observe this to present a banner
    /// reading "Hotkey conflict — pick a different shortcut in Settings".
    public private(set) var lastBindingError: BindingError?

    // MARK: - Private

    private let registrar: HotkeyRegistrar

    // MARK: - Initialisation

    /// Production initialiser — uses the real `KeyboardShortcuts` registrar.
    public convenience init() {
        self.init(registrar: KeyboardShortcutsRegistrar())
    }

    /// Designated initialiser with an injectable `HotkeyRegistrar` seam.
    ///
    /// - Parameter registrar: Provide a `StubHotkeyRegistrar` in tests to avoid
    ///   hitting the real NSEvent-tap machinery.
    public init(registrar: HotkeyRegistrar) {
        self.registrar = registrar
    }

    // MARK: - Public API

    /// Register the global shortcut and wire `toggleHandler` as its action.
    ///
    /// - Parameter toggleHandler: Closure invoked each time the user presses the
    ///   bound shortcut. For the production app this will be
    ///   `AppStore.toggleRecording` (REQ-022).
    /// - Throws: `BindingError.conflict` when macOS rejects the registration.
    ///   The error is also written to `lastBindingError` so `@Observable` bindings
    ///   pick it up without additional try/catch at the call site.
    public func start(toggleHandler: @escaping () -> Void) throws {
        do {
            try registrar.register(handler: toggleHandler)
            lastBindingError = nil
        } catch let HotkeyRegistrarError.registrationFailed(message) {
            let bindingError = BindingError.conflict(message)
            lastBindingError = bindingError
            throw bindingError
        } catch {
            let bindingError = BindingError.conflict(error.localizedDescription)
            lastBindingError = bindingError
            throw bindingError
        }
    }

    /// Deregister the global shortcut.
    ///
    /// Call this when the app is quitting or the user disables the hotkey.
    public func stop() {
        registrar.unregister()
    }

    // MARK: - SwiftUI factory

    /// Returns the `KeyboardShortcuts` recorder widget for embedding in the
    /// Settings view (REQ-029 — `OutputSettingsView`).
    ///
    /// The recorder allows the user to bind or rebind the shortcut. The binding
    /// is persisted automatically in `UserDefaults` by the `KeyboardShortcuts`
    /// package and survives app restarts.
    ///
    /// Usage:
    /// ```swift
    /// HotkeyManager.recorder()
    ///     .padding()
    /// ```
    public static func recorder() -> some View {
        KeyboardShortcuts.Recorder("Toggle recording", name: .toggleRecording)
    }
}
