import SwiftUI

@main
struct RaskladushkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            Image(systemName: state.needsPermissions ? "keyboard.badge.ellipsis"
                  : (state.autoSwitchEnabled || state.hotkeyEnabled) ? "keyboard.fill" : "keyboard")
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
        if !UserDefaults.standard.bool(forKey: "launchedBefore") || CommandLine.arguments.contains("--render") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            SettingsWindow.show()
        }
    }

    /// Повторный запуск уже работающего приложения (например, из Launchpad) открывает настройки.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuContent: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.needsPermissions {
            Button("⚠️ Нужны разрешения…") { showSettings() }
            Divider()
        }
        Toggle("Автопереключение раскладки", isOn: $state.autoSwitchEnabled)
        Toggle(String(format: NSLocalizedString("Перевод выделенного по %@", comment: ""), state.combo.display),
               isOn: $state.hotkeyEnabled)
        if let app = state.lastApp {
            Toggle(String(format: NSLocalizedString("Не исправлять в «%@»", comment: ""), app.name),
                   isOn: Binding(get: { state.isExcluded(app.bundleID) },
                                 set: { _ in state.toggleExcluded(app.bundleID) }))
        }
        Divider()
        Toggle("Запускать при входе в систему",
               isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
        Button("Настройки…") { showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Завершить Раскладушку") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showSettings() {
        SettingsWindow.show()
    }
}

/// Окно настроек. Создаётся вручную: у приложения без значка в Dock сцены SwiftUI сами не открываются.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let created = NSWindow(contentViewController: controller)
            created.title = NSLocalizedString("Раскладушка", comment: "")
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
