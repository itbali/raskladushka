import Foundation

/// Проверка «существует ли такое слово в языке». В приложении — системный спеллчекер.
public protocol WordValidating {
    func isWord(_ word: String, language: String) -> Bool
}

public struct Conversion: Equatable, Sendable {
    public enum Strength: Sendable { case strong, weak }
    /// Чем заменить набранное слово целиком.
    public let text: String
    /// Раскладка, на которую нужно переключиться.
    public let layoutID: String
    public let strength: Strength
}

/// Решает, набрано ли слово «не в той раскладке».
public struct LayoutDetector {
    public let validator: WordValidating
    /// Слова (в нижнем регистре, как набраны), которые пользователь запретил исправлять.
    public var exceptions: Set<String> = []

    public init(validator: WordValidating, exceptions: Set<String> = []) {
        self.validator = validator
        self.exceptions = exceptions
    }

    public func evaluate(strokes: [KeyStroke], current: LayoutTable, others: [LayoutTable]) -> Conversion? {
        guard !strokes.isEmpty, strokes.count <= 40,
              let typed = current.string(for: strokes) else { return nil }
        if exceptions.contains(typed.lowercased()) { return nil }
        if Self.looksTechnical(typed) { return nil }

        var weak: Conversion?
        for other in others where other.id != current.id {
            guard let found = evaluate(strokes: strokes, typed: typed, current: current, other: other) else { continue }
            if found.strength == .strong { return found }
            if weak == nil { weak = found }
        }
        return weak
    }

    // MARK: - Внутреннее

    private func evaluate(strokes: [KeyStroke], typed: String, current: LayoutTable, other: LayoutTable) -> Conversion? {
        guard let alt = other.string(for: strokes), alt != typed else { return nil }

        // Вариант А: всё слово читается в другой раскладке (знаки по краям тоже переводятся).
        let typedCore = Self.core(of: typed)
        if let altCore = Self.core(of: alt),
           let strength = verdict(typedCore: typedCore, current: current, altCore: altCore, other: other) {
            return Conversion(text: alt, layoutID: other.id, strength: strength)
        }

        // Вариант Б: знаки по краям оставляем как набраны («ghbdtn,» → «привет,»).
        let chars = Array(typed)
        var start = 0, end = chars.count
        while start < end, !chars[start].isLetter { start += 1 }
        while end > start, !chars[end - 1].isLetter { end -= 1 }
        guard start > 0 || end < chars.count, start < end,
              let inner = other.string(for: Array(strokes[start..<end])),
              let innerCore = Self.core(of: inner), innerCore == inner,
              let strength = verdict(typedCore: String(chars[start..<end]), current: current, altCore: innerCore, other: other)
        else { return nil }
        return Conversion(text: String(chars[..<start]) + inner + String(chars[end...]),
                          layoutID: other.id, strength: strength)
    }

    private func verdict(typedCore: String?, current: LayoutTable, altCore: String, other: LayoutTable) -> Conversion.Strength? {
        let letters = altCore.filter(\.isLetter).count
        let typedIsWordLike = typedCore != nil
        let typed = typedCore ?? ""
        let typedCommon = typedIsWordLike && CommonWords.contains(typed, language: current.language)
        let altCommon = CommonWords.contains(altCore, language: other.language)

        switch letters {
        case 0:
            return nil
        case 1:
            return altCommon && !typedCommon ? .weak : nil
        case 2, 3:
            let altOK: Bool
            if letters == 2, CommonWords.hasList(for: other.language) {
                altOK = altCommon
            } else {
                altOK = altCommon || isWord(altCore, other.language)
            }
            guard altOK else { return nil }
            if typedCommon { return nil }
            // Для двух букв спрашиваем словарь без вариантов с заглавной: «Yt», «Gj» он примет как сокращения.
            let typedAccepted = typedIsWordLike
                && (letters == 2 ? validator.isWord(typed, language: current.language) : isWord(typed, current.language))
            if !typedAccepted { return .strong }
            // Спеллчекер принимает почти любые две буквы как сокращение, поэтому для двухбуквенных
            // его «да» не запрещает замену, а лишь откладывает её до подтверждения соседним словом.
            return altCommon && (letters == 2 || !typedCommon) ? .weak : nil
        default:
            if typedIsWordLike, typedCommon || isWord(typed, current.language) { return nil }
            if isWord(altCore, other.language) { return .strong }
            // Слова нет в словаре: смотрим на сочетания букв. Набранное должно выглядеть
            // бессмыслицей в своей раскладке, а перевод — обычным словом.
            guard typedIsWordLike, !altCore.contains(where: { !$0.isLetter }),
                  let typedMisses = Plausibility.unusualTrigrams(in: typed, language: current.language),
                  let altMisses = Plausibility.unusualTrigrams(in: altCore, language: other.language)
            else { return nil }
            return altMisses == 0 && typedMisses >= max(2, typed.count / 3) ? .strong : nil
        }
    }

    /// Слово считается существующим и в варианте с заглавной буквы («москва» → «Москва»).
    private func isWord(_ word: String, _ language: String) -> Bool {
        if validator.isWord(word, language: language) { return true }
        let lower = word.lowercased()
        if lower != word, validator.isWord(lower, language: language) { return true }
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        return capitalized != word && validator.isWord(capitalized, language: language)
    }

    /// Буквенное ядро слова без знаков по краям. `nil`, если внутри есть что-то кроме букв, дефиса и апострофа.
    static func core(of text: String) -> String? {
        let chars = Array(text)
        var start = 0, end = chars.count
        while start < end, !chars[start].isLetter { start += 1 }
        while end > start, !chars[end - 1].isLetter { end -= 1 }
        guard start < end else { return nil }
        let inner = chars[start..<end]
        for c in inner where !(c.isLetter || c == "-" || c == "'" || c == "’") { return nil }
        return String(inner)
    }

    /// Адреса, почта, camelCase и слова с цифрами не трогаем.
    static func looksTechnical(_ typed: String) -> Bool {
        if typed.contains(where: \.isNumber) { return true }
        if typed.contains("@") || typed.contains("://") || typed.contains("_") { return true }
        let chars = Array(typed)
        for i in chars.indices.dropFirst() where chars[i].isUppercase && chars[i - 1].isLowercase { return true }
        return false
    }
}
