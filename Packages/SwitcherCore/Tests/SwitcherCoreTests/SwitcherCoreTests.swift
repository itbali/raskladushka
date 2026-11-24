import XCTest
@testable import SwitcherCore

struct FakeDictionary: WordValidating {
    let words: [String: Set<String>] = [
        "ru": ["привет", "как", "дела", "хорошо", "как-то", "Москва", "за", "домом", "ещё", "мы", "я", "пишу", "ну", "из", "мир", "тест", "он"],
        "en": ["hello", "world", "don't", "tot", "pf", "bp", "vs", "ye", "test", "good", "morning", "z", "b", "the", "git"],
    ]
    func isWord(_ word: String, language: String) -> Bool { words[language]?.contains(word) ?? false }
}

final class SwitcherCoreTests: XCTestCase {
    let en = LayoutTable.usQWERTY
    let ru = LayoutTable.russianPC
    var detector: LayoutDetector { LayoutDetector(validator: FakeDictionary()) }
    var enCtx: LayoutContext { LayoutContext(current: en, others: [ru]) }
    var ruCtx: LayoutContext { LayoutContext(current: ru, others: [en]) }

    func strokes(_ text: String, in layout: LayoutTable) -> [KeyStroke] {
        text.map { $0 == " " ? KeyStroke(keyCode: 49) : layout.stroke(for: $0)! }
    }

    func eval(_ typed: String, from: LayoutTable, to: LayoutTable) -> Conversion? {
        detector.evaluate(strokes: strokes(typed, in: from), current: from, others: [to])
    }

    // MARK: Таблицы

    func testTablesRoundTrip() {
        XCTAssertEqual(ru.string(for: strokes("ghbdtn", in: en)), "привет")
        XCTAssertEqual(en.string(for: strokes("руддщ", in: ru)), "hello")
        XCTAssertEqual(ru.string(for: strokes("Ghbdtn", in: en)), "Привет")
        XCTAssertEqual(ru.string(for: strokes("[jhjij/", in: en)), "хорошо.")
        XCTAssertEqual(LayoutTable.russianApple.string(for: strokes("t\\", in: en)), "её")
    }

    func testCapsLock() {
        let s = [KeyStroke(keyCode: 5, caps: true), KeyStroke(keyCode: 18, caps: true)]
        XCTAssertEqual(en.string(for: s), "G1")
        XCTAssertEqual(ru.string(for: s), "П1")
    }

    // MARK: Детектор

    func testStrongConversions() {
        XCTAssertEqual(eval("ghbdtn", from: en, to: ru)?.text, "привет")
        XCTAssertEqual(eval("Ghbdtn", from: en, to: ru)?.text, "Привет")
        XCTAssertEqual(eval("GHBDTN", from: en, to: ru)?.text, "ПРИВЕТ")
        XCTAssertEqual(eval("руддщ", from: ru, to: en)?.text, "hello")
        XCTAssertEqual(eval("rfr-nj", from: en, to: ru)?.text, "как-то")
        XCTAssertEqual(eval("вщтэе", from: ru, to: en)?.text, "don't")
        XCTAssertEqual(eval("vjcrdf", from: en, to: ru)?.text, "москва")
        XCTAssertEqual(eval("jy", from: en, to: ru)?.strength, .strong)
    }

    func testPunctuation() {
        XCTAssertEqual(eval("ghbdtn,", from: en, to: ru)?.text, "привет,")
        XCTAssertEqual(eval("[jhjij/", from: en, to: ru)?.text, "хорошо.")
        XCTAssertEqual(eval("руддщб", from: ru, to: en)?.text, "hello,")
        XCTAssertEqual(eval("(ghbdtn)", from: en, to: ru)?.text, "(привет)")
        XCTAssertEqual(eval("ghbdtn!", from: en, to: ru)?.text, "привет!")
    }

    func testNoConversion() {
        XCTAssertNil(eval("hello", from: en, to: ru))
        XCTAssertNil(eval("привет", from: ru, to: en))
        XCTAssertNil(eval("git", from: en, to: ru))
        XCTAssertNil(eval("qwzx", from: en, to: ru))          // мусор в обеих раскладках
        XCTAssertNil(eval("ghbdtn2", from: en, to: ru))       // цифры
        XCTAssertNil(eval("ghbDtn", from: en, to: ru))        // camelCase
        XCTAssertNil(eval("db", from: en, to: ru))            // «ви» не в списке частых
        XCTAssertNil(eval("the", from: en, to: ru))
    }

