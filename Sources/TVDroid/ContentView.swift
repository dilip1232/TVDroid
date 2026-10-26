import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: APKLibrary
    @EnvironmentObject var tv: TVController
    @EnvironmentObject var remote: RemoteServer
    @EnvironmentObject var setup: SetupManager
    @StateObject private var ui = UIState()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.09, green: 0.11, blue: 0.19)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if !setup.hasChecked {
                    Spacer()
                    ProgressView("Checking the setup…")
                    Spacer()
                } else if !setup.isComplete {
                    SetupView(setup: setup)
                } else if library.items.isEmpty {
                    EmptyLibraryView { library.revealFolder() }
                } else {
                    grid
                }
                footer
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Dropped .apk, .xapk, .apks and .apkm files are copied into the APK folder.
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in library.add([url]) }
                }
            }
            return true
        }
        .onChange(of: setup.isComplete) { _, done in
            // APKs that were read before the setup have no icon or name (aapt2 was missing).
            if done { Task { await library.rescan() } }
        }
        .alert("Cannot open the app", isPresented: Binding(
            get: { tv.errorMessage != nil },
            set: { if !$0 { tv.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tv.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("TVDroid").font(.system(size: 24, weight: .bold, design: .rounded))
                StatusPill(state: tv.state)
            }
            Spacer()
            if setup.isComplete { headerButtons }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var headerButtons: some View {
        Button {
            remote.refreshURL()
            ui.showRemote.toggle()
        } label: {
            Label("Phone Remote", systemImage: "iphone.gen3")
        }
        .buttonStyle(PillButtonStyle())
        .popover(isPresented: $ui.showRemote, arrowEdge: .bottom) {
            RemotePopover(remote: remote)
        }
        Button {
            library.revealFolder()
        } label: {
            Label("APK Folder", systemImage: "folder")
        }
        .buttonStyle(PillButtonStyle())
        Button {
            Task { await tv.showTV() }
        } label: {
            Label("Show TV", systemImage: "tv")
        }
        .buttonStyle(PillButtonStyle())
        .disabled(tv.busyMessage != nil)
        .help("Opens the TV window. Starts the TV if it is off.")
        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(PillButtonStyle())
        .help("Screen size, home app, game controllers, root, and setup tools (⌘,).")
        if tv.state != .off {
            Button {
                Task { await tv.stop() }
            } label: {
                Label("Turn Off TV", systemImage: "power")
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 24)], spacing: 28) {
                ForEach(library.items) { item in
                    AppTile(
                        item: item,
                        isSelected: ui.selection == item.url,
                        busyMessage: tv.busyItem == item.url ? tv.busyMessage : nil
                    )
                    .onTapGesture(count: 2) { open(item) }
                    .simultaneousGesture(TapGesture().onEnded { ui.selection = item.url })
                    .contextMenu {
                        Button("Open") { open(item) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("Uninstall from TV") { Task { await tv.uninstall(item) } }
                            .disabled(item.packageName == nil || tv.busyItem != nil)
                        Button("Move to Trash") { library.trash(item) }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Hint(keys: "Double-click", text: "open an app")
            Hint(keys: "Drop", text: "add APKs")
            Hint(keys: "Arrows + Return", text: "move and select")
            Hint(keys: "Esc", text: "back")
            Hint(keys: "⌥H", text: "home")
            Hint(keys: "⌘F", text: "full screen")
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.black.opacity(0.25))
    }

    private func open(_ item: APKItem) {
        ui.selection = item.url
        Task { await tv.open(item) }
    }
}

// MARK: - Local view state

// Plain ObservableObjects. The Command Line Tools SDK has no SwiftUI macro plugin for @State.
final class UIState: ObservableObject {
    @Published var selection: URL?
    @Published var showRemote = false
}
final class HoverState: ObservableObject { @Published var on = false }

// MARK: - Tile

struct AppTile: View {
    let item: APKItem
    let isSelected: Bool
    let busyMessage: String?
    @StateObject private var hover = HoverState()
    private var hovering: Bool { hover.on }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                artwork
                if let busyMessage {
                    Rectangle().fill(.black.opacity(0.55))
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular).tint(.white)
                        Text(busyMessage).font(.callout.weight(.medium))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected || hovering ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                  lineWidth: isSelected ? 3 : 1.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 18 : 8, y: hovering ? 10 : 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hover.on = $0 }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [item.isTVApp ? "TV app" : "Phone app"]
        if let v = item.versionName, !v.isEmpty { parts.append(v) }
        if item.packageName == nil { parts = ["Cannot read this APK"] }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let banner = item.banner {
            Image(nsImage: banner).resizable().scaledToFill()
        } else if let icon = item.icon {
            ZStack {
                Image(nsImage: icon).resizable().scaledToFill().blur(radius: 40).saturation(1.4)
                Rectangle().fill(.black.opacity(0.25))
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            }
        } else {
            ZStack {
                LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(item.label.prefix(1)).uppercased())
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var placeholderColors: [Color] {
        let palettes: [[Color]] = [[.purple, .blue], [.orange, .pink], [.teal, .blue], [.green, .teal], [.red, .orange]]
        let index = abs(item.label.hashValue) % palettes.count
        return palettes[index]
    }
}

// MARK: - Small views

struct StatusPill: View {
    let state: TVController.State

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .off: return .gray
        case .starting: return .orange
        case .ready: return .green
        }
    }

    private var text: String {
        switch state {
        case .off: return "TV is off"
        case .starting: return "TV is starting…"
        case .ready: return "TV is on"
        }
    }
}

struct RemotePopover: View {
    @ObservedObject var remote: RemoteServer

    var body: some View {
        VStack(spacing: 14) {
            Text("Phone Remote").font(.headline)
            if let url = remote.url, let qr = remote.qrCode(size: 200) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                Text("Scan with your phone camera. Your phone must be on the same Wi-Fi.")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Tip: add the page to your home screen. Then it opens like an app.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.tertiary)
            } else {
                Text(remote.isRunning ? "This Mac is not on a Wi-Fi or Ethernet network." : "The remote server is not running.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

struct EmptyLibraryView: View {
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("No apps yet").font(.title2.weight(.semibold))
            Text("Drop .apk, .xapk, .apks or .apkm files here, or put them in the APK folder.")
                .foregroundStyle(.secondary)
            Text(APKLibrary.folder.path.replacingOccurrences(of: Tools.home.path, with: "~"))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
            Button("Open APK Folder", action: openFolder)
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct Hint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            )
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
