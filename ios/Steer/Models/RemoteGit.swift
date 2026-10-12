import Foundation

struct GitChange: Identifiable, Equatable {
    enum Area: String, CaseIterable { case staged = "Staged", unstaged = "Unstaged", untracked = "Untracked" }
    let path: String
    let originalPath: String?
    let status: Character
    let area: Area
    var id: String { area.rawValue + ":" + path }
}

struct GitCommit: Identifiable, Equatable {
    let id: String
    let subject: String
}

enum RemoteGit {
    static func command(_ arguments: String, directory: String) -> String {
        "cd -- \(ShellQuote.posixSingle(directory)) && git --literal-pathspecs \(arguments)"
    }

    static func changes(_ data: Data) -> [GitChange] {
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitChange] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count >= 4 else { continue }
            let status = Array(field.prefix(2))
            let path = String(field.dropFirst(3))
            var original: String?
            if status.contains("R") || status.contains("C") {
                guard index < fields.count else { break }
                original = fields[index]
                index += 1
            }
            if status == ["?", "?"] {
                result.append(GitChange(path: path, originalPath: nil, status: "?", area: .untracked))
            } else {
                if status[0] != " " {
                    result.append(GitChange(path: path, originalPath: original, status: status[0], area: .staged))
                }
                if status[1] != " " {
                    result.append(GitChange(path: path, originalPath: original, status: status[1], area: .unstaged))
                }
            }
        }
        return result
    }

    static func paths(_ data: Data) -> [String] {
        Array(Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })).sorted()
    }

    static func commits(_ data: Data) -> [GitCommit] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        return stride(from: 0, to: max(0, fields.count - 1), by: 2).compactMap { index in
            let hash = String(decoding: fields[index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCommit(hash) else { return nil }
            return GitCommit(id: hash, subject: String(decoding: fields[index + 1], as: UTF8.self))
        }
    }

    static func isCommit(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func diffCommand(_ change: GitChange, directory: String) -> String {
        let path = ShellQuote.posixSingle("./" + change.path)
        let options = "--no-ext-diff --no-textconv --no-color"
        if change.area == .untracked {
            return "cd -- \(ShellQuote.posixSingle(directory)) && (git --literal-pathspecs diff \(options) --no-index -- /dev/null \(path); result=$?; [ \"$result\" -le 1 ])"
        }
        let original = change.originalPath.map { " " + ShellQuote.posixSingle("./" + $0) } ?? ""
        return command("diff \(options) \(change.area == .staged ? "--cached" : "") -- \(path)\(original)", directory: directory)
    }

    static func sourceCommand(path: String, revision: String?, directory: String, staged: Bool = false) -> String {
        if revision != nil || staged {
            // Only immutable object IDs from git log are accepted as revisions.
            if let revision, !isCommit(revision) { return "exit 1" }
            let object = ShellQuote.posixSingle((revision ?? "") + ":" + path)
            return "cd -- \(ShellQuote.posixSingle(directory)) && size=$(git cat-file -s \(object)) && [ \"$size\" -le 524288 ] && git cat-file blob \(object)"
        }
        let quoted = ShellQuote.posixSingle("./" + path)
        return "cd -- \(ShellQuote.posixSingle(directory)) && [ -f \(quoted) ] && [ \"$(wc -c < \(quoted))\" -le 524288 ] && cat -- \(quoted)"
    }
}

struct DiffRow: Identifiable, Equatable {
    let id: Int
    let left: String
    let right: String
    let removed: Bool
    let added: Bool

    static func parse(_ patch: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [String] = []
        var added: [String] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(DiffRow(id: rows.count, left: index < removed.count ? removed[index] : "",
                                    right: index < added.count ? added[index] : "",
                                    removed: index < removed.count, added: index < added.count))
            }
            removed = []
            added = []
        }
        var inHunk = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("@@") { inHunk = true }
            if line.hasPrefix("diff --git") { inHunk = false }
            if inHunk && line.hasPrefix("-") { removed.append(String(line.dropFirst())); continue }
            if inHunk && line.hasPrefix("+") { added.append(String(line.dropFirst())); continue }
            flush()
            let text = inHunk && line.hasPrefix(" ") ? String(line.dropFirst()) : line
            rows.append(DiffRow(id: rows.count, left: text, right: text, removed: false, added: false))
        }
        flush()
        return rows
    }
}

/// Branch, ahead/behind, and dirty state for one working tree.
struct GitSummary: Equatable, Sendable {
    var branch: String
    var ahead = 0
    var behind = 0
    var dirty = false

    var label: String {
        [branch, ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil, dirty ? "●" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Parses `git status --porcelain=v2 --branch`; nil when the output has no branch header.
    init?(porcelain: String) {
        var branch: String?
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                ahead = parts.count > 2 ? Int(parts[2].dropFirst()) ?? 0 : 0
                behind = parts.count > 3 ? Int(parts[3].dropFirst()) ?? 0 : 0
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        guard let branch else { return nil }
        self.branch = branch
    }
}

extension RemoteGit {
    private static let recordSeparator: Character = "\u{1E}"

    /// One exec for many directories; each result starts with a record separator and the directory.
    static func summaryCommand(directories: [String]) -> String {
        directories.map { directory in
            let quoted = ShellQuote.posixSingle(directory)
            return "printf '\\036%s\\n' \(quoted); git -C \(quoted) status --porcelain=v2 --branch 2>/dev/null"
        }.joined(separator: "; ")
    }

    static func summaries(from output: String) -> [String: GitSummary] {
        var result: [String: GitSummary] = [:]
        for record in output.split(separator: recordSeparator) {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let directory = String(record[..<newline])
            if let summary = GitSummary(porcelain: String(record[record.index(after: newline)...])) {
                result[directory] = summary
            }
        }
        return result
    }
}
