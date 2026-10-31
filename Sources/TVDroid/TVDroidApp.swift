import AppKit
import SwiftUI

@main
struct TVDroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = APKLibrary()
    @StateObject private var tv = TVController()
    @StateObject private var remote = RemoteServer()
    @StateObject private var setup = SetupManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(tv)
                .environmentObject(remote)
                .environmentObject(setup)
                .onAppear {
                    appDelegate.tv = tv
                    appDelegate.library = library
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands { TVCommands(tv: tv) }

        Settings {
            SettingsView(tv: tv, setup: setup, library: library)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var tv: TVController?
    /// Files dropped on the Dock icon before the window exists wait here.
    private var pendingFiles: [URL] = []
    weak var library: APKLibrary? {
        didSet {
            guard let library, !pendingFiles.isEmpty else { return }
            MainActor.assumeIsolated { library.add(pendingFiles) }
            pendingFiles = []
        }
    }

    /// APKs dropped on the Dock icon (or opened with TVDroid in Finder) go into the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let library else { pendingFiles += urls; return }
        MainActor.assumeIsolated { library.add(urls) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Read ~/.zshrc (JAVA_HOME, ANDROID_HOME, PATH) early, so the first check does not wait.
        UserShell.preload()
        // A crash during "Rooted TV" setup can leave the patched ramdisk in the SDK. Put the original back.
        RootManager.restoreStockRamdisk()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            GameControllerBridge.shared.start()
            UpdateChecker.checkAtLaunch()
        }
    }

    /// Keep running while the TV is on. The Dock icon or ⇧⌘T brings the windows back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { tv?.state ?? .off == .off }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { tv?.stopSync() }
        Shell.terminateAll()
    }
}
