import Carbon
import CoreGraphics
import Foundation

/// Метка наших собственных синтетических событий — по ней перехватчик их пропускает.
let syntheticEventMarker: Int64 = 0x5241_534B  // "RASK"

/// Перехватчик нажатий «только чтение». Ничего не изменяет и не блокирует.
final class KeyboardTap {
    enum Event {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown
    }

    var handler: ((Event) -> Void)?
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        guard let port else { return false }
        return CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        stop()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
            tap.received(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        port = nil
        runLoopSource = nil
    }

    private func received(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            handler?(.keyDown(keyCode: keyCode, flags: event.flags))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handler?(.mouseDown)
        default:
            break
        }
    }
}
