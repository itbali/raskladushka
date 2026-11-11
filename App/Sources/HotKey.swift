import AppKit
import Carbon

/// Сочетание клавиш: код клавиши и модификаторы.
struct KeyCombo: Equatable, Codable {
    var keyCode: UInt16
    /// Сырые флаги `NSEvent.ModifierFlags` (только ⌃⌥⇧⌘).
    var modifiers: UInt

    static let `default` = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)
    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    func matches(keyCode: UInt16, flags cgFlags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        var pressed: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskControl) { pressed.insert(.control) }
        if cgFlags.contains(.maskAlternate) { pressed.insert(.option) }
        if cgFlags.contains(.maskShift) { pressed.insert(.shift) }
        if cgFlags.contains(.maskCommand) { pressed.insert(.command) }
        return pressed == flags
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt16) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        ]
        if let name = special[keyCode] { return name }
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
            35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
            47: ".", 50: "`",
        ]
        return names[keyCode] ?? "#\(keyCode)"
    }
}

/// Глобальная горячая клавиша через Carbon — не требует никаких разрешений.
final class HotKey {
    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x5241_534B), id: 1)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }
}
