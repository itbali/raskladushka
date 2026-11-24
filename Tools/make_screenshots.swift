// Собирает четыре скриншота для App Store (2880×1800, без альфа-канала):
// swift Tools/make_screenshots.swift <папка фонов> <окно настроек.png> <иконка.png> <ru|en> <папка результата>
import AppKit

let args = CommandLine.arguments
guard args.count == 6, let settings = NSImage(contentsOfFile: args[2]), let icon = NSImage(contentsOfFile: args[3]) else {
    fatalError("usage: make_screenshots <backgrounds> <window.png> <icon.png> <ru|en> <outdir>")
}
let ru = args[4] == "ru"
let W: CGFloat = 2880, H: CGFloat = 1800
func t(_ r: String, _ e: String) -> String { ru ? r : e }
let ink = NSColor(red: 0.13, green: 0.11, blue: 0.36, alpha: 1)
let glass = NSColor.white.withAlphaComponent(0.16)
let soft = NSColor.white.withAlphaComponent(0.88)

// MARK: Примитивы

@discardableResult
func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, mono: Bool = false,
          at point: NSPoint, width: CGFloat = 2400, align: NSTextAlignment = .left, strike: Bool = false, draw: Bool = true) -> NSSize {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.04
    style.alignment = align
    var attributes: [NSAttributedString.Key: Any] = [
        .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style,
    ]
    if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if color == .white || color == soft {
        // Белый текст поверх светлых клавиш фона должен оставаться читаемым.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.05, green: 0.03, blue: 0.3, alpha: 0.75)
        shadow.shadowBlurRadius = size * 0.22
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.03)
        attributes[.shadow] = shadow
    }
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 3000), options: [.usesLineFragmentOrigin])
    if draw {
        attributed.draw(with: NSRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                        options: [.usesLineFragmentOrigin])
    }
    return bounds.size
}

func shadowed(_ path: NSBezierPath, fill: NSColor, blur: CGFloat = 80, dy: CGFloat = -30, alpha: CGFloat = 0.4) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: dy)
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func image(_ img: NSImage, in rect: NSRect, radius: CGFloat = 0, shadow: Bool = false) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if shadow { shadowed(path, fill: .white) }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

/// Плашка с текстом; возвращает правый край.
@discardableResult
func pill(_ string: String, at origin: NSPoint, size: CGFloat = 104, fill: NSColor, color: NSColor, mono: Bool = true,
          strike: Bool = false, padX: CGFloat = 56, padY: CGFloat = 30, radius: CGFloat = 46) -> NSRect {
    let s = text(string, size: size, weight: .semibold, color: color, mono: mono, at: .zero, strike: strike, draw: false)
    let rect = NSRect(x: origin.x, y: origin.y, width: s.width + padX * 2, height: s.height + padY * 2)
    shadowed(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), fill: fill, blur: 40, dy: -14, alpha: 0.25)
    text(string, size: size, weight: .semibold, color: color, mono: mono, at: NSPoint(x: rect.minX + padX, y: rect.maxY - padY), strike: strike)
    return rect
}

/// Клавиша; возвращает правый край.
func keycap(_ label: String, at origin: NSPoint, height: CGFloat = 150) -> CGFloat {
    let s = text(label, size: 64, weight: .semibold, color: ink, at: .zero, draw: false)
    let rect = NSRect(x: origin.x, y: origin.y, width: max(height, s.width + 80), height: height)
    shadowed(NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -12), xRadius: 30, yRadius: 30), fill: NSColor(white: 0.78, alpha: 1), blur: 30, dy: -12, alpha: 0.35)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
    text(label, size: 64, weight: .semibold, color: ink, at: NSPoint(x: rect.minX, y: rect.midY + s.height / 2), width: rect.width, align: .center)
    return rect.maxX
}

func brand(at origin: NSPoint) {
    image(icon, in: NSRect(x: origin.x, y: origin.y, width: 170, height: 170), radius: 38, shadow: true)
    text(t("Раскладушка", "Raskladushka"), size: 76, weight: .semibold, at: NSPoint(x: origin.x + 210, y: origin.y + 130))
}

