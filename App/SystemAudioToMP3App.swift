import AppKit
import SwiftUI

@main
struct SystemAudioToMP3App: App {
    @State private var appStore = AppStore()

    /// Menu-bar controller — kept alive as long as the app runs.
    /// Initialized once in `.onAppear` to ensure AppKit is ready.
    @State private var menuBarController: MenuBarController?

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
                }
        }
        .windowResizability(.contentSize)
    }
}
