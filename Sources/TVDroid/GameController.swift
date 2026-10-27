import AppKit
import GameController

/// A virtual USB gamepad in the TV. Android sees a real game controller, so games work,
/// and the TV home screen moves with the D-pad and stick. A selects, B goes back.
final class VirtualGamepad: @unchecked Sendable {
    static let shared = VirtualGamepad()

    /// Linux button codes (BTN_*).
    enum Button: Int, CaseIterable {
        case a = 304, b = 305, x = 307, y = 308
        case leftShoulder = 310, rightShoulder = 311
        case select = 314, start = 315, mode = 316, leftThumb = 317, rightThumb = 318
    }

    /// Linux axis codes (ABS_*).
    enum Axis: Int, CaseIterable {
        case x = 0, y = 1, z = 2, rz = 5, gas = 9, brake = 10, hatX = 16, hatY = 17
    }

    /// Linux keys that the controller's Home button sends (Android: HOME, VOLUME_UP/DOWN, MUTE).
    private enum Key: Int, CaseIterable { case home = 172, volumeUp = 115, volumeDown = 114, mute = 113 }

    private static let stick = 32767
    private let device: UinputDevice
    /// What the TV has now. Used on device.queue.
    private var buttons: [Button: Bool] = [:]
    private var axes: [Axis: Int] = [:]
    /// The state of each controller. The TV gets the merge of all of them, so one controller
    /// (or a second HID interface of the same controller) cannot release a button that another holds.
    private var sources: [ObjectIdentifier: (buttons: [Button: Bool], axes: [Axis: Int])] = [:]
    /// Shortcuts while Select (View / Share / -) is held. The controller's Home button is not used:
    /// macOS takes it and opens the Games app.
    private static let shortcuts: [Button: Key] = [
        .rightShoulder: .volumeUp, .leftShoulder: .volumeDown, .y: .home, .x: .mute,
    ]
    /// Select is held.
    private var selectHeld = false
    /// A shortcut was used while Select was held. Then releasing Select sends nothing.
    private var selectUsed = false
    /// The merged buttons of the last call, to find new presses.
    private var lastPressed: Set<Button> = []

    private init() {
        device = UinputDevice(
            name: "TVDroid Gamepad", productID: 0x4ee9,
            configuration: [
                .init(ioctl: 100, data: [1, 3]),                       // UI_SET_EVBIT: EV_KEY, EV_ABS
                .init(ioctl: 101, data: Button.allCases.map(\.rawValue) + Key.allCases.map(\.rawValue)),
                .init(ioctl: 103, data: Axis.allCases.map(\.rawValue)),
            ],
            axes: [
                .init(code: Axis.x.rawValue, minimum: -Self.stick, maximum: Self.stick, fuzz: 16, flat: 2048),
                .init(code: Axis.y.rawValue, minimum: -Self.stick, maximum: Self.stick, fuzz: 16, flat: 2048),
                .init(code: Axis.z.rawValue, minimum: -Self.stick, maximum: Self.stick, fuzz: 16, flat: 2048),
                .init(code: Axis.rz.rawValue, minimum: -Self.stick, maximum: Self.stick, fuzz: 16, flat: 2048),
                .init(code: Axis.gas.rawValue, minimum: 0, maximum: 255),
                .init(code: Axis.brake.rawValue, minimum: 0, maximum: 255),
                .init(code: Axis.hatX.rawValue, minimum: -1, maximum: 1),
                .init(code: Axis.hatY.rawValue, minimum: -1, maximum: 1),
            ]
        )
        // A new helper makes a new device that starts with nothing pressed. Send the full state again.
        device.onStart = { [unowned self] in self.buttons.removeAll(); self.axes.removeAll() }
    }

    /// Sets the whole state of one controller.
    func update(source: ObjectIdentifier, buttons newButtons: [Button: Bool], axes newAxes: [Axis: Int]) {
        device.queue.async {
            self.sources[source] = (newButtons, newAxes)
            self.sendMerged()
        }
    }

    /// Changes some values of one controller and keeps the others.
    func change(source: ObjectIdentifier, buttons changed: [Button: Bool] = [:], axes changedAxes: [Axis: Int] = [:]) {
        device.queue.async {
            var state = self.sources[source] ?? ([:], [:])
            state.buttons.merge(changed) { $1 }
            state.axes.merge(changedAxes) { $1 }
            self.sources[source] = state
            self.sendMerged()
        }
    }

    /// A controller went away. Its buttons are released on the TV.
    func remove(source: ObjectIdentifier) {
        device.queue.async {
            guard self.sources.removeValue(forKey: source) != nil else { return }
            self.selectUsed = true  // A lost controller is no Select tap.
            self.sendMerged()
        }
    }

    /// Releases everything, for example when TVDroid is no longer the active app.
    func releaseAll() {
        device.queue.async {
            self.sources = self.sources.mapValues { _ in ([:], [:]) }
            self.selectUsed = true  // Leaving TVDroid is no Select tap.
            self.sendMerged()
        }
    }

