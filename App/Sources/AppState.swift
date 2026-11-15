import AppKit
import Carbon
import Combine
import ServiceManagement
import SwitcherCore

/// Состояние приложения и связка всех частей.
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: Настройки

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            applySettings(old: oldValue)
        }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var hotkeyRegistered = true

    // MARK: Разрешения и состояние

    @Published private(set) var canPostEvents = false
    @Published private(set) var canListenEvents = false
    @Published private(set) var tapRunning = false
    @Published private(set) var layoutCount = 0
    /// Последнее приложение, в котором пользователь работал (не мы сами).
    @Published private(set) var lastApp: (bundleID: String, name: String)?
    /// Сочетание сейчас забирает перехватчик, а не Carbon.
    @Published private(set) var capturing = false
    /// Язык текущей раскладки — для значка в строке меню.
    @Published private(set) var currentLanguage = "en"
    /// До какого времени исправления приостановлены. `distantFuture` — до перезапуска.
    @Published private(set) var pausedUntil: Date?
    /// Значок в строке меню «мигает» после автозамены.
    @Published private(set) var flashing = false
    @Published private(set) var stats = Stats()
    /// Журнал последних замен. Только в памяти.
    @Published private(set) var journal: [JournalEntry] = []
    /// Сколько раз пользователь сам перевёл каждое слово (ключ — «слово\u{1}раскладка»).
    @Published private(set) var manualCounts: [String: Int] = [:]

    var needsPermissions: Bool { !canPostEvents || (settings.autoSwitch && !tapRunning) }
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    private var working: Bool { (settings.autoSwitch || settings.hotkeyEnabled) && !isPaused }

    let defaults: UserDefaults
    private let inputSources = InputSources()
    private let tap = KeyboardTap()
    private let injector = TextInjector()
    private let hotKey = HotKey()
    /// ⌘Z сразу после замены и ⇧⌘Z сразу после отмены. Сочетания заняты только пока есть что
    /// возвращать или повторять — в остальное время они идут в приложение как обычно.
    private let undoKey = HotKey(id: 2)
    private let redoKey = HotKey(id: 3)
    private static let undoCombo = KeyCombo(keyCode: 6, modifiers: NSEvent.ModifierFlags.command.rawValue)
    private static let redoCombo = KeyCombo(keyCode: 6, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    private let session: TypingSession
    private var timer: Timer?
    /// Пока в настройках записывается сочетание, нажатия уходят сюда, а не в набор.
    var recordingProbe: ((UInt16, CGEventFlags) -> Void)? { didSet { updateCapture() } }
    /// Модификаторы, зажатые с момента, когда не было зажато ни одного; `nil` — в эту серию
    /// вмешалась клавиша или мышь, и сочетанием из одних модификаторов она уже не станет.
    private var heldModifiers: NSEvent.ModifierFlags? = []
    private var askedListenAccess = false
    /// Перехватчик уже работал — если он вдруг остановится, это стоит заметить.
    private var tapWasRunning = false
    private var lastTapNotice = Date.distantPast

    private init() {
        defaults = Self.makeDefaults()
        settings = Settings.load(from: defaults)
        session = TypingSession(detector: LayoutDetector(validator: SpellValidator()))
        if let data = defaults.data(forKey: "stats"), let saved = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = saved
        }
        stats.rollDay()
        manualCounts = defaults.dictionary(forKey: "manualCounts") as? [String: Int] ?? [:]
        configureSession()
    }

    /// Отладочные проверки работают на отдельных настройках, чтобы не трогать настоящие.
    private static func makeDefaults() -> UserDefaults {
        #if DEBUG
        if CommandLine.arguments.contains("--uitest") || CommandLine.arguments.contains("--render"),
           let isolated = UserDefaults(suiteName: "raskladushka-selftest") {
            isolated.removePersistentDomain(forName: "raskladushka-selftest")
            return isolated
        }
        #endif
        return .standard
    }

    func start() {
        tap.handler = { [weak self] in self?.handle($0) }
        updateCapture()
        hotKey.action = { [weak self] in self?.hotKeyPressed() }
        undoKey.action = { [weak self] in self?.undoPressed() }
        redoKey.action = { [weak self] in self?.redoPressed() }
        inputSources.onUserChangedLayout = { [weak self] in self?.session.layoutChangedByUser(); self?.syncUndoKeys() }
        inputSources.onLayoutChanged = { [weak self] in self?.updateLanguage() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.session.reset()
            self.syncUndoKeys()
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
                self.lastApp = (id, app.localizedName ?? id)
            }
            self.configureSession()
        }
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            lastApp = (id, app.localizedName ?? id)
        }
        #if DIRECT
        Updater.shared.automatic = settings.autoUpdate
        #endif
        configureSession()
        updateLanguage()
        registerHotKey()
        refresh()
        refreshLaunchAtLogin()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Раздаёт настройки частям, которые по ним работают.
    private func applySettings(old: Settings) {
        configureSession()
        if settings.journalLimit < journal.count { journal.removeLast(journal.count - settings.journalLimit) }
        if !settings.journalEnabled, !journal.isEmpty { journal.removeAll() }
        if settings.hotkeyEnabled != old.hotkeyEnabled || settings.combo != old.combo
            || settings.overrideSystem != old.overrideSystem || settings.autoSwitch != old.autoSwitch {
            registerHotKey()
        }
        if settings.excludedApps != old.excludedApps { session.reset() }
        #if DIRECT
        if settings.autoUpdate != old.autoUpdate { Updater.shared.automatic = settings.autoUpdate }
        #endif
        syncUndoKeys()
    }

    private var frontmostBundleID: String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }

    /// Исключения для приложения, которое сейчас впереди: общие и его собственные.
    private func configureSession() {
        session.autoSwitchEnabled = settings.autoSwitch
        session.mixedWordsEnabled = settings.mixedWords
        session.contextEnabled = settings.contextAware
        session.backspaceUndoEnabled = settings.undoByBackspace
        session.detector.exceptions = Set(settings.exceptions).union(settings.appExceptions[frontmostBundleID] ?? [])
        session.detector.learned = settings.learnFrequent ? settings.learned : [:]
    }

    private func updateLanguage() {
        let id = InputSources.currentID()
        let language = inputSources.tables.first { $0.id == id }?.language ?? currentLanguage
        if language != currentLanguage { currentLanguage = language }
    }

    /// Название раскладки для показа в настройках.
    func layoutName(_ id: String) -> String { inputSources.names[id] ?? id }

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
        if let until = pausedUntil, until <= Date() { resume() }
        if working {
            // Активный перехват требует «Универсального доступа»; не дали или не вышло — работаем как обычно.
            let active = settings.overrideSystem && settings.hotkeyEnabled && post
            if running, tap.isActive != active { tap.stop(); running = false; tapWasRunning = false }
            if !running, post || listen {
                running = (active && tap.start(active: true)) || tap.start()
                // Перехватчик работал и вдруг остановился — macOS отключает его, если он долго не отвечал.
                if tapWasRunning { noticeTap(restored: running) }
            }
            tapWasRunning = running
        } else {
            if running { tap.stop(); running = false }
            tapWasRunning = false
        }
        let count = inputSources.tables.count
        if post != canPostEvents { canPostEvents = post }
        if listen != canListenEvents { canListenEvents = listen }
        if running != tapRunning { tapRunning = running }
        if count != layoutCount { layoutCount = count }
        updateCapture()
        if tap.isActive != capturing { applyHotKey() }
        syncUndoKeys()
    }

    private func noticeTap(restored: Bool) {
        record(JournalEntry(kind: L("Служебное"), before: "", after: "",
                            reason: restored ? L("Перехватчик клавиатуры был отключён системой и восстановлен")
                                : L("Перехватчик клавиатуры отключён системой, восстановить не удалось"),
                            app: ""))
        guard settings.notifyTapRestored, Date().timeIntervalSince(lastTapNotice) > 60 else { return }
        lastTapNotice = Date()
        Hud.shared.show(restored ? L("Раскладушка: слежение за клавиатурой восстановлено")
                            : L("Раскладушка не видит клавиатуру — проверьте разрешения"),
                        position: settings.hudPosition, duration: 4)
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

    // MARK: Пауза

    /// Приостанавливает исправления и сочетания. `minutes == nil` — до перезапуска приложения.
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        session.reset()
        registerHotKey()
    }

    func resume() {
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        registerHotKey()
    }

    // MARK: Исключения

    func isExcluded(_ bundleID: String) -> Bool { settings.excludedApps.contains(bundleID) }

    func toggleExcluded(_ bundleID: String) {
        if let index = settings.excludedApps.firstIndex(of: bundleID) {
            settings.excludedApps.remove(at: index)
        } else {
            settings.excludedApps.append(bundleID)
        }
    }

    /// Слова-исключения: общие (`app == nil`) или одного приложения.
    func exceptionWords(app: String?) -> [String] {
        app.map { settings.appExceptions[$0] ?? [] } ?? settings.exceptions
    }

    func addException(_ word: String, app: String?) {
        guard !word.isEmpty, !exceptionWords(app: app).contains(word) else { return }
        if let app { settings.appExceptions[app, default: []].append(word) } else { settings.exceptions.append(word) }
    }

    func removeException(_ word: String, app: String?) {
        if let app {
            settings.appExceptions[app]?.removeAll { $0 == word }
            if settings.appExceptions[app]?.isEmpty == true { settings.appExceptions[app] = nil }
        } else {
            settings.exceptions.removeAll { $0 == word }
        }
    }

    func forgetLearned(_ word: String) {
        settings.learned[word] = nil
        for key in manualCounts.keys where key.hasPrefix(word + "\u{1}") { manualCounts[key] = nil }
        defaults.set(manualCounts, forKey: "manualCounts")
    }

    func resetStats() {
        stats = Stats()
        stats.rollDay()
        saveStats()
    }

    func clearJournal() { journal.removeAll() }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: "stats") }
    }

    // MARK: Горячая клавиша

    /// Что активный перехватчик забирает себе: своё сочетание, а пока сочетание записывается
    /// в настройках — всё, что на него похоже, чтобы система не сработала раньше нас.
    private func updateCapture() {
        let enabled = settings.hotkeyEnabled && !isPaused
        tap.capture = KeyboardTap.Capture(combo: enabled ? settings.combo : nil,
                                          anyShortcut: enabled && recordingProbe != nil)
    }

    private func registerHotKey() {
        refresh()
        applyHotKey()
    }

    /// Когда сочетание забирает перехватчик, Carbon не нужен: до него нажатие всё равно не дойдёт.
    private func applyHotKey() {
        let byTap = tap.isActive
        if byTap != capturing { capturing = byTap }
        let registered = hotKey.register(settings.hotkeyEnabled && !isPaused && !byTap ? settings.combo : nil)
        if registered != hotkeyRegistered { hotkeyRegistered = registered }
    }

    /// Выполняет действие, когда отпущены ⌃⌥⇧⌘ (но не дольше полутора секунд ожидания).
    /// Пока клавиши сочетания зажаты, наши стирания и буквы некоторые поля читают как сочетания:
    /// в строке Spotlight ⌃ вместе с нашей «буквой» уводил курсор в начало, а слово не менялось.
    private func whenModifiersReleased(deadline: Date = Date().addingTimeInterval(1.5), _ action: @escaping () -> Void) {
        let held = KeyCombo.modifiers(CGEventSource.flagsState(.combinedSessionState))
        if held.isEmpty || Date() > deadline { action(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.whenModifiersReleased(deadline: deadline, action)
        }
    }

    private func hotKeyPressed() {
        whenModifiersReleased { [weak self] in self?.convert() }
    }

    private func convert() {
        guard settings.hotkeyEnabled, !isPaused, let context = inputSources.context() else { return }
        guard Self.hasPostAccess else { requestPostAccess(); return }
        if let replacement = session.manualToggle(context: context) {
            apply(replacement)
            return
        }
        convertSelection(context: context)
    }

    // MARK: Отмена и повтор

    /// Занимает ⌘Z, пока последнюю замену можно вернуть, и ⇧⌘Z, пока её можно повторить, — и отпускает,
    /// как только нельзя. Без работающего перехватчика не занимает вовсе: некому было бы заметить
    /// следующее нажатие.
    private func syncUndoKeys() {
        let live = tap.isRunning && !isPaused
        let undo = live && settings.undoByCommandZ && session.canUndo && settings.combo != Self.undoCombo
        if undo != undoKey.isRegistered { undoKey.register(undo ? Self.undoCombo : nil) }
        let redo = live && settings.redoEnabled && session.canRedo && settings.combo != Self.redoCombo
        if redo != redoKey.isRegistered { redoKey.register(redo ? Self.redoCombo : nil) }
    }

    private func undoPressed() {
        whenModifiersReleased { [weak self] in
            guard let self else { return }
            defer { self.syncUndoKeys() }
            guard Self.hasPostAccess, let replacement = self.session.undoLast() else { return }
            self.apply(replacement)
        }
    }

    private func redoPressed() {
        whenModifiersReleased { [weak self] in
            guard let self else { return }
            defer { self.syncUndoKeys() }
            guard Self.hasPostAccess, let replacement = self.session.redoLast() else { return }
            self.apply(replacement)
        }
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
            session.rememberUndo(deleteCount: result.text.count, insert: text, switchTo: context.current.id,
                                 redoInsert: result.text, redoSwitchTo: result.targetLayoutID)
            report(.init(kind: .selection, before: text, after: result.text, words: 0))
            syncUndoKeys()
            return
        }
        guard !Self.looksLikeWholeLineCopy(text),
              let result = SelectionConverter.convert(text, context: context) else { return }
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        injector.paste()
        inputSources.select(result.targetLayoutID)
        session.reset()
        report(.init(kind: .selection, before: text, after: result.text, words: 0))
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
        defer { syncUndoKeys() }
        if isPaused, recordingProbe == nil { return }
        switch event {
        case .reenabled:
            noticeTap(restored: true)
        case .flagsChanged(let flags):
            let now = KeyCombo.modifiers(flags)
            if !now.isEmpty {
                heldModifiers?.formUnion(now)
            } else {
                let held = heldModifiers
                heldModifiers = []
                if settings.hotkeyEnabled, settings.combo.isModifiersOnly, recordingProbe == nil, held == settings.combo.flags {
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
            if settings.hotkeyEnabled, settings.combo.matches(keyCode: keyCode, flags: flags) { return }
            // Наши ⌘Z и ⇧⌘Z: замену вернёт обработчик сочетания, сессию до него не трогаем.
            if undoKey.isRegistered, Self.undoCombo.matches(keyCode: keyCode, flags: flags) { return }
            if redoKey.isRegistered, Self.redoCombo.matches(keyCode: keyCode, flags: flags) { return }
            guard !IsSecureEventInputEnabled(),
                  let context = inputSources.context(),
                  !isExcluded(frontmostBundleID)
            else { session.reset(); return }
            let input: InputEvent
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                // Сочетанием с пробелом обычно меняют язык — недописанное слово пока не забываем.
                input = keyCode == KeyStroke.spaceKeyCode ? .softReset : .reset
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

    /// Открыта ли строка Spotlight. Это панель поверх активного приложения, само приложение при этом
    /// не меняется — узнать о ней можно только по её окну на экране.
    private static var spotlightIsOpen: Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { $0[kCGWindowOwnerName as String] as? String == "Spotlight" }
    }

    private static let printable = Set(LayoutTable.printableKeyCodes)

    private func apply(_ replacement: Replacement) {
        injector.replace(deleteCount: replacement.deleteCount, with: replacement.insert,
                         dismissSuggestion: Self.spotlightIsOpen)
        inputSources.select(replacement.switchTo)
        if let word = replacement.learnedException { rememberUndone(word) }
        if let word = replacement.forgetException {
            removeException(word, app: nil)
            removeException(word, app: frontmostBundleID)
        }
        if let info = replacement.info { report(info) }
        syncUndoKeys()
    }

    /// Слово, автозамену которого отменили, — в исключения: общие, приложения или никуда, как настроено.
    private func rememberUndone(_ word: String) {
        switch settings.rememberUndone {
        case .everywhere: addException(word, app: nil)
        case .currentApp: if !frontmostBundleID.isEmpty { addException(word, app: frontmostBundleID) }
        case .nowhere: break
        }
    }

    // MARK: Отклик: журнал, счётчики, подсказка, звук

    private func record(_ entry: JournalEntry) {
        guard settings.journalEnabled else { return }
        journal.insert(entry, at: 0)
        if journal.count > settings.journalLimit { journal.removeLast(journal.count - settings.journalLimit) }
    }

    private func report(_ info: Replacement.Info) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        record(JournalEntry(kind: Self.title(info.kind), before: info.before, after: info.after,
                            reason: info.reason.map(Self.title) ?? "", app: app))
        switch info.kind {
        case .auto, .redo:
            stats.rollDay()
            stats.total += max(1, info.words)
            stats.today += max(1, info.words)
            saveStats()
            if settings.soundEnabled { Sounds.play(settings.soundName) }
            if settings.flashIcon { flash() }
            if settings.hudEnabled {
                var text = L("Исправлено: %@", info.after)
                if settings.undoByCommandZ { text += " · " + L("⌘Z — вернуть") }
                Hud.shared.show(text, position: settings.hudPosition, duration: settings.hudDuration)
            }
        case .undo:
            if settings.hudEnabled {
                var text = L("Возвращено: %@", info.after)
                if settings.redoEnabled, session.canRedo { text += " · " + L("⇧⌘Z — повторить") }
                Hud.shared.show(text, position: settings.hudPosition, duration: settings.hudDuration)
            }
        case .manual, .selection:
            stats.rollDay()
            stats.manual += 1
            saveStats()
            if settings.hudEnabled, settings.hudForManual {
                Hud.shared.show(L("Переведено: %@", info.after), position: settings.hudPosition, duration: settings.hudDuration)
            }
            if let word = info.manualWord { countManual(word.typed, layoutID: word.layoutID) }
        }
    }

    /// Человек сам перевёл слово. После нескольких раз слово начинает исправляться автоматически.
    private func countManual(_ typed: String, layoutID: String) {
        guard settings.learnFrequent, settings.learned[typed] == nil else { return }
        let key = typed + "\u{1}" + layoutID
        let count = (manualCounts[key] ?? 0) + 1
        manualCounts[key] = count
        if count >= settings.learnThreshold {
            settings.learned[typed] = layoutID
            if settings.hudEnabled {
                Hud.shared.show(L("Запомнила: «%@» теперь исправляется само", typed),
                                position: settings.hudPosition, duration: 3)
            }
        }
        // Счётчики копим не больше чем по пятистам словам — самые редкие отбрасываем.
        if manualCounts.count > 500, let rarest = manualCounts.min(by: { $0.value < $1.value })?.key {
            manualCounts[rarest] = nil
        }
        defaults.set(manualCounts, forKey: "manualCounts")
    }

    private func flash() {
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.flashing = false }
    }

    private static func title(_ kind: Replacement.Info.Kind) -> String {
        switch kind {
        case .auto: return L("Автозамена")
        case .manual: return L("Сочетанием")
        case .selection: return L("Выделение")
        case .undo: return L("Отмена")
        case .redo: return L("Повтор")
        }
    }

    private static func title(_ reason: Conversion.Reason) -> String {
        switch reason {
        case .dictionary: return L("перевод есть в словаре, набранного нет")
        case .commonWord: return L("частое короткое слово")
        case .letterStatistics: return L("сочетания букв похожи на другой язык")
        case .context: return L("соседние слова на другом языке")
        case .learned: return L("вы не раз переводили это слово сами")
        case .mixed: return L("слово набрано в двух раскладках")
        }
    }

    #if DEBUG
    /// Для отладочных проверок: что сейчас помнит сессия и какие сочетания заняты.
    var debugState: String {
        "undo=\(session.canUndo) redo=\(session.canRedo) undoKey=\(undoKey.isRegistered) redoKey=\(redoKey.isRegistered) tap=\(tap.isRunning) active=\(tap.isActive)"
    }

    /// Смена раскладки так, будто её сделал человек (а не мы сами).
    func debugSwitchLayout(to id: String) { inputSources.selectAsUser(id) }
    var debugLayoutIDs: [String] { inputSources.tables.map(\.id) }
    func debugResetSession() {
        session.reset()
        syncUndoKeys()
    }

    func debugReset() {
        session.reset()
        journal.removeAll()
        stats = Stats()
        manualCounts = [:]
        syncUndoKeys()
    }
    #endif
}
