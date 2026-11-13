import CVNCBridge
import RemoraCore

struct VNCKey: Sendable, Equatable {
    let keysym: UInt32
    let code: UInt32

    init(scalar: Unicode.Scalar) {
        keysym = rm_vnc_unicode_keysym(scalar.value)
        code = 0
    }
    init(keysym: UInt32, code: UInt32) {
        self.keysym = keysym
        self.code = code
    }

    init?(physical key: PhysicalKey) {
        let name = key.name
        let symbol: UInt32
        if name.hasPrefix("Key"), let scalar = name.lowercased().unicodeScalars.last {
            symbol = scalar.value
        } else if name.hasPrefix("Digit"), let scalar = name.unicodeScalars.last {
            symbol = scalar.value
        } else if name.hasPrefix("Numpad"), let n = Int(name.dropFirst(6)) {
            symbol = 0xffb0 + UInt32(n)
        } else if name.hasPrefix("F"), let n = Int(name.dropFirst()) {
            symbol = 0xffbd + UInt32(n)
        } else if let value = Self.symbols[name] {
            symbol = value
        } else {
            return nil
        }
        keysym = symbol
        switch name {
        case "PrintScreen": code = 0x54
        case "Pause": code = 0xc6
        default: code = (key.scancode & 0x7f) | (key.scancode & 0x100 != 0 ? 0x80 : 0)
        }
    }

    private static let symbols: [String: UInt32] = [
        "ControlLeft": 0xffe3, "ControlRight": 0xffe4, "ShiftLeft": 0xffe1, "ShiftRight": 0xffe2,
        "AltLeft": 0xffe9, "AltRight": 0xffea, "MetaLeft": 0xffeb, "MetaRight": 0xffec,
        "Enter": 0xff0d, "NumpadEnter": 0xff8d, "Backspace": 0xff08, "Delete": 0xffff,
        "Escape": 0xff1b, "Tab": 0xff09, "Space": 0x20, "ArrowLeft": 0xff51, "ArrowRight": 0xff53,
        "ArrowUp": 0xff52, "ArrowDown": 0xff54, "Home": 0xff50, "End": 0xff57,
        "PageUp": 0xff55, "PageDown": 0xff56, "Insert": 0xff63, "Minus": 0x2d, "Equal": 0x3d,
        "BracketLeft": 0x5b, "BracketRight": 0x5d, "Backslash": 0x5c, "Semicolon": 0x3b,
        "Quote": 0x27, "Backquote": 0x60, "Comma": 0x2c, "Period": 0x2e, "Slash": 0x2f,
        "IntlBackslash": 0x3c, "IntlYen": 0xa5, "IntlRo": 0x5c, "NumpadDecimal": 0xffae,
        "NumpadAdd": 0xffab, "NumpadSubtract": 0xffad, "NumpadMultiply": 0xffaa, "NumpadDivide": 0xffaf,
        "NumpadEqual": 0xffbd, "NumpadComma": 0xffac, "CapsLock": 0xffe5, "NumLock": 0xff7f,
        "ScrollLock": 0xff14, "ContextMenu": 0xff67, "PrintScreen": 0xff61, "Pause": 0xff13,
        "AudioVolumeUp": 0x1008_ff13, "AudioVolumeDown": 0x1008_ff11, "AudioVolumeMute": 0x1008_ff12,
        "Lang1": 0xff31, "Lang2": 0xff34, "Convert": 0xff23, "NonConvert": 0xff22,
    ]
}

/// Transport writes are serialized with frame decoding on the session thread.
protocol VNCInputTransport {
    func key(_ key: VNCKey, down: Bool) -> Bool
    func pointer(_ point: RemotePoint, mask: UInt8) -> Bool
}

struct VNCInputState {
    private var human: [UInt32: VNCKey] = [:]
    private var agent: [UInt32: VNCKey] = [:]
    private(set) var humanButtons: PointerButtons = []
    private var agentButtons: PointerButtons = []
    private var position = RemotePoint(x: 0, y: 0)
    private var vertical: [Int64] = [0, 0]
    private var horizontal: [Int64] = [0, 0]

    private var buttons: UInt8 {
        let union = humanButtons.union(agentButtons)
        // RFB buttons 4-7 are wheel pulses. Back/forward use 8/9 and require
        // a negotiated extension, which LibVNCClient does not expose here.
        return (union.contains(.left) ? 1 : 0) | (union.contains(.middle) ? 2 : 0) | (union.contains(.right) ? 4 : 0)
    }

