import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WebKit

struct RemoteToolsView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case diff
        case files
        case directories
        case web

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var controller: TerminalController
    @Environment(\.dismiss) private var dismiss
    @State private var tool = Tool.diff

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SteerTabStrip(tabs: Tool.allCases.map {
                    SteerTabItem(id: $0.id, title: $0.title, isSelected: tool == $0)
                }, select: { id in
                    if let next = Tool(rawValue: id) { tool = next }
                })
                .accessibilityLabel("Remote tool")
                .padding()

                switch tool {
                case .diff:
                    RemoteGitView(controller: controller)
                case .files:
                    RemoteFilesView(controller: controller)
                case .directories:
                    RemoteDirectoriesView(controller: controller)
                case .web:
                    RemoteWebPreviewView(controller: controller)
                }
            }
            .navigationTitle("Remote Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct RemoteWebPreviewView: View {
    var controller: TerminalController
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = 3000
    @State private var path = "/"
    @State private var forward: SSHLocalForward?
    @State private var previewURL: URL?
    @State private var errorMessage: String?
    @State private var isConnecting = false

    var body: some View {
        Group {
            if let previewURL {
                WebPreview(url: previewURL)
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Text("\(remoteHost):\(remotePort)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop", role: .destructive) { stop() }
                        }
                        .padding(10)
                        .background(.bar)
                    }
            } else {
                Form {
                    Section("Remote server") {
                        TextField("Host", text: $remoteHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", value: $remotePort, format: .number)
                            .keyboardType(.numberPad)
                        TextField("Path", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Button("Open Preview", systemImage: "safari") {
                            Task { await connect() }
                        }
                        .disabled(
                            isConnecting
                                || remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !(1...65_535).contains(remotePort)
                        )
                    } footer: {
                        Text("Steer opens a loopback-only TCP tunnel through this SSH connection. The remote port is not exposed to your network.")
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .overlay {
                    if isConnecting {
                        ProgressView("Opening tunnel…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .onDisappear { stop() }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        do {
            let forward = try await controller.openWebPreview(
                remoteHost: remoteHost.trimmingCharacters(in: .whitespacesAndNewlines),
                remotePort: remotePort
            )
            let normalizedPath = path.hasPrefix("/") ? path : "/" + path
            guard let url = URL(string: "http://127.0.0.1:\(forward.localPort)\(normalizedPath)") else {
                forward.close()
                throw URLError(.badURL)
            }
            self.forward = forward
            previewURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }

    private func stop() {
        forward?.close()
        forward = nil
        previewURL = nil
    }
}

private struct WebPreview: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Loaded { Loaded() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    // Compare with the last requested URL, not webView.url, so in-page
    // navigation and redirects are not undone on every re-render.
    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        webView.load(URLRequest(url: url))
    }

    final class Loaded {
        var url: URL?
    }
}

private struct RemoteFilesView: View {
    var controller: TerminalController
    @State private var directory = ""
    @State private var entries: [RemoteFileEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var shareItem: ShareItem?
    @State private var annotationSource: ImageAnnotationSource?

    var body: some View {
        Group {
            if isLoading, entries.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, entries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                List {
                    if directory != "/" {
                        Button {
                            directory = RemoteWorkspaceService.parent(of: directory)
                            Task { await load() }
                        } label: {
                            Label("Parent Directory", systemImage: "arrow.up.left")
                        }
                    }
                    ForEach(entries) { entry in
                        Button {
                            if entry.kind == .directory {
                                directory = entry.path
                                Task { await load() }
                            } else {
                                Task { await download(entry) }
                            }
                        } label: {
                            Label(
                                entry.name,
                                systemImage: entry.kind == .directory ? "folder" : "doc"
                            )
                        }
                    }
                }
                .overlay {
                    if isLoading {
                        ProgressView()
                            .padding()
                            .background(.regularMaterial, in: Circle())
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Text(directory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Upload File", systemImage: "square.and.arrow.up") {
                        isImporting = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Annotate", systemImage: "pencil.and.scribble") {
                        beginImageAnnotation()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .task {
            if directory.isEmpty {
                directory = (try? await resolveDirectory(controller: controller)) ?? "/"
            }
            await load()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            Task { await upload(url) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(item: $annotationSource) { source in
            ImageAnnotationView(image: source.image) { annotatedImage in
                Task { await uploadAnnotatedImage(annotatedImage) }
            }
        }
    }

    private func load() async {
        guard !directory.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await controller.execRemote(RemoteWorkspaceService.fileListCommand(directory: directory))
            try MuxDiscovery.requireSuccess(result)
            entries = RemoteWorkspaceService.parseFiles(result.stdoutData, directory: directory)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func download(_ entry: RemoteFileEntry) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await controller.execRemote(RemoteWorkspaceService.downloadCommand(path: entry.path))
            try MuxDiscovery.requireSuccess(result)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(URL(fileURLWithPath: entry.name).pathExtension)
            try result.stdoutData.write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try Data(contentsOf: url)
            let remotePath = RemoteWorkspaceService.join(directory: directory, name: url.lastPathComponent)
            let result = try await controller.execRemote(
                RemoteWorkspaceService.uploadCommand(path: remotePath, byteCount: data.count),
                stdin: data
            )
            try MuxDiscovery.requireSuccess(result)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginImageAnnotation() {
        guard let image = UIPasteboard.general.image else {
            errorMessage = "The clipboard doesn't contain an image."
            return
        }
        annotationSource = ImageAnnotationSource(image: image)
    }

    private func uploadAnnotatedImage(_ image: UIImage) async {
        guard let data = image.pngData() else {
            errorMessage = "The annotated image could not be encoded."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let name = "steer-paste-\(UUID().uuidString.lowercased()).png"
            let remotePath = RemoteWorkspaceService.join(directory: directory, name: name)
            let result = try await controller.execRemote(
                RemoteWorkspaceService.uploadCommand(path: remotePath, byteCount: data.count),
                stdin: data
            )
            try MuxDiscovery.requireSuccess(result)
            controller.send(Array(remotePath.utf8)[...])
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteDirectoriesView: View {
    var controller: TerminalController

    var body: some View {
        if controller.recentDirectories.isEmpty {
            ContentUnavailableView(
                "No recent directories",
                systemImage: "folder",
                description: Text("Directories reported by the remote shell will appear here.")
            )
        } else {
            List(controller.recentDirectories, id: \.self) { directory in
                Button {
                    controller.send(Array(directory.utf8)[...])
                } label: {
                    Label(directory, systemImage: "folder")
                        .font(.body.monospaced())
                }
            }
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context _: Context) {}
}

@MainActor
func resolveDirectory(controller: TerminalController) async throws -> String {
    if let directory = controller.currentDirectory, !directory.isEmpty {
        return directory
    }
    let result = try await controller.execRemote(RemoteWorkspaceService.workingDirectoryCommand)
    try MuxDiscovery.requireSuccess(result)
    let directory = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !directory.isEmpty else { throw MuxDiscoveryError.unusableOutput }
    controller.recordDirectory(directory)
    return directory
}
