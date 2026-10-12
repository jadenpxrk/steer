import Foundation
import Testing
@testable import Steer

struct RemoteWorkspaceServiceTests {
    @Test
    func parsesNullDelimitedFilesAndSortsDirectoriesFirst() {
        let data = Data("f\0./z.txt\0d\0./Sources\0f\0./a.txt\0".utf8)

        let entries = RemoteWorkspaceService.parseFiles(data, directory: "/tmp/project")

        #expect(entries.map(\.name) == ["Sources", "a.txt", "z.txt"])
        #expect(entries[0].kind == .directory)
        #expect(entries[0].path == "/tmp/project/Sources")
    }

    @Test
    func remoteCommandsQuotePathsAsSingleArguments() {
        let path = "/tmp/it's $(unsafe)"

        #expect(RemoteWorkspaceService.diffCommand(directory: path).contains("'/tmp/it'\\''s $(unsafe)'"))
        #expect(RemoteWorkspaceService.downloadCommand(path: path) == "cat -- '/tmp/it'\\''s $(unsafe)'")
        #expect(RemoteWorkspaceService.uploadCommand(path: path, byteCount: 3).contains("target='/tmp/it'\\''s $(unsafe)'"))
    }

    @Test
    func joinsAndNavigatesRemotePaths() {
        #expect(RemoteWorkspaceService.join(directory: "/", name: "tmp") == "/tmp")
        #expect(RemoteWorkspaceService.join(directory: "/tmp", name: "file") == "/tmp/file")
        #expect(RemoteWorkspaceService.parent(of: "/tmp/file") == "/tmp")
        #expect(RemoteWorkspaceService.parent(of: "/tmp") == "/")
    }
}
