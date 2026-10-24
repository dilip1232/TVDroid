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
                        SetupStepRow(step: step, status: setup.status[step] ?? .checking)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22).accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
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
