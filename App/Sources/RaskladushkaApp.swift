import SwiftUI

@main
struct RaskladushkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            MenuBarLabel().environmentObject(state)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
        AppState.shared.start()
        // При первом запуске показываем окно: оно объясняет, какие разрешения нужны и зачем.
        let arguments = CommandLine.arguments
        if arguments.contains("--render") {
            if arguments.contains("--onboarding") { OnboardingWindow.show() } else { SettingsWindow.show() }
        } else if !arguments.contains("--uitest"), !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            OnboardingWindow.show()
        }
    }

    /// Повторный запуск уже работающего приложения (например, из Launchpad) открывает настройки.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Значок в строке меню: клавиатура, буквы языка или флаг — как выбрано в настройках.
struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.needsPermissions {
            Image(systemName: "keyboard.badge.ellipsis")
        } else if state.isPaused {
            Image(systemName: "pause.circle")
        } else if state.flashing {
            Image(systemName: "checkmark.circle.fill")
        } else {
            switch state.settings.iconStyle {
            case .symbol:
                Image(systemName: (state.settings.autoSwitch || state.settings.hotkeyEnabled) ? "keyboard.fill" : "keyboard")
            case .letters:
                Text(LanguageBadge.letters(state.currentLanguage))
            case .flag:
                Text(LanguageBadge.flag(state.currentLanguage))
            }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var state: AppState

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        if state.needsPermissions {
            Button("⚠️ Нужны разрешения…") { SettingsWindow.show() }
            Divider()
        }
        if state.isPaused {
            Text(pauseTitle)
            Button("Продолжить работу") { state.resume() }
            Divider()
        }
        Toggle("Автопереключение раскладки", isOn: $state.settings.autoSwitch)
        Toggle(L("Перевод выделенного по %@", state.settings.combo.display), isOn: $state.settings.hotkeyEnabled)
        if let app = state.lastApp {
            Toggle(L("Не исправлять в «%@»", app.name),
                   isOn: Binding(get: { state.isExcluded(app.bundleID) },
                                 set: { _ in state.toggleExcluded(app.bundleID) }))
        }
        if !state.isPaused {
            Menu("Приостановить") {
                Button("На 5 минут") { state.pause(minutes: 5) }
                Button("На 30 минут") { state.pause(minutes: 30) }
                if ![5, 30].contains(state.settings.pauseMinutes) {
                    Button(L("На %d мин", state.settings.pauseMinutes)) { state.pause(minutes: state.settings.pauseMinutes) }
                }
                Button("До перезапуска Раскладушки") { state.pause(minutes: nil) }
            }
        }
        if state.settings.showStats {
            Divider()
            Text(L("Исправлено сегодня: %d · всего: %d", state.stats.today, state.stats.total))
        }
        Divider()
        Toggle("Запускать при входе в систему",
               isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
        #if DIRECT
        Button("Проверить обновления…") { Updater.shared.check() }
        #endif
        Button("Настройки…") { SettingsWindow.show() }
            .keyboardShortcut(",")
        Divider()
        Button("Завершить Раскладушку") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var pauseTitle: String {
        guard let until = state.pausedUntil, until != .distantFuture else { return L("Пауза до перезапуска") }
        return L("Пауза до %@", Self.time.string(from: until))
    }
}

/// Окно настроек. Создаётся вручную: у приложения без значка в Dock сцены SwiftUI сами не открываются.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let created = NSWindow(contentViewController: controller)
            created.title = L("Раскладушка")
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        AppState.shared.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
