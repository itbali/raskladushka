import Carbon
import CoreGraphics
import Foundation

/// Метка наших собственных синтетических событий — по ней перехватчик их пропускает.
let syntheticEventMarker: Int64 = 0x5241_534B  // "RASK"

/// Перехватчик нажатий. Обычно «только чтение»: ничего не изменяет и не блокирует.
/// В активном режиме (перехват системного сочетания) может не пропустить дальше одно нажатие —
/// то, на которое укажет `swallow`; всё остальное проходит нетронутым.
final class KeyboardTap {
    enum Event {
        case keyDown(keyCode: UInt16, flags: CGEventFlags)
        case mouseDown
        case flagsChanged(flags: CGEventFlags)
        /// Нажатие, которое перехватчик забрал себе и дальше не пустил.
        case captured(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool)
    }

    var handler: ((Event) -> Void)?
    /// Активный режим: забрать ли это нажатие. Вызывается прямо в обработчике системы — должна быть быстрой.
    var swallow: ((UInt16, CGEventFlags) -> Bool)?
    private(set) var isActive = false
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        guard let port else { return false }
        return CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    @discardableResult
    func start(active: Bool = false) -> Bool {
        if isRunning, isActive == active { return true }
        stop()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.received(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: active ? .defaultTap : .listenOnly, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.port = port
        isActive = active
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
        isActive = false
    }

    /// Сообщает о событии. В режиме «только чтение» — сразу: нажатие уйдёт в приложение независимо от нас.
    /// В активном режиме нажатие ждёт, пока мы вернём управление, поэтому обработка откладывается:
    /// иначе наши стирания и набор попали бы в приложение раньше самого нажатия.
    private func emit(_ event: Event) {
        if isActive {
            DispatchQueue.main.async { [weak self] in self?.handler?(event) }
        } else {
            handler?(event)
        }
    }

    /// Возвращает `true`, если нажатие нужно забрать и дальше не пускать.
    private func received(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else { return false }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if isActive, swallow?(keyCode, event.flags) == true {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                emit(.captured(keyCode: keyCode, flags: event.flags, isRepeat: isRepeat))
                return true
            }
            emit(.keyDown(keyCode: keyCode, flags: event.flags))
        case .flagsChanged:
            guard event.getIntegerValueField(.eventSourceUserData) != syntheticEventMarker else { return false }
            emit(.flagsChanged(flags: event.flags))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            emit(.mouseDown)
        default:
            break
        }
        return false
    }
}
