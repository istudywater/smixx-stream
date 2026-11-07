import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: StreamStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let store, store.recordingInProgress else { return .terminateNow }
            if store.recordingBusy && !store.recording { return .terminateCancel }
            Task { @MainActor in
                await store.stopRecording()
                // Leave the app open on failure so the recovery path remains visible.
                NSApp.reply(toApplicationShouldTerminate: store.recordingError == nil)
            }
            return .terminateLater
        }
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
                Button("Pause / resume presentation") { if store.presenting || store.recording { store.togglePause() } }.keyboardShortcut(".",modifiers: [.command])
                Button("Stop presentation") { store.stopPresentation() }.keyboardShortcut(.escape,modifiers: [])
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { store.setup = true }.keyboardShortcut(",",modifiers: .command) }
        }
    }
}
