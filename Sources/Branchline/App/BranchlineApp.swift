import SwiftUI

@main
struct BranchlineApp: App {
    @NSApplicationDelegateAdaptor(BranchlineAppDelegate.self) private var appDelegate
    @State private var store = BranchlineStore()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .task { store.startBackgroundAutoFetch() }
        }
        .defaultSize(width: 1440, height: 850)
        .commands { BranchlineCommands(store: store, updater: updater) }

        Settings {
            SettingsView(store: store)
        }
    }
}

@MainActor
final class BranchlineAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
