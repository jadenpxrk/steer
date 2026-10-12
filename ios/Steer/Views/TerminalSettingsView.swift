import SwiftUI

struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @State private var showingNewShortcut = false

    var body: some View {
        List {
                Section("Appearance") {
                    HStack {
                        Text("Font size")
                        Slider(value: $settings.preferences.fontSize, in: 10...28, step: 1)
                        Text(settings.preferences.fontSize, format: .number.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                    Picker("Font", selection: $settings.preferences.fontName) {
                        ForEach(TerminalFontRegistry.builtIn) { font in
                            Text(font.title).tag(font.postScriptName)
                        }
                    }
                    Picker("CJK fallback", selection: $settings.preferences.cjkLanguage) {
                        Text("Automatic").tag("")
                        Text("Korean").tag("ko")
                        Text("Japanese").tag("ja")
                        Text("Simplified Chinese").tag("zh-Hans")
                        Text("Traditional Chinese").tag("zh-Hant")
                    }
                    Toggle("Font ligatures", isOn: $settings.preferences.ligaturesEnabled)
                        .tint(.green)
                    Picker("Theme", selection: Binding(get: { settings.preferences.theme }, set: { settings.preferences.theme = $0; settings.preferences.customPalette = nil })) {
                        ForEach(TerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    ThemeFileControls()
                    Picker("Cursor", selection: $settings.preferences.cursor) {
                        ForEach(TerminalCursor.allCases) { cursor in
                            Text(cursor.title).tag(cursor)
                        }
                    }
                    Toggle("Blink cursor", isOn: $settings.preferences.cursorBlinks)
                        .tint(.green)
                    Toggle("Glass toolbar", isOn: $settings.preferences.glassToolbar)
                        .tint(.green)
                }

                Section("Keyboard") {
                    Toggle("Option acts as Meta", isOn: $settings.preferences.optionAsMeta)
                        .tint(.green)
                    Toggle("Hide toolbar with hardware keyboard", isOn: $settings.preferences.hideToolbarWithHardwareKeyboard)
                        .tint(.green)
                    Toggle("Keep screen awake", isOn: $settings.preferences.keepScreenOn)
                        .tint(.green)
                    Toggle("Reopen last terminal", isOn: $settings.preferences.reopenLastTerminal)
                        .tint(.green)
                    Picker("Scrollback lines", selection: $settings.preferences.scrollbackLines) {
                        ForEach([1_000, 10_000, 50_000, 100_000], id: \.self) { Text($0, format: .number).tag($0) }
                    }
                }

                Section("Attention") {
                    Toggle("Terminal notifications", isOn: Binding(
                        get: { settings.preferences.notificationsEnabled },
                        set: { enabled in
                            Task { await settings.setNotificationsEnabled(enabled) }
                        }
                    ))
                    .tint(.green)
                    Text("Notifies when a Herdr agent asks for permission or finishes a turn, and on a connection drop or terminal bell. Nothing runs on the host, so alerts stop once iOS suspends Steer in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Security") {
                    AppLockSetting()
                }

                Section("Remote shell") {
                    Toggle("STEER_CLIENT env", isOn: $settings.preferences.exportClientFlag)
                    Text("Exports STEER_CLIENT=1 into new remote shells over SSH, Mosh, and ET, so shell startup files, tmux config, or scripts can detect Steer. Applies to the next connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Dictation") {
                    NavigationLink("Language, Models, and History") { SpeechSettingsView() }
                }

                Section("Gestures") {
                    Toggle("Pinch to resize text", isOn: $settings.preferences.pinchToResizeFont)
                        .tint(.green)
                    ForEach(TerminalGesture.allCases) { gesture in
                        Picker(gesture.title, selection: Binding(
                            get: { settings.preferences.action(for: gesture) },
                            set: { settings.preferences.gestureBindings[gesture.rawValue] = $0 }
                        )) {
                            ForEach(TerminalGestureAction.builtIn, id: \.self) { Text($0.title).tag($0) }
                            ForEach(settings.preferences.customShortcuts) { shortcut in
                                Text(shortcut.label).tag(TerminalGestureAction.shortcut(shortcut.id))
                            }
                        }
                    }
                }

                Section("Toolbar") {
                    ForEach(settings.preferences.toolbarActions) { action in
                        Label(action.title, systemImage: action.systemImage ?? "keyboard")
                    }
                    .onMove(perform: settings.moveToolbarActions)
                    .onDelete(perform: settings.removeToolbarActions)

                    Menu("Add button", systemImage: "plus") {
                        ForEach(availableToolbarActions) { action in
                            Button(action.title) {
                                settings.addToolbarAction(action)
                            }
                        }
                    }
                    .disabled(availableToolbarActions.isEmpty)
                }

                Section("Custom shortcuts") {
                    ForEach(settings.preferences.customShortcuts) { shortcut in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.label)
                            Text(shortcut.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .onDelete(perform: settings.removeShortcuts)

                    Button("Add shortcut", systemImage: "plus") {
                        showingNewShortcut = true
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .steerChrome()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showingNewShortcut) {
                NewTerminalShortcutView()
            }
    }

    private var availableToolbarActions: [TerminalToolbarAction] {
        TerminalToolbarAction.allCases.filter { !settings.preferences.toolbarActions.contains($0) }
    }
}

private struct NewTerminalShortcutView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var text = ""
    @State private var appendReturn = true
    @State private var keySequence = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $label)
                TextField("Text or command", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Advanced binding", isOn: $keySequence)
                    .tint(.green)
                if keySequence {
                    Text("Keystrokes separated by commas: C-b, S-t sends the tmux prefix then Shift+T; F12, h uses a function-key prefix. Modifiers: C- (Ctrl), M- (Opt/Alt), S- (Shift). Keys: Tab, Enter, Esc, Space, BSpace, arrows, Home, End, PageUp, PageDown, F1–F12, dash, plus. text:/clear sends text.")
                        .font(.caption).foregroundStyle(.secondary)
                    if (try? TerminalBinding.steps(text)) == nil {
                        Text("The binding contains an unknown key or modifier.").foregroundStyle(.red)
                    }
                }
                Toggle("Press Return after sending", isOn: $appendReturn)
                    .tint(.green)
                Text("Shortcuts send exactly what you save to the active terminal. They are never used for session discovery or attachment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("New Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.addShortcut(
                            CustomTerminalShortcut(
                                label: label, text: text, appendReturn: appendReturn,
                                keySequence: keySequence, bindingSyntax: keySequence ? true : nil
                            )
                        )
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty || (keySequence && (try? TerminalBinding.steps(text)) == nil))
                }
            }
        }
    }
}
