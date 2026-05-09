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
        .windowResizability(.contentSize)
    }
}
