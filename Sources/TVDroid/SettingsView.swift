import SwiftUI

/// TVDroid ▸ Settings… (⌘,)
struct SettingsView: View {
    @ObservedObject var tv: TVController
    @ObservedObject var setup: SetupManager
    @ObservedObject var library: APKLibrary
    @ObservedObject var gamepads = GameControllerBridge.shared
    @ObservedObject var hid = HIDGamepads.shared
    @ObservedObject var root = RootManager.shared
    @StateObject private var form = SettingsForm()

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Screen size", selection: $form.resolution) {
                        Text("1080p (1920 × 1080)").tag(Prefs.Resolution.p1080)
                        Text("720p (1280 × 720) – faster on older Macs").tag(Prefs.Resolution.p720)
                    }
                    .disabled(root.busyMessage != nil || tv.isBusy)
                    .onChange(of: form.resolution) { _, value in
                        Prefs.resolution = value
                        Task { await tv.restart() }
                    }
                    Text("The TV restarts when you change the screen size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Home app") {
                    if tv.state != .ready {
                        Text("Turn on the TV to choose the home app.").foregroundStyle(.secondary)
                    } else if tv.homeApps.count < 2 {
                        Text("Install another launcher (for example Projectivy Launcher) to use it as the home screen.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Home screen", selection: Binding(
                            get: { tv.currentHome ?? "" },
                            set: { package in Task { await tv.setHome(package) } }
                        )) {
                            ForEach(tv.homeApps) { Text(homeName($0.package)).tag($0.package) }
                        }
                    }
                    Text("Google TV has no setting for this. TVDroid turns the Google TV launcher off when you choose another one (it is not removed). Choose Google TV to turn it on again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear { Task { await tv.loadHomeApps() } }
                .onChange(of: tv.state) { _, _ in Task { await tv.loadHomeApps() } }
                Section("Battery") {
                    Picker("Turn off the TV when unused for", selection: $form.idleMinutes) {
                        Text("Never").tag(0)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    Text("Unused: no key, click, remote or controller input and no video playing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Toggle("Type characters, not key positions", isOn: $form.typeByCharacter)
                    Text("Turn on for a non-US Mac keyboard: the TV gets the letter you see on the key. Letters a US keyboard does not have (é, ü) cannot be typed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Game controllers") {
                    ForEach(hid.pads) { pad in
                        HStack {
                            Label(pad.name, systemImage: "gamecontroller.fill")
                            Text("generic").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Set Up Buttons…") { hid.startLearning(pad) }
                            Button("Reset") { hid.resetMap(pad) }
                        }
                    }
                    if gamepads.controllers.isEmpty && hid.pads.isEmpty {
                        Text("None connected. Pair a PlayStation, Xbox or other controller in System Settings ▸ Bluetooth.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(gamepads.controllers, id: \.self) { Label($0, systemImage: "gamecontroller") }
                    }
                    Text("Controllers work in games and on the home screen: A selects, B goes back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Reset") {
                    Button("Reset TV…", role: .destructive) { form.confirmReset = true }
                        .disabled(tv.isBusy)
                    Text("Erases all apps, accounts and settings on the TV. Your APK files stay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: UpdateChecker.currentVersion)
                    Button("Check for Updates…") { Task { await UpdateChecker.check(userInitiated: true) } }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("TV", systemImage: "tv") }

            RootSettingsView(tv: tv, root: root, form: form)
                .tabItem { Label("Root", systemImage: "lock.open") }

            ScrollView {
                AdvancedSetupView(setup: setup).padding(20)
            }
            .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 520)
        .sheet(isPresented: Binding(get: { hid.learning != nil }, set: { if !$0 { hid.cancelLearning() } })) {
            ButtonSetupView(hid: hid)
        }
        .confirmationDialog("Reset the TV?", isPresented: $form.confirmReset) {
            Button("Reset TV", role: .destructive) { Task { await tv.resetTV() } }
        } message: {
            Text("All apps, accounts and settings on the TV are erased.")
        }
    }
}

extension SettingsView {
    func homeName(_ package: String) -> String {
        switch package {
        case TVController.googleLauncher: return "Google TV"
        case "com.spocky.projengmenu": return "Projectivy Launcher"
        default: return library.items.first { $0.packageName == package }?.label ?? package
        }
    }
}

/// Asks for each button of a generic controller in turn.
struct ButtonSetupView: View {
    @ObservedObject var hid: HIDGamepads

    var body: some View {
        let step = hid.learning?.step ?? 0
        VStack(spacing: 16) {
            Text("Set Up Buttons").font(.title2.weight(.semibold))
            Text("Press the button for").foregroundStyle(.secondary)
            Text(hid.learning?.target?.title ?? "").font(.title3.weight(.medium))
            ProgressView(value: Double(step), total: Double(HIDGamepads.Target.allCases.count))
            Text("The sticks and the D-pad work without setup.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { hid.cancelLearning() }
                Spacer()
                Button("Skip (no such button)") { hid.skipStep() }
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// Plain ObservableObject instead of @State: the SwiftUI macros are missing with Command Line Tools only.
final class SettingsForm: ObservableObject {
    @Published var resolution = Prefs.resolution
    /// Count unused time from now: turning the setting on must not turn off a TV that sat unused before.
    @Published var idleMinutes = Prefs.idleTurnOffMinutes {
        didSet { Prefs.idleTurnOffMinutes = idleMinutes; TVActivity.touch() }
    }
    @Published var typeByCharacter = Prefs.typeByCharacter { didSet { Prefs.typeByCharacter = typeByCharacter } }
    @Published var confirmReset = false
    @Published var confirmRoot = false
}

/// Settings ▸ Root: rooted TV (experimental), ad blocking, app backup.
struct RootSettingsView: View {
    @ObservedObject var tv: TVController
    @ObservedObject var root: RootManager
    @ObservedObject var form: SettingsForm

    var body: some View {
        Form {
            Section {
                Toggle("Rooted TV (experimental)", isOn: Binding(
                    get: { root.isOn },
                    set: { on in
                        if on { form.confirmRoot = true } else { Task { await root.setRoot(false, tv: tv) } }
                    }
                ))
                .disabled(root.busyMessage != nil || tvBusy)
                if root.needsNewPatch {
                    Button("Set Up Root Again") { Task { await root.setRoot(true, tv: tv) } }
                        .disabled(root.busyMessage != nil || tvBusy)
                }
                Text(statusText).foregroundStyle(root.isWorking ? .green : .secondary)
                Text("TVDroid patches a copy of the TV's ramdisk with Magisk (made with rootAVD) and starts the TV with it. Google TV, the Play Store and your apps stay. `adb shell su` works without a prompt. Turn it off to start the original TV again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ad blocking") {
                Toggle("Block ads and trackers on the whole TV", isOn: Binding(
                    get: { root.adBlocking },
                    set: { on in Task { await root.setAdBlocking(on, tv: tv) } }
                ))
                .disabled(!root.isWorking || root.busyMessage != nil || tvBusy)
                if root.adBlocking {
                    Button("Update Block List") { Task { await root.setAdBlocking(true, tv: tv) } }
                        .disabled(root.busyMessage != nil || tvBusy)
                }
                Text("Uses the StevenBlack hosts list as a Magisk module. Android restarts when you turn it on or off. Ads that come from the same servers as the video (for example on YouTube) are not blocked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App backup") {
                HStack {
                    Button("Back Up Apps") { Task { await root.backUpApps(tv: tv) } }
                    Button("Restore Backup…") { Task { await root.restoreBackup(tv: tv) } }
                    Spacer()
                    Button("Show Backups") { root.openBackupsFolder() }
                }
                .disabled(!root.isWorking || root.busyMessage != nil || tvBusy)
                Text("Saves every app you installed, with its data (logins, settings), to ~/TVDroid/Backups. Restore it after a Reset TV. Files in the shared storage (Downloads, Movies) are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = root.busyMessage {
                HStack { ProgressView().controlSize(.small); Text(message) }
            }
            if let error = root.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Root the TV?", isPresented: $form.confirmRoot) {
            Button("Root the TV") { Task { await root.setRoot(true, tv: tv) } }
        } message: {
            Text("TVDroid downloads rootAVD and Magisk, patches the TV and restarts it. This takes about a minute. Apps with root can change everything on the TV, so give root only to apps you trust. Root does not improve Netflix quality or Play Integrity checks.")
        }
    }

    private var tvBusy: Bool { tv.busyMessage != nil || tv.busyItem != nil }

    private var statusText: String {
        if root.needsNewPatch { return "The TV system image changed, so the TV starts without root. Click Set Up Root Again." }
        if root.isWorking { return "Root works." }
        if root.isOn { return tv.state == .ready ? "Root is on, but it does not work yet." : "Root is on. Start the TV to use it." }
        return "Root is off."
    }
}

/// Menu bar: TV menu with screenshot, recording, restart.
struct TVCommands: Commands {
    @ObservedObject var tv: TVController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await UpdateChecker.check(userInitiated: true) } }
        }
        CommandMenu("TV") {
            Button("Show TV") { Task { await tv.showTV() } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Take Screenshot") { Task { await tv.screenshot() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(tv.state != .ready)
            Button(tv.isRecording ? "Stop Recording" : "Start Recording") { Task { await tv.toggleRecording() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(tv.state != .ready && !tv.isRecording)
            Divider()
            Toggle("Keep TV on Top", isOn: $tv.keepTVOnTop)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Restart TV") { Task { await tv.restart() } }
                .disabled(tv.state == .off || tv.isBusy)
            Button("Turn Off TV") { Task { await tv.stop() } }
                .disabled(tv.state == .off || tv.isBusy)
        }
    }
}
