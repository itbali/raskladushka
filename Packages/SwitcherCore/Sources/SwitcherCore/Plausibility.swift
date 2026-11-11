import Foundation

/// Запасная оценка «похоже ли это на слово языка» по сочетаниям букв.
/// Нужна для слов, которых нет в системном словаре («раскладка», «деплой»).
public enum Plausibility {
    private static let sets: [String: Set<Substring>] = [
        "ru": Set(TrigramData.ru.split(whereSeparator: \.isWhitespace)),
        "en": Set(TrigramData.en.split(whereSeparator: \.isWhitespace)),
    ]

    public static func isSupported(_ language: String) -> Bool {
        sets[CommonWords.baseLanguage(language)] != nil
    }

    /// Сколько троек букв в слове не встречается в языке. `nil`, если язык не поддержан.
    public static func unusualTrigrams(in word: String, language: String) -> Int? {
        guard let set = sets[CommonWords.baseLanguage(language)] else { return nil }
        let chars = Array("^" + word.lowercased() + "$")
        guard chars.count >= 3 else { return 0 }
        var misses = 0
        for i in 0...(chars.count - 3) where !set.contains(Substring(String(chars[i..<i + 3]))) {
            misses += 1
        }
        return misses
    }
}
