import Foundation

/// Физическое нажатие: код клавиши и состояние Shift / Caps Lock.
public struct KeyStroke: Hashable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let caps: Bool

    public init(keyCode: UInt16, shift: Bool = false, caps: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.caps = caps
    }

    public static let spaceKeyCode: UInt16 = 49
    public var isSpace: Bool { keyCode == Self.spaceKeyCode }
}

/// Таблица одной раскладки: какое нажатие даёт какой символ и наоборот.
public struct LayoutTable: Sendable {
    /// Идентификатор источника ввода (например, `com.apple.keylayout.Russian`).
    public let id: String
    /// Основной язык раскладки (`ru`, `en`, `uk`…).
    public let language: String
    private let forward: [KeyStroke: Character]
    private let reverse: [Character: KeyStroke]

    public init(id: String, language: String, map: [KeyStroke: Character]) {
        self.id = id
        self.language = language
        self.forward = map
        var reverse: [Character: KeyStroke] = [:]
        // Для обратного поиска берём самый простой способ набрать символ:
        // без Caps Lock, по возможности без Shift, с наименьшим кодом клавиши.
        let ordered = map.sorted { a, b in
            let ka = (a.key.caps ? 2 : 0) + (a.key.shift ? 1 : 0)
            let kb = (b.key.caps ? 2 : 0) + (b.key.shift ? 1 : 0)
            return ka != kb ? ka < kb : a.key.keyCode < b.key.keyCode
        }
        for (stroke, char) in ordered where reverse[char] == nil {
            reverse[char] = stroke
        }
        self.reverse = reverse
    }

    public func character(for stroke: KeyStroke) -> Character? {
        if stroke.isSpace { return " " }
        return forward[stroke]
    }

    public func stroke(for character: Character) -> KeyStroke? { reverse[character] }

    /// Текст, который дала бы эта раскладка для последовательности нажатий.
    public func string(for strokes: [KeyStroke]) -> String? {
        var result = ""
        result.reserveCapacity(strokes.count)
        for stroke in strokes {
            guard let c = character(for: stroke) else { return nil }
            result.append(c)
        }
        return result
    }

    /// Сколько букв из текста умеет набирать эта раскладка.
    public func letterCoverage(of text: Substring) -> Int {
        text.reduce(0) { $0 + (($1.isLetter && reverse[$1] != nil) ? 1 : 0) }
    }
}

// MARK: - Встроенные таблицы (тесты и запасной вариант)

extension LayoutTable {
    private static let ansiRows: [[UInt16]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]

    /// Все коды клавиш, дающих печатные символы на ANSI-клавиатуре (плюс ISO-клавиша 10).
    public static let printableKeyCodes: [UInt16] = ansiRows.flatMap { $0 } + [10]

    static func build(id: String, language: String, lower: [String], upper: [String]) -> LayoutTable {
        var map: [KeyStroke: Character] = [:]
        for (rowIndex, row) in ansiRows.enumerated() {
            let lowerChars = Array(lower[rowIndex])
            let upperChars = Array(upper[rowIndex])
            precondition(lowerChars.count == row.count && upperChars.count == row.count, "row \(rowIndex) of \(id)")
            for (i, keyCode) in row.enumerated() {
                let lo = lowerChars[i], up = upperChars[i]
                map[KeyStroke(keyCode: keyCode)] = lo
                map[KeyStroke(keyCode: keyCode, shift: true)] = up
                // Caps Lock поднимает только буквы.
                map[KeyStroke(keyCode: keyCode, caps: true)] = lo.isLetter ? up : lo
                map[KeyStroke(keyCode: keyCode, shift: true, caps: true)] = up
            }
        }
        return LayoutTable(id: id, language: language, map: map)
    }

    public static let usQWERTY = build(
        id: "com.apple.keylayout.US", language: "en",
        lower: ["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"],
        upper: ["~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"]
    )

    public static let russianPC = build(
        id: "com.apple.keylayout.RussianWin", language: "ru",
        lower: ["ё1234567890-=", "йцукенгшщзхъ\\", "фывапролджэ", "ячсмитьбю."],
        upper: ["Ё!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЪ/", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ,"]
    )

    public static let russianApple = build(
        id: "com.apple.keylayout.Russian", language: "ru",
        lower: ["]1234567890-=", "йцукенгшщзхъё", "фывапролджэ", "ячсмитьбю/"],
        upper: ["[!\"№%:,.;()_+", "ЙЦУКЕНГШЩЗХЪЁ", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ?"]
    )
}
