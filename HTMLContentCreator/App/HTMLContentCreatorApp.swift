import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = NSImage(named: NSImage.Name("AppIcon")) ??
            Bundle.main
            .url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }

        guard let icon else { return }
        NSApp.applicationIconImage = icon
    }
}

@main
struct HTMLContentCreatorApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
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
