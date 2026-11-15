import SwiftUI
#if DIRECT
import Sparkle

/// Автообновление сборки с GitHub. Проверяет список версий раз в день и по кнопке.
final class Updater {
    static let shared = Updater()
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    var automatic: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { if controller.updater.automaticallyChecksForUpdates != newValue { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    func check() {
        // У приложения нет значка в Dock — без этого окно обновления окажется под другими окнами.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
#endif

/// Раздел «Обновления» на вкладке «О программе».
/// Сборка для App Store обновляется самим магазином и в сеть не выходит.
/// Сборка с GitHub (флаг `DIRECT`) проверяет новые версии сама.
struct UpdatesSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Обновления") {
            #if DIRECT
            Toggle("Проверять обновления автоматически", isOn: $state.settings.autoUpdate)
            Button("Проверить сейчас") { Updater.shared.check() }
            Text("Раз в день Раскладушка спрашивает у GitHub, не вышла ли новая версия. Больше она в сеть ни за чем не выходит.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            #else
            Text("Эта сборка обновляется через App Store и в сеть не выходит.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }
}
