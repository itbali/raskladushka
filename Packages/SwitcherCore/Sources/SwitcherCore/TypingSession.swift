import Foundation

public enum InputEvent: Sendable {
    /// Печатная клавиша (включая пробел).
    case stroke(KeyStroke)
    case backspace
    /// Всё, после чего мы не знаем, где курсор: стрелки, мышь, Enter, Tab, ⌘-сочетания, смена приложения.
    case reset
    /// Сочетание с пробелом (⌃Space, ⌘Space…): возможно, так сменили раскладку посреди слова.
    /// Набранное пока помним; если следующая буква придёт в той же раскладке — это был не язык, сбрасываем.
    case softReset
}

public struct LayoutContext: Sendable {
    public let current: LayoutTable
    /// Остальные включённые раскладки, сначала наиболее вероятная.
    public let others: [LayoutTable]
    public init(current: LayoutTable, others: [LayoutTable]) {
        self.current = current
        self.others = others
    }

    var all: [LayoutTable] { [current] + others }
    func table(_ id: String) -> LayoutTable? { all.first { $0.id == id } }
}

/// Что нужно сделать в текстовом поле: стереть `deleteCount` символов, вставить `insert`, сменить раскладку.
public struct Replacement: Equatable, Sendable {
    /// Что это за замена — для журнала, счётчиков и подсказки. На само действие не влияет.
    public struct Info: Sendable {
        public enum Kind: String, Sendable { case auto, manual, selection, undo, redo }
        public let kind: Kind
        /// Что было в поле и что стало (без пробелов по краям).
        public let before: String
        public let after: String
        public let reason: Conversion.Reason?
        /// Сколько слов исправлено.
        public let words: Int
        /// Пользователь сам перевёл готовое слово: как оно было набрано и в какую раскладку переведено.
        public var manualWord: (typed: String, layoutID: String)?

        public init(kind: Kind, before: String, after: String, reason: Conversion.Reason? = nil, words: Int = 1,
                    manualWord: (typed: String, layoutID: String)? = nil) {
            self.kind = kind
            self.before = before
            self.after = after
            self.reason = reason
            self.words = words
            self.manualWord = manualWord
        }
    }

    public let deleteCount: Int
    public let insert: String
    public let switchTo: String
    /// Слово, которое пользователь вернул после автозамены, — его стоит запомнить как исключение.
    public var learnedException: String?
    /// Слово, замену которого пользователь повторил после отмены, — исключение нужно снять.
    public var forgetException: String?
    public var info: Info?

    public init(deleteCount: Int, insert: String, switchTo: String, learnedException: String? = nil,
                forgetException: String? = nil, info: Info? = nil) {
        self.deleteCount = deleteCount
        self.insert = insert
        self.switchTo = switchTo
        self.learnedException = learnedException
        self.forgetException = forgetException
        self.info = info
    }

    public static func == (a: Replacement, b: Replacement) -> Bool {
        a.deleteCount == b.deleteCount && a.insert == b.insert && a.switchTo == b.switchTo
            && a.learnedException == b.learnedException && a.forgetException == b.forgetException
    }
}

/// Следит за набором текущего слова и нескольких предыдущих. Чистая логика без системных вызовов.
public final class TypingSession {
    struct Token {
        var strokes: [KeyStroke]
        /// Раскладка каждого нажатия: слово могли начать в одной, а закончить в другой.
        var layouts: [String]
        var displayed: String
        var layoutID: String
        var trailingSpaces: Int
        var pending: Conversion?
        var autoConverted = false
        var originalTyped: String
        var locked = false
        /// Настоящее слово своего языка — по таким судим, на каком языке идёт фраза.
        var known = false
    }

    public var detector: LayoutDetector
    public var autoSwitchEnabled = true
    /// Собирать слово, начатое в одной раскладке и законченное в другой.
    public var mixedWordsEnabled = true
    /// Учитывать язык предыдущих слов фразы.
    public var contextEnabled = true
    /// Backspace сразу после автозамены возвращает слово.
    public var backspaceUndoEnabled = true

