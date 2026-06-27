import SwiftUI
import AppKit

struct OCRStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { model.startBrowsing() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files…") { model.openFilePicker() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        SwiftUI.Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Ensures the app activates as a normal foreground GUI app (needed when launched
/// as a bare SPM binary; harmless inside the .app bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
