import AppKit
import SwitcherCore

/// Проверка слов системным спеллчекером macOS — без собственных словарей и без сети.
final class SpellValidator: WordValidating {
    private let checker = NSSpellChecker.shared
    private lazy var available: [String] = checker.availableLanguages
    private var resolved: [String: String?] = [:]
    private var cache: [String: Bool] = [:]

    func isWord(_ word: String, language: String) -> Bool {
        guard let spellLanguage = resolve(language) else { return false }
        let key = spellLanguage + "\u{1}" + word
        if let known = cache[key] { return known }
        let range = checker.checkSpelling(of: word, startingAt: 0, language: spellLanguage, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        let result = range.location == NSNotFound
        if cache.count > 5_000 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private func resolve(_ language: String) -> String? {
        if let known = resolved[language] { return known }
        let base = String(language.prefix { $0 != "-" && $0 != "_" })
        let found = available.first { $0 == language }
            ?? available.first { $0 == base }
            ?? available.first { $0.hasPrefix(base + "_") }
        resolved[language] = found
        return found
    }
}
