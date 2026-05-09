import SwiftUI

@main
struct SystemAudioToMP3App: App {
    @State private var appStore = AppStore()

    var body: some Scene {
        WindowGroup("System Audio Recorder") {
            ContentView()
                .environment(\.appStore, appStore)
        }
        .windowResizability(.contentSize)
    }
}
