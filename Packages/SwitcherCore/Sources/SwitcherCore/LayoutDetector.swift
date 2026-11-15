import Foundation

/// Проверка «существует ли такое слово в языке». В приложении — системный спеллчекер.
public protocol WordValidating {
    func isWord(_ word: String, language: String) -> Bool
}

public struct Conversion: Equatable, Sendable {
    public enum Strength: Sendable { case strong, weak }
    /// Почему решено заменить — для журнала замен.
    public enum Reason: String, Sendable {
        /// Перевод есть в словаре, набранного там нет.
        case dictionary
        /// Короткое частое слово из встроенного списка.
        case commonWord
        /// Слова нет в словаре, но сочетания букв похожи на язык перевода.
        case letterStatistics
        /// Соседние слова — на языке перевода.
        case context
        /// Пользователь несколько раз переводил это слово сам.
        case learned
        /// Слово начато в одной раскладке, а закончено в другой.
        case mixed
    }
    /// Чем заменить набранное слово целиком.
    public let text: String
    /// Раскладка, на которую нужно переключиться.
    public let layoutID: String
    public let strength: Strength
    public var reason: Reason = .dictionary
}

/// Решает, набрано ли слово «не в той раскладке».
public struct LayoutDetector {
    public let validator: WordValidating
    /// Слова (в нижнем регистре, как набраны), которые пользователь запретил исправлять.
    public var exceptions: Set<String> = []
    /// Слова (в нижнем регистре, как набраны), которые пользователь сам не раз переводил:
    /// для каждого — раскладка, в которую его переводить.
    public var learned: [String: String] = [:]

    public init(validator: WordValidating, exceptions: Set<String> = []) {
        self.validator = validator
        self.exceptions = exceptions
    }

    /// `contextLayoutID` — раскладка, в которой набраны предыдущие слова фразы. Сомнительное короткое
    /// слово, которое читается на этом языке, исправляется сразу, не дожидаясь подтверждения.
    public func evaluate(strokes: [KeyStroke], current: LayoutTable, others: [LayoutTable],
                         contextLayoutID: String? = nil) -> Conversion? {
        guard !strokes.isEmpty, strokes.count <= 40,
              let typed = current.string(for: strokes) else { return nil }
        let lower = typed.lowercased()
        if exceptions.contains(lower) { return nil }
        if let target = learned[lower], let other = others.first(where: { $0.id == target }),
           let alt = other.string(for: strokes), alt != typed {
            return Conversion(text: alt, layoutID: other.id, strength: .strong, reason: .learned)
        }
        if Self.looksTechnical(typed) { return nil }

        // Раскладок может быть больше двух: берём не первую подходящую, а самую убедительную —
        // слово из словаря важнее похожего по сочетаниям букв, а оно важнее сомнительного.
        var best: Conversion?
        for other in others where other.id != current.id {
            guard let found = evaluate(strokes: strokes, typed: typed, current: current, other: other) else { continue }
            if best == nil || Self.rank(found) > Self.rank(best!) { best = found }
        }
        if var found = best, found.strength == .weak, found.layoutID == contextLayoutID {
            found = Conversion(text: found.text, layoutID: found.layoutID, strength: .strong, reason: .context)
            return found
        }
        return best
    }

    private static func rank(_ conversion: Conversion) -> Int {
        guard conversion.strength == .strong else { return 1 }
        return conversion.reason == .letterStatistics ? 2 : 3
    }

    /// Слово набрано кусками в разных раскладках («ghbвет»). Если целиком в одной из них оно читается
    /// как настоящее слово — это оно и есть. `tables` — сначала предпочтительная раскладка.
    public func evaluateMixed(strokes: [KeyStroke], typed: String, tables: [LayoutTable]) -> Conversion? {
        guard strokes.count >= 2, strokes.count <= 40, !exceptions.contains(typed.lowercased()),
              !Self.looksTechnical(typed) else { return nil }
        for table in tables {
            guard let alt = table.string(for: strokes), alt != typed, let core = Self.core(of: alt),
                  core.count >= 2 else { continue }
            let known = CommonWords.contains(core, language: table.language)
                || (core.count >= 3 && isWord(core, table.language))
            if known { return Conversion(text: alt, layoutID: table.id, strength: .strong, reason: .mixed) }
        }
        return nil
    }

