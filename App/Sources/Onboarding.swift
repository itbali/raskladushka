import SwiftUI

/// Знакомство при первом запуске: что делает программа, какое разрешение нужно и живая проба.
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = NSHostingController(rootView: OnboardingView().environmentObject(AppState.shared))
            let created = NSWindow(contentViewController: controller)
            created.title = L("Знакомство с Раскладушкой")
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @State private var step = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Что набрать и что должно получиться — зависит от того, какая раскладка сейчас включена.
    private var demo: (type: String, expect: String) {
        LanguageBadge.base(state.currentLanguage) == "ru" ? ("руддщ", "hello") : ("ghbdtn", "привет")
    }

    private var solved: Bool { text.lowercased().contains(demo.expect) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Раскладушка").font(.largeTitle.bold())
                    Text("Исправляет текст, набранный не в той раскладке").foregroundStyle(.secondary)
                }
            }
            Divider()
            switch step {
            case 0: permissions
            case 1: tryIt
            default: done
            }
            Spacer(minLength: 0)
            HStack {
                Text(L("Шаг %d из 3", step + 1)).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("Назад") { step -= 1 } }
                if step < 2 {
                    Button(step == 1 && !solved ? L("Пропустить") : L("Дальше")) { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 0 && !state.canPostEvents)
                } else {
                    Button("Готово") { OnboardingWindow.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сначала — одно разрешение").font(.title3.bold())
            Text("Чтобы стереть слово в неверной раскладке и напечатать его заново, Раскладушке нужно разрешение «Универсальный доступ». Нажатия обрабатываются только в памяти вашего Mac и никуда не отправляются.")
                .fixedSize(horizontal: false, vertical: true)
            PermissionRow(title: "Управление клавиатурой",
                          detail: "Системные настройки → Конфиденциальность и безопасность → Универсальный доступ.",
                          granted: state.canPostEvents) { state.requestPostAccess() }
            if state.layoutCount < 2 {
                Label("Добавьте вторую раскладку в настройках клавиатуры macOS.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if state.canPostEvents {
                Label("Разрешение есть — можно пробовать.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Попробуйте прямо здесь").font(.title3.bold())
            Text(L("Не переключая язык, наберите в поле ниже «%@» и нажмите пробел.", demo.type))
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $text, prompt: Text(demo.type))
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospaced())
                .focused($focused)
                .onAppear { focused = true }
            if solved {
                Label(L("Получилось «%@» — раскладка переключилась сама.", demo.expect), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Если замена не нужна, сразу нажмите ⌘Z или Backspace — слово вернётся, а Раскладушка запомнит его как исключение.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Слово исправится после пробела. Если ничего не происходит — проверьте разрешение на предыдущем шаге.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что ещё умеет Раскладушка").font(.title3.bold())
            Label(L("%@ — перевести выделенный текст или последнее слово", state.settings.combo.display), systemImage: "command")
            Label("⌘Z или Backspace сразу после замены — вернуть как было", systemImage: "arrow.uturn.backward")
            Label("Значок в строке меню — пауза, исключения и настройки", systemImage: "menubar.arrow.up.rectangle")
            Toggle("Запускать при входе в систему",
                   isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                .padding(.top, 6)
            Button("Открыть настройки") { OnboardingWindow.close(); SettingsWindow.show() }
        }
    }
}
