import AppKit

/// Пункт «Перевести раскладку» в системном меню «Службы» и по правому щелчку на выделенном тексте.
/// Выделенный текст приложению передаёт сама macOS и сама же вставляет ответ на его место —
/// поэтому служба не требует никаких разрешений и работает даже без «Универсального доступа».
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()
    /// Имя порта — то же, что записано в `NSServices` в Info.plist: по нему система находит службу.
    static let portName: String = {
        let services = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]]
        return services?.first?["NSPortName"] as? String ?? "Raskladushka"
    }()
    /// Сколько раз служба отработала в этом процессе — для проверок.
    private(set) var handled = 0

    func register() {
        NSApp.servicesProvider = self
        NSRegisterServicesProvider(self, Self.portName)
        NSUpdateDynamicServices()
    }

    @objc func convertLayout(_ pasteboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
              let converted = AppState.shared.convertForService(text) else {
            error.pointee = L("В выделенном тексте нечего переводить.") as NSString
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)
        handled += 1
    }
}