func symbol(_ name: String, size: CGFloat, color: NSColor, at point: NSPoint) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))) else { return }
    img.draw(at: NSPoint(x: point.x, y: point.y), from: .zero, operation: .sourceOver, fraction: 1)
}

func render(_ name: String, background: String, _ body: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let bg = NSImage(contentsOfFile: "\(args[1])/\(background).png")!
    // Фон 16:10 с запасом по высоте: заполняем кадр, обрезая лишнее сверху и снизу.
    let scale = max(W / bg.size.width, H / bg.size.height)
    let size = NSSize(width: bg.size.width * scale, height: bg.size.height * scale)
    bg.draw(in: NSRect(x: (W - size.width) / 2, y: (H - size.height) / 2, width: size.width, height: size.height))
    body()
    let flat = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    flat.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: W, height: H))
    let out = URL(fileURLWithPath: args[5]).appendingPathComponent("\(name)-\(args[4]).png")
    try! NSBitmapImageRep(cgImage: flat.makeImage()!).representation(using: .png, properties: [:])!.write(to: out)
}

// MARK: 1. Главный

render("01-hero", background: "bg1") {
    brand(at: NSPoint(x: 200, y: 1430))
    text(t("Забыли переключить\nраскладку?", "Forgot to switch\nthe keyboard layout?"), size: 150, weight: .bold, at: NSPoint(x: 200, y: 1300), width: 2000)
    let a = pill("ghbdtn", at: NSPoint(x: 200, y: 640), size: 120, fill: glass, color: NSColor.white.withAlphaComponent(0.7), strike: true)
    text("→", size: 130, weight: .semibold, at: NSPoint(x: a.maxX + 50, y: a.midY + 85))
    pill("привет", at: NSPoint(x: a.maxX + 240, y: 640), size: 120, fill: .white, color: ink)
    text(t("Раскладушка сама исправит слово после пробела\nи переключит язык.",
           "Raskladushka fixes the word after you press Space\nand switches the language for you."),
         size: 64, color: soft, at: NSPoint(x: 200, y: 520), width: 2000)
}

// MARK: 2. Выделение

render("02-selection", background: "bg2") {
    text(t("Выделите текст — и одно сочетание клавиш", "Select text — one shortcut fixes it"), size: 112, weight: .bold,
         at: NSPoint(x: 0, y: 1590), width: W, align: .center)
    var x = W / 2 - 430
    for key in ["⌃", "⇧", "Space"] { x = keycap(key, at: NSPoint(x: x, y: 1180)) + 36 }

    func card(_ body: String, y: CGFloat, highlighted: Bool, caption: String) {
        let rect = NSRect(x: 520, y: y, width: 1840, height: 300)
        shadowed(NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44), fill: .white)
        text(caption, size: 44, weight: .medium, color: NSColor(white: 0.55, alpha: 1), at: NSPoint(x: rect.minX + 70, y: rect.maxY - 44))
        let s = text(body, size: 92, weight: .medium, color: ink, at: .zero, draw: false)
        if highlighted {
            NSColor(red: 0.70, green: 0.82, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 56, y: rect.minY + 52, width: s.width + 28, height: s.height + 12), xRadius: 12, yRadius: 12).fill()
        }
        text(body, size: 92, weight: .medium, color: ink, at: NSPoint(x: rect.minX + 70, y: rect.minY + 58 + s.height))
    }
    card("Ghbdtn? rfr ltkf&", y: 760, highlighted: true, caption: t("Было", "Before"))
    text("↓", size: 110, weight: .semibold, at: NSPoint(x: 0, y: 745), width: W, align: .center)
    card("Привет, как дела?", y: 290, highlighted: false, caption: t("Стало", "After"))
    text(t("Работает и с последним набранным словом. Сочетание можно сменить.",
           "Works for the last typed word too. The shortcut is customizable."),
         size: 54, color: soft, at: NSPoint(x: 0, y: 215), width: W, align: .center)
}

