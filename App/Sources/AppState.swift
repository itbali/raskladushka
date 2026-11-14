import AppKit
import Carbon
import Combine
import ServiceManagement
import SwitcherCore

/// Состояние приложения и связка всех частей.
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Настройки

    @Published var autoSwitchEnabled: Bool { didSet { defaults.set(autoSwitchEnabled, forKey: "autoSwitch"); session.autoSwitchEnabled = autoSwitchEnabled; refresh() } }
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled"); registerHotKey() } }
    @Published var combo: KeyCombo { didSet { defaults.set(try? JSONEncoder().encode(combo), forKey: "combo"); registerHotKey() } }
    /// Забирать сочетание у macOS (Spotlight, смена языка…): перехватчик становится активным.
    @Published var overrideSystem: Bool { didSet { defaults.set(overrideSystem, forKey: "overrideSystem"); registerHotKey() } }
    @Published var exceptions: [String] { didSet { defaults.set(exceptions, forKey: "exceptions"); session.detector.exceptions = Set(exceptions) } }
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: "excludedApps") } }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var hotkeyRegistered = true

    // MARK: Разрешения и состояние

    @Published private(set) var canPostEvents = false
    @Published private(set) var canListenEvents = false
    @Published private(set) var tapRunning = false
    @Published private(set) var layoutCount = 0
    /// Последнее приложение, в котором пользователь работал (не мы сами).
    @Published private(set) var lastApp: (bundleID: String, name: String)?

    var needsPermissions: Bool { !canPostEvents || (autoSwitchEnabled && !tapRunning) }

    private let defaults = UserDefaults.standard
    private let inputSources = InputSources()
    private let tap = KeyboardTap()
    private let injector = TextInjector()
    private let hotKey = HotKey()
    /// ⌘Z сразу после замены. Сочетание занято только пока есть что возвращать — в остальное время
    /// ⌘Z идёт в приложение как обычно.
    private let undoKey = HotKey(id: 2)
    private static let undoCombo = KeyCombo(keyCode: 6, modifiers: NSEvent.ModifierFlags.command.rawValue)
    private let session: TypingSession
    private var timer: Timer?
    /// Пока в настройках записывается сочетание, нажатия уходят сюда, а не в набор.
    var recordingProbe: ((UInt16, CGEventFlags) -> Void)?
    /// Модификаторы, зажатые с момента, когда не было зажато ни одного; `nil` — в эту серию
    /// вмешалась клавиша или мышь, и сочетанием из одних модификаторов она уже не станет.
    private var heldModifiers: NSEvent.ModifierFlags? = []
    private var askedListenAccess = false

    private init() {
        defaults.register(defaults: ["autoSwitch": true, "hotkeyEnabled": true])
        autoSwitchEnabled = defaults.bool(forKey: "autoSwitch")
        hotkeyEnabled = defaults.bool(forKey: "hotkeyEnabled")
        overrideSystem = defaults.bool(forKey: "overrideSystem")
        combo = defaults.data(forKey: "combo").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        let savedExceptions = defaults.stringArray(forKey: "exceptions") ?? []
        exceptions = savedExceptions
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        session = TypingSession(detector: LayoutDetector(validator: SpellValidator(), exceptions: Set(savedExceptions)))
        session.autoSwitchEnabled = defaults.bool(forKey: "autoSwitch")
    }

    func start() {
        tap.handler = { [weak self] in self?.handle($0) }
        tap.swallow = { [weak self] keyCode, flags in
            guard let self, self.hotkeyEnabled else { return false }
            // Пока записывается сочетание — забираем всё, что на него похоже, чтобы система не сработала.
            if self.recordingProbe != nil {
                return !KeyCombo.modifiers(flags).intersection([.control, .option, .command]).isEmpty
            }
            return self.combo.matches(keyCode: keyCode, flags: flags)
        }
        hotKey.action = { [weak self] in self?.hotKeyPressed() }
        undoKey.action = { [weak self] in self?.undoPressed() }
        inputSources.onUserChangedLayout = { [weak self] in self?.session.reset(); self?.syncUndoKey() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.session.reset()
            self?.syncUndoKey()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                self?.lastApp = (id, app.localizedName ?? id)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            lastApp = (id, app.localizedName ?? id)
        }
        registerHotKey()
        refresh()
        refreshLaunchAtLogin()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Перепроверяет разрешения и поднимает или останавливает перехватчик.
    func refresh() {
        var post = Self.hasPostAccess
        let listen = CGPreflightListenEventAccess()
        var running = tap.isRunning
        #if DEBUG
        // Режим для скриншотов: показать окно таким, каким оно будет после выдачи разрешений.
        if CommandLine.arguments.contains("--demo") {
            post = true
            if !canPostEvents { canPostEvents = true }
            if !tapRunning { tapRunning = true }
            layoutCount = max(2, inputSources.tables.count)
            return
        }
        #endif
        if autoSwitchEnabled || hotkeyEnabled {
            // Активный перехват требует «Универсального доступа»; не дали или не вышло — работаем как обычно.
            let active = overrideSystem && hotkeyEnabled && post
            if running, tap.isActive != active { tap.stop(); running = false }
            if !running, post || listen { running = (active && tap.start(active: true)) || tap.start() }
        } else if running {
            tap.stop()
            running = false
        }
        let count = inputSources.tables.count
        if post != canPostEvents { canPostEvents = post }
        if listen != canListenEvents { canListenEvents = listen }
        if running != tapRunning { tapRunning = running }
        if count != layoutCount { layoutCount = count }
        injector.bypassSessionTaps = tap.isActive
        if tap.isActive != capturing { applyHotKey() }
        syncUndoKey()
    }

    // MARK: Разрешения

    /// Право отправлять нажатия: отдельное разрешение или общий «Универсальный доступ».
    static var hasPostAccess: Bool { CGPreflightPostEventAccess() || AXIsProcessTrusted() }

    func requestPostAccess() {
        guard !Self.hasPostAccess else { refresh(); return }
        // Два запроса подряд: первый регистрирует право на отправку нажатий, второй гарантированно
        // добавляет приложение в список «Универсальный доступ» и показывает системное окно.
        _ = CGRequestPostEventAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(pane: "Privacy_Accessibility")
        refresh()
    }

    /// Показывает приложение в Finder, чтобы его можно было перетащить в список разрешений вручную.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func requestListenAccess() {
        if askedListenAccess || !CGRequestListenEventAccess() { openSettings(pane: "Privacy_ListenEvent") }
        askedListenAccess = true
        refresh()
    }

    private func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Автозапуск

    func refreshLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    // MARK: Исключённые приложения

    func isExcluded(_ bundleID: String) -> Bool { excludedApps.contains(bundleID) }

    func toggleExcluded(_ bundleID: String) {
        if let index = excludedApps.firstIndex(of: bundleID) { excludedApps.remove(at: index) } else { excludedApps.append(bundleID) }
        session.reset()
        syncUndoKey()
    }

    // MARK: Горячая клавиша

    /// Сочетание сейчас забирает перехватчик, а не Carbon.
    @Published private(set) var capturing = false

    private func registerHotKey() {
        refresh()
        applyHotKey()
    }

    /// Когда сочетание забирает перехватчик, Carbon не нужен: до него нажатие всё равно не дойдёт.
    private func applyHotKey() {
        let byTap = tap.isActive
        if byTap != capturing { capturing = byTap }
        let registered = hotKey.register(hotkeyEnabled && !byTap ? combo : nil)
        if registered != hotkeyRegistered { hotkeyRegistered = registered }
    }

    private func hotKeyPressed() {
        guard hotkeyEnabled, let context = inputSources.context() else { return }
        guard Self.hasPostAccess else { requestPostAccess(); return }
        if let replacement = session.manualToggle(context: context) {
            apply(replacement)
            return
        }
        convertSelection(context: context)
    }

    // MARK: Отмена по ⌘Z

    /// Занимает ⌘Z, пока последнюю замену можно вернуть, и отпускает, как только нельзя.
    /// Без работающего перехватчика не занимает вовсе: некому было бы заметить следующее нажатие.
    private func syncUndoKey() {
        let wanted = session.canUndo && tap.isRunning && combo != Self.undoCombo
        if wanted != undoKey.isRegistered { undoKey.register(wanted ? Self.undoCombo : nil) }
    }

    private func undoPressed() {
        defer { syncUndoKey() }
        guard Self.hasPostAccess, let replacement = session.undoLast() else { return }
        apply(replacement)
    }

    /// Терминалы: щелчок мышью не двигает курсор, а выделенный текст нельзя заменить вставкой.
    private static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "com.itbali.projects-hub",
    ]

    private var frontmostIsTerminal: Bool {
        Self.terminalApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    private func convertSelection(context: LayoutContext) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        injector.copy()
        var copied = false
        for _ in 0..<25 {
            usleep(20_000)
            if pasteboard.changeCount != before { copied = true; break }
        }
        let terminal = frontmostIsTerminal
        // Терминал мог скопировать выделение сам, ещё при выделении мышью, — тогда ⌘C ничего не меняет.
        guard copied || terminal, var text = pasteboard.string(forType: .string), !text.isEmpty else {
            if copied { snapshot.restore(to: pasteboard) }
            return
        }
        if terminal {
            while let last = text.last, last.isWhitespace { text.removeLast() }
        }
        defer { if copied { snapshot.restore(to: pasteboard) } }

        // Выделен кусок только что набранного текста: стираем и набираем заново, буфер обмена не нужен.
        if let replacement = session.replaceInTail(selected: text, context: context) {
            apply(replacement)
            return
        }
        if terminal {
            // Про набранное ничего не известно (например, после смены окна) — считаем, что выделен
            // текст прямо перед курсором. Если же известно и выделение в него не входит — не трогаем.
            guard copied, !session.hasPendingWord,
                  let result = SelectionConverter.convert(text, context: context) else { return }
            injector.replace(deleteCount: text.count, with: result.text)
            inputSources.select(result.targetLayoutID)
            session.rememberUndo(deleteCount: result.text.count, insert: text, switchTo: context.current.id)
            syncUndoKey()
            return
        }
        guard !Self.looksLikeWholeLineCopy(text),
              let result = SelectionConverter.convert(text, context: context) else { return }
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        injector.paste()
        inputSources.select(result.targetLayoutID)
        session.reset()
        // Вставка читает буфер чуть позже — возвращаем прежнее содержимое с задержкой.
        copied = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { snapshot.restore(to: pasteboard) }
    }

    /// Редакторы кода по ⌘C без выделения копируют всю строку целиком, с переводом строки на конце.
    /// Такой текст не трогаем: пользователь ничего не выделял.
    static func looksLikeWholeLineCopy(_ text: String) -> Bool {
        guard text.hasSuffix("\n") else { return false }
        return !text.dropLast().contains(where: \.isNewline)
    }

    // MARK: Нажатия

    private func handle(_ event: KeyboardTap.Event) {
        defer { syncUndoKey() }
        switch event {
        case .flagsChanged(let flags):
            let now = KeyCombo.modifiers(flags)
            if !now.isEmpty {
                heldModifiers?.formUnion(now)
            } else {
                let held = heldModifiers
                heldModifiers = []
                if hotkeyEnabled, combo.isModifiersOnly, recordingProbe == nil, held == combo.flags {
                    DispatchQueue.main.async { [weak self] in self?.hotKeyPressed() }
                }
            }
        case .captured(let keyCode, let flags, let isRepeat):
            heldModifiers = nil
            if let recordingProbe { recordingProbe(keyCode, flags) } else if !isRepeat { hotKeyPressed() }
        case .mouseDown:
            if !KeyCombo.modifiers(CGEventSource.flagsState(.combinedSessionState)).isEmpty { heldModifiers = nil }
            if !frontmostIsTerminal { session.reset() }
        case .keyDown(let keyCode, let flags):
            if !KeyCombo.modifiers(flags).isEmpty { heldModifiers = nil }
            if let recordingProbe { recordingProbe(keyCode, flags); return }
            if hotkeyEnabled, combo.matches(keyCode: keyCode, flags: flags) { return }
            // Наш ⌘Z: замену вернёт обработчик сочетания, сессию до него не трогаем.
            if undoKey.isRegistered, Self.undoCombo.matches(keyCode: keyCode, flags: flags) { return }
            guard !IsSecureEventInputEnabled(),
                  let context = inputSources.context(),
                  !isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            else { session.reset(); return }
            let input: InputEvent
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                input = .reset
            } else if keyCode == 51 {
                input = .backspace
            } else if keyCode == KeyStroke.spaceKeyCode || Self.printable.contains(keyCode) {
                input = .stroke(KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
            } else {
                input = .reset
            }
            if let replacement = session.handle(input, context: context) {
                guard Self.hasPostAccess else { return }
                apply(replacement)
            }
        }
    }

    private static let printable = Set(LayoutTable.printableKeyCodes)

    private func apply(_ replacement: Replacement) {
        injector.replace(deleteCount: replacement.deleteCount, with: replacement.insert)
        inputSources.select(replacement.switchTo)
        if let word = replacement.learnedException, !exceptions.contains(word) {
            exceptions.append(word)
        }
        syncUndoKey()
    }
}
