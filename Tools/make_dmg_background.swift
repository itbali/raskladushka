// Рисует фон окна установочного образа: swift Tools/make_dmg_background.swift Design/dmg-background.png
// Окно 600×460 точек; значок приложения встаёт слева (150, 215), папка «Программы» справа (450, 215).
// Высота с запасом: у кого в Finder включены строка пути и строка состояния, те съедают низ окна.
// Картинка сохраняется в двойном разрешении и помечается как 144 dpi — Finder показывает её чётко.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: make_dmg_background <out.png>") }
let width = 600, height = 460, scale = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
                    NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)])!.draw(in: bounds, angle: -90)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ])
    attributed.draw(in: NSRect(x: 0, y: y, width: CGFloat(width), height: size * 1.5))
}

let ink = NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.3, alpha: 1)
text("Раскладушка", size: 26, weight: .bold, color: ink, y: 392)
text("Перетащите значок на папку «Программы»", size: 14, weight: .regular, color: ink.withAlphaComponent(0.7), y: 366)

// Стрелка от значка приложения к папке.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 236, y: 245))
arrow.line(to: NSPoint(x: 356, y: 245))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
let head = NSBezierPath()
head.move(to: NSPoint(x: 342, y: 261))
head.line(to: NSPoint(x: 362, y: 245))
head.line(to: NSPoint(x: 342, y: 229))
head.lineWidth = 6
head.lineCapStyle = .round
head.lineJoinStyle = .round
ink.withAlphaComponent(0.35).setStroke()
arrow.stroke()
head.stroke()

// Английская подпись — сразу под русской: низ окна у многих закрыт строками Finder.
text("Drag the icon onto the Applications folder", size: 12, weight: .regular, color: ink.withAlphaComponent(0.5), y: 344)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
