import Foundation

struct RemoteFileEntry: Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case directory = "d"
        case file = "f"
    }

    var id: String { path }

    let name: String
    let path: String
    let kind: Kind
}

enum RemoteWorkspaceService {
    static let workingDirectoryCommand = "pwd -P"

    static func diffCommand(directory: String) -> String {
        let directory = ShellQuote.posixSingle(directory)
        return "cd -- \(directory) && (git diff --no-ext-diff --no-color HEAD -- . 2>/dev/null || git diff --no-ext-diff --no-color -- .)"
    }

    static func fileListCommand(directory: String) -> String {
        let directory = ShellQuote.posixSingle(directory)
        return "cd -- \(directory) && find . -mindepth 1 -maxdepth 1 -exec sh -c 'for p do if [ -d \"$p\" ]; then printf \"d\\000%s\\000\" \"$p\"; else printf \"f\\000%s\\000\" \"$p\"; fi; done' sh {} +"
    }

    static func downloadCommand(path: String) -> String {
        "cat -- \(ShellQuote.posixSingle(path))"
    }

    static func uploadCommand(path: String, byteCount: Int) -> String {
        """
        umask 077
        target=\(ShellQuote.posixSingle(path))
        [ ! -d "$target" ] || exit 1
        tmp=$(mktemp "$target.steer.XXXXXX") || exit 1
        trap 'rm -f -- "$tmp"' EXIT
        trap 'exit 1' HUP INT TERM
        cat > "$tmp" && [ "$(wc -c < "$tmp")" -eq \(byteCount) ] && mv -f -- "$tmp" "$target"
        """
    }

    static func parseFiles(_ data: Data, directory: String) -> [RemoteFileEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return [] }
        var entries: [RemoteFileEntry] = []
        var index = 0
        while index + 1 < fields.count {
            defer { index += 2 }
            guard let kind = RemoteFileEntry.Kind(rawValue: String(decoding: fields[index], as: UTF8.self)) else {
                continue
            }
            var name = String(decoding: fields[index + 1], as: UTF8.self)
            if name.hasPrefix("./") { name.removeFirst(2) }
            guard !name.isEmpty else { continue }
            entries.append(
                RemoteFileEntry(
                    name: name,
                    path: join(directory: directory, name: name),
                    kind: kind
                )
            )
        }
        return entries.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func join(directory: String, name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        return url.path.isEmpty ? "/" : url.path
    }
}
