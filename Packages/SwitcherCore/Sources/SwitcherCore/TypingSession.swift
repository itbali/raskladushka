import Foundation

public enum InputEvent: Sendable {
    /// Печатная клавиша (включая пробел).
    case stroke(KeyStroke)
    case backspace
    /// Всё, после чего мы не знаем, где курсор: стрелки, мышь, Enter, Tab, ⌘-сочетания, смена приложения.
    case reset
}

public struct LayoutContext: Sendable {
    public let current: LayoutTable
    /// Остальные включённые раскладки, сначала наиболее вероятная.
    public let others: [LayoutTable]
    public init(current: LayoutTable, others: [LayoutTable]) {
        self.current = current
        self.others = others
    }
}

/// Что нужно сделать в текстовом поле: стереть `deleteCount` символов, вставить `insert`, сменить раскладку.
public struct Replacement: Equatable, Sendable {
    public let deleteCount: Int
    public let insert: String
    public let switchTo: String
    /// Слово, которое пользователь вернул после автозамены, — его стоит запомнить как исключение.
    public var learnedException: String?
}

/// Следит за набором текущего слова и нескольких предыдущих. Чистая логика без системных вызовов.
public final class TypingSession {
    struct Token {
        var strokes: [KeyStroke]
        var displayed: String
        var layoutID: String
        var trailingSpaces: Int
        var pending: Conversion?
        var autoConverted = false
        var originalTyped: String
        var locked = false
    }

    public var detector: LayoutDetector
    public var autoSwitchEnabled = true
    private var strokes: [KeyStroke] = []
    private var run: [Token] = []
    /// Как вернуть последнюю замену: что стереть и набрать, и какими были слова до неё.
    private struct Undo {
        var replacement: Replacement
        var first = 0
        var tokens: [Token]?
    }
    private var undo: Undo?
    /// Сколько последних слов помним: нужно для отмены и для перевода выделенного «хвоста» в терминалах.
    private let maxRun = 60

    public init(detector: LayoutDetector) {
        self.detector = detector
    }

    public var hasPendingWord: Bool { !strokes.isEmpty || !run.isEmpty }

    /// Есть замена, которую ещё можно вернуть: после неё ничего не набрано и курсор не сдвинут.
    public var canUndo: Bool { undo != nil }

    /// Возврат последней замены — автоматической или по сочетанию. Слова возвращаются целиком,
    /// вместе с исправленными задним числом, и больше не переводятся сами.
    public func undoLast() -> Replacement? {
        guard let undo else { return nil }
        self.undo = nil
        if let tokens = undo.tokens, undo.first <= run.count {
            run.replaceSubrange(undo.first..., with: tokens)
        }
        return undo.replacement
    }

    /// Замена, сделанная мимо сессии (выделение в терминале): запоминаем, как её вернуть.
    public func rememberUndo(deleteCount: Int, insert: String, switchTo: String) {
        undo = Undo(replacement: Replacement(deleteCount: deleteCount, insert: insert, switchTo: switchTo))
    }

    public func reset() {
        undo = nil
        strokes.removeAll(keepingCapacity: true)
        run.removeAll(keepingCapacity: true)
    }

    public func handle(_ event: InputEvent, context: LayoutContext) -> Replacement? {
        undo = nil
        switch event {
        case .reset:
            reset()
            return nil
        case .backspace:
            if strokes.isEmpty { reset() } else { strokes.removeLast() }
            return nil
        case .stroke(let stroke):
            if stroke.isSpace { return boundary(context: context) }
            guard context.current.character(for: stroke) != nil else { reset(); return nil }
            strokes.append(stroke)
            return nil
        }
    }

