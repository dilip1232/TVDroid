import AppKit
import SwiftUI

/// Shared state for the views on top of the TV picture.
@MainActor
final class TVOverlayState: ObservableObject {
    @Published var hasPicture = false
    @Published var isFullScreen = false
}

/// The window that shows the TV. Closing it only hides it; the TV keeps running.
@MainActor
final class TVWindowController: NSObject, NSWindowDelegate {
    static let shared = TVWindowController()

    private var window: NSWindow?
    private var container: TVContainerView?
    private let state = TVOverlayState()

    func show(fullScreen: Bool) {
        if window == nil { makeWindow() }
        guard let window, let container else { return }
        hideAfterFullScreen = false
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(container.screen)
        NSApp.activate(ignoringOtherApps: true)
        container.showControls()
        if fullScreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private var hideAfterFullScreen = false

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// Shown (not closed and not in the Dock). Video in a hidden window does not keep the display awake.
    var isShown: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    /// Shows an error on the TV window when you watch the TV, or when no other TVDroid window is open.
    /// - Returns: false when the main window should show it.
    func showError(_ message: String) -> Bool {
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        // A window that leaves full screen to hide would take a sheet away with it.
        let hiding = hideAfterFullScreen
        let watching = !hiding && (window?.isKeyWindow == true || isFullScreen)
        guard watching || !others else { return false }
        let alert = NSAlert()
        alert.messageText = "TVDroid"
        alert.informativeText = message
        if let window, window.isVisible, !hiding {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        return true
    }

    /// The TV window is on screen and not covered by other windows.
    var isOnScreen: Bool { window?.occlusionState.contains(.visible) == true && window?.isVisible == true }

    func hide() {
        guard let window else { return }
        // Leave full screen first. Hiding the window during the animation can leave it in a broken state.
        if window.styleMask.contains(.fullScreen) {
            hideAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
    }

    /// Call after the emulator starts again, so the view maps the new shared memory.
    func reconnect() {
        container?.screen.renderer.reconnect()
        EmulatorConsole.shared.reset()
    }

    private func makeWindow() {
        guard let screen = TVScreenView(port: TVController.port) else {
            NSLog("TVDroid: Metal is not available")
            return
        }
        let container = TVContainerView(screen: screen, state: state)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "TVDroid TV"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.contentAspectRatio = CGSize(width: 16, height: 9)
        window.contentMinSize = CGSize(width: 640, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = container
        window.delegate = self
        window.setFrameAutosaveName("TVDroidTV")
        // A frame saved on a monitor that is now unplugged would open the window off-screen.
        if !window.setFrameUsingName("TVDroidTV") || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        self.window = window
        self.container = container
    }

    // MARK: NSWindowDelegate

    /// Hide instead of close. A closed window can be the "last window", and then the app quits and turns the TV off.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        state.isFullScreen = true
        container?.needsLayout = true
        container?.setTrafficLights(visible: false, animated: false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        container?.showControls()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        state.isFullScreen = false
        container?.needsLayout = true
        if hideAfterFullScreen {
            hideAfterFullScreen = false
            window?.orderOut(nil)
            return
        }
        container?.showControls()
    }

    /// Controllers stop driving the TV when its window is covered (see `acceptsInput`). Then nothing may stay held.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if !GameControllerBridge.shared.acceptsInput { VirtualGamepad.shared.releaseAll() }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if !GameControllerBridge.shared.acceptsInput { VirtualGamepad.shared.releaseAll() }
    }

    func windowDidResignKey(_ notification: Notification) {
        VirtualKeyboard.shared.releaseAll()
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

// MARK: - Container

/// Holds the picture and the "starting" view. All clicks go to the picture.
/// The window buttons and the cursor hide after a short time without mouse movement, like a video player.
@MainActor
final class TVContainerView: NSView {
    let screen: TVScreenView
    private let state: TVOverlayState
    private var loading: PassthroughHostingView<TVLoadingView>!
    private var backButton: NSHostingView<TVNavButtons>!
    private var hideTimer: Timer?
    private var chromeVisible = true

    private static let hideDelay: TimeInterval = 2.5

    init(screen: TVScreenView, state: TVOverlayState) {
        self.screen = screen
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        screen.frame = bounds
        screen.autoresizingMask = [.width, .height]
        addSubview(screen)

        loading = PassthroughHostingView(rootView: TVLoadingView())
        loading.frame = bounds
        loading.autoresizingMask = [.width, .height]
        addSubview(loading)

        backButton = NSHostingView(rootView: TVNavButtons { [weak self] key in
            EmulatorConsole.shared.press(key)
            if let self { self.window?.makeFirstResponder(self.screen) }
        })
        backButton.frame.size = backButton.fittingSize
        addSubview(backButton)

        screen.renderer.onPictureChange = { [weak self] hasPicture in
            guard let self else { return }
            self.state.hasPicture = hasPicture
            if !hasPicture { self.loading.isHidden = false }
            self.showControls()
            self.setTrafficLights(visible: true, animated: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                self.loading.animator().alphaValue = hasPicture ? 0 : 1
            } completionHandler: {
                MainActor.assumeIsolated { self.loading.isHidden = self.state.hasPicture }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Send every click to the TV picture, also where the loading view is on top.
    /// The only exception is the Back button when it shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        if !backButton.isHidden, backButton.alphaValue > 0.5, backButton.frame.contains(local) {
            return backButton.hitTest(convert(local, to: backButton.superview)) ?? backButton
        }
        return screen
    }

    /// Keep the Back button at the top left, below the window buttons.
    override func layout() {
        super.layout()
        let size = backButton.fittingSize
        let top: CGFloat = state.isFullScreen ? 20 : 40
        backButton.frame = CGRect(x: 20, y: bounds.height - size.height - top, width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { showControls() }
    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseExited(with event: NSEvent) { scheduleHide(after: 0.6) }

    // MARK: Window buttons and cursor

    func showControls() {
        if !chromeVisible {
            chromeVisible = true
            setTrafficLights(visible: true, animated: true)
        }
        needsLayout = true
        scheduleHide(after: Self.hideDelay)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideChrome() }
        }
    }

    private func hideChrome() {
        guard let window else { return }
        chromeVisible = false
        setTrafficLights(visible: false, animated: true)
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if window.isKeyWindow, bounds.contains(mouse) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func setTrafficLights(visible: Bool, animated: Bool) {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let alpha: CGFloat = visible || state.isFullScreen ? 1 : 0
        let backAlpha: CGFloat = visible && state.hasPicture ? 1 : 0
        if backAlpha > 0 { backButton.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.25 : 0
            (animated ? backButton.animator() : backButton).alphaValue = backAlpha
            for type in buttons {
                guard let button = window.standardWindowButton(type) else { continue }
                (animated ? button.animator() : button).alphaValue = alpha
            }
        } completionHandler: {
            // A hidden button (not only a clear one) lets macOS show the TV layer without
            // compositing an overlay on every frame, which matters most in full screen.
            MainActor.assumeIsolated {
                if self.backButton.alphaValue == 0 { self.backButton.isHidden = true }
            }
        }
    }
}

/// A hosting view that never takes mouse clicks.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - SwiftUI overlays

/// Back and Home buttons on top of the picture. They send the Android keys.
struct TVNavButtons: View {
    let send: (EmulatorConsole.Key) -> Void

    var body: some View {
        HStack(spacing: 8) {
            TVGlassButton(icon: "chevron.left", title: "Back", help: "Back (Esc or right-click)") { send(.back) }
            TVGlassButton(icon: "house.fill", title: "Home", help: "Home (⌥H)") { send(.home) }
        }
        .padding(4)
        .environment(\.colorScheme, .dark)
    }
}

struct TVGlassButton: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hover.on ? 0.35 : 0.15), lineWidth: 1))
            .scaleEffect(hover.on ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: hover.on)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// Shows while the TV starts and before the first frame arrives.
struct TVLoadingView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 72, height: 72)
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .purple.opacity(0.5), radius: 24)
                Text("Starting TV…")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
