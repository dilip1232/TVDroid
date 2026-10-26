import Foundation
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

    private static let stick = 32767
    private let device: UinputDevice
    private var buttons: [Button: Bool] = [:]
    private var axes: [Axis: Int] = [:]

    private init() {
        device = UinputDevice(
            name: "TVDroid Gamepad", productID: 0x4ee9,
            configuration: [
                .init(ioctl: 100, data: [1, 3]),                       // UI_SET_EVBIT: EV_KEY, EV_ABS
                .init(ioctl: 101, data: Button.allCases.map(\.rawValue)),
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
    }

    /// Sends only the values that changed since the last call.
    func update(buttons newButtons: [Button: Bool], axes newAxes: [Axis: Int]) {
        device.queue.async {
            var events: [Int] = []
            for (button, down) in newButtons where self.buttons[button, default: false] != down {
                events += [1, button.rawValue, down ? 1 : 0]
                self.buttons[button] = down
            }
            for (axis, value) in newAxes where self.axes[axis, default: 0] != value {
                events += [3, axis.rawValue, value]
                self.axes[axis] = value
            }
            guard !events.isEmpty else { return }
            self.device.injectOnQueue(events + [0, 0, 0])
        }
    }

    func reset() {
        device.queue.async { self.buttons.removeAll(); self.axes.removeAll() }
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
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshList() }
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

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.send(pad) }
        }
    }

    private func send(_ pad: GCExtendedGamepad) {
        guard isTVOn else { return }
        func stick(_ value: Float) -> Int { Int((max(-1, min(1, value)) * 32767).rounded()) }
        func trigger(_ value: Float) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        let dpad = pad.dpad
        let hatX = dpad.left.isPressed ? -1 : (dpad.right.isPressed ? 1 : 0)
        let hatY = dpad.up.isPressed ? -1 : (dpad.down.isPressed ? 1 : 0)
        var buttons: [VirtualGamepad.Button: Bool] = [
            .a: pad.buttonA.isPressed, .b: pad.buttonB.isPressed,
            .x: pad.buttonX.isPressed, .y: pad.buttonY.isPressed,
            .leftShoulder: pad.leftShoulder.isPressed, .rightShoulder: pad.rightShoulder.isPressed,
            .start: pad.buttonMenu.isPressed,
            .select: pad.buttonOptions?.isPressed ?? false,
            .mode: pad.buttonHome?.isPressed ?? false,
            .leftThumb: pad.leftThumbstickButton?.isPressed ?? false,
            .rightThumb: pad.rightThumbstickButton?.isPressed ?? false,
        ]
        // Some controllers have no Options button. Then Home works as Select.
        if pad.buttonOptions == nil { buttons[.select] = buttons[.mode] }
        // Linux axes: y grows downward. GameController y grows upward.
        let axes: [VirtualGamepad.Axis: Int] = [
            .x: stick(pad.leftThumbstick.xAxis.value), .y: -stick(pad.leftThumbstick.yAxis.value),
            .z: stick(pad.rightThumbstick.xAxis.value), .rz: -stick(pad.rightThumbstick.yAxis.value),
            .brake: trigger(pad.leftTrigger.value), .gas: trigger(pad.rightTrigger.value),
            .hatX: hatX, .hatY: hatY,
        ]
        VirtualGamepad.shared.update(buttons: buttons, axes: axes)
    }
}