    private func boundary(context: LayoutContext) -> Replacement? {
        guard !strokes.isEmpty else {
            if run.isEmpty { return nil }
            run[run.count - 1].trailingSpaces += 1
            return nil
        }
        guard let typed = context.current.string(for: strokes) else { reset(); return nil }
        var token = Token(strokes: strokes, displayed: typed, layoutID: context.current.id,
                          trailingSpaces: 1, originalTyped: typed)
        strokes.removeAll(keepingCapacity: true)
        defer {
            let extra = run.count - maxRun
            if extra > 0 {
                run.removeFirst(extra)
                if undo?.tokens != nil {
                    undo!.first -= extra
                    if undo!.first < 0 { undo = nil }
                }
            }
        }

        guard autoSwitchEnabled,
              let found = detector.evaluate(strokes: token.strokes, current: context.current, others: context.others)
        else {
            run.append(token)
            return nil
        }
        guard found.strength == .strong else {
            token.pending = found
            run.append(token)
            return nil
        }

        // Уверенное слово: заодно исправляем сомнительные слова прямо перед ним.
        var first = run.count
        while first > 0, let p = run[first - 1].pending, p.layoutID == found.layoutID,
              !run[first - 1].locked, run[first - 1].layoutID == context.current.id {
            first -= 1
        }
        var before = Array(run[first...]) + [token]
        var deleteCount = 0
        var insert = ""
        for i in first..<run.count {
            deleteCount += run[i].displayed.count + run[i].trailingSpaces
            let text = run[i].pending!.text
            insert += text + String(repeating: " ", count: run[i].trailingSpaces)
            run[i].displayed = text
            run[i].layoutID = found.layoutID
            run[i].pending = nil
            run[i].autoConverted = true
        }
        deleteCount += token.displayed.count + 1
        insert += found.text + " "
        token.displayed = found.text
        token.layoutID = found.layoutID
        token.autoConverted = true
        run.append(token)
        // Оставшиеся сомнения относились к старой раскладке — они больше не актуальны.
        for i in 0..<first { run[i].pending = nil }
        var original = ""
        for i in before.indices {
            before[i].pending = nil
            before[i].locked = true
            original += before[i].displayed + String(repeating: " ", count: before[i].trailingSpaces)
        }
        undo = Undo(replacement: Replacement(deleteCount: insert.count, insert: original, switchTo: context.current.id,
                                             learnedException: token.originalTyped.lowercased()),
                    first: first, tokens: before)
        return Replacement(deleteCount: deleteCount, insert: insert, switchTo: found.layoutID)
    }

    /// Текст, набранный с последнего сброса и стоящий прямо перед курсором.
    public func tailText(context: LayoutContext) -> String {
        var text = ""
        for token in run {
            text += token.displayed + String(repeating: " ", count: token.trailingSpaces)
        }
        return text + (context.current.string(for: strokes) ?? "")
    }

    /// Перевод выделенного фрагмента, если он входит в только что набранный текст перед курсором.
    /// Тогда его можно заменить стиранием и повторным набором — без вставки из буфера обмена
    /// (в терминалах выделение нельзя заменить вставкой). Иначе `nil`.
    public func replaceInTail(selected: String, context: LayoutContext) -> Replacement? {
        let tail = tailText(context: context)
        guard !selected.isEmpty, let range = tail.range(of: selected, options: .backwards),
              let converted = SelectionConverter.convert(selected, context: context) else { return nil }
        let result = Replacement(deleteCount: tail.distance(from: range.lowerBound, to: tail.endIndex),
                                 insert: converted.text + tail[range.upperBound...],
                                 switchTo: converted.targetLayoutID)
        reset()
        rememberUndo(deleteCount: result.insert.count, insert: String(tail[range.lowerBound...]),
                     switchTo: context.current.id)
        return result
    }

    /// Ручное переключение по горячей клавише: текущее недописанное слово либо последнее набранное.
    /// Возвращает `nil`, если переключать нечего (тогда приложение работает с выделением).
    public func manualToggle(context: LayoutContext) -> Replacement? {
        if !strokes.isEmpty {
            guard let typed = context.current.string(for: strokes) else { reset(); return nil }
            for target in context.others {
                if let text = target.string(for: strokes) {
                    undo = Undo(replacement: Replacement(deleteCount: text.count, insert: typed,
                                                         switchTo: context.current.id))
                    return Replacement(deleteCount: typed.count, insert: text, switchTo: target.id)
                }
            }
            return nil
        }
        guard var token = run.last else { return nil }
        let all = [context.current] + context.others
        let candidates = all.filter { $0.id != token.layoutID }
        for target in candidates {
            guard let text = target.string(for: token.strokes) else { continue }
            let spaces = String(repeating: " ", count: token.trailingSpaces)
            var result = Replacement(deleteCount: token.displayed.count + token.trailingSpaces,
                                     insert: text + spaces, switchTo: target.id)
            if token.autoConverted, text == token.originalTyped {
                result.learnedException = token.originalTyped.lowercased()
            }
            var back = token
            back.pending = nil
            back.locked = true
            undo = Undo(replacement: Replacement(deleteCount: result.insert.count, insert: token.displayed + spaces,
                                                 switchTo: token.layoutID),
                        first: run.count - 1, tokens: [back])
            token.displayed = text
            token.layoutID = target.id
            token.pending = nil
            token.autoConverted = false
            token.locked = true
            run[run.count - 1] = token
            return result
        }
        return nil
    }
}
