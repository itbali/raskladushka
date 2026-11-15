import AppKit
import CoreGraphics

/// Отправляет синтетические нажатия: стирание, набор текста, ⌘C / ⌘V.
final class TextInjector {
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticEventMarker
        return source
    }()

    private func post(keyCode: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
        usleep(3_000)
    }

    /// `dismissSuggestion` — для строки Spotlight: там за набранным стоит подсказка-дополнение, и первое
    /// стирание убирает её, а не букву. ⌦ убирает подсказку, а без неё в конце строки ничего не делает.
    func replace(deleteCount: Int, with text: String, dismissSuggestion: Bool = false) {
        if dismissSuggestion, deleteCount > 0 {
            post(keyCode: 117)
            usleep(30_000)
        }
        for _ in 0..<deleteCount { post(keyCode: 51) }
        if deleteCount > 0 { usleep(8_000) }
        type(text)
    }

    func type(_ text: String) {
        // По одному символу на событие. Несколько символов в одном событии понимают обычные
        // текстовые поля, но не терминалы на веб-движке (xterm.js): те берут из нажатия только
        // одиночный символ, и слово после стирания не появлялось.
        for character in text {
            post(keyCode: character == " " ? 49 : 0, text: String(character))
        }
    }

    func copy() { post(keyCode: 8, flags: .maskCommand) }
    func paste() { post(keyCode: 9, flags: .maskCommand) }
}

/// Сохранение и восстановление буфера обмена со всеми типами данных.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard = .general) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.compactMap { pairs in
            guard !pairs.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
