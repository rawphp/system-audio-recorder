import AppKit
import Observation

// MARK: - ActivationPolicySetting (test seam)

/// Abstracts `NSApp.setActivationPolicy(_:)` for testability.
///
/// The production implementation forwards the call to `NSApp`.
/// Tests inject a `SpyActivationPolicySetting` that records every call.
public protocol ActivationPolicySetting: AnyObject {
    func set(_ policy: NSApplication.ActivationPolicy)
}

// MARK: - NSAppActivationPolicySetting (production)

/// Production implementation: delegates directly to `NSApp`.
public final class NSAppActivationPolicySetting: ActivationPolicySetting {
    public init() {}

    public func set(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }
}

// MARK: - DockPolicyController

/// Observes `AppSettings.showInDock` and applies the matching
/// `NSApplication.ActivationPolicy` to keep the Dock icon state in sync.
///
/// ## Usage
/// ```swift
/// let controller = DockPolicyController(settings: settings)
/// controller.start()   // call once in .onAppear
/// ```
///
/// ## Activation policy semantics
/// - `showInDock = true`  → `.regular`  (icon in Dock, Command+Tab switcher)
/// - `showInDock = false` → `.accessory` (no Dock icon; app stays alive via status item)
///
/// With `.accessory`, SwiftUI's `WindowGroup` does **not** terminate the process when
/// the last window closes — the status item (REQ-031) keeps the run loop alive.
@MainActor
public final class DockPolicyController {

    // MARK: - Private storage

    private let settings: AppSettings
    private let policy: ActivationPolicySetting

    // MARK: - Initialisation

    /// - Parameters:
    ///   - settings: The shared `AppSettings` instance.
    ///   - policy: Seam for `NSApp.setActivationPolicy`. Defaults to the
    ///     production `NSAppActivationPolicySetting`.
    public init(
        settings: AppSettings,
        policy: ActivationPolicySetting = NSAppActivationPolicySetting()
    ) {
        self.settings = settings
        self.policy = policy
    }

    // MARK: - Public API

    /// Apply the current `showInDock` value and begin observing future changes.
    ///
    /// Call once from `.onAppear` in `SystemAudioRecorderApp`. The recursive
    /// `withObservationTracking` loop re-runs `apply()` whenever
    /// `settings.showInDock` changes.
    public func start() {
        observeAndApply()
    }

    /// Apply the current `showInDock` value immediately.
    ///
    /// Exposed as `public` so tests can drive it directly without the
    /// `withObservationTracking` recursion.
    public func apply() {
        let activationPolicy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        policy.set(activationPolicy)
    }

    // MARK: - Private

    /// Recursive `withObservationTracking` loop.
    ///
    /// Each call to `apply()` inside the tracking block registers a dependency on
    /// `settings.showInDock`. When that property changes, the `onChange` closure
    /// fires and we recurse to re-apply and re-register the dependency.
    private func observeAndApply() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            // `onChange` is called on an arbitrary thread; dispatch to MainActor.
            DispatchQueue.main.async { [weak self] in
                self?.observeAndApply()
            }
        }
    }
}
