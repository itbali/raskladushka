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

    /// `Raskladushka --typetest`: через 4 секунды сам печатает «руддщ » настоящими (непомеченными)
    /// нажатиями в окно на переднем плане, затем дважды жмёт ⌘Z. Первое ⌘Z должно вернуть слово,
    /// второе — уйти в приложение. Слово из исключений в конце убирает.
    static func typeTestIfRequested() {
        guard CommandLine.arguments.contains("--typetest") else { return }
        func press(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cgSessionEventTap)
                usleep(30_000)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            for key: CGKeyCode in [4, 14, 37, 37, 31, 49] { press(key) }
            sleep(2)
            press(6, .maskCommand)
            sleep(2)
            press(6, .maskCommand)
            sleep(2)
            DispatchQueue.main.async { AppState.shared.exceptions.removeAll { $0 == "руддщ" } }
        }
    }

    /// `Raskladushka --capturetest`: проверяет перехват системного сочетания на примере ⌃Space
    /// (в macOS — смена языка). Сначала жмёт ⌃Space без перехвата: раскладка должна смениться.
    /// Потом с перехватом: меняться не должна. Настройки в конце возвращает.
    static func captureTestIfRequested() {
        guard CommandLine.arguments.contains("--capturetest") else { return }
        func press(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("capturetest.txt")
        var lines = ["доступ на отправку: \(AppState.hasPostAccess)"]
        func note(_ line: String) { lines.append(line); try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8) }
        func onMain(_ work: @escaping () -> Void) { DispatchQueue.main.sync(execute: work) }
        let state = AppState.shared
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            var saved: (Bool, Bool, KeyCombo) = (false, false, .default)
            onMain {
                saved = (state.hotkeyEnabled, state.overrideSystem, state.combo)
                state.hotkeyEnabled = false
            }
            sleep(1)
            let start = InputSources.currentID()
            press(49, .maskControl)
            sleep(1)
            let free = InputSources.currentID()
            note("без перехвата: ⌃Space сменил раскладку — \(free != start)")
            if free != start { press(49, .maskControl); sleep(1) }
            onMain {
                state.combo = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)
                state.overrideSystem = true
                state.hotkeyEnabled = true
            }
            sleep(1)
            var capturing = false
            onMain { capturing = state.capturing }
            let before = InputSources.currentID()
            press(49, .maskControl)
            sleep(1)
            note("перехват включился — \(capturing); ⌃Space сменил раскладку — \(InputSources.currentID() != before)")
            onMain {
                state.hotkeyEnabled = saved.0
                state.overrideSystem = saved.1
                state.combo = saved.2
            }
            sleep(1)
            exit(0)
        }
    }

    /// `Raskladushka --activetest`: проверяет перевод слова перехваченным ⌃Space так, как его нажимает
    /// человек, — с зажатым Control. Печатает в собственное окно, чужие окна не трогает.
    /// Итог — в tmp/activetest.txt контейнера. Настройки в конце возвращает.
    static func activeTestIfRequested() {
        guard CommandLine.arguments.contains("--activetest") else { return }
        let hold = CommandLine.arguments.contains("--hold")
        func key(_ keyCode: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("activetest.txt")
        var lines: [String] = []
        func note(_ line: String) { lines.append(line); try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8) }
        func onMain<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }
        let state = AppState.shared
        var window: NSWindow?
        var view: NSTextView?
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Проверка Раскладушки"
            let v = NSTextView(frame: w.contentView!.bounds)
            v.isAutomaticSpellingCorrectionEnabled = false
            v.isAutomaticTextReplacementEnabled = false
            w.contentView?.addSubview(v)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
            window = w
            view = v
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let saved = onMain { (state.hotkeyEnabled, state.overrideSystem, state.combo) }
            let override = !CommandLine.arguments.contains("--carbon")
            onMain {
                state.combo = KeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)
                state.overrideSystem = override
                state.hotkeyEnabled = true
            }
            sleep(1)
            let russian = onMain { InputSources.currentID() }.contains("Russian")
            note("перехват: \(onMain { state.capturing }), окно впереди: \(onMain { window?.isKeyWindow ?? false }), раскладка: \(onMain { InputSources.currentID() })")
            // Наше окно не впереди — значит, человек работает в другом. Туда не печатаем.
            guard onMain({ window?.isKeyWindow ?? false }) else {
                note("отменено: окно проверки не на переднем плане")
                onMain { state.hotkeyEnabled = saved.0; state.overrideSystem = saved.1; state.combo = saved.2 }
                exit(0)
            }
            for code: CGKeyCode in russian ? [4, 14, 37, 37, 31] : [5, 4, 11, 2, 17, 45] { key(code, true); key(code, false) }
            usleep(300_000)
            note("набрано: [\(onMain { view?.string ?? "?" })]")
            key(59, true, .maskControl)
            key(49, true, .maskControl)
            if hold {
                sleep(2)
                note("Control ещё зажат: [\(onMain { view?.string ?? "?" })]")
            }
            key(49, false, .maskControl)
            key(59, false)
            sleep(2)
            note("после отпускания: [\(onMain { view?.string ?? "?" })] раскладка: \(onMain { InputSources.currentID() })")
            onMain {
                state.hotkeyEnabled = saved.0
                state.overrideSystem = saved.1
                state.combo = saved.2
            }
            sleep(1)
            exit(0)
        }
    }

    /// `Raskladushka --axprobe`: 20 секунд раз в секунду пишет, что видно через Accessibility о поле
    /// с курсором: чьё оно, какой роли и есть ли выделение. Сам текст не читает, ничего не нажимает.
    /// Итог — в tmp/axprobe.txt контейнера.
    static func axProbeIfRequested() {
        guard CommandLine.arguments.contains("--axprobe") else { return }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("axprobe.txt")
        var lines = ["trusted: \(AXIsProcessTrusted())"]
        var count = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            count += 1
            let system = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            let e1 = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
            var line = "\(count): focused=\(e1.rawValue)"
            if e1 == .success, let focused {
                let element = focused as! AXUIElement
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                var value: CFTypeRef?
                let e2 = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
                var range = CFRange()
                if e2 == .success, let value { AXValueGetValue(value as! AXValue, .cfRange, &range) }
                var length: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &length)
                line += " app=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") role=\(role as? String ?? "?")"
                    + " range=\(e2.rawValue):\(range.location)+\(range.length) chars=\(length as? Int ?? -1)"
            }
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            if count >= 20 { timer.invalidate() }
        }
    }

    /// `Raskladushka --spotprobe`: открывает Spotlight (⌘Space), смотрит, какие окна появились на экране,
    /// и закрывает его (Esc). Итог — в tmp/spotprobe.txt контейнера.
    static func spotProbeIfRequested() {
        guard CommandLine.arguments.contains("--spotprobe") else { return }
        func windows() -> Set<String> {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return Set(list.map { w in
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                return "\(w[kCGWindowOwnerName as String] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?") "
                    + "\(b["Width"] ?? "?")x\(b["Height"] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?")"
            })
        }
        func key(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("spotprobe.txt")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let before = windows()
            key(49, .maskCommand)
            sleep(1)
            let opened = windows()
            key(53)
            sleep(1)
            let after = windows()
            let text = (["появились:"] + opened.subtracting(before).sorted() + ["после закрытия остались:"]
                        + after.subtracting(before).sorted() + ["Spotlight до открытия:"]
                        + before.filter { $0.contains("Spotlight") }.sorted()).joined(separator: "\n")
            try? text.write(to: log, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// `Raskladushka --spottest`: открывает Spotlight, набирает в нём слово не в той раскладке, жмёт
    /// сочетание перевода и читает, что получилось в строке (⌘A ⌘C, буфер обмена потом возвращает).
    /// Если Spotlight не открылся — ничего не печатает. Итог — в tmp/spottest.txt контейнера.
    static func spotTestIfRequested() {
        guard CommandLine.arguments.contains("--spottest") else { return }
        func spotlightOpen() -> Bool {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.contains { $0[kCGWindowOwnerName as String] as? String == "Spotlight" }
        }
        func key(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
        func onMain<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("spottest.txt")
        var lines: [String] = []
        func note(_ line: String) { lines.append(line); try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8) }
        let state = AppState.shared
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let combo = onMain { state.combo }
            var flags: CGEventFlags = []
            if combo.flags.contains(.control) { flags.insert(.maskControl) }
            if combo.flags.contains(.option) { flags.insert(.maskAlternate) }
            if combo.flags.contains(.shift) { flags.insert(.maskShift) }
            if combo.flags.contains(.command) { flags.insert(.maskCommand) }
            let russian = onMain { InputSources.currentID() }.contains("Russian")
            note("сочетание \(combo.display), перехват \(onMain { state.capturing }), раскладка русская: \(russian)")
            key(49, .maskCommand)
            sleep(1)
            guard spotlightOpen(), !combo.isModifiersOnly else { note("отменено: Spotlight не открылся"); exit(0) }
            for code: CGKeyCode in russian ? [4, 14, 37, 37, 31] : [5, 4, 11, 2, 17, 45] { key(code) }
            usleep(700_000)
            key(CGKeyCode(combo.keyCode), flags)
            sleep(2)
            let pasteboard = NSPasteboard.general
            let snapshot = onMain { PasteboardSnapshot(pasteboard) }
            let before = pasteboard.changeCount
            key(0, .maskCommand)
            key(8, .maskCommand)
            usleep(500_000)
            let text = pasteboard.changeCount != before ? (pasteboard.string(forType: .string) ?? "<не текст>") : "<ничего не скопировалось>"
            note("набрано \(russian ? "руддщ" : "ghbdtn"), в строке после перевода: [\(text)]")
            onMain { snapshot.restore(to: pasteboard) }
            if spotlightOpen() { key(53) }
            usleep(300_000)
            if spotlightOpen() { key(53) }
            exit(0)
        }
    }

    static func runIfRequested() {
        renderIfRequested()
        spotTestIfRequested()
        spotProbeIfRequested()
        axProbeIfRequested()
        typeTestIfRequested()
        captureTestIfRequested()
        activeTestIfRequested()
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
