#if DEBUG
import AppKit
import ServiceManagement
import SwiftUI
import SwitcherCore

/// Отладочная самопроверка: `Raskladushka --selftest` печатает, что видит приложение в песочнице.
enum SelfTest {
    /// `Raskladushka --render` сохраняет снимок окна настроек в PNG (во временную папку контейнера).
    static func renderIfRequested() {
        guard CommandLine.arguments.contains("--render") else { return }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (index, window) in NSApp.windows.enumerated() {
                guard window.isVisible, window.frame.width > 100, let frame = window.contentView?.superview,
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width) * 2,
                                                 pixelsHigh: Int(frame.bounds.height) * 2, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = frame.bounds.size
                frame.cacheDisplay(in: frame.bounds, to: rep)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("window-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("rendered", url.path, window.title, window.frame.size)
            }
            exit(0)
        }
    }

    // MARK: - Проверка в собственном окне

    /// `Raskladushka --uitest`: проверяет приложение целиком так, как им пользуется человек, — настоящими
    /// нажатиями, но в собственном окне. Чужие окна не трогает: если окно проверки не впереди, всё
    /// останавливается. Настройки берёт отдельные, настоящие не меняет. Итог — в tmp/uitest.txt контейнера.
    /// С `--spotlight` дополнительно проверяет перевод в строке Spotlight (открывает её на несколько секунд).
    static func uiTestIfRequested() {
        guard CommandLine.arguments.contains("--uitest") else { return }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("uitest.txt")
        try? FileManager.default.removeItem(at: log)
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        func onMain<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }
        let state = AppState.shared
        var window: NSWindow?
        var view: NSTextView?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 90),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Проверка Раскладушки — не трогайте клавиатуру"
            let v = NSTextView(frame: w.contentView!.bounds)
            v.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            v.isAutomaticSpellingCorrectionEnabled = false
            v.isAutomaticTextReplacementEnabled = false
            v.isAutomaticQuoteSubstitutionEnabled = false
            v.isAutomaticDashSubstitutionEnabled = false
            w.contentView?.addSubview(v)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
            window = w
            view = v
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let startLayout = onMain { InputSources.currentID() }
            let ids = onMain { state.debugLayoutIDs }
            func finish(_ line: String) -> Never {
                note(line)
                onMain { state.debugSwitchLayout(to: startLayout) }
                usleep(300_000)
                exit(0)
            }
            guard let en = ids.first(where: { $0.contains("US") || $0.contains("ABC") || $0.contains("British") }),
                  let ru = ids.first(where: { $0.contains("Russian") }) else {
                finish("ОТМЕНЕНО: нужны английская и русская раскладки, есть \(ids)")
            }
            func ours() -> Bool { onMain { window?.isKeyWindow ?? false } }
            /// Любое нажатие — только пока наше окно впереди.
            func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], down: Bool? = nil) {
                guard ours() else { finish("ОТМЕНЕНО: окно проверки ушло с переднего плана — запустите ещё раз и не трогайте клавиатуру") }
                for isDown in down.map({ [$0] }) ?? [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                    usleep(25_000)
                }
            }
            func keys(_ codes: [CGKeyCode]) { codes.forEach { key($0) } }
            func pause(_ seconds: Double = 0.6) { usleep(useconds_t(seconds * 1_000_000)) }
            func text() -> String { onMain { view?.string ?? "?" } }
            func layout(_ id: String) {
                if onMain({ InputSources.currentID() }) != id { onMain { state.debugSwitchLayout(to: id) }; pause(0.5) }
            }
            /// Чистое поле, настройки по умолчанию, нужная раскладка.
            func fresh(_ id: String, _ change: (inout Settings) -> Void = { _ in }) {
                onMain {
                    var settings = Settings()
                    settings.soundEnabled = false
                    change(&settings)
                    state.settings = settings
                    state.resume()
                    view?.string = ""
                    state.debugReset()
                }
                layout(id)
                onMain { state.debugReset() }
                pause(0.3)
            }
            /// ⌘Z и ⇧⌘Z как их жмёт человек: сначала модификаторы, потом клавиша, потом всё отпустить.
            func undoKey(shift: Bool = false) {
                var flags: CGEventFlags = .maskCommand
                key(55, flags, down: true)
                if shift { flags.insert(.maskShift); key(56, flags, down: true) }
                key(6, flags)
                if shift { key(56, .maskCommand, down: false) }
                key(55, [], down: false)
            }
            var failed = 0
            func check(_ name: String, _ got: String, _ want: String) {
                if got == want { note("ок      \(name)") } else { failed += 1; note("ОШИБКА  \(name): получилось [\(got)], ожидалось [\(want)]") }
            }
            func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
                if condition { note("ок      \(name)") } else { failed += 1; note("ОШИБКА  \(name) \(detail())") }
            }
            // Клавиши: руддщ = h e l l o; ghbdtn = g h b d t n.
            let hello: [CGKeyCode] = [4, 14, 37, 37, 31]
            let privet: [CGKeyCode] = [5, 4, 11, 2, 17, 45]
            let space: CGKeyCode = 49, backspace: CGKeyCode = 51, z: CGKeyCode = 6
            let own = Bundle.main.bundleIdentifier ?? ""

            // 1. Автозамена, отмена, повтор.
            fresh(ru)
            keys(hello + [space]); pause()
            check("автозамена по пробелу", text(), "hello ")
            check("после автозамены раскладка английская", onMain { InputSources.currentID() }, en)
            check("подсказка показана", onMain { Hud.shared.isVisible })
            check("журнал и счётчик", onMain { state.journal.count == 1 && state.stats.total == 1 }, onMain { "\(state.journal.count) \(state.stats.total)" })
            undoKey(); pause()
            check("⌘Z возвращает слово", text(), "руддщ ")
            check("⌘Z возвращает раскладку", onMain { InputSources.currentID() }, ru)
            check("отменённое слово — в исключениях", onMain { state.settings.exceptions }.joined(), "руддщ")
            undoKey(shift: true); pause()
            check("⇧⌘Z повторяет замену", text(), "hello ")
            check("повтор снимает исключение", onMain { state.settings.exceptions }.joined(), "")
            undoKey(); pause()
            check("после повтора ⌘Z снова возвращает", text(), "руддщ ")
            undoKey(); pause()
            check("второй ⌘Z уходит в приложение, а не к нам", onMain { state.debugState }.contains("undoKey=false"), onMain { state.debugState })

            // 2. Отмена Backspace.
            fresh(ru)
            keys(hello + [space]); pause()
            key(backspace); pause()
            check("Backspace после автозамены возвращает слово", text(), "руддщ")
            key(space); pause()
            check("возвращённое слово больше не исправляется", text(), "руддщ ")
            fresh(ru) { $0.undoByBackspace = false }
            keys(hello + [space]); pause()
            key(backspace); pause()
            check("с выключенной настройкой Backspace просто стирает", text(), "hello")

            // Перевод выделенного вставкой из буфера здесь не проверяется: приложение ждёт ответа на свой ⌘C,
            // а отвечать в собственном окне должно оно же. Этот случай проверяется руками в другом приложении.

            // 3. Перевод сочетанием: обычный режим, зажатые клавиши.
            fresh(ru) { $0.autoSwitch = false }
            keys(hello); pause(0.3)
            key(59, .maskControl, down: true); key(56, [.maskControl, .maskShift], down: true)
            key(space, [.maskControl, .maskShift])
            key(56, .maskControl, down: false); key(59, [], down: false); pause(0.8)
            check("⌃⇧Space переводит недописанное слово", text(), "hello")
            undoKey(); pause()
            check("⌘Z отменяет ручной перевод", text(), "руддщ")

            // 4. Перехват системного сочетания ⌃Space.
            fresh(ru) { $0.autoSwitch = false; $0.overrideSystem = true
                        $0.combo = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue) }
            pause(0.5)
            check("перехват включился", onMain { state.capturing })
            keys(hello); pause(0.3)
            key(59, .maskControl, down: true); key(space, .maskControl); key(59, [], down: false); pause(0.8)
            check("перехваченный ⌃Space переводит слово", text(), "hello")
            check("система по ⌃Space язык не сменила", onMain { InputSources.currentID() }, en)

            // 5. Сочетание из одних модификаторов.
            fresh(ru) { $0.autoSwitch = false
                        $0.combo = KeyCombo(keyCode: KeyCombo.modifiersOnly, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue) }
            keys(hello); pause(0.3)
            key(59, .maskControl, down: true); key(56, [.maskControl, .maskShift], down: true)
            key(56, .maskControl, down: false); key(59, [], down: false); pause(0.8)
            check("⌃⇧ без клавиши переводит слово", text(), "hello")

            // 6. Слово в двух раскладках.
            fresh(en)
            keys([5, 4, 11]); pause(0.3)
            layout(ru)
            keys([2, 17, 45, space]); pause()
            check("слово, начатое в английской и законченное в русской", text(), "привет ")
            fresh(en) { $0.mixedWords = false }
            keys([5, 4, 11]); pause(0.3)
            layout(ru)
            keys([2, 17, 45, space]); pause()
            check("с выключенной настройкой смешанное слово не трогаем", text(), "ghbвет ")

            // 7. Язык соседних слов.
            fresh(ru)
            keys(privet + [space, 15, 3, 15, space]); pause(0.3)
            layout(en)
            keys([z, space]); pause()
            check("после русских слов «z» сразу становится «я»", text(), "привет как я ")
            fresh(ru) { $0.contextAware = false }
            keys(privet + [space, 15, 3, 15, space]); pause(0.3)
            layout(en)
            keys([z, space]); pause()
            check("без учёта соседних слов «z» ждёт подтверждения", text(), "привет как z ")

            // 8. Самообучение: дважды перевели слово сами — третий раз оно исправляется само.
            let garbage: [CGKeyCode] = [12, 13, 6, 7]   // qwzx → йцяч: такого слова нет ни в одном словаре
            fresh(en) { $0.learnThreshold = 2 }
            for _ in 0..<2 {
                layout(en)
                onMain { view?.string = ""; state.debugResetSession() }
                keys(garbage + [space]); pause(0.4)
                key(59, .maskControl, down: true); key(56, [.maskControl, .maskShift], down: true)
                key(space, [.maskControl, .maskShift])
                key(56, .maskControl, down: false); key(59, [], down: false); pause(0.8)
            }
            check("ручной перевод готового слова", text(), "йцяч ")
            check("слово запомнено после двух переводов", onMain { state.settings.learned["qwzx"] != nil })
            layout(en)
            onMain { view?.string = ""; state.debugResetSession() }
            keys(garbage + [space]); pause()
            check("запомненное слово исправляется само", text(), "йцяч ")

            // 9. Исключение только для одного приложения и приложение без исправлений.
            fresh(ru) { $0.appExceptions = [own: ["руддщ"]] }
            keys(hello + [space]); pause()
            check("исключение приложения действует в нём", text(), "руддщ ")
            fresh(ru) { $0.appExceptions = ["com.example.other": ["руддщ"]] }
            keys(hello + [space]); pause()
            check("исключение чужого приложения здесь не действует", text(), "hello ")
            fresh(ru) { $0.rememberUndone = .currentApp }
            keys(hello + [space]); pause()
            undoKey(); pause()
            check("отменённое слово запоминается для приложения",
                  onMain { state.settings.appExceptions[own] ?? [] }.joined() + "|" + onMain { state.settings.exceptions }.joined(), "руддщ|")
            fresh(ru) { $0.excludedApps = [own] }
            keys(hello + [space]); pause()
            check("в приложении без исправлений ничего не меняется", text(), "руддщ ")

            // 10. Пауза.
            fresh(ru)
            onMain { state.pause(minutes: nil) }
            keys(hello + [space]); pause()
            check("на паузе слово не исправляется", text(), "руддщ ")
            onMain { state.resume(); view?.string = ""; state.debugReset() }
            pause(0.5)
            keys(hello + [space]); pause()
            check("после паузы снова исправляется", text(), "hello ")

            // 11. Spotlight — по отдельной просьбе: открывает строку поиска поверх всего.
            if CommandLine.arguments.contains("--spotlight") {
                func spotlightOpen() -> Bool {
                    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    return list.contains { $0[kCGWindowOwnerName as String] as? String == "Spotlight" }
                }
                func post(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
                    for isDown in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
                        event?.flags = flags
                        event?.post(tap: .cghidEventTap)
                        usleep(25_000)
                    }
                }
                fresh(ru) { $0.autoSwitch = false; $0.overrideSystem = true; $0.hudEnabled = false
                            $0.combo = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue) }
                pause(0.5)
                key(space, .maskCommand); pause(1)
                if spotlightOpen() {
                    hello.forEach { post($0) }; pause(0.7)
                    post(space, .maskControl); pause(1.5)
                    let pasteboard = NSPasteboard.general
                    let snapshot = onMain { PasteboardSnapshot(pasteboard) }
                    let before = pasteboard.changeCount
                    if spotlightOpen() { post(0, .maskCommand); post(8, .maskCommand) }
                    pause(0.5)
                    let got = pasteboard.changeCount != before ? (pasteboard.string(forType: .string) ?? "") : "<не скопировалось>"
                    onMain { snapshot.restore(to: pasteboard) }
                    if spotlightOpen() { post(53) }
                    pause(0.3)
                    if spotlightOpen() { post(53) }
                    check("перевод в строке Spotlight", got, "hello")
                } else {
                    failed += 1
                    note("ОШИБКА  Spotlight не открылся")
                }
            }

            finish(failed == 0 ? "ИТОГ: всё в порядке" : "ИТОГ: ошибок — \(failed)")
        }
    }

    static func runIfRequested() {
        renderIfRequested()
        uiTestIfRequested()
        guard CommandLine.arguments.contains("--selftest") else { return }
        let sources = InputSources()
        print("sandbox:", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "no")
        print("post access:", CGPreflightPostEventAccess(), "listen access:", CGPreflightListenEventAccess())
        for table in sources.tables {
            let row: [UInt16] = [50, 12, 13, 14, 15, 17, 16, 33, 30, 42, 41, 39, 43, 47, 44]
            let sample = row.compactMap { table.character(for: KeyStroke(keyCode: $0)) }
            let shifted = row.compactMap { table.character(for: KeyStroke(keyCode: $0, shift: true)) }
            print(table.id, table.language, String(sample), String(shifted))
        }
        for name in ["keyboard", "keyboard.fill", "keyboard.badge.ellipsis"] {
            print("symbol", name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
        if CommandLine.arguments.contains("--request") {
            print("CGRequestPostEventAccess:", CGRequestPostEventAccess(), "preflight:", CGPreflightPostEventAccess())
            print("CGRequestListenEventAccess:", CGRequestListenEventAccess(), "preflight:", CGPreflightListenEventAccess())
            print("AXIsProcessTrusted:", AXIsProcessTrusted())
            RunLoop.main.run(until: Date().addingTimeInterval(3))
        }
        if CommandLine.arguments.contains("--system") {
            // Автозапуск: включить → проверить → выключить.
            let service = SMAppService.mainApp
            print("login item before:", service.status.rawValue)
            do { try service.register(); print("registered, status:", service.status.rawValue) } catch { print("register failed:", error) }
            do { try service.unregister(); print("unregistered, status:", service.status.rawValue) } catch { print("unregister failed:", error) }
            // Смена раскладки: видим ли мы её сами и приходит ли уведомление.
            if let start = sources.context() {
                let target = start.others[0].id
                sources.select(target)
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                print("after select:", InputSources.currentID() == target, "notifications:", sources.notificationCount,
                      "context current:", sources.context()?.current.id ?? "nil")
                sources.select(start.current.id)
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                print("restored:", InputSources.currentID() == start.current.id, "notifications:", sources.notificationCount)
            }
        }
        // Как прочитаются настоящие настройки (в том числе сохранённые версиями до 1.2).
        let saved = Settings.load(from: .standard)
        print("settings: combo", saved.combo.display, "override", saved.overrideSystem, "auto", saved.autoSwitch,
              "hotkey", saved.hotkeyEnabled, "exceptions", saved.exceptions.count, "excluded apps", saved.excludedApps.count)
        guard let context = sources.context() else { print("no context"); exit(1) }
        print("current:", context.current.id, "others:", context.others.map(\.id))
        let detector = LayoutDetector(validator: SpellValidator())
        let en = sources.tables.first { $0.language.hasPrefix("en") }
        let ru = sources.tables.first { $0.language.hasPrefix("ru") }
        if let en, let ru {
            let cases: [(String, LayoutTable, LayoutTable)] = [
                ("ghbdtn", en, ru), ("Ghbdtn,", en, ru), ("[jhjij", en, ru), ("vjcrdf", en, ru), ("xnj", en, ru),
                ("yt", en, ru), ("pf", en, ru), ("z", en, ru), ("hello", en, ru), ("github", en, ru), ("ls", en, ru),
                ("cd", en, ru), ("git", en, ru), ("npm", en, ru), ("sudo", en, ru), ("claude", en, ru), ("ok", en, ru),
                ("руддщ", ru, en), ("цщкдв", ru, en), ("привет", ru, en), ("еуые", ru, en), ("вщтэе", ru, en),
                ("пше", ru, en), ("нейрослоп", ru, en), ("щл", ru, en), ("ащк", ru, en), ("ше", ru, en),
            ]
            for (typed, from, to) in cases {
                let strokes = typed.compactMap { from.stroke(for: $0) }
                let result = detector.evaluate(strokes: strokes, current: from, others: [to])
                print(typed, "→", result.map { "\($0.text) [\($0.strength)]" } ?? "—")
            }
            if CommandLine.arguments.contains("--pairs") {
                let validator = SpellValidator()
                let letters: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 6, 7, 8, 9, 11, 45, 46, 43, 47, 50, 42]
                for (from, to) in [(en, ru), (ru, en)] {
                    var hits: [String] = []
                    for a in letters { for b in letters {
                        let strokes = [KeyStroke(keyCode: a), KeyStroke(keyCode: b)]
                        guard let typed = from.string(for: strokes),
                              let r = detector.evaluate(strokes: strokes, current: from, others: [to]), r.strength == .strong else { continue }
                        let accepted = typed.allSatisfy(\.isLetter) && validator.isWord(typed, language: from.language)
                        hits.append("\(typed)→\(r.text)\(accepted ? "*" : "")")
                    } }
                    print(from.language, "strong 2-letter (\(hits.count)), * = спеллчекер принимает набранное:")
                    print(hits.joined(separator: " "))
                }
            }
            let session = TypingSession(detector: detector)
            let ctx = LayoutContext(current: en, others: [ru])
            for c in "z ghbie ntrcn b pf,sdf. gthtrk.xbnm hfcrkflre " {
                let stroke = c == " " ? KeyStroke(keyCode: 49) : en.stroke(for: c)!
                if let r = session.handle(.stroke(stroke), context: ctx) { print("replace:", r.deleteCount, "«\(r.insert)»") }
            }
            print(SelectionConverter.convert("Ghbdtn? rfr ltkf& Z nen", context: ctx)?.text ?? "nil")
        }
        exit(0)
    }
}
#endif
