import SwiftUI

/// First-start screen. Shows each setup step and installs the missing ones.
struct SetupView: View {
    @ObservedObject var setup: SetupManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up the TV").font(.title2.weight(.semibold))
                    Text("TVDroid needs the Android emulator and a Google TV system image. "
                         + "The download is about 2 GB. You need about 10 GB of free disk space.")
                        .foregroundStyle(.secondary)
                    if let testHome = Tools.testHome {
                        Text("Test mode: files go to \(testHome)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(SetupManager.Step.allCases.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().opacity(0.4) }
                        SetupStepRow(step: step, status: setup.status[step] ?? .checking, setup: setup)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))

                HStack(spacing: 12) {
                    Button {
                        Task { await setup.install() }
                    } label: {
                        Label(setup.isWorking ? "Installing…" : "Install", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(setup.isWorking || !setup.hasChecked)

                    Button("Check Again") { Task { await setup.refresh() } }
                        .buttonStyle(PillButtonStyle())
                        .disabled(setup.isWorking)

                    Button("Show Log") { setup.revealLogs() }
                        .buttonStyle(PillButtonStyle())

                    if setup.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let progress = setup.progress {
                    Text(progress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }

                if !setup.log.isEmpty { logView }

                DisclosureGroup("Advanced: Java, SDK folder and Terminal") {
                    AdvancedSetupView(setup: setup).padding(.top, 10)
                }
                .font(.callout)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(setup.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("==>") ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .textSelection(.enabled)
                .padding(12)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
            .onChange(of: setup.log.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct SetupStepRow: View {
    let step: SetupManager.Step
    let status: SetupManager.Status
    @ObservedObject var setup: SetupManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22).accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                if step == .java, let java = setup.java, java.isSupported {
                    Text("Java \(java.major) · \(java.home)")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    if !java.registered, java.bundle != nil {
                        HStack(spacing: 8) {
                            Text("Terminal cannot find this Java.").font(.caption).foregroundStyle(.orange)
                            Button("Register Java") { Task { await setup.registerJava() } }
                                .buttonStyle(.link).font(.caption)
                                .help("Links it into /Library/Java/JavaVirtualMachines. Asks for your Mac password.")
                        }
                    }
                }
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button("Open in Terminal") { setup.openInTerminal(step) }
                            .help("Opens the command in your shell (\(UserShell.name)), ready to edit and run.")
                        Button("Copy Command") { setup.copyCommand(step) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var statusText: String {
        switch status {
        case .checking: return "Checking"
        case .running: return "Installing"
        case .done: return "Done"
        case .missing: return "Not installed"
        case .failed: return "Failed"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .checking, .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Java and SDK folder overrides, and helpers to use the same tools in Terminal.
struct AdvancedSetupView: View {
    @ObservedObject var setup: SetupManager
    @StateObject private var form = AdvancedForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PathField(title: "Java home", placeholder: setup.java?.home ?? "Automatic", text: $form.javaHome,
                      help: "The folder that contains bin/java, for example /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")
            PathField(title: "Android SDK", placeholder: Tools.sdkRoot.path, text: $form.sdkRoot,
                      help: "Leave empty to find the SDK automatically (ANDROID_HOME, Homebrew, ~/Library/Android/sdk).")
            HStack(spacing: 10) {
                Button("Save and Check") { Task { await setup.saveOverrides(javaHome: form.javaHome, sdkRoot: form.sdkRoot) } }
                Button("Use Automatic") {
                    form.javaHome = ""; form.sdkRoot = ""
                    Task { await setup.saveOverrides(javaHome: "", sdkRoot: "") }
                }
            }
            .disabled(setup.isWorking)

            Divider().opacity(0.4)

            Text("Terminal uses your \(UserShell.rcFile.lastPathComponent). TVDroid uses the variables from it too.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(setup.shellProfileInstalled ? "Update \(UserShell.rcFile.lastPathComponent)" : "Add to \(UserShell.rcFile.lastPathComponent)") {
                    setup.installShellProfile()
                }
                .help("Adds JAVA_HOME, ANDROID_HOME and PATH, so sdkmanager, adb and emulator work in Terminal.")
                Button("Open Terminal with SDK") { setup.openShell() }
                    .help("A Terminal window with the same Java and SDK as TVDroid.")
            }

            if let notice = setup.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear {
            form.javaHome = Prefs.javaHome ?? ""
            form.sdkRoot = Prefs.sdkRoot ?? ""
        }
    }
}

final class AdvancedForm: ObservableObject {
    @Published var javaHome = ""
    @Published var sdkRoot = ""
}

private struct PathField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose…") { choose() }
            }
            Text(help).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { text = url.path }
    }
}
