import SwiftUI
import UIKit

/// The message bar above the terminal toolbar: type or dictate a prompt, read it over, then send it.
/// Dictated text is never sent on its own.
struct TerminalComposer: View {
    var controller: TerminalController
    @Binding var draft: String
    @EnvironmentObject private var settings: TerminalSettingsStore
    @StateObject private var speech = SpeechInputController()
    @FocusState private var focused: Bool
    @State private var draftBeforeDictation = ""
    @State private var annotationSource: ImageAnnotationSource?
    @State private var imageError: String?
    @State private var isUploadingImage = false

    private var listening: Bool { speech.isListening || speech.isStarting }
    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Menu {
                Button("Annotate Clipboard Image", systemImage: "photo.badge.pencil", action: annotateClipboardImage)
                    .disabled(isUploadingImage)
                Button("Wrap as Code", systemImage: "chevron.left.forwardslash.chevron.right", action: wrapInCodeFence)
                    .disabled(!hasText)
            } label: {
                Image(systemName: isUploadingImage ? "arrow.up.circle" : "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")

            TextField(speech.isListening ? "Listening…" : speech.isStarting ? "Getting dictation ready…" : "Message",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(listening)
                .accessibilityLabel("Message")
                .padding(.vertical, 8)

            micButton
            sendButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
        }
        .onAppear { focused = true }
        .onDisappear { speech.stop() }
        .onChange(of: speech.isListening) { _, isListening in
            if isListening { draftBeforeDictation = hasText ? draft + " " : "" }
        }
        .onChange(of: speech.transcript) { _, value in
            guard !value.isEmpty else { return }
            draft = draftBeforeDictation + WordReplacement.apply(settings.preferences.dictationReplacements, to: value)
        }
        .onChange(of: speech.isFinal) { _, isFinal in
            if isFinal { settings.rememberTranscription(speech.transcript) }
        }
        .errorAlert("Dictation", message: $speech.errorMessage)
        .errorAlert("Couldn't upload image", message: $imageError)
        .sheet(item: $annotationSource) { source in
            ImageAnnotationView(image: source.image) { image in
                Task { await upload(image) }
            }
        }
    }

    private var micButton: some View {
        Button {
            // Keep the terminal in view while talking.
            if !listening { focused = false }
            speech.toggle(language: settings.preferences.speechLanguage)
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: listening ? 12 : 15, weight: listening ? .bold : .semibold))
                .foregroundStyle(listening ? Theme.bg : Theme.ink)
                .frame(width: 32, height: 32)
                .background(listening ? Theme.danger : Theme.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(2)
        .accessibilityLabel(listening ? "Stop Dictation" : "Dictate")
    }

    private var sendButton: some View {
        let enabled = hasText && !listening && controller.canAcceptInput
        return Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 32, height: 32)
                .background(Theme.ink.opacity(enabled ? 1 : 0.3), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(2)
        .disabled(!enabled)
        .accessibilityLabel("Send")
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var bytes = Array(text.utf8)
        bytes.append(0x0d)
        guard controller.send(bytes[...]) else { return }
        settings.rememberCommand(text)
        draft = ""
    }

    private func wrapInCodeFence() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```") { return }
        draft = "```\n\(text)\n```"
    }

    private func annotateClipboardImage() {
        guard let image = UIPasteboard.general.image else {
            imageError = "Copy an image first, then try again."
            return
        }
        annotationSource = ImageAnnotationSource(image: image)
    }

    /// Uploads the annotated image to the session's directory and puts its path in the message.
    private func upload(_ image: UIImage) async {
        guard let data = image.pngData() else {
            imageError = "The annotated image could not be encoded."
            return
        }
        isUploadingImage = true
        defer { isUploadingImage = false }
        do {
            let directory: String
            if let currentDirectory = controller.currentDirectory, !currentDirectory.isEmpty {
                directory = currentDirectory
            } else {
                let result = try await controller.execRemote(RemoteWorkspaceService.workingDirectoryCommand)
                try MuxDiscovery.requireSuccess(result)
                directory = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !directory.isEmpty else { throw MuxDiscoveryError.unusableOutput }
                controller.recordDirectory(directory)
            }
            let name = "steer-annotation-\(UUID().uuidString.lowercased()).png"
            let remotePath = RemoteWorkspaceService.join(directory: directory, name: name)
            let result = try await controller.execRemote(
                RemoteWorkspaceService.uploadCommand(path: remotePath, byteCount: data.count),
                stdin: data
            )
            try MuxDiscovery.requireSuccess(result)
            draft = hasText ? draft + " " + remotePath : remotePath
        } catch {
            imageError = error.localizedDescription
        }
    }
}
