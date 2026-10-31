import Foundation
import GameController
import IOKit.hid

/// Generic USB/Bluetooth gamepads and joysticks that macOS's GameController framework does not know
/// (many "DirectInput" pads for Windows, arcade sticks, wheels). Wine and GPTK read them the same way:
/// as raw HID devices. Their buttons are numbers only, so the user can map them in Settings.
@MainActor
final class HIDGamepads: ObservableObject {
    static let shared = HIDGamepads()

    /// The buttons a user can map, in the order of the setup.
    enum Target: String, CaseIterable {
        case a, b, x, y, leftShoulder, rightShoulder, leftTrigger, rightTrigger
        case select, start, home, leftThumb, rightThumb

        var title: String {
            switch self {
            case .a: "A (bottom, ✕ on PlayStation)"
            case .b: "B (right, ○) – Back"
            case .x: "X (left, □)"
            case .y: "Y (top, △)"
            case .leftShoulder: "Left shoulder (LB / L1)"
            case .rightShoulder: "Right shoulder (RB / R1)"
            case .leftTrigger: "Left trigger (LT / L2)"
            case .rightTrigger: "Right trigger (RT / R2)"
            case .select: "Select / Back / Share"
            case .start: "Start / Menu / Options"
            case .home: "Home / Guide / PS"
            case .leftThumb: "Left stick press (L3)"
            case .rightThumb: "Right stick press (R3)"
            }
        }

        var button: VirtualGamepad.Button? {
            switch self {
            case .a: .a
            case .b: .b
            case .x: .x
            case .y: .y
            case .leftShoulder: .leftShoulder
            case .rightShoulder: .rightShoulder
            case .select: .select
            case .start: .start
            case .home: .mode
            case .leftThumb: .leftThumb
            case .rightThumb: .rightThumb
            case .leftTrigger, .rightTrigger: nil
            }
        }
    }

    struct Pad: Identifiable {
        let id: ObjectIdentifier
        let key: String          // "vendor:product", used to save the button map
        let name: String
    }

    struct Learning {
        let key: String
        var step: Int
        var map: [Target: Int]
        var target: Target? { step < Target.allCases.count ? Target.allCases[step] : nil }
    }

    @Published private(set) var pads: [Pad] = []
    @Published private(set) var learning: Learning?

    private final class State {
        let device: IOHIDDevice
        let pad: Pad
        /// XInput-style layout: right stick on Rx/Ry, triggers on Z/Rz.
        let xboxLayout: Bool
        var map: [Target: Int]
        var buttons: [Int: Bool] = [:]
        var axes: [UInt32: Double] = [:]      // HID usage → -1...1 (triggers 0...1)
        var hat = -1                          // 0 = up, clockwise to 7. -1 = centered.

        init(device: IOHIDDevice, pad: Pad, xboxLayout: Bool, map: [Target: Int]) {
            self.device = device; self.pad = pad; self.xboxLayout = xboxLayout; self.map = map
        }
    }

    private var manager: IOHIDManager?
    private var states: [ObjectIdentifier: State] = [:]