    func testWeakAmbiguous() {
        XCTAssertEqual(eval("pf", from: en, to: ru)?.strength, .weak)   // «за»: словарь принимает «pf» — ждём подтверждения
        XCTAssertEqual(eval("yf", from: en, to: ru)?.strength, .strong) // «на»: «yf» словарь не знает
        XCTAssertNil(eval("ща", from: ru, to: en))                      // частое русское, хотя читается как «of"
        XCTAssertNil(eval("kb", from: en, to: ru))                      // «ли», но kb — частое сокращение
        XCTAssertEqual(eval("z", from: en, to: ru)?.strength, .weak)    // «я»
        XCTAssertEqual(eval("tot", from: en, to: ru)?.strength, .weak)  // «ещё»
        XCTAssertNil(eval("vs", from: en, to: ru))                      // частое английское
        XCTAssertNil(eval("a", from: en, to: ru))
    }

    func testExceptions() {
        var d = detector
        d.exceptions = ["ghbdtn"]
        XCTAssertNil(d.evaluate(strokes: strokes("Ghbdtn", in: en), current: en, others: [ru]))
    }

    func testPlausibilityFallback() {
        // Этих слов нет в тестовом словаре — решает статистика сочетаний букв.
        XCTAssertEqual(eval("hfcrkflre", from: en, to: ru)?.text, "раскладку")
        XCTAssertEqual(eval("ltgkjq", from: en, to: ru)?.text, "деплой")
        XCTAssertEqual(eval("лунищфкв", from: ru, to: en)?.text, "keyboard")
        XCTAssertNil(eval("github", from: en, to: ru))
        XCTAssertNil(eval("kubernetes", from: en, to: ru))
        XCTAssertNil(eval("нейрослоп", from: ru, to: en))
        XCTAssertNil(eval("xcodebuild", from: en, to: ru))
        XCTAssertNil(eval("бэкенд", from: ru, to: en))
    }

    // MARK: Сессия

    func type(_ text: String, layout: LayoutTable, session: TypingSession, ctx: LayoutContext) -> [Replacement] {
        strokes(text, in: layout).compactMap { session.handle(.stroke($0), context: ctx) }
    }

