import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

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

            if !state.exceptions.isEmpty {
                Section("Слова-исключения") {
                    ForEach(state.exceptions, id: \.self) { word in
                        HStack {
                            Text(word).font(.body.monospaced())
                            Spacer()
                            Button { state.exceptions.removeAll { $0 == word } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Text("Сюда попадают слова, автозамену которых вы отменили сочетанием клавиш или ⌘Z.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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

    var body: some View {
        Button(recording ? LocalizedStringKey("Нажмите сочетание…") : LocalizedStringKey(combo.display)) {
            recording ? stop() : start()
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(KeyCombo.relevant)
            if event.keyCode == 53 && flags.isEmpty { stop(); return nil }
            // Без ⌃, ⌥ или ⌘ сочетание мешало бы обычному набору.
            guard !flags.intersection([.control, .option, .command]).isEmpty else { NSSound.beep(); return nil }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
