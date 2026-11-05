import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: StreamStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { store?.shutdown() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct SmixxStreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = StreamStore()
    var body: some Scene {
        Window("Smixx Stream",id: "studio") {
            ContentView(store: store).onAppear { delegate.store = store }
        }.defaultSize(width: 1160,height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Open Program") { store.openProgram() }.keyboardShortcut("p",modifiers: [.command,.shift])
                Button("Pause / resume presentation") { if store.presenting { store.togglePause() } }.keyboardShortcut(".",modifiers: [.command])
                Button("Stop presentation") { store.stopPresentation() }.keyboardShortcut(.escape,modifiers: [])
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { store.setup = true }.keyboardShortcut(",",modifiers: .command) }
        }
    }
}
