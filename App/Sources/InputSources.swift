import Carbon
import Foundation
import SwitcherCore

/// Включённые в системе раскладки клавиатуры: чтение, таблицы символов, переключение.
final class InputSources {
    private(set) var tables: [LayoutTable] = []
    private var sources: [String: TISInputSource] = [:]
    private var lastUsed: [String: Date] = [:]
    /// Раскладка, которую мы только что выбрали сами (чтобы не принять это за действие пользователя).
    private var expectedID: String?
    private var expectedSince = Date.distantPast
    private(set) var notificationCount = 0
    var onUserChangedLayout: (() -> Void)?
    /// Раскладка сменилась — неважно, кем.
    var onLayoutChanged: (() -> Void)?
    /// Названия раскладок, как их показывает система.
    private(set) var names: [String: String] = [:]

    init() {
        reload()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(selectedChanged),
                           name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        center.addObserver(self, selector: #selector(enabledChanged),
                           name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil)
    }

    @objc private func selectedChanged() {
        notificationCount += 1
        let id = Self.currentID()
        lastUsed[id] = Date()
        if id == expectedID {
            expectedID = nil
        } else {
            expectedID = nil
            onUserChangedLayout?()
        }
        onLayoutChanged?()
    }

    @objc private func enabledChanged() {
        reload()
        onUserChangedLayout?()
    }

    func reload() {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        var tables: [LayoutTable] = []
        var sources: [String: TISInputSource] = [:]
        var names: [String: String] = [:]
        for source in list {
            guard Self.string(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String),
                  let id = Self.string(source, kTISPropertyInputSourceID),
                  let table = Self.buildTable(source: source, id: id) else { continue }
            tables.append(table)
            sources[id] = source
            names[id] = Self.string(source, kTISPropertyLocalizedName) ?? id
        }
        self.tables = tables
        self.sources = sources
        self.names = names
    }

    /// Текущая раскладка и остальные (сначала недавно использованные). `nil`, если активен метод ввода, а не раскладка.
    func context() -> LayoutContext? {
        // Сразу после нашего переключения система может ещё отдавать старую раскладку —
        // полсекунды верим своему выбору, дальше только тому, что реально включено.
        var id = Self.currentID()
        if let expected = expectedID {
            if Date().timeIntervalSince(expectedSince) < 0.5 { id = expected } else { expectedID = nil }
        }
        guard let current = tables.first(where: { $0.id == id }) else { return nil }
        let others = tables.filter { $0.id != id }.sorted {
            (lastUsed[$0.id] ?? .distantPast) > (lastUsed[$1.id] ?? .distantPast)
        }
        guard !others.isEmpty else { return nil }
        return LayoutContext(current: current, others: others)
    }

    func select(_ id: String) {
        guard let source = sources[id], id != Self.currentID() else { return }
        expectedID = id
        expectedSince = Date()
        lastUsed[id] = Date()
        TISSelectInputSource(source)
    }

    #if DEBUG
    /// Для проверок: переключение, которое приложение примет за сделанное человеком.
    func selectAsUser(_ id: String) {
        guard let source = sources[id] else { return }
        expectedID = nil
        TISSelectInputSource(source)
    }
    #endif

    // MARK: - Carbon

    static func currentID() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return string(source, kTISPropertyInputSourceID) ?? ""
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func buildTable(source: TISInputSource, id: String) -> LayoutTable? {
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        var language = "en"
        if let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String],
           let first = langs.first {
            language = first
        }
        let keyboardType = UInt32(LMGetKbdType())
        var map: [KeyStroke: Character] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for keyCode in LayoutTable.printableKeyCodes {
                for (shift, caps) in [(false, false), (true, false), (false, true), (true, true)] {
                    let modifiers = UInt32(((shift ? shiftKey : 0) | (caps ? alphaLock : 0)) >> 8) & 0xFF
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                                chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    guard text.count == 1, let c = text.first, !c.isWhitespace,
                          c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { continue }
                    map[KeyStroke(keyCode: keyCode, shift: shift, caps: caps)] = c
                }
            }
        }
        guard map.count > 40 else { return nil }
        return LayoutTable(id: id, language: language, map: map)
    }
}
