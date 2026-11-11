import Foundation

/// Перевод произвольного (выделенного) текста из одной раскладки в другую.
public enum SelectionConverter {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let targetLayoutID: String
    }

    public static func convert(_ text: String, context: LayoutContext) -> Result? {
        let all = [context.current] + context.others
        guard all.count >= 2 else { return nil }

        // Раскладка, в которой текст набран: та, чьих букв в нём больше.
        let whole = Substring(text)
        var source = context.current
        var best = -1
        for layout in all {
            let score = layout.letterCoverage(of: whole)
            if score > best { best = score; source = layout }
        }
        guard best > 0 else { return nil }
        let target = source.id == context.current.id ? context.others[0] : context.current

        var result = ""
        result.reserveCapacity(text.count)
        var word = Substring()
        func flush() {
            guard !word.isEmpty else { return }
            // Слово целиком из букв целевой раскладки переводим обратно — выделение «переворачивается».
            let fromSource = source.letterCoverage(of: word)
            let fromTarget = target.letterCoverage(of: word)
            let (from, to) = fromTarget > fromSource ? (target, source) : (source, target)
            for c in word {
                if let stroke = from.stroke(for: c), let mapped = to.character(for: stroke) {
                    result.append(mapped)
                } else {
                    result.append(c)
                }
            }
            word = Substring()
        }
        for c in text {
            if c.isWhitespace { flush(); result.append(c) } else { word.append(c) }
        }
        flush()
        guard result != text else { return nil }
        return Result(text: result, targetLayoutID: target.id)
    }
}
