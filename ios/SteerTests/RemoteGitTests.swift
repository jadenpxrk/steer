import Foundation
import Testing
@testable import Steer

struct RemoteGitTests {
    @Test func preservesUnusualPathsAndBothStages() {
        let changes = RemoteGit.changes(Data("MM a b\n'$(x)\0R  new name\0old name\0?? :(glob)*.txt\0".utf8))
        #expect(changes.count == 4)
        #expect(changes[0].area == .staged)
        #expect(changes[1].area == .unstaged)
        #expect(changes[0].path == "a b\n'$(x)")
        #expect(changes[2].originalPath == "old name")
        #expect(changes[3].area == .untracked)
        #expect(changes[3].path == ":(glob)*.txt")
    }

    @Test func parsesCommitRecords() {
        let hash = String(repeating: "a", count: 40)
        let history = Data("\(hash)\0First commit\0\n\(hash)\0Second commit\0\n".utf8)
        #expect(RemoteGit.commits(history).map(\.subject) == ["First commit", "Second commit"])
        #expect(!RemoteGit.isCommit("--output=/tmp/x"))
        #expect(RemoteGit.sourceCommand(path: "test", revision: "HEAD", directory: "/tmp") == "exit 1")
    }

    @Test func alignsReplacementsAndKeepsHunkHeaders() {
        let rows = DiffRow.parse("@@ -1,2 +1,3 @@\n same\n-old\n+new\n+extra")
        #expect(rows.count == 4)
        #expect(rows[2].left == "old")
        #expect(rows[2].right == "new")
        #expect(rows[2].removed && rows[2].added)
        #expect(rows[3].left.isEmpty && rows[3].right == "extra")
    }

    @Test func quotesPathsAndDisablesGitExternalHelpers() {
        let change = GitChange(path: ":(glob)*'$(touch x)", originalPath: nil, status: "M", area: .staged)
        let command = RemoteGit.diffCommand(change, directory: "/tmp/a b")
        #expect(command.contains("--literal-pathspecs"))
        #expect(command.contains("--no-ext-diff --no-textconv"))
        #expect(command.contains(ShellQuote.posixSingle("./" + change.path)))
    }
}

struct GitSummaryTests {
    @Test func parsesBranchAheadBehindAndDirtyState() throws {
        let output = "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b file.swift\n"
        let summary = try #require(GitSummary(porcelain: output))
        #expect(summary == GitSummary(porcelain: output))
        #expect(summary.branch == "main")
        #expect(summary.ahead == 2)
        #expect(summary.behind == 1)
        #expect(summary.dirty)
        #expect(summary.label == "main ↑2 ↓1 ●")
        #expect(GitSummary(porcelain: "")?.branch == nil)
    }

    @Test func splitsBatchedSummariesByDirectory() throws {
        let output = "\u{1E}/work/app\n# branch.head feature\n\u{1E}/work/not-a-repo\n\u{1E}/work/clean\n# branch.head main\n# branch.ab +0 -0\n"
        let summaries = RemoteGit.summaries(from: output)
        #expect(summaries.count == 2)
        #expect(summaries["/work/app"]?.label == "feature")
        #expect(summaries["/work/clean"]?.label == "main")
        #expect(RemoteGit.summaryCommand(directories: ["/a b", "/c'd"]).contains("git -C '/c'\\''d' status"))
    }
}