    mutating func apply(_ event: AgentInputEvent, source: InputSource, wire: any VNCInputTransport) -> Bool {
        switch event {
        case .key(let physical, let down):
            guard let mapped = VNCKey(physical: physical) else { return false }
            return key(physical.scancode, mapped: mapped, down: down, source: source, wire: wire)
        case .pointer(let point, let held):
            guard held.intersection([.back, .forward]).isEmpty else { return false }
            position = point
            if source == .human { humanButtons = held } else { agentButtons = held }
            return wire.pointer(point, mask: buttons)
        case .wheel(let wheel):
            let sourceIndex = source == .human ? 0 : 1
            vertical[sourceIndex] += Int64(wheel.vertical)
            horizontal[sourceIndex] += Int64(wheel.horizontal)
            // Bound one command's work. CLI validation also bounds intended duration.
            guard abs(vertical[sourceIndex]) + abs(horizontal[sourceIndex]) <= 120 * 4096 else { return false }
            while abs(vertical[sourceIndex]) >= 120 {
                let positive = vertical[sourceIndex] > 0
                guard wire.pointer(position, mask: buttons | (positive ? 8 : 16)), wire.pointer(position, mask: buttons) else { return false }
                vertical[sourceIndex] += positive ? -120 : 120
            }
            while abs(horizontal[sourceIndex]) >= 120 {
                let positive = horizontal[sourceIndex] > 0
                guard wire.pointer(position, mask: buttons | (positive ? 64 : 32)), wire.pointer(position, mask: buttons) else { return false }
                horizontal[sourceIndex] += positive ? -120 : 120
            }
            return true
        case .unicode(let scalar):
            let mapped = VNCKey(scalar: scalar)
            // Do not release a key currently held by either source.
            guard !human.values.contains(where: { $0.keysym == mapped.keysym }),
                !agent.values.contains(where: { $0.keysym == mapped.keysym })
            else { return false }
            return wire.key(mapped, down: true) && wire.key(mapped, down: false)
        case .pause:
            let mapped = VNCKey(keysym: 0xff13, code: 0xc6)
            return wire.key(mapped, down: true) && wire.key(mapped, down: false)
        }
    }

    /// Wheel pulses are pointer events, so a pulse also moves the pointer to `point`.
    /// `moved` is false when the wheel only adds to a fraction of a notch.
    mutating func humanWheel(_ wheel: WheelInput, at point: RemotePoint, wire: any VNCInputTransport) -> (ok: Bool, moved: Bool) {
        let moved = abs(vertical[0] + Int64(wheel.vertical)) >= 120 || abs(horizontal[0] + Int64(wheel.horizontal)) >= 120
        if moved { position = point }
        return (apply(.wheel(wheel), source: .human, wire: wire), moved)
    }

    mutating func humanKey(scan: UInt32, down: Bool, characters: String?, wire: any VNCInputTransport) -> Bool {
        guard let physical = PhysicalKey(scancode: scan), var mapped = VNCKey(physical: physical) else { return true }
        let shortcutHeld = human.keys.contains { [0x1d, 0x11d, 0x38, 0x138, 0x15b, 0x15c].contains($0) }
        if !physical.isModifier, !shortcutHeld, let chars = characters, chars.unicodeScalars.count == 1,
            let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7f,
            !((0xf700...0xf8ff).contains(scalar.value))
        {
            mapped = VNCKey(keysym: VNCKey(scalar: scalar).keysym, code: mapped.code)
        }
        return key(scan, mapped: mapped, down: down, source: .human, wire: wire)
    }

    private mutating func key(_ scan: UInt32, mapped: VNCKey, down: Bool, source: InputSource, wire: any VNCInputTransport) -> Bool {
        let previous = source == .human ? human[scan] : agent[scan]
        let other = source == .human ? agent[scan] : human[scan]
        let symbol = previous ?? other ?? mapped
        if down {
            if source == .human { human[scan] = symbol } else { agent[scan] = symbol }
            return other != nil ? true : wire.key(symbol, down: true)
        }
        guard let previous else { return true }
        if source == .human { human.removeValue(forKey: scan) } else { agent.removeValue(forKey: scan) }
        return other != nil ? true : wire.key(previous, down: false)
    }

    /// A display boundary releases held state without moving an idle pointer.
    mutating func releaseForDisplay(wire: any VNCInputTransport) -> Bool {
        let humanHeld = !human.isEmpty || !humanButtons.isEmpty
        let agentHeld = !agent.isEmpty || !agentButtons.isEmpty
        guard !humanHeld || release(.human, wire: wire), !agentHeld || release(.agent, wire: wire) else { return false }
        self = VNCInputState()
        return true
    }

    mutating func release(_ source: InputSource, wire: any VNCInputTransport) -> Bool {
        let keys = source == .human ? human : agent
        for (scan, key) in keys.sorted(by: { $0.key > $1.key }) {
            guard self.key(scan, mapped: key, down: false, source: source, wire: wire) else { return false }
        }
        let index = source == .human ? 0 : 1
        vertical[index] = 0
        horizontal[index] = 0
        if source == .human { humanButtons = [] } else { agentButtons = [] }
        return wire.pointer(position, mask: buttons)
    }
}
