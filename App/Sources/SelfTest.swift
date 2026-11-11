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

    static func runIfRequested() {
        renderIfRequested()
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