    private var strokes: [KeyStroke] = []
    private var strokeLayouts: [String] = []
    private var softResetPending = false
    /// Слово, которое только что вернули клавишей Backspace: при следующем пробеле его не трогаем.
    private var keptStrokes: [KeyStroke]?
    private var run: [Token] = []

    /// Как вернуть последнюю замену и как потом повторить её.
    private struct Change {
        /// Что сделать с текстом, чтобы вернуть как было.
        var back: Replacement
        /// Что сделать, чтобы снова получить результат замены. `nil` — повторить нельзя.
        var forward: Replacement?
        /// С какого слова в `run` начинается изменённое, какими слова были и какими стали.
        var first = 0
        var before: [Token]?
        var after: [Token]?
        /// То же для недописанного слова: раскладки его кусков до и после.
        var layoutsBefore: [String]?
        var layoutsAfter: [String]?
        var auto = false
    }
    private var undo: Change?
    private var redo: Change?
    /// Сколько последних слов помним: нужно для отмены и для перевода выделенного «хвоста» в терминалах.
    private let maxRun = 60

    public init(detector: LayoutDetector) {
        self.detector = detector
    }

    public var hasPendingWord: Bool { !strokes.isEmpty || !run.isEmpty }

    /// Есть замена, которую ещё можно вернуть: после неё ничего не набрано и курсор не сдвинут.
    public var canUndo: Bool { undo != nil }
    /// Замену только что вернули, и её ещё можно повторить.
    public var canRedo: Bool { redo?.forward != nil }
    /// Последняя замена — автоматическая, и Backspace её вернёт.
    public var canUndoByBackspace: Bool {
        backspaceUndoEnabled && strokes.isEmpty && undo?.auto == true && undo?.before?.last?.trailingSpaces == 1
    }

    /// Возврат последней замены — автоматической или по сочетанию. Слова возвращаются целиком,
    /// вместе с исправленными задним числом, и больше не переводятся сами.
    public func undoLast() -> Replacement? {
        guard let change = undo else { return nil }
        undo = nil
        apply(tokens: change.before, layouts: change.layoutsBefore, from: change.first)
        redo = change
        return change.back
    }

    /// Повтор только что отменённой замены.
    public func redoLast() -> Replacement? {
        guard let change = redo, var forward = change.forward else { return nil }
        redo = nil
        apply(tokens: change.after, layouts: change.layoutsAfter, from: change.first)
        undo = change
        forward.forgetException = change.back.learnedException
        if let info = forward.info {
            forward.info = .init(kind: .redo, before: info.before, after: info.after, reason: info.reason, words: info.words)
        }
        return forward
    }

    private func apply(tokens: [Token]?, layouts: [String]?, from first: Int) {
        if let tokens, first <= run.count { run.replaceSubrange(first..., with: tokens) }
        if let layouts, layouts.count == strokes.count { strokeLayouts = layouts }
    }

    /// Замена, сделанная мимо сессии (выделение в терминале): запоминаем, как её вернуть и повторить.
    public func rememberUndo(deleteCount: Int, insert: String, switchTo: String,
                             redoInsert: String? = nil, redoSwitchTo: String? = nil) {
        redo = nil
        var forward: Replacement?
        if let redoInsert, let redoSwitchTo {
            forward = Replacement(deleteCount: insert.count, insert: redoInsert, switchTo: redoSwitchTo,
                                  info: .init(kind: .selection, before: insert.trimmed, after: redoInsert.trimmed, words: 0))
        }
        undo = Change(back: Replacement(deleteCount: deleteCount, insert: insert, switchTo: switchTo,
                                        info: .init(kind: .undo, before: (redoInsert ?? "").trimmed,
                                                    after: insert.trimmed, words: 0)),
                      forward: forward)
    }

    public func reset() {
        undo = nil
        redo = nil
        softResetPending = false
        keptStrokes = nil
        strokes.removeAll(keepingCapacity: true)
        strokeLayouts.removeAll(keepingCapacity: true)
        run.removeAll(keepingCapacity: true)
    }

