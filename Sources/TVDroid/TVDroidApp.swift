import AppKit
import SwiftUI

@main
struct TVDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = APKLibrary()
    @StateObject private var tv = TVController()
    @StateObject private var remote = RemoteServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(tv)
                .environmentObject(remote)
                .onAppear { appDelegate.tv = tv }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var tv: TVController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { tv?.stopSync() }
    }
}
