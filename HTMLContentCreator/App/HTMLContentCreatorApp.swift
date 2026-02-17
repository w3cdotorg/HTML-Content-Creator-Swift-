import SwiftUI

@main
struct HTMLContentCreatorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrapIfNeeded()
                }
        }
        .windowResizability(.contentSize)
    }
}