    private init() {}

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let me = Unmanaged<HIDGamepads>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let me = Unmanaged<HIDGamepads>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let me = Unmanaged<HIDGamepads>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(value) }
        }, context)
        // Common modes: input keeps working while a menu, an alert or a window resize runs.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    // MARK: - Button setup

    func startLearning(_ pad: Pad) {
        learning = Learning(key: pad.key, step: 0, map: [:])
        // Release what this pad holds now; it stays quiet while it is set up.
        for state in states.values where state.pad.key == pad.key { VirtualGamepad.shared.remove(source: state.pad.id) }
    }

    func skipStep() {
        learning?.step += 1
        if learning?.target == nil { finishLearning() }
    }

    func cancelLearning() {
        let key = learning?.key
        learning = nil
        for state in states.values where state.pad.key == key { send(state) }
    }

    func resetMap(_ pad: Pad) {
        UserDefaults.standard.removeObject(forKey: Self.mapKey(pad.key))
        for state in states.values where state.pad.key == pad.key {
            state.map = Self.defaultMap(xboxLayout: state.xboxLayout)
        }
    }

    private func finishLearning() {
        guard let learning else { return }
        let saved = Dictionary(uniqueKeysWithValues: learning.map.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(saved, forKey: Self.mapKey(learning.key))
        self.learning = nil
        for state in states.values where state.pad.key == learning.key { state.map = learning.map; send(state) }
    }

    // MARK: - Devices

    private func added(_ device: IOHIDDevice) {
        // Controllers that GameController supports (Xbox, PlayStation, MFi, Switch) go through
        // GameControllerBridge. Do not send them twice.
        if GCController.supportsHIDDevice(device) { return }
        let vendor = Self.property(device, kIOHIDVendorIDKey) as? Int ?? 0
        let product = Self.property(device, kIOHIDProductIDKey) as? Int ?? 0
        let name = Self.property(device, kIOHIDProductKey) as? String ?? "USB gamepad"
        let key = String(format: "%04x:%04x", vendor, product)

        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        let usages = Set(elements.filter { IOHIDElementGetUsagePage($0) == UInt32(kHIDPage_GenericDesktop) }.map(IOHIDElementGetUsage))
        let xbox = usages.contains(UInt32(kHIDUsage_GD_Rx)) && usages.contains(UInt32(kHIDUsage_GD_Ry))

        var map = Self.defaultMap(xboxLayout: xbox)
        if let saved = UserDefaults.standard.dictionary(forKey: Self.mapKey(key)) as? [String: Int] {
            map = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Target(rawValue: k).map { ($0, v) } })
        }
        let pad = Pad(id: ObjectIdentifier(device), key: key, name: name)
        states[pad.id] = State(device: device, pad: pad, xboxLayout: xbox, map: map)
        refresh()
    }

    private func removed(_ device: IOHIDDevice) {
        states[ObjectIdentifier(device)] = nil
        refresh()
        // Release everything, so no button stays down on the TV.
        VirtualGamepad.shared.remove(source: ObjectIdentifier(device))
    }

    private func refresh() {
        pads = states.values.map(\.pad).sorted { $0.name < $1.name }
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let state = states[ObjectIdentifier(device)] else { return }
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let minimum = IOHIDElementGetLogicalMin(element)
        let maximum = IOHIDElementGetLogicalMax(element)

        switch page {
        case kHIDPage_Button:
            let number = Int(usage), down = raw != 0
            guard state.buttons[number] != down else { return }
            state.buttons[number] = down
            if down, var learning, learning.key == state.pad.key, let target = learning.target {
                learning.map[target] = number
                learning.step += 1
                self.learning = learning
                if learning.target == nil { finishLearning() }
                return
            }
        case kHIDPage_GenericDesktop where usage == UInt32(kHIDUsage_GD_Hatswitch):
            let index = Int(raw - minimum), range = Int(maximum - minimum)
            if range == 3 { state.hat = (0...3).contains(index) ? index * 2 : -1 }   // 4-way hat
            else { state.hat = (0...7).contains(index) ? index : -1 }
        case kHIDPage_GenericDesktop, kHIDPage_Simulation:
            guard maximum > minimum else { return }
            state.axes[usage] = Double(raw - minimum) / Double(maximum - minimum) * 2 - 1
        default:
            return
        }
        // Only the pad that is being set up is quiet. Other pads keep working.
        if learning?.key != state.pad.key { send(state) }
    }

    private func send(_ state: State) {
        guard GameControllerBridge.shared.acceptsInput else { return }
        func axis(_ usage: Int) -> Double { state.axes[UInt32(usage)] ?? 0 }
        func stick(_ value: Double) -> Int { Int((max(-1, min(1, value)) * 32767).rounded()) }
        // Triggers rest at -1 (minimum) and go to 1. Values that were never sent count as released.
        func trigger(_ usage: Int) -> Double { state.axes[UInt32(usage)].map { ($0 + 1) / 2 } ?? 0 }
        func pressed(_ target: Target) -> Bool { state.map[target].map { state.buttons[$0] ?? false } ?? false }

        var buttons: [VirtualGamepad.Button: Bool] = [:]
        for target in Target.allCases { if let button = target.button { buttons[button] = pressed(target) } }

        let rightX, rightY: Double
        var leftTrigger = max(trigger(kHIDUsage_Sim_Brake), pressed(.leftTrigger) ? 1 : 0)
        var rightTrigger = max(trigger(kHIDUsage_Sim_Accelerator), pressed(.rightTrigger) ? 1 : 0)
        if state.xboxLayout {
            rightX = axis(kHIDUsage_GD_Rx); rightY = axis(kHIDUsage_GD_Ry)
            leftTrigger = max(leftTrigger, trigger(kHIDUsage_GD_Z))
            rightTrigger = max(rightTrigger, trigger(kHIDUsage_GD_Rz))
        } else {
            // DirectInput layout: right stick on Z (x) and Rz (y).
            rightX = axis(kHIDUsage_GD_Z); rightY = axis(kHIDUsage_GD_Rz)
        }
        let hat: [(Int, Int)] = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]
        let (hatX, hatY) = (0...7).contains(state.hat) ? hat[state.hat] : (0, 0)

        // HID and Linux both grow y downward, so no sign change.
        VirtualGamepad.shared.update(source: state.pad.id, buttons: buttons, axes: [
            .x: stick(axis(kHIDUsage_GD_X)), .y: stick(axis(kHIDUsage_GD_Y)),
            .z: stick(rightX), .rz: stick(rightY),
            .brake: Int(leftTrigger * 255), .gas: Int(rightTrigger * 255),
            .hatX: hatX, .hatY: hatY,
        ])
    }

    // MARK: - Helpers

    private static func mapKey(_ key: String) -> String { "hidButtonMap.\(key)" }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    /// Button numbers (1-based) for the common layouts. The user can change them in Settings.
    static func defaultMap(xboxLayout: Bool) -> [Target: Int] {
        xboxLayout
            // XInput-style HID (8BitDo X mode, many "Xbox" clones over Bluetooth)
            ? [.a: 1, .b: 2, .x: 3, .y: 4, .leftShoulder: 5, .rightShoulder: 6,
               .select: 7, .start: 8, .leftThumb: 9, .rightThumb: 10, .home: 11]
            // DirectInput (Logitech "D" mode and most generic USB pads)
            : [.x: 1, .a: 2, .b: 3, .y: 4, .leftShoulder: 5, .rightShoulder: 6,
               .leftTrigger: 7, .rightTrigger: 8, .select: 9, .start: 10,
               .leftThumb: 11, .rightThumb: 12, .home: 13]
    }
}