    /// Настоящее ли это слово языка — для оценки, на каком языке идёт фраза.
    public func isKnownWord(_ text: String, language: String) -> Bool {
        guard let core = Self.core(of: text) else { return false }
        return CommonWords.contains(core, language: language) || (core.count >= 3 && isWord(core, language))
    }

    // MARK: - Внутреннее

    private func evaluate(strokes: [KeyStroke], typed: String, current: LayoutTable, other: LayoutTable) -> Conversion? {
        guard let alt = other.string(for: strokes), alt != typed else { return nil }

        // Вариант А: всё слово читается в другой раскладке (знаки по краям тоже переводятся).
        let typedCore = Self.core(of: typed)
        if let altCore = Self.core(of: alt),
           let (strength, reason) = verdict(typedCore: typedCore, current: current, altCore: altCore, other: other) {
            return Conversion(text: alt, layoutID: other.id, strength: strength, reason: reason)
        }

        // Вариант Б: знаки по краям оставляем как набраны («ghbdtn,» → «привет,»).
        let chars = Array(typed)
        var start = 0, end = chars.count
        while start < end, !chars[start].isLetter { start += 1 }
        while end > start, !chars[end - 1].isLetter { end -= 1 }
        guard start > 0 || end < chars.count, start < end,
              let inner = other.string(for: Array(strokes[start..<end])),
              let innerCore = Self.core(of: inner), innerCore == inner,
              let (strength, reason) = verdict(typedCore: String(chars[start..<end]), current: current,
                                               altCore: innerCore, other: other)
        else { return nil }
        return Conversion(text: String(chars[..<start]) + inner + String(chars[end...]),
                          layoutID: other.id, strength: strength, reason: reason)
    }

    private func verdict(typedCore: String?, current: LayoutTable, altCore: String, other: LayoutTable)
        -> (Conversion.Strength, Conversion.Reason)? {
        let letters = altCore.filter(\.isLetter).count
        let typedIsWordLike = typedCore != nil
        let typed = typedCore ?? ""
        let typedCommon = typedIsWordLike && CommonWords.contains(typed, language: current.language)
        let altCommon = CommonWords.contains(altCore, language: other.language)

        switch letters {
        case 0:
            return nil
        case 1:
            return altCommon && !typedCommon ? (.weak, .commonWord) : nil
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
            if !typedAccepted { return (.strong, altCommon ? .commonWord : .dictionary) }
            // Спеллчекер принимает почти любые две буквы как сокращение, поэтому для двухбуквенных
            // его «да» не запрещает замену, а лишь откладывает её до подтверждения соседним словом.
            return altCommon && (letters == 2 || !typedCommon) ? (.weak, .commonWord) : nil
        default:
            if typedIsWordLike, typedCommon || isWord(typed, current.language) { return nil }
            if isWord(altCore, other.language) { return (.strong, .dictionary) }
            // Слова нет в словаре: смотрим на сочетания букв. Набранное должно выглядеть
            // бессмыслицей в своей раскладке, а перевод — обычным словом.
            guard typedIsWordLike, !altCore.contains(where: { !$0.isLetter }),
                  let typedMisses = Plausibility.unusualTrigrams(in: typed, language: current.language),
                  let altMisses = Plausibility.unusualTrigrams(in: altCore, language: other.language)
            else { return nil }
            return altMisses == 0 && typedMisses >= max(2, typed.count / 3) ? (.strong, .letterStatistics) : nil
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