    /// Sends only the values that changed. Call on device.queue.
    /// A button is down when any controller holds it. An axis uses the value farthest from rest.
    private func sendMerged() {
        // Start first: a new helper clears the cache, so the full state is sent below.
        guard device.ensureStarted() else { return }
        var events: [Int] = []
        func tap(_ code: Int) { events += [1, code, 1, 0, 0, 0, 1, code, 0, 0, 0, 0] }
        let pressed = Set(Button.allCases.filter { button in sources.values.contains { $0.buttons[button] == true } })
        let newPresses = pressed.subtracting(lastPressed)
        lastPressed = pressed
        if pressed.contains(.select) {
            if !selectHeld { selectHeld = true; selectUsed = false }
            for button in newPresses { if let key = Self.shortcuts[button] { tap(key.rawValue); selectUsed = true } }
        } else if selectHeld {
            selectHeld = false
            if !selectUsed { tap(Button.select.rawValue) }
        }
        for button in Button.allCases where button != .mode {
            var down = pressed.contains(button)
            // Select and the shortcut buttons go to the TV only as shortcuts while Select is held.
            // A button already held before Select keeps its state.
            if button == .select || (selectHeld && Self.shortcuts[button] != nil && !buttons[button, default: false]) {
                down = false
            }
            if buttons[button, default: false] != down {
                events += [1, button.rawValue, down ? 1 : 0]
                buttons[button] = down
            }
        }
        for axis in Axis.allCases {
            let value = mergedAxis(axis)
            if axes[axis, default: 0] != value {
                events += [3, axis.rawValue, value]
                axes[axis] = value
            }
        }
        guard !events.isEmpty else { return }
        device.injectOnQueue(events + [0, 0, 0])
    }

    /// The value farthest from rest, over all controllers. Call on device.queue.
    private func mergedAxis(_ axis: Axis) -> Int {
        sources.values.compactMap { $0.axes[axis] }.max { abs($0) < abs($1) } ?? 0
    }

    func reset() {
        device.queue.async {
            self.buttons.removeAll(); self.axes.removeAll(); self.sources.removeAll()
            self.selectHeld = false; self.lastPressed = []
        }
        device.reset()
    }
}

/// Connects Mac game controllers (PlayStation, Xbox, MFi, Switch Pro) to the TV's virtual gamepad.
@MainActor
final class GameControllerBridge: ObservableObject {
    static let shared = GameControllerBridge()

    @Published private(set) var controllers: [String] = []

    /// Only send input while the TV runs. Otherwise each event would try to start adb.
    var isTVOn = false {
        didSet { if !isTVOn { VirtualGamepad.shared.reset() } }
    }

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let controller = note.object as? GCController { self?.attach(controller) }
                self?.refreshList()
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // A controller that sleeps or disconnects must not leave a button down on the TV.
                if let controller = note.object as? GCController {
                    VirtualGamepad.shared.remove(source: ObjectIdentifier(controller))
                }
                self?.refreshList()
            }
        })
        // Without this, macOS sends no controller input while another app is in front
        // (for example after the Home button opens the Games app), and every button seems dead.
        GCController.shouldMonitorBackgroundEvents = true
        // A button held while focus moves away would stay down (Android repeats it). Release all.
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            VirtualGamepad.shared.releaseAll()
        })
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
        refreshList()
        // Controllers that macOS does not know (Windows "DirectInput" pads) are read as raw HID devices.
        HIDGamepads.shared.start()
    }

    private func refreshList() {
        controllers = GCController.controllers().compactMap { $0.vendorName ?? "Game controller" }
    }

    /// Each input sends its own change, with the value from the event. Reading `isPressed` later
    /// can miss a quick press: when the handler runs late, the button is already up again.
    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let source = ObjectIdentifier(controller)
        let gamepad = VirtualGamepad.shared
        // Home, Options and Share must reach the TV, not open the Games app or take screenshots.
        for name in [GCInputButtonHome, GCInputButtonOptions, GCInputButtonShare] {
            controller.physicalInputProfile.buttons[name]?.preferredSystemGestureState = .disabled
        }
        pad.valueChangedHandler = nil

        func bind(_ input: GCControllerButtonInput?, _ buttons: [VirtualGamepad.Button]) {
            input?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    guard self?.isTVOn == true else { return }
                    gamepad.change(source: source, buttons: Dictionary(uniqueKeysWithValues: buttons.map { ($0, pressed) }))
                }
            }
        }
        bind(pad.buttonA, [.a]); bind(pad.buttonB, [.b]); bind(pad.buttonX, [.x]); bind(pad.buttonY, [.y])
        bind(pad.leftShoulder, [.leftShoulder]); bind(pad.rightShoulder, [.rightShoulder])
        bind(pad.buttonMenu, [.start])
        bind(pad.leftThumbstickButton, [.leftThumb]); bind(pad.rightThumbstickButton, [.rightThumb])
        bind(pad.buttonOptions, [.select])
        // Home is not sent: macOS takes it for the Games app. Select + Y is TV Home.

        func stick(_ value: Float) -> Int { Int((max(-1, min(1, value)) * 32767).rounded()) }
        func trigger(_ value: Float) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        func bind(_ input: GCControllerDirectionPad, _ handler: @escaping (Float, Float) -> [VirtualGamepad.Axis: Int]) {
            input.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated {
                    guard self?.isTVOn == true else { return }
                    gamepad.change(source: source, axes: handler(x, y))
                }
            }
        }
        // Linux axes: y grows downward. GameController y grows upward.
        bind(pad.dpad) { x, y in [.hatX: x < -0.5 ? -1 : (x > 0.5 ? 1 : 0), .hatY: y > 0.5 ? -1 : (y < -0.5 ? 1 : 0)] }
        bind(pad.leftThumbstick) { x, y in [.x: stick(x), .y: -stick(y)] }
        bind(pad.rightThumbstick) { x, y in [.z: stick(x), .rz: -stick(y)] }
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            MainActor.assumeIsolated { if self?.isTVOn == true { gamepad.change(source: source, axes: [.brake: trigger(value)]) } }
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            MainActor.assumeIsolated { if self?.isTVOn == true { gamepad.change(source: source, axes: [.gas: trigger(value)]) } }
        }
    }
}
