import SwiftUI

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Разрешить…", action: action) }
        }
    }
}

/// Кнопка записи сочетания клавиш.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    /// Модификаторы, зажатые без клавиши: если их отпустят как есть — это сочетание из одних модификаторов.
    @State private var held: NSEvent.ModifierFlags? = []
    /// Сочетание, которое нажали, но до окна оно не дошло: его забрала система.
    @State private var taken: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? L("Нажмите сочетание…") : combo.display) {
                recording ? stop() : start()
            }
            if let taken {
                Text(taken)
                    .font(.footnote).foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        held = []
        taken = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(KeyCombo.relevant)
            if event.type == .flagsChanged {
                if !flags.isEmpty {
                    held?.formUnion(flags)
                } else {
                    // Одного модификатора мало: ⇧ или ⌘ постоянно нажимают сами по себе.
                    if let held, held.rawValue.nonzeroBitCount >= 2 {
                        combo = KeyCombo(keyCode: KeyCombo.modifiersOnly, modifiers: held.rawValue)
                        stop()
                    }
                    held = []
                }
                return event
            }
            held = nil
            taken = nil
            if event.keyCode == 53 && flags.isEmpty { stop(); return nil }
            // Без ⌃, ⌥ или ⌘ сочетание мешало бы обычному набору.
            guard !flags.intersection([.control, .option, .command]).isEmpty else { NSSound.beep(); return nil }
            let pressed = KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue)
            // ⌘C и ⌘V Раскладушка нажимает сама, когда переводит выделение, ⌘Z — отмена замены.
            guard !(flags == .command && [6, 8, 9].contains(event.keyCode)) else {
                NSSound.beep()
                taken = L("%@ нужно самой Раскладушке и другим программам — выберите другое.", pressed.display)
                return nil
            }
            combo = pressed
            stop()
            return nil
        }
        // Перехватчик видит нажатие раньше системы. Если до окна оно так и не дошло — его забрала macOS
        // (Spotlight, смена языка, панель эмодзи), и назначить такое сочетание нельзя.
        AppState.shared.recordingProbe = { keyCode, cgFlags in
            let flags = KeyCombo.modifiers(cgFlags)
            guard !flags.intersection([.control, .option, .command]).isEmpty else { return }
            let pressed = KeyCombo(keyCode: keyCode, modifiers: flags.rawValue)
            held = nil
            if AppState.shared.capturing {
                // Нажатие забрал перехватчик — до окна оно не дойдёт, принимаем его здесь.
                guard recording else { return }
                if flags == .command && [6, 8, 9].contains(keyCode) {
                    NSSound.beep()
                    taken = L("%@ нужно самой Раскладушке и другим программам — выберите другое.", pressed.display)
                } else {
                    combo = pressed
                    stop()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if recording {
                    taken = L("%@ забирает сама macOS. Включите «Перехватывать системные сочетания» ниже или выберите другое.", pressed.display)
                }
            }
        }
    }

    private func stop() {
        recording = false
        AppState.shared.recordingProbe = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
