import AppKit

/// Строка интерфейса на языке системы. Ключ — русский текст; перевод лежит в `en.lproj/Localizable.strings`.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Строка с подстановками: `L("Исправлено: %@", word)`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

/// Куда запоминать слово, автозамену которого отменили.
enum RememberUndone: String, Codable, CaseIterable, Identifiable {
    case everywhere, currentApp, nowhere
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everywhere: return L("Во всех приложениях")
        case .currentApp: return L("Только в приложении, где отменили")
        case .nowhere: return L("Не запоминать")
        }
    }
}

/// Что показывать в строке меню.
enum IconStyle: String, Codable, CaseIterable, Identifiable {
    case symbol, letters, flag
    var id: String { rawValue }
    var title: String {
        switch self {
        case .symbol: return L("Значок клавиатуры")
        case .letters: return L("Буквы языка (RU, EN)")
        case .flag: return L("Флаг языка")
        }
    }
}

/// Где показывать всплывающую подсказку о замене. Положение курсора в чужом поле узнать нельзя,
/// поэтому место — на выбор.
enum HudPosition: String, Codable, CaseIterable, Identifiable {
    case bottom, top, pointer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottom: return L("Внизу экрана")
        case .top: return L("Вверху экрана")
        case .pointer: return L("У указателя мыши")
        }
    }
}

/// Все настройки приложения. Хранятся одной записью; новые поля получают значения по умолчанию,
/// даже если сохранённая запись старше.
struct Settings: Codable, Equatable {
    // Основное
    var autoSwitch = true
    var mixedWords = true
    var contextAware = true
    var learnFrequent = true
    var learnThreshold = 3
    /// Слова, которые пользователь не раз переводил сам: как набрано → в какую раскладку переводить.
    var learned: [String: String] = [:]

    // Сочетания
    var hotkeyEnabled = true
    var combo = KeyCombo.default
    var overrideSystem = false
    var undoByCommandZ = true
    var undoByBackspace = true
    var redoEnabled = true
    var rememberUndone = RememberUndone.everywhere

    // Исключения
    var exceptions: [String] = []
    var appExceptions: [String: [String]] = [:]
    var excludedApps: [String] = []

    // Отклик
    var iconStyle = IconStyle.symbol
    var flashIcon = true
    var soundEnabled = false
    var soundName = "Tink"
    var hudEnabled = true
    var hudPosition = HudPosition.bottom
    var hudDuration = 2.0
    var hudForManual = false
    var showStats = true
    var notifyTapRestored = true

    // Журнал
    var journalEnabled = true
    var journalLimit = 50

    // Пауза и обновления
    var pauseMinutes = 60
    var autoUpdate = true

    static let sounds = ["Tink", "Pop", "Morse", "Bottle", "Frog", "Glass", "Ping", "Purr", "Submarine"]

    /// Читает сохранённые настройки, накладывая их на значения по умолчанию.
    static func load(from defaults: UserDefaults) -> Settings {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        guard let base = try? JSONSerialization.jsonObject(with: encoder.encode(Settings())) as? [String: Any] else {
            return Settings()
        }
        var merged = base
        if let data = defaults.data(forKey: "settings"),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in saved where base[key] != nil { merged[key] = value }
        } else {
            // Настройки версий до 1.2 лежали отдельными записями.
            if defaults.object(forKey: "autoSwitch") != nil { merged["autoSwitch"] = defaults.bool(forKey: "autoSwitch") }
            if defaults.object(forKey: "hotkeyEnabled") != nil { merged["hotkeyEnabled"] = defaults.bool(forKey: "hotkeyEnabled") }
            if defaults.object(forKey: "overrideSystem") != nil { merged["overrideSystem"] = defaults.bool(forKey: "overrideSystem") }
            if let data = defaults.data(forKey: "combo"), let combo = try? JSONSerialization.jsonObject(with: data) {
                merged["combo"] = combo
            }
            if let words = defaults.stringArray(forKey: "exceptions") { merged["exceptions"] = words }
            if let apps = defaults.stringArray(forKey: "excludedApps") { merged["excludedApps"] = apps }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? decoder.decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "settings") }
    }
}

/// Счётчики исправлений. Сами слова сюда не попадают — только числа.
struct Stats: Codable, Equatable {
    var total = 0
    var today = 0
    var manual = 0
    var day = ""

    static func currentDay() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    mutating func rollDay() {
        let now = Self.currentDay()
        if day != now { day = now; today = 0 }
    }
}

/// Запись журнала замен. Журнал живёт только в памяти и пропадает при выходе из приложения.
struct JournalEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: String
    let before: String
    let after: String
    let reason: String
    let app: String
}
