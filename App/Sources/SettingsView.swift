import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var newException = ""

    var body: some View {
        Form {
            Section {
                Toggle("Автопереключение раскладки", isOn: $state.autoSwitchEnabled)
                Text("Если слово набрано не в той раскладке, после пробела оно будет исправлено, а раскладка переключится.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Перевод выделенного текста и последнего слова", isOn: $state.hotkeyEnabled)
                LabeledContent("Сочетание клавиш") {
                    ShortcutRecorder(combo: $state.combo)
                }
                if state.hotkeyEnabled && !state.hotkeyRegistered {
                    Label("Это сочетание занято другой программой — выберите другое.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Toggle("Перехватывать системные сочетания", isOn: $state.overrideSystem)
                    .disabled(!state.hotkeyEnabled)
                Text("Позволяет назначить сочетание, занятое самой macOS: ⌘Space, ⌃Space и подобные. Раскладушка заберёт его себе, и системное действие (Spotlight, смена языка) по нему больше не сработает, пока она запущена.")
                    .font(.footnote).foregroundStyle(.secondary)
                if state.overrideSystem && state.hotkeyEnabled && !state.capturing {
                    Label("Перехват не включился: нужно разрешение «Универсальный доступ».", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("Нажмите сочетание сразу после слова, чтобы перевести его или отменить автозамену. Если текст выделен — будет переведено выделение. Любую замену сразу после неё отменяет ⌘Z.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Запускать при входе в систему",
                       isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            }

            Section("Разрешения") {
                PermissionRow(title: "Управление клавиатурой",
                              detail: "Нужно, чтобы стереть слово в неверной раскладке и напечатать его заново. Раздел «Универсальный доступ» в настройках.",
                              granted: state.canPostEvents) { state.requestPostAccess() }
                if !state.canPostEvents {
                    HStack {
                        Text("Раскладушки нет в списке? Нажмите «+» под списком и выберите приложение — или перетащите его туда из Finder.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Показать в Finder") { state.revealInFinder() }
                    }
                }
                if !state.tapRunning && state.canPostEvents && (state.autoSwitchEnabled || state.hotkeyEnabled) || state.canListenEvents {
                    PermissionRow(title: "Мониторинг ввода",
                                  detail: "Нужно, чтобы заметить слово, набранное не в той раскладке.",
                                  granted: state.canListenEvents) { state.requestListenAccess() }
                }
                if state.layoutCount < 2 {
                    Label("Добавьте вторую раскладку в настройках клавиатуры macOS.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("Нажатия обрабатываются только в памяти вашего Mac: ничего не сохраняется и никуда не отправляется. Поля паролей не затрагиваются.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Слова-исключения") {
                    ForEach(state.exceptions, id: \.self) { word in
                        HStack {
                            Text(word).font(.body.monospaced())
                            Spacer()
                            Button { state.exceptions.removeAll { $0 == word } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Слово", text: $newException, prompt: Text("слово, как вы его набираете"))
                            .labelsHidden().font(.body.monospaced())
                            .onSubmit(addException)
                        Button("Добавить", action: addException)
                            .disabled(exceptionToAdd == nil)
                    }
                    Text("Эти слова Раскладушка не исправляет. Сюда же попадают слова, автозамену которых вы отменили сочетанием клавиш или ⌘Z.")
                        .font(.footnote).foregroundStyle(.secondary)
            }

            if !state.excludedApps.isEmpty {
                Section("Приложения без исправлений") {
                    ForEach(state.excludedApps, id: \.self) { bundleID in
                        HStack {
                            Text(appName(bundleID))
                            Spacer()
                            Button { state.toggleExcluded(bundleID) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Слово из поля ввода, если его можно добавить: одно слово, которого ещё нет в списке.
    private var exceptionToAdd: String? {
        let word = newException.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !word.contains(where: \.isWhitespace), !state.exceptions.contains(word) else { return nil }
        return word
    }

    private func addException() {
        guard let word = exceptionToAdd else { return }
        state.exceptions.append(word)
        newException = ""
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}

private struct PermissionRow: View {
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
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    /// Модификаторы, зажатые без клавиши: если их отпустят как есть — это сочетание из одних модификаторов.
    @State private var held: NSEvent.ModifierFlags? = []
    /// Сочетание, которое нажали, но до окна оно не дошло: его забрала система.
    @State private var taken: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(recording ? LocalizedStringKey("Нажмите сочетание…") : LocalizedStringKey(combo.display)) {
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
                taken = "\(pressed.display) нужно самой Раскладушке и другим программам — выберите другое."
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
                    taken = "\(pressed.display) нужно самой Раскладушке и другим программам — выберите другое."
                } else {
                    combo = pressed
                    stop()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if recording {
                    taken = "\(pressed.display) забирает сама macOS. Включите «Перехватывать системные сочетания» ниже или выберите другое."
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