    /// Пользователь сам сменил раскладку. Текст перед курсором от этого не изменился, поэтому набранное
    /// помним — и недописанное слово, и предыдущие (по ним видно, на каком языке шла фраза).
    public func layoutChangedByUser() {
        guard mixedWordsEnabled || strokes.isEmpty else { reset(); return }
        undo = nil
        redo = nil
        softResetPending = false
        for i in run.indices { run[i].pending = nil }
    }

    public func handle(_ event: InputEvent, context: LayoutContext) -> Replacement? {
        switch event {
        case .reset:
            reset()
            return nil
        case .softReset:
            guard mixedWordsEnabled, !strokes.isEmpty else { reset(); return nil }
            undo = nil
            redo = nil
            softResetPending = true
            return nil
        case .backspace:
            if let back = undoByBackspace() { return back }
            undo = nil
            redo = nil
            softResetPending = false
            keptStrokes = nil
            if strokes.isEmpty { reset() } else { strokes.removeLast(); strokeLayouts.removeLast() }
            return nil
        case .stroke(let stroke):
            undo = nil
            redo = nil
            if softResetPending {
                softResetPending = false
                // Раскладка та же — значит, сочетание было не сменой языка, и где курсор, неизвестно.
                if strokeLayouts.last == context.current.id { reset() }
            }
            if stroke.isSpace { return boundary(context: context) }
            guard context.current.character(for: stroke) != nil else { reset(); return nil }
            // Слово после возврата правят — значит, при пробеле его нужно проверить заново.
            keptStrokes = nil
            strokes.append(stroke)
            strokeLayouts.append(context.current.id)
            return nil
        }
    }

    // MARK: - Текущее слово

    private var isMixed: Bool {
        guard let first = strokeLayouts.first else { return false }
        return strokeLayouts.contains { $0 != first }
    }

    /// Недописанное слово так, как оно выглядит в поле: каждый кусок — в раскладке, в которой набран.
    private func currentText(context: LayoutContext) -> String? {
        var text = ""
        for (stroke, layoutID) in zip(strokes, strokeLayouts) {
            guard let c = context.table(layoutID)?.character(for: stroke) else { return nil }
            text.append(c)
        }
        return text
    }

    /// Раскладка, в которой набраны два последних настоящих слова фразы.
    private func contextLayoutID() -> String? {
        guard contextEnabled, run.count >= 2 else { return nil }
        let last = run[run.count - 1], previous = run[run.count - 2]
        return last.known && previous.known && last.layoutID == previous.layoutID ? last.layoutID : nil
    }

