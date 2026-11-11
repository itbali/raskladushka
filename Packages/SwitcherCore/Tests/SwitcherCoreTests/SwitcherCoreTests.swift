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
