import SwiftUI

/// Окно настроек: вкладки по смыслу.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab = Self.initialTab

    /// `--tab N` — открыть нужную вкладку (для снимков окна).
    private static var initialTab: Int {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("Основное", systemImage: "gearshape") }.tag(0)
            ShortcutsTab().tabItem { Label("Сочетания", systemImage: "command") }.tag(1)
            ExceptionsTab().tabItem { Label("Исключения", systemImage: "nosign") }.tag(2)
            FeedbackTab().tabItem { Label("Отклик", systemImage: "bell") }.tag(3)
            JournalTab().tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }.tag(4)
            AboutTab().tabItem { Label("О программе", systemImage: "info.circle") }.tag(5)
        }
        .frame(width: 560, height: 600)
    }
}

/// Мелкий серый пояснительный текст под настройкой.
private struct Hint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path)
}

/// Запущенные обычные приложения — для меню «добавить приложение».
private func runningApps(excluding: [String]) -> [(id: String, name: String)] {
    var seen = Set(excluding)
    var result: [(String, String)] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
        result.append((id, app.localizedName ?? id))
    }
    return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
}

// MARK: - Основное

private struct GeneralTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Автопереключение раскладки", isOn: $state.settings.autoSwitch)
                Hint("Если слово набрано не в той раскладке, после пробела оно будет исправлено, а раскладка переключится.")
                Toggle("Собирать слова, набранные в двух раскладках", isOn: $state.settings.mixedWords)
                    .disabled(!state.settings.autoSwitch)
                Hint("Начали слово, заметили ошибку, переключили язык и дописали — «ghbвет» станет «привет».")
                Toggle("Учитывать язык соседних слов", isOn: $state.settings.contextAware)
                    .disabled(!state.settings.autoSwitch)
                Hint("После пары русских слов короткое «z» сразу станет «я», не дожидаясь следующего слова.")
            }

            Section("Самообучение") {
                Toggle("Запоминать слова, которые я перевожу сам", isOn: $state.settings.learnFrequent)
                Stepper(value: $state.settings.learnThreshold, in: 2...10) {
                    Text(L("Исправлять автоматически после %d ручных переводов", state.settings.learnThreshold))
                }
                .disabled(!state.settings.learnFrequent)
                if state.settings.learned.isEmpty {
                    Hint("Здесь появятся слова, которые Раскладушка научилась исправлять по вашим ручным переводам.")
                } else {
                    ForEach(state.settings.learned.keys.sorted(), id: \.self) { word in
                        HStack {
                            Text(word).font(.body.monospaced())
                            Text("→ " + state.layoutName(state.settings.learned[word] ?? "")).foregroundStyle(.secondary)
                            Spacer()
                            Button { state.forgetLearned(word) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Разрешения") {
                PermissionRow(title: "Управление клавиатурой",
                              detail: "Нужно, чтобы стереть слово в неверной раскладке и напечатать его заново. Раздел «Универсальный доступ» в настройках.",
                              granted: state.canPostEvents) { state.requestPostAccess() }
                if !state.canPostEvents {
                    HStack {
                        Hint("Раскладушки нет в списке? Нажмите «+» под списком и выберите приложение — или перетащите его туда из Finder.")
                        Spacer()
                        Button("Показать в Finder") { state.revealInFinder() }
                    }
                }
                if !state.tapRunning && state.canPostEvents && (state.settings.autoSwitch || state.settings.hotkeyEnabled) && !state.isPaused
                    || state.canListenEvents {
                    PermissionRow(title: "Мониторинг ввода",
                                  detail: "Нужно, чтобы заметить слово, набранное не в той раскладке.",
                                  granted: state.canListenEvents) { state.requestListenAccess() }
                }
                if state.layoutCount < 2 {
                    Label("Добавьте вторую раскладку в настройках клавиатуры macOS.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Hint("Нажатия обрабатываются только в памяти вашего Mac: ничего не сохраняется и никуда не отправляется. Поля паролей не затрагиваются.")
            }

            Section {
                Toggle("Запускать при входе в систему",
                       isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Stepper(value: $state.settings.pauseMinutes, in: 1...720, step: 5) {
                    Text(L("Свой интервал паузы в меню: %d мин", state.settings.pauseMinutes))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Сочетания

private struct ShortcutsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Перевод выделенного текста и последнего слова", isOn: $state.settings.hotkeyEnabled)
                LabeledContent("Сочетание клавиш") {
                    ShortcutRecorder(combo: $state.settings.combo)
                }
                if state.settings.hotkeyEnabled && !state.hotkeyRegistered {
                    Label("Это сочетание занято другой программой — выберите другое.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Hint("Нажмите сочетание сразу после слова, чтобы перевести его или отменить автозамену. Если текст выделен — будет переведено выделение. Сочетанием могут быть и одни модификаторы, например ⌃⇧.")
                Toggle("Перехватывать системные сочетания", isOn: $state.settings.overrideSystem)
                    .disabled(!state.settings.hotkeyEnabled)
                Hint("Позволяет назначить сочетание, занятое самой macOS: ⌘Space, ⌃Space и подобные. Раскладушка заберёт его себе, и системное действие (Spotlight, смена языка) по нему больше не сработает, пока она запущена.")
                if state.settings.overrideSystem && state.settings.hotkeyEnabled && !state.capturing && !state.isPaused {
                    Label("Перехват не включился: нужно разрешение «Универсальный доступ».", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("Отмена замены") {
                Toggle("⌘Z сразу после замены возвращает текст", isOn: $state.settings.undoByCommandZ)
                Toggle("Backspace сразу после автозамены возвращает слово", isOn: $state.settings.undoByBackspace)
                Hint("Пробел после слова стирается как обычно, а само слово возвращается таким, каким вы его набрали.")
                Toggle("⇧⌘Z сразу после отмены повторяет замену", isOn: $state.settings.redoEnabled)
                Hint("Эти сочетания заняты Раскладушкой только сразу после замены. Стоит нажать любую другую клавишу — и они снова работают в приложении как обычно.")
                Picker("Отменённое слово запоминать", selection: $state.settings.rememberUndone) {
                    ForEach(RememberUndone.allCases) { Text($0.title).tag($0) }
                }
                Hint("Слово, автозамену которого вы отменили, попадает в исключения и больше не исправляется.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Исключения

private struct ExceptionsTab: View {
    @EnvironmentObject private var state: AppState
    /// Чей список открыт: `nil` — общий, иначе идентификатор приложения.
    @State private var scope: String?
    @State private var newWord = ""
    @State private var search = ""
    @State private var alphabetical = false

    private var scopes: [String] {
        var apps = Array(state.settings.appExceptions.keys)
        if let scope, !apps.contains(scope) { apps.append(scope) }
        return apps.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private var words: [String] {
        var list = state.exceptionWords(app: scope)
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty { list = list.filter { $0.contains(query) } }
        // Без сортировки — в порядке добавления, новые сверху.
        return alphabetical ? list.sorted() : list.reversed()
    }

    private var wordToAdd: String? {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !word.contains(where: \.isWhitespace),
              !state.exceptionWords(app: scope).contains(word) else { return nil }
        return word
    }

    private func add() {
        guard let word = wordToAdd else { return }
        state.addException(word, app: scope)
        newWord = ""
    }

    var body: some View {
        Form {
            Section("Слова-исключения") {
                HStack {
                    Picker("Список", selection: $scope) {
                        Text("Все приложения").tag(String?.none)
                        ForEach(scopes, id: \.self) { Text(appName($0)).tag(String?.some($0)) }
                    }
                    Menu("Для приложения…") {
                        let apps = runningApps(excluding: scopes)
                        if apps.isEmpty { Text("Нет других запущенных приложений") }
                        ForEach(apps, id: \.id) { app in Button(app.name) { scope = app.id } }
                    }
                    .fixedSize()
                }
                HStack {
                    TextField("Слово", text: $newWord, prompt: Text("слово, как вы его набираете"))
                        .labelsHidden().font(.body.monospaced())
                        .onSubmit(add)
                    Button("Добавить", action: add).disabled(wordToAdd == nil)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск", text: $search, prompt: Text("Поиск по списку")).labelsHidden()
                    Toggle("По алфавиту", isOn: $alphabetical).toggleStyle(.checkbox)
                }
                if words.isEmpty {
                    Text(search.isEmpty ? L("В этом списке пока нет слов.") : L("Ничего не найдено."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(words, id: \.self) { word in
                        HStack {
                            Text(word).font(.body.monospaced())
                            Spacer()
                            Button { state.removeException(word, app: scope) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Hint("Эти слова Раскладушка не исправляет. Список «Все приложения» действует везде, список приложения — только в нём. Сюда же попадают слова, автозамену которых вы отменили.")
            }

            Section("Приложения без исправлений") {
                ForEach(state.settings.excludedApps, id: \.self) { bundleID in
                    HStack {
                        Text(appName(bundleID))
                        Spacer()
                        Button { state.toggleExcluded(bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Добавить приложение…") {
                    let apps = runningApps(excluding: state.settings.excludedApps)
                    if apps.isEmpty { Text("Нет других запущенных приложений") }
                    ForEach(apps, id: \.id) { app in Button(app.name) { state.toggleExcluded(app.id) } }
                }
                .fixedSize()
                Hint("В этих приложениях Раскладушка ничего не исправляет. В меню выбираются запущенные сейчас приложения.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Отклик

private struct FeedbackTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Строка меню") {
                Picker("Значок", selection: $state.settings.iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Мигать значком при автозамене", isOn: $state.settings.flashIcon)
                Toggle("Показывать счётчик исправлений в меню", isOn: $state.settings.showStats)
                LabeledContent("Исправлено") {
                    HStack {
                        Text(L("сегодня %d · всего %d · вручную %d", state.stats.today, state.stats.total, state.stats.manual))
                            .foregroundStyle(.secondary)
                        Button("Сбросить") { state.resetStats() }
                    }
                }
                Hint("Считаются только числа. Сами слова в счётчик не попадают.")
            }

            Section("Подсказка на экране") {
                Toggle("Показывать подсказку при автозамене", isOn: $state.settings.hudEnabled)
                Picker("Где показывать", selection: $state.settings.hudPosition) {
                    ForEach(HudPosition.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!state.settings.hudEnabled)
                LabeledContent(L("Сколько держать: %.1f с", state.settings.hudDuration)) {
                    Slider(value: $state.settings.hudDuration, in: 0.8...6, step: 0.2).frame(width: 200)
                }
                .disabled(!state.settings.hudEnabled)
                Toggle("Показывать и при переводе сочетанием", isOn: $state.settings.hudForManual)
                    .disabled(!state.settings.hudEnabled)
                Button("Показать пример") {
                    Hud.shared.show(L("Исправлено: %@", "привет") + " · " + L("⌘Z — вернуть"),
                                    position: state.settings.hudPosition, duration: state.settings.hudDuration)
                }
                Hint("Где стоит курсор в чужом окне, Раскладушка узнать не может, поэтому подсказка появляется в выбранном месте экрана.")
            }

            Section("Звук") {
                Toggle("Звук при автозамене", isOn: $state.settings.soundEnabled)
                HStack {
                    Picker("Какой", selection: $state.settings.soundName) {
                        ForEach(Settings.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Прослушать") { Sounds.play(state.settings.soundName) }
                }
                .disabled(!state.settings.soundEnabled)
            }

            Section("Надёжность") {
                Toggle("Сообщать, если слежение за клавиатурой пришлось восстановить", isOn: $state.settings.notifyTapRestored)
                Hint("macOS иногда отключает слежение за клавиатурой у программ. Раскладушка включает его обратно сама; с этой настройкой она ещё и скажет об этом.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Журнал

private struct JournalTab: View {
    @EnvironmentObject private var state: AppState

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                Toggle("Вести журнал замен", isOn: $state.settings.journalEnabled)
                Stepper(value: $state.settings.journalLimit, in: 10...500, step: 10) {
                    Text(L("Помнить последние %d записей", state.settings.journalLimit))
                }
                .disabled(!state.settings.journalEnabled)
                HStack {
                    Hint("Журнал хранится только в памяти и пропадает при выходе из Раскладушки. По нему видно, почему слово было исправлено.")
                    Spacer()
                    Button("Очистить") { state.clearJournal() }.disabled(state.journal.isEmpty)
                }
            }
            Section("Последние замены") {
                if state.journal.isEmpty {
                    Text("Пока пусто.").foregroundStyle(.secondary)
                }
                ForEach(state.journal) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(Self.time.string(from: entry.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(entry.kind).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.app).font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.before.isEmpty || !entry.after.isEmpty {
                            Text(entry.before + " → " + entry.after).font(.body.monospaced()).lineLimit(2)
                        }
                        if !entry.reason.isEmpty {
                            Text(entry.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - О программе

private struct AboutTab: View {
    @EnvironmentObject private var state: AppState

    private var version: String {
        let info = Bundle.main.infoDictionary
        return L("Версия %@ (сборка %@)", info?["CFBundleShortVersionString"] as? String ?? "?",
                 info?["CFBundleVersion"] as? String ?? "?")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Раскладушка").font(.title2.bold())
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                Button("Показать знакомство ещё раз") { OnboardingWindow.show() }
                Link("Исходный код и новые версии на GitHub", destination: URL(string: "https://github.com/itbali/raskladushka")!)
            }
            UpdatesSection()
        }
        .formStyle(.grouped)
    }
}
