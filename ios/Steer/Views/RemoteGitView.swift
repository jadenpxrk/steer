import SwiftUI

struct RemoteGitView: View {
    var controller: TerminalController
    @State private var directory = ""
    @State private var changes: [GitChange] = []
    @State private var files: [String] = []
    @State private var commits: [GitCommit] = []
    @State private var mode = "Changes"
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var loading = false

    var body: some View {
        List {
            SteerTabStrip(tabs: ["Changes", "Files", "History"].map {
                SteerTabItem(id: $0, title: $0, isSelected: mode == $0)
            }, select: { mode = $0 })
            .accessibilityLabel("Repository view")
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if mode == "Changes" {
                ForEach(GitChange.Area.allCases, id: \.self) { area in
                    let entries = changes.filter { $0.area == area && matches($0.path) }
                    if !entries.isEmpty {
                        Section(area.rawValue) {
                            ForEach(entries) { change in
                                NavigationLink {
                                    GitFileView(controller: controller, directory: directory,
                                                path: change.path, change: change)
                                } label: {
                                    HStack {
                                        Text(String(change.status)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Text(change.path).font(.subheadline.monospaced())
                                    }
                                }
                            }
                        }
                    }
                }
                if changes.isEmpty && !loading && errorMessage == nil {
                    ContentUnavailableView("No changes", systemImage: "checkmark.circle")
                }
            } else if mode == "Files" {
                ForEach(files.filter(matches), id: \.self) { path in
                    NavigationLink(path) {
                        GitFileView(controller: controller, directory: directory, path: path)
                    }
                    .font(.subheadline.monospaced())
                }
            } else {
                ForEach(commits.filter { matches($0.subject) || matches($0.id) }) { commit in
                    NavigationLink {
                        GitRevisionView(controller: controller, directory: directory, commit: commit)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.subject)
                            Text(commit.id.prefix(10)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Filter files or commits")
        .overlay { if loading { ProgressView() } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(directory).font(.caption).lineLimit(1)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(loading)
            }.padding(10).background(.bar)
        }
        .task { await load() }
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            let cwd = try await resolveDirectory(controller: controller)
            let root = try await controller.execRemote(RemoteGit.command("rev-parse --show-toplevel", directory: cwd))
            if root.exitStatus != 0, root.stderr.contains("not a git repository") {
                errorMessage = "\(cwd) is not in a Git repository."
                return
            }
            try MuxDiscovery.requireSuccess(root)
            directory = root.stdout.hasSuffix("\n") ? String(root.stdout.dropLast()) : root.stdout
            let status = try await controller.execRemote(RemoteGit.command("status --porcelain=v1 -z --untracked-files=all", directory: directory))
            try MuxDiscovery.requireSuccess(status)
            changes = RemoteGit.changes(status.stdoutData)
            let listing = try await controller.execRemote(RemoteGit.command("ls-files -z --cached --others --exclude-standard", directory: directory))
            try MuxDiscovery.requireSuccess(listing)
            files = RemoteGit.paths(listing.stdoutData)
            let history = try await controller.execRemote(RemoteGit.command("log -100 --format='%H%x00%s%x00'", directory: directory))
            // An unborn repository has files and changes, but no commits yet.
            if history.exitStatus == 0 {
                commits = RemoteGit.commits(history.stdoutData)
            } else {
                let head = try await controller.execRemote(RemoteGit.command("rev-parse --verify HEAD", directory: directory))
                if head.exitStatus == 0 { try MuxDiscovery.requireSuccess(history) }
                commits = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GitRevisionView: View {
    var controller: TerminalController
    let directory: String
    let commit: GitCommit
    @State private var paths: [String] = []
    @State private var search = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Text(commit.subject).font(.headline)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(paths.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { path in
                NavigationLink(path) {
                    GitFileView(controller: controller, directory: directory, path: path, revision: commit.id)
                }.font(.subheadline.monospaced())
            }
        }
        .navigationTitle(String(commit.id.prefix(10)))
        .searchable(text: $search, prompt: "Filter files")
        .task {
            do {
                guard RemoteGit.isCommit(commit.id) else { throw MuxDiscoveryError.unusableOutput }
                let result = try await controller.execRemote(RemoteGit.command("ls-tree -rz --name-only \(commit.id)", directory: directory))
                try MuxDiscovery.requireSuccess(result)
                paths = RemoteGit.paths(result.stdoutData)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct GitFileView: View {
    var controller: TerminalController
    let directory: String
    let path: String
    var revision: String?
    var change: GitChange?
    @State private var content = ""
    @State private var mode = "Patch"
    @State private var errorMessage: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            if change != nil {
                SteerTabStrip(tabs: [
                    SteerTabItem(id: "Patch", title: "Patch", isSelected: mode == "Patch"),
                    SteerTabItem(id: "Split", title: "Side by side", isSelected: mode == "Split"),
                    SteerTabItem(id: "Source", title: "Source", isSelected: mode == "Source")
                ], select: { mode = $0 })
                .accessibilityLabel("View")
                .padding()
            }
            if let errorMessage {
                ContentUnavailableView("Couldn't load file", systemImage: "doc.badge.ellipsis", description: Text(errorMessage))
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == "Split", change != nil {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(DiffRow.parse(content)) { row in
                            HStack(alignment: .top, spacing: 0) {
                                diffCell(row.left, color: row.removed ? .red : .clear)
                                Divider()
                                diffCell(row.right, color: row.added ? .green : .clear)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(highlight(content, isDiff: change != nil && mode != "Source"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mode == "Source") { await load() }
    }

    private func diffCell(_ text: String, color: Color) -> some View {
        Text(text.isEmpty ? " " : text)
            .frame(minWidth: 360, maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 6)
            .background(color.opacity(0.15))
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let command: String
            if let change, mode != "Source" {
                command = RemoteGit.diffCommand(change, directory: directory)
            } else {
                command = RemoteGit.sourceCommand(path: path, revision: revision, directory: directory, staged: change?.area == .staged)
            }
            let result = try await controller.execRemote(command)
            try Task.checkCancellation()
            guard result.exitStatus == 0 else {
                throw GitPreviewError.unavailable
            }
            guard !result.stdoutData.contains(0), let text = String(data: result.stdoutData, encoding: .utf8) else {
                throw GitPreviewError.binary
            }
            content = text
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum GitPreviewError: LocalizedError {
    case unavailable, binary
    var errorDescription: String? {
        switch self {
        case .unavailable: "This file is unavailable or exceeds the 512 KB source preview limit. Deleted files can still be reviewed in Patch view."
        case .binary: "This file isn't UTF-8 text. Use Files to download it."
        }
    }
}

private func highlight(_ source: String, isDiff: Bool) -> AttributedString {
    var result = AttributedString(source)
    let pattern = isDiff
        ? "(?m)^[+].*$|^[-].*$|^@@.*$"
        : #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:func|let|var|struct|class|enum|import|return|if|else|for|while|async|await|throw|throws|try|const|function|def|from|public|private|static|true|false|null|nil)\b|//[^\n]*"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        guard let range = Range(match.range, in: source),
              let start = AttributedString.Index(range.lowerBound, within: result),
              let end = AttributedString.Index(range.upperBound, within: result) else { continue }
        let token = source[range]
        result[start..<end].foregroundColor = isDiff
            ? (token.hasPrefix("+") ? .green : token.hasPrefix("-") ? .red : .secondary)
            : (token.hasPrefix("\"") || token.hasPrefix("'") ? .orange : token.hasPrefix("//") ? .secondary : .purple)
    }
    return result
}