    func testAutoReplaceOnSpace() {
        let s = TypingSession(detector: detector)
        let r = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertEqual(r, [Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id)])
    }

    func testRetroConvertsWeakWords() {
        let s = TypingSession(detector: detector)
        let r = type("z tot ljvjv ", layout: en, session: s, ctx: enCtx)
        XCTAssertEqual(r, [Replacement(deleteCount: 12, insert: "я еще домом ", switchTo: ru.id)])
    }

    func testWeakAloneStays() {
        let s = TypingSession(detector: detector)
        XCTAssertTrue(type("tot good morning ", layout: en, session: s, ctx: enCtx).isEmpty)
    }

    func testBackspaceEditsWord() {
        let s = TypingSession(detector: detector)
        _ = type("ghbdtnn", layout: en, session: s, ctx: enCtx)
        XCTAssertNil(s.handle(.backspace, context: enCtx))
        let r = s.handle(.stroke(KeyStroke(keyCode: 49)), context: enCtx)
        XCTAssertEqual(r?.insert, "привет ")
    }

    func testResetDropsWord() {
        let s = TypingSession(detector: detector)
        _ = type("ghb", layout: en, session: s, ctx: enCtx)
        _ = s.handle(.reset, context: enCtx)
        XCTAssertTrue(type("dtn ", layout: en, session: s, ctx: enCtx).isEmpty)
    }

    func testDisabledAuto() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        XCTAssertTrue(type("ghbdtn ", layout: en, session: s, ctx: enCtx).isEmpty)
        XCTAssertEqual(s.manualToggle(context: enCtx), Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id))
    }

    func testManualToggleCurrentWord() {
        let s = TypingSession(detector: detector)
        _ = type("ghbd", layout: en, session: s, ctx: enCtx)
        XCTAssertEqual(s.manualToggle(context: enCtx), Replacement(deleteCount: 4, insert: "прив", switchTo: ru.id))
        // Дальше набор идёт уже в русской раскладке.
        _ = s.handle(.stroke(KeyStroke(keyCode: 14)), context: ruCtx)
        _ = s.handle(.stroke(KeyStroke(keyCode: 17)), context: ruCtx)
        XCTAssertNil(s.handle(.stroke(KeyStroke(keyCode: 49)), context: ruCtx))
    }

    func testUndoAutoConversionLearnsException() {
        let s = TypingSession(detector: detector)
        XCTAssertEqual(type("ghbdtn ", layout: en, session: s, ctx: enCtx).count, 1)
        let undo = s.manualToggle(context: ruCtx)
        XCTAssertEqual(undo, Replacement(deleteCount: 7, insert: "ghbdtn ", switchTo: en.id, learnedException: "ghbdtn"))
        // Повторное нажатие снова переводит, но уже без запоминания.
        let redo = s.manualToggle(context: enCtx)
        XCTAssertEqual(redo, Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id))
    }

    // MARK: Отмена по ⌘Z

    func testUndoAutoConversion() {
        let s = TypingSession(detector: detector)
        XCTAssertFalse(s.canUndo)
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertTrue(s.canUndo)
        XCTAssertEqual(s.undoLast(),
                       Replacement(deleteCount: 7, insert: "ghbdtn ", switchTo: en.id, learnedException: "ghbdtn"))
        XCTAssertFalse(s.canUndo)
        XCTAssertNil(s.undoLast())
        XCTAssertEqual(s.tailText(context: enCtx), "ghbdtn ")
    }

    func testUndoReturnsRetroWordsAndKeepsThem() {
        let s = TypingSession(detector: detector)
        _ = type("z tot ljvjv ", layout: en, session: s, ctx: enCtx)
        XCTAssertEqual(s.undoLast(),
                       Replacement(deleteCount: 12, insert: "z tot ljvjv ", switchTo: en.id, learnedException: "ljvjv"))
        // Возвращённые слова следующее уверенное слово с собой уже не утянет.
        XCTAssertEqual(type("ghbdtn ", layout: en, session: s, ctx: enCtx),
                       [Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id)])
    }

    func testUndoGoneAfterAnyKey() {
        for event in [InputEvent.stroke(KeyStroke(keyCode: 0)), .stroke(KeyStroke(keyCode: 49)), .backspace, .reset] {
            let s = TypingSession(detector: detector)
            _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
            _ = s.handle(event, context: ruCtx)
            XCTAssertFalse(s.canUndo)
        }
    }

    func testUndoManualToggle() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("ghbd", layout: en, session: s, ctx: enCtx)
        _ = s.manualToggle(context: enCtx)
        XCTAssertEqual(s.undoLast(), Replacement(deleteCount: 4, insert: "ghbd", switchTo: en.id))
        // Слово набрано до конца и переведено сочетанием: возвращаем его с пробелом.
        _ = type("tn ", layout: en, session: s, ctx: enCtx)
        _ = s.manualToggle(context: enCtx)
        XCTAssertEqual(s.undoLast(), Replacement(deleteCount: 7, insert: "ghbdtn ", switchTo: en.id))
        XCTAssertEqual(s.tailText(context: enCtx), "ghbdtn ")
    }

    func testUndoSelectionInTail() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("hello ghbdtn rfr ltkf", layout: en, session: s, ctx: enCtx)
        _ = s.replaceInTail(selected: "ghbdtn rfr", context: enCtx)
        XCTAssertEqual(s.undoLast(), Replacement(deleteCount: 15, insert: "ghbdtn rfr ltkf", switchTo: en.id))
    }

    // MARK: Отмена по Backspace и повтор

    func testBackspaceUndoesAutoConversion() {
        let s = TypingSession(detector: detector)
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertTrue(s.canUndoByBackspace)
        // Пробел человек стёр сам — возвращаем слово без него, и оно снова недописанное.
        // В исключения слово при этом не попадает: Backspace жмут и просто чтобы стереть пробел.
        XCTAssertEqual(s.handle(.backspace, context: ruCtx),
                       Replacement(deleteCount: 6, insert: "ghbdtn", switchTo: en.id))
        XCTAssertFalse(s.canUndo)
        XCTAssertEqual(s.tailText(context: enCtx), "ghbdtn")
        // Пробел за тем же словом второй раз его не исправляет…
        XCTAssertNil(s.handle(.stroke(KeyStroke(keyCode: 49)), context: enCtx))
        XCTAssertEqual(s.tailText(context: enCtx), "ghbdtn ")
        // …а следующее такое же слово — исправляет: исключением оно не стало.
        XCTAssertEqual(type("ghbdtn ", layout: en, session: s, ctx: enCtx).first?.insert, "привет ")
    }

    func testWordChangedAfterBackspaceUndoIsCheckedAgain() {
        let s = TypingSession(detector: detector)
        _ = type("vbh ", layout: en, session: s, ctx: enCtx)       // «мир»
        _ = s.handle(.backspace, context: ruCtx)
        // Слово дописали — это уже другое слово, проверяем его заново.
        XCTAssertNil(s.handle(.backspace, context: enCtx))
        XCTAssertEqual(type("h ", layout: en, session: s, ctx: enCtx).first?.insert, "мир ")
    }

    func testBackspaceUndoCanBeTurnedOff() {
        let s = TypingSession(detector: detector)
        s.backspaceUndoEnabled = false
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertNil(s.handle(.backspace, context: ruCtx))
        XCTAssertFalse(s.hasPendingWord)
    }

    func testBackspaceDoesNotUndoManualConversion() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        _ = s.manualToggle(context: enCtx)
        XCTAssertNil(s.handle(.backspace, context: ruCtx))
    }

    func testRedoAfterUndo() {
        let s = TypingSession(detector: detector)
        _ = type("z tot ljvjv ", layout: en, session: s, ctx: enCtx)
        XCTAssertFalse(s.canRedo)
        let undo = s.undoLast()
        XCTAssertTrue(s.canRedo)
        // Повтор возвращает замену и снимает исключение, которое запомнила отмена.
        XCTAssertEqual(s.redoLast(), Replacement(deleteCount: 12, insert: "я еще домом ", switchTo: ru.id,
                                                 forgetException: "ljvjv"))
        XCTAssertFalse(s.canRedo)
        XCTAssertEqual(s.tailText(context: ruCtx), "я еще домом ")
        XCTAssertEqual(s.undoLast(), undo)
    }

    func testRedoGoneAfterAnyKey() {
        let s = TypingSession(detector: detector)
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        _ = s.undoLast()
        _ = s.handle(.stroke(KeyStroke(keyCode: 0)), context: enCtx)
        XCTAssertFalse(s.canRedo)
        XCTAssertNil(s.redoLast())
    }

    func testRedoManualToggle() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("ghbd", layout: en, session: s, ctx: enCtx)
        _ = s.manualToggle(context: enCtx)
        _ = s.undoLast()
        XCTAssertEqual(s.redoLast(), Replacement(deleteCount: 4, insert: "прив", switchTo: ru.id))
        XCTAssertEqual(s.tailText(context: ruCtx), "прив")
    }

    // MARK: Смешанные слова

    func testWordStartedInOneLayoutFinishedInAnother() {
        let s = TypingSession(detector: detector)
        _ = type("ghb", layout: en, session: s, ctx: enCtx)
        s.layoutChangedByUser()
        XCTAssertEqual(s.tailText(context: ruCtx), "ghb")
        XCTAssertEqual(type("вет ", layout: ru, session: s, ctx: ruCtx),
                       [Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id)])
        // Отмена возвращает слово кусками, как оно было набрано.
        XCTAssertEqual(s.undoLast(), Replacement(deleteCount: 7, insert: "ghbвет ", switchTo: ru.id,
                                                 learnedException: "ghbвет"))
    }

    func testLayoutSwitchedByShortcutMidWord() {
        // ⌃Space посреди слова: уведомление о смене раскладки может опоздать, поэтому смотрим на следующую букву.
        let s = TypingSession(detector: detector)
        _ = type("при", layout: ru, session: s, ctx: ruCtx)
        XCTAssertNil(s.handle(.softReset, context: ruCtx))
        XCTAssertEqual(type("dtn ", layout: en, session: s, ctx: enCtx),
                       [Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id)])
    }

    func testShortcutWithoutLayoutChangeDropsWord() {
        let s = TypingSession(detector: detector)
        _ = type("ghb", layout: en, session: s, ctx: enCtx)
        _ = s.handle(.softReset, context: enCtx)
        XCTAssertTrue(type("dtn ", layout: en, session: s, ctx: enCtx).isEmpty)
        XCTAssertEqual(s.tailText(context: enCtx), "dtn ")
    }

    func testMixedWordsCanBeTurnedOff() {
        let s = TypingSession(detector: detector)
        s.mixedWordsEnabled = false
        _ = type("ghb", layout: en, session: s, ctx: enCtx)
        s.layoutChangedByUser()
        XCTAssertTrue(type("вет ", layout: ru, session: s, ctx: ruCtx).isEmpty)
    }

    func testManualToggleOfMixedWord() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("ghb", layout: en, session: s, ctx: enCtx)
        s.layoutChangedByUser()
        _ = type("ве", layout: ru, session: s, ctx: ruCtx)
        // Текущая раскладка русская — в неё и собираем, хотя начало набрано в английской.
        XCTAssertEqual(s.manualToggle(context: ruCtx), Replacement(deleteCount: 5, insert: "приве", switchTo: ru.id))
        XCTAssertEqual(s.undoLast(), Replacement(deleteCount: 5, insert: "ghbве", switchTo: ru.id))
        XCTAssertEqual(s.tailText(context: ruCtx), "ghbве")
    }

    // MARK: Язык фразы

    func testContextMakesWeakWordStrong() {
        let s = TypingSession(detector: detector)
        XCTAssertTrue(type("привет как ", layout: ru, session: s, ctx: ruCtx).isEmpty)
        s.layoutChangedByUser()
        // После двух русских слов «z» в английской раскладке — это «я», ждать подтверждения незачем.
        XCTAssertEqual(type("z ", layout: en, session: s, ctx: enCtx),
                       [Replacement(deleteCount: 2, insert: "я ", switchTo: ru.id)])
    }

    func testNoContextKeepsWeakWordWaiting() {
        let s = TypingSession(detector: detector)
        XCTAssertTrue(type("z ", layout: en, session: s, ctx: enCtx).isEmpty)
        let off = TypingSession(detector: detector)
        off.contextEnabled = false
        _ = type("привет как ", layout: ru, session: off, ctx: ruCtx)
        off.layoutChangedByUser()
        XCTAssertTrue(type("z ", layout: en, session: off, ctx: enCtx).isEmpty)
    }

    // MARK: Выученные слова и три раскладки

    func testLearnedWordIsConverted() {
        var d = detector
        XCTAssertNil(d.evaluate(strokes: strokes("qwzx", in: en), current: en, others: [ru]))
        d.learned = ["qwzx": ru.id]
        let found = d.evaluate(strokes: strokes("Qwzx", in: en), current: en, others: [ru])
        XCTAssertEqual(found?.text, "Йцяч")
        XCTAssertEqual(found?.reason, .learned)
        d.exceptions = ["qwzx"]
        XCTAssertNil(d.evaluate(strokes: strokes("qwzx", in: en), current: en, others: [ru]))
    }

    func testManualToggleReportsWordForLearning() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("qwzx ", layout: en, session: s, ctx: enCtx)
        let first = s.manualToggle(context: enCtx)
        XCTAssertEqual(first?.info?.manualWord?.typed, "qwzx")
        XCTAssertEqual(first?.info?.manualWord?.layoutID, ru.id)
        // Повторное нажатие на том же слове — уже не «перевёл сам», а перебор.
        XCTAssertNil(s.manualToggle(context: ruCtx)?.info?.manualWord)
    }

    func testUndoByHotkeyIsNotLearning() {
        let s = TypingSession(detector: detector)
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertNil(s.manualToggle(context: ruCtx)?.info?.manualWord)
    }

    static let german = LayoutTable.build(
        id: "com.apple.keylayout.German", language: "de",
        lower: ["^1234567890ß´", "qwertzuiopü+#", "asdfghjklöä", "yxcvbnm,.-"],
        upper: ["°!\"§$%&/()=?`", "QWERTZUIOPÜ*'", "ASDFGHJKLÖÄ", "YXCVBNM;:_"]
    )

    func testBestOfThreeLayouts() {
        let de = Self.german
        // Немецкая стоит первой, но слово получается только в русской.
        let found = detector.evaluate(strokes: strokes("ghbdtn", in: en), current: en, others: [de, ru])
        XCTAssertEqual(found?.text, "привет")
        XCTAssertEqual(found?.layoutID, ru.id)
    }

    func testManualToggleWithThreeLayouts() {
        let de = Self.german
        let ctx = LayoutContext(current: en, others: [de, ru])
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        // «z» и «y» в немецкой раскладке поменяны местами: «yt» по-немецки «zt», по-русски «не».
        _ = type("ljvjv ", layout: en, session: s, ctx: ctx)
        XCTAssertEqual(s.manualToggle(context: ctx), Replacement(deleteCount: 6, insert: "домом ", switchTo: ru.id))
        // Дальше нажатия перебирают раскладки по кругу.
        let next = s.manualToggle(context: LayoutContext(current: ru, others: [en, de]))
        XCTAssertEqual(next?.insert, "ljvjv ")
        XCTAssertEqual(next?.switchTo, en.id)
    }

    func testReasons() {
        XCTAssertEqual(eval("ghbdtn", from: en, to: ru)?.reason, .dictionary)
        XCTAssertEqual(eval("hfcrkflre", from: en, to: ru)?.reason, .letterStatistics)
        XCTAssertEqual(eval("z", from: en, to: ru)?.reason, .commonWord)
        let info = type("ghbdtn ", layout: en, session: TypingSession(detector: detector), ctx: enCtx).first?.info
        XCTAssertEqual(info?.kind, .auto)
        XCTAssertEqual(info?.before, "ghbdtn")
        XCTAssertEqual(info?.after, "привет")
        XCTAssertEqual(info?.words, 1)
    }

    // MARK: Двойное нажатие модификатора

    func testDoubleTap() {
        var d = DoubleTapDetector(interval: 0.4)
        XCTAssertFalse(d.soloTap(1, at: 10.0))
        XCTAssertTrue(d.soloTap(1, at: 10.3))
        // После срабатывания счёт начинается заново: третье нажатие — снова первое.
        XCTAssertFalse(d.soloTap(1, at: 10.5))
        XCTAssertTrue(d.soloTap(1, at: 10.7))
    }

    func testDoubleTapTooSlowOrOtherKey() {
        var d = DoubleTapDetector(interval: 0.4)
        XCTAssertFalse(d.soloTap(1, at: 10.0))
        XCTAssertFalse(d.soloTap(1, at: 10.6))      // медленно — это новое первое нажатие
        XCTAssertTrue(d.soloTap(1, at: 10.8))
        XCTAssertFalse(d.soloTap(1, at: 20.0))
        XCTAssertFalse(d.soloTap(2, at: 20.1))      // другой модификатор
        XCTAssertFalse(d.soloTap(1, at: 20.2))
    }

    func testDoubleTapInterrupted() {
        var d = DoubleTapDetector(interval: 0.4)
        XCTAssertFalse(d.soloTap(1, at: 10.0))
        d.interrupted()                              // между нажатиями набрали букву
        XCTAssertFalse(d.soloTap(1, at: 10.2))
    }

    func testNothingToToggle() {
        let s = TypingSession(detector: detector)
        XCTAssertNil(s.manualToggle(context: enCtx))
    }

    func testReplaceSelectionInTail() {
        let s = TypingSession(detector: detector)
        s.autoSwitchEnabled = false
        _ = type("hello ghbdtn rfr ltkf", layout: en, session: s, ctx: enCtx)
        XCTAssertEqual(s.tailText(context: enCtx), "hello ghbdtn rfr ltkf")
        // Выделена середина: стираем до её начала и допечатываем остаток как был.
        XCTAssertEqual(s.replaceInTail(selected: "ghbdtn rfr", context: enCtx),
                       Replacement(deleteCount: 15, insert: "привет как ltkf", switchTo: ru.id))
        XCTAssertFalse(s.hasPendingWord)
        _ = type("ghbdtn ", layout: en, session: s, ctx: enCtx)
        XCTAssertNil(s.replaceInTail(selected: "world", context: enCtx))
        XCTAssertEqual(s.replaceInTail(selected: "ghbdtn", context: enCtx),
                       Replacement(deleteCount: 7, insert: "привет ", switchTo: ru.id))
    }

    // MARK: Выделение

    func testSelection() {
        XCTAssertEqual(SelectionConverter.convert("ghbdtn? rfr ltkf&", context: enCtx),
                       .init(text: "привет, как дела?", targetLayoutID: ru.id))
        XCTAssertEqual(SelectionConverter.convert("руддщ цщкдв", context: enCtx),
                       .init(text: "hello world", targetLayoutID: en.id))
        XCTAssertEqual(SelectionConverter.convert("руддщ цщкдв", context: ruCtx),
                       .init(text: "hello world", targetLayoutID: en.id))
        XCTAssertEqual(SelectionConverter.convert("ghbdtn\nvbh", context: ruCtx)?.text, "привет\nмир")
        XCTAssertEqual(SelectionConverter.convert("ghbdtn мир", context: enCtx)?.text, "привет vbh")
        XCTAssertNil(SelectionConverter.convert("123 456", context: enCtx))
    }
}
