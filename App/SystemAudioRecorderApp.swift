import AppKit
import SwiftUI

@main
struct SystemAudioRecorderApp: App {
    @State private var appStore = AppStore()

    /// Menu-bar controller — kept alive as long as the app runs.
    /// Initialized once in `.onAppear` to ensure AppKit is ready.
    @State private var menuBarController: MenuBarController?

    /// Dock policy controller — binds `AppSettings.showInDock` to
    /// `NSApp.setActivationPolicy(_:)`. Kept alive for the app lifetime.
    @State private var dockPolicyController: DockPolicyController?

    var body: some Scene {
        WindowGroup("System Audio Recorder") {
            ContentView()
                .environment(\.appStore, appStore)
                .onAppear {
                    // Defer to the next runloop tick so SwiftUI's first layout
                    // pass for this WindowGroup has completed. NSStatusItem
                    // creation and NSApp.setActivationPolicy(_:) both mutate
                    // window-server state and, if invoked synchronously inside
                    // .onAppear, can re-enter layout on the view currently
                    // being laid out (logs: "It's not legal to call
                    // -layoutSubtreeIfNeeded on a view which is already being
                    // laid out").
                    DispatchQueue.main.async {
                        if menuBarController == nil {
                            let renderer = NSStatusItemRenderer()
                            let controller = MenuBarController(store: appStore, renderer: renderer)
                            menuBarController = controller
                            controller.start()
                        }

                        if dockPolicyController == nil {
                            let controller = DockPolicyController(settings: appStore.settings)
                            dockPolicyController = controller
                            controller.start()
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