    private func boundary(context: LayoutContext) -> Replacement? {
        guard !strokes.isEmpty else {
            if run.isEmpty { return nil }
            run[run.count - 1].trailingSpaces += 1
            return nil
        }
        guard let typed = currentText(context: context) else { reset(); return nil }
        let mixed = isMixed
        var token = Token(strokes: strokes, layouts: strokeLayouts, displayed: typed, layoutID: context.current.id,
                          trailingSpaces: 1, originalTyped: typed)
        strokes.removeAll(keepingCapacity: true)
        strokeLayouts.removeAll(keepingCapacity: true)
        defer {
            let extra = run.count - maxRun
            if extra > 0 {
                run.removeFirst(extra)
                if undo?.before != nil {
                    undo!.first -= extra
                    if undo!.first < 0 { undo = nil }
                }
            }
        }

        let kept = keptStrokes == token.strokes
        keptStrokes = nil
        let found: Conversion?
        if !autoSwitchEnabled || kept {
            found = nil
        } else if mixed {
            // Сначала пробуем раскладку, на которую переключились последней, — её выбрали сознательно.
            found = detector.evaluateMixed(strokes: token.strokes, typed: typed, tables: context.all)
        } else {
            found = detector.evaluate(strokes: token.strokes, current: context.current, others: context.others,
                                      contextLayoutID: contextLayoutID())
        }
        guard let found else {
            token.known = !mixed && detector.isKnownWord(typed, language: context.current.language)
            token.locked = kept
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
        while !mixed, first > 0, let p = run[first - 1].pending, p.layoutID == found.layoutID,
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
            run[i].known = true
        }
        deleteCount += token.displayed.count + 1
        insert += found.text + " "
        token.displayed = found.text
        token.layoutID = found.layoutID
        token.autoConverted = true
        token.known = true
        run.append(token)
        // Оставшиеся сомнения относились к старой раскладке — они больше не актуальны.
        for i in 0..<first { run[i].pending = nil }
        var original = ""
        for i in before.indices {
            before[i].pending = nil
            before[i].locked = true
            original += before[i].displayed + String(repeating: " ", count: before[i].trailingSpaces)
        }
        let info = Replacement.Info(kind: .auto, before: original.trimmed, after: insert.trimmed,
                                    reason: found.reason, words: before.count)
        undo = Change(back: Replacement(deleteCount: insert.count, insert: original, switchTo: context.current.id,
                                        learnedException: token.originalTyped.lowercased(),
                                        info: .init(kind: .undo, before: insert.trimmed, after: original.trimmed,
                                                    words: before.count)),
                      forward: Replacement(deleteCount: original.count, insert: insert, switchTo: found.layoutID, info: info),
                      first: first, before: before, after: Array(run[first...]), auto: true)
        return Replacement(deleteCount: deleteCount, insert: insert, switchTo: found.layoutID, info: info)
    }

    /// Backspace сразу после автозамены: пробел за словом человек стёр сам, мы возвращаем слово
    /// как оно было набрано — и оно снова считается недописанным. В исключения слово не попадает:
    /// Backspace нажимают и просто чтобы стереть пробел. Но если дописать пробел, не меняя слова,
    /// второй раз оно не исправится.
    private func undoByBackspace() -> Replacement? {
        guard canUndoByBackspace, let change = undo, var tokens = change.before, let last = tokens.last,
              change.first <= run.count else { return nil }
        undo = nil
        redo = nil
        softResetPending = false
        tokens.removeLast()
        run.replaceSubrange(change.first..., with: tokens)
        strokes = last.strokes
        strokeLayouts = last.layouts
        keptStrokes = last.strokes
        let back = change.back
        return Replacement(deleteCount: back.deleteCount - 1, insert: String(back.insert.dropLast()),
                           switchTo: back.switchTo, info: back.info)
    }

    /// Текст, набранный с последнего сброса и стоящий прямо перед курсором.
    public func tailText(context: LayoutContext) -> String {
        var text = ""
        for token in run {
            text += token.displayed + String(repeating: " ", count: token.trailingSpaces)
        }
        return text + (currentText(context: context) ?? "")
    }

    /// Перевод выделенного фрагмента, если он входит в только что набранный текст перед курсором.
    /// Тогда его можно заменить стиранием и повторным набором — без вставки из буфера обмена
    /// (в терминалах выделение нельзя заменить вставкой). Иначе `nil`.
    public func replaceInTail(selected: String, context: LayoutContext) -> Replacement? {
        let tail = tailText(context: context)
        guard !selected.isEmpty, let range = tail.range(of: selected, options: .backwards),
              let converted = SelectionConverter.convert(selected, context: context) else { return nil }
        let original = String(tail[range.lowerBound...])
        let info = Replacement.Info(kind: .selection, before: selected.trimmed, after: converted.text.trimmed, words: 0)
        let result = Replacement(deleteCount: tail.distance(from: range.lowerBound, to: tail.endIndex),
                                 insert: converted.text + tail[range.upperBound...],
                                 switchTo: converted.targetLayoutID, info: info)
        reset()
        undo = Change(back: Replacement(deleteCount: result.insert.count, insert: original, switchTo: context.current.id,
                                        info: .init(kind: .undo, before: converted.text.trimmed,
                                                    after: selected.trimmed, words: 0)),
                      forward: Replacement(deleteCount: original.count, insert: result.insert,
                                           switchTo: converted.targetLayoutID, info: info))
        return result
    }

