import SwiftUI
import UniformTypeIdentifiers
import Speech

struct ThemeFileControls: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @State private var importing = false
    @State private var exporting = false
    @State private var errorMessage: String?

    var body: some View {
        if let custom = settings.preferences.customPalette {
            LabeledContent("Imported theme", value: custom.name)
            Button("Use built-in theme") { settings.preferences.customPalette = nil }
        }
        Button("Import Theme", systemImage: "square.and.arrow.down") { importing = true }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    settings.preferences.customPalette = try TerminalPalette.decode(data)
                } catch { errorMessage = error.localizedDescription }
            }
        Button("Export Theme", systemImage: "square.and.arrow.up") { exporting = true }
            .fileExporter(isPresented: $exporting, document: ThemeDocument(palette: settings.preferences.palette), contentType: .json, defaultFilename: "Steer Theme") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
            .errorAlert("Theme", message: $errorMessage)
    }
}

private struct ThemeDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var palette: TerminalPalette
    init(palette: TerminalPalette) { self.palette = palette }
    init(configuration: ReadConfiguration) throws {
        palette = try TerminalPalette.decode(configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(palette))
    }
}

struct AppLockSetting: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @State private var errorMessage: String?
    @State private var changing = false

    var body: some View {
        Toggle("Lock when returning to Steer", isOn: Binding(
            get: { settings.preferences.lockOnResume },
            set: { value in
                changing = true
                Task {
                    do { try await settings.setAppLock(value) }
                    catch { errorMessage = error.localizedDescription }
                    changing = false
                }
            }
        ))
        .tint(.green)
        .disabled(changing)
        .errorAlert("App Lock", message: $errorMessage)
    }
}

struct SpeechSettingsView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore

    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Language", selection: $settings.preferences.speechLanguage) {
                    Text("System language").tag("")
                    ForEach(SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted(), id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Text("Apple on-device recognition. Audio stays on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($settings.preferences.dictationReplacements) { $rule in
                    HStack {
                        TextField("Heard", text: $rule.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Replace with", text: $rule.replacement)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                .onDelete { settings.preferences.dictationReplacements.remove(atOffsets: $0) }
                Button("Add Replacement", systemImage: "plus") {
                    settings.preferences.dictationReplacements.append(WordReplacement(heard: "", replacement: ""))
                }
            } header: {
                Text("Word replacements")
            } footer: {
                Text("Fix words dictation keeps getting wrong. Matches whole words, ignoring case.")
            }
            Section("Transcription history") {
                if settings.preferences.transcriptionHistory.isEmpty {
                    Text("No saved transcriptions").foregroundStyle(.secondary)
                }
                ForEach(settings.preferences.transcriptionHistory, id: \.self) { text in
                    Text(text).textSelection(.enabled)
                        .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                }
                if !settings.preferences.transcriptionHistory.isEmpty {
                    Button("Clear Transcription History", role: .destructive) { settings.preferences.transcriptionHistory = [] }
                }
            }
        }
        .navigationTitle("Dictation")
    }
}
