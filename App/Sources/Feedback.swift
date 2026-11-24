import AppKit
import AVFoundation
import SwiftUI

/// Всплывающая подсказка поверх всех окон: «Исправлено: привет · ⌘Z — вернуть».
/// Фокус не забирает и щелчки пропускает сквозь себя.
final class Hud {
    static let shared = Hud()
    private var panel: NSPanel?
    private var generation = 0
    /// Размер и контраст — из настроек «Доступность».
    var scale = 1.0
    var highContrast = false

    var isVisible: Bool { panel?.isVisible ?? false }
    var height: CGFloat { panel?.frame.height ?? 0 }

    func show(_ text: String, position: HudPosition, duration: Double) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Системные настройки доступности важнее наших: контраст, непрозрачность, отказ от анимации.
        let workspace = NSWorkspace.shared
        let contrast = highContrast || workspace.accessibilityDisplayShouldIncreaseContrast
        let solid = contrast || workspace.accessibilityDisplayShouldReduceTransparency
        let still = workspace.accessibilityDisplayShouldReduceMotion
        let host = NSHostingView(rootView: HudView(text: text, scale: scale, contrast: contrast, solid: solid))
        let size = host.fittingSize
        panel.contentView = host
        panel.setFrame(frame(size: size, position: position), display: true)
        generation += 1
        let mine = generation
        panel.alphaValue = still ? 1 : 0
        panel.orderFrontRegardless()
        if !still { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == mine else { return }
            guard !still else { panel.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { if self.generation == mine { panel.orderOut(nil) } })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func frame(size: NSSize, position: HudPosition) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var origin: NSPoint
        switch position {
        case .bottom:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 90)
        case .top:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
        case .pointer:
            origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 14)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }
}

private struct HudView: View {
    let text: String
    let scale: Double
    /// Чёрное на белом (или наоборот) с толстой рамкой.
    let contrast: Bool
    /// Сплошной фон вместо полупрозрачного.
    let solid: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14 * scale, weight: contrast ? .bold : .medium))
            .foregroundStyle(contrast ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 9 * scale)
            .background(background)
            .overlay(Capsule().strokeBorder(.primary.opacity(contrast ? 1 : 0.12), lineWidth: contrast ? 2 : 1))
            .fixedSize()
    }

    @ViewBuilder private var background: some View {
        if contrast {
            Capsule().fill(Color.primary)
        } else if solid {
            Capsule().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

/// Проговаривает исправления вслух. Если включён VoiceOver, берёт его голос и скорость.
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()
    /// Для проверок: что сказали последним и не издавать ли звук на самом деле.
    private(set) var lastSpoken: String?
    var muted = false

    /// `language` — язык текста («ru», «en-US»); без него говорит голос системы.
    func speak(_ text: String, language: String?) {
        let text = String(text.prefix(80))
        lastSpoken = text
        guard !muted, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        if let language, let voice = Self.voice(for: language) { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language) { return exact }
        let base = LanguageBadge.base(language)
        return AVSpeechSynthesisVoice.speechVoices().first { LanguageBadge.base($0.language) == base }
    }
}

enum Sounds {
    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.play()
    }
}

/// Флаг и буквы для языка раскладки — для значка в строке меню.
enum LanguageBadge {
    private static let flags: [String: String] = [
        "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾", "kk": "🇰🇿", "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸",
        "it": "🇮🇹", "pt": "🇵🇹", "pl": "🇵🇱", "cs": "🇨🇿", "tr": "🇹🇷", "he": "🇮🇱", "el": "🇬🇷", "ka": "🇬🇪",
        "hy": "🇦🇲", "bg": "🇧🇬", "sr": "🇷🇸", "nl": "🇳🇱", "sv": "🇸🇪", "fi": "🇫🇮", "nb": "🇳🇴", "da": "🇩🇰",
    ]

    static func base(_ language: String) -> String {
        String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    static func letters(_ language: String) -> String { base(language).uppercased() }

    /// Флаг, а если для языка его нет — буквы.
    static func flag(_ language: String) -> String { flags[base(language)] ?? letters(language) }
}