    /// Раскладки, в которые можно перевести слово, по порядку предпочтения: сначала та, где получается
    /// настоящее слово. Уже переведённое вручную слово идёт по кругу — так перебираются три раскладки.
    private func targets(from layoutID: String, strokes: [KeyStroke], cycling: Bool, context: LayoutContext) -> [LayoutTable] {
        let ring = context.all.sorted { $0.id < $1.id }
        if cycling, ring.count > 2, let index = ring.firstIndex(where: { $0.id == layoutID }) {
            return Array(ring[(index + 1)...] + ring[..<index])
        }
        var candidates = context.all.filter { $0.id != layoutID }
        if candidates.count > 1,
           let known = candidates.firstIndex(where: { table in
               table.string(for: strokes).map { detector.isKnownWord($0, language: table.language) } ?? false
           }) {
            candidates.insert(candidates.remove(at: known), at: 0)
        }
        return candidates
    }

    /// Ручное переключение по горячей клавише: текущее недописанное слово либо последнее набранное.
    /// Возвращает `nil`, если переключать нечего (тогда приложение работает с выделением).
    public func manualToggle(context: LayoutContext) -> Replacement? {
        softResetPending = false
        redo = nil
        if !strokes.isEmpty {
            guard let typed = currentText(context: context) else { reset(); return nil }
            // Смешанное слово можно привести и к текущей раскладке — в ней набран только его конец.
            let candidates = isMixed ? context.all
                : targets(from: context.current.id, strokes: strokes, cycling: false, context: context)
            for target in candidates {
                guard let text = target.string(for: strokes), text != typed else { continue }
                let info = Replacement.Info(kind: .manual, before: typed, after: text)
                let layouts = Array(repeating: target.id, count: strokes.count)
                undo = Change(back: Replacement(deleteCount: text.count, insert: typed, switchTo: context.current.id,
                                                info: .init(kind: .undo, before: text, after: typed)),
                              forward: Replacement(deleteCount: typed.count, insert: text, switchTo: target.id, info: info),
                              layoutsBefore: strokeLayouts, layoutsAfter: layouts)
                strokeLayouts = layouts
                return Replacement(deleteCount: typed.count, insert: text, switchTo: target.id, info: info)
            }
            return nil
        }
        guard var token = run.last else { return nil }
        for target in targets(from: token.layoutID, strokes: token.strokes, cycling: token.locked, context: context) {
            guard let text = target.string(for: token.strokes), text != token.displayed else { continue }
            let spaces = String(repeating: " ", count: token.trailingSpaces)
            var info = Replacement.Info(kind: .manual, before: token.displayed, after: text)
            var result = Replacement(deleteCount: token.displayed.count + token.trailingSpaces,
                                     insert: text + spaces, switchTo: target.id)
            if token.autoConverted, text == token.originalTyped {
                result.learnedException = token.originalTyped.lowercased()
            } else if !token.locked, !token.autoConverted {
                // Человек сам перевёл обычное готовое слово — так копится «это слово я всегда перевожу».
                info.manualWord = (token.originalTyped.lowercased(), target.id)
            }
            result.info = info
            var back = token
            back.pending = nil
            back.locked = true
            token.displayed = text
            token.layoutID = target.id
            token.layouts = Array(repeating: target.id, count: token.strokes.count)
            token.pending = nil
            token.autoConverted = false
            token.locked = true
            token.known = detector.isKnownWord(text, language: target.language)
            undo = Change(back: Replacement(deleteCount: result.insert.count, insert: back.displayed + spaces,
                                            switchTo: back.layoutID,
                                            info: .init(kind: .undo, before: text, after: back.displayed)),
                          forward: Replacement(deleteCount: back.displayed.count + token.trailingSpaces,
                                               insert: result.insert, switchTo: target.id, info: info),
                          first: run.count - 1, before: [back], after: [token])
            run[run.count - 1] = token
            return result
        }
        return nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