// MARK: 3. Меню и настройки

render("03-menu", background: "bg3") {
    text(t("Живёт в строке меню", "Lives in your menu bar"), size: 128, weight: .bold, at: NSPoint(x: 0, y: 1640), width: W, align: .center)
    text(t("Включайте и выключайте функции в один клик", "Turn features on and off in one click"),
         size: 62, color: soft, at: NSPoint(x: 0, y: 1470), width: W, align: .center)

    // Меню приложения (те же пункты, что в настоящем меню).
    let items: [(String, Bool?)] = [
        (t("Автопереключение раскладки", "Auto-switch keyboard layout"), true),
        (t("Перевод выделенного по ⌃⇧Space", "Convert selection with ⌃⇧Space"), true),
        (t("Не исправлять в «Терминал»", "Don’t correct in “Terminal”"), false),
        ("-", nil),
        (t("Запускать при входе в систему", "Launch at login"), false),
        (t("Настройки…", "Settings…"), nil),
        ("-", nil),
        (t("Завершить Раскладушку", "Quit Raskladushka"), nil),
    ]
    let menu = NSRect(x: 250, y: 330, width: 1080, height: 800)
    let tab = NSRect(x: menu.minX + 60, y: menu.maxY + 26, width: 130, height: 104)
    shadowed(NSBezierPath(roundedRect: tab, xRadius: 26, yRadius: 26), fill: NSColor.white.withAlphaComponent(0.28), blur: 20, dy: -6, alpha: 0.2)
    symbol("keyboard.fill", size: 58, color: .white, at: NSPoint(x: tab.minX + 22, y: tab.minY + 26))
    shadowed(NSBezierPath(roundedRect: menu, xRadius: 36, yRadius: 36), fill: NSColor(white: 0.97, alpha: 1))
    var y = menu.maxY - 50
    for (title, checked) in items {
        if title == "-" {
            NSColor(white: 0.82, alpha: 1).setFill()
            NSRect(x: menu.minX + 40, y: y - 22, width: menu.width - 80, height: 3).fill()
            y -= 46
            continue
        }
        if checked == true { symbol("checkmark", size: 40, color: ink, at: NSPoint(x: menu.minX + 44, y: y - 76)) }
        text(title, size: 54, weight: .regular, color: NSColor(white: 0.1, alpha: 1), at: NSPoint(x: menu.minX + 116, y: y - 14))
        y -= 106
    }

    let rep = settings.representations[0]
    // Окно настроек с вкладками шире прежнего — вписываем его в ту же ширину, чтобы не закрыть меню слева.
    let scale: CGFloat = min(1.16, 1114 / CGFloat(rep.pixelsWide))
    let size = NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
    image(settings, in: NSRect(x: W - size.width - 250, y: 1230 - size.height + 100, width: size.width, height: size.height), radius: 30, shadow: true)
}

// MARK: 4. Конфиденциальность

render("04-privacy", background: "bg4") {
    brand(at: NSPoint(x: 200, y: 1430))
    text(t("Ничего не уходит\nс вашего Mac", "Nothing ever leaves\nyour Mac"), size: 150, weight: .bold, at: NSPoint(x: 200, y: 1300), width: 1900)
    let points = [
        ("wifi.slash", t("Без доступа к сети", "No network access")),
        ("hand.raised.fill", t("Данные не собираются", "No data collected")),
        ("memorychip", t("Нажатия живут только в памяти", "Keystrokes stay in memory only")),
        ("lock.fill", t("Поля паролей не видны", "Password fields are never seen")),
    ]
    var y: CGFloat = 800
    for (name, title) in points {
        let chip = NSRect(x: 200, y: y - 104, width: 120, height: 120)
        glass.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 32, yRadius: 32).fill()
        symbol(name, size: 52, color: .white, at: NSPoint(x: chip.minX + 28, y: chip.minY + 30))
        text(title, size: 70, weight: .medium, at: NSPoint(x: 370, y: y))
        y -= 160
    }
}
