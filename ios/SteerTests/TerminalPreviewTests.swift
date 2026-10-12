import Foundation
import Testing
@testable import Steer

@MainActor
struct TerminalPreviewTests {
    @Test
    func discoveryStartsPreviewsAfterAnEarlyRequestWasSkipped() async throws {
        let controller = makeController(["main"])
        controller.mux.catalog = nil
        let (discovery, reply) = AsyncStream<SSHExecResult>.makeStream()
        var discoveryStarted = false
        let loading = Task {
            await controller.mux.load { command in
                switch command {
                case MuxCommands.herdrSessionList:
                    discoveryStarted = true
                    for await result in discovery { return result }
                    throw CancellationError()
                case MuxCommands.tmuxList:
                    return SSHExecResult(stdout: "main: 1 windows\n", stderr: "", exitStatus: 0)
                default:
                    return SSHExecResult(stdout: "terminal preview", stderr: "", exitStatus: 0)
                }
            }
        }
        defer { reply.finish() }
        try await waitUntil { discoveryStarted }
        await controller.mux.loadPreviews { _ in
            Issue.record("Previews must wait for a catalog")
            throw SSHExecError.failed
        }
        await controller.mux.load { _ in
            Issue.record("Discovery must not run twice")
            throw SSHExecError.failed
        }
        reply.yield(SSHExecResult(stdout: "", stderr: "command not found", exitStatus: 127))
        reply.finish()
        await loading.value

        try await waitUntil { controller.mux.previews["tmux:main"] != nil }
        #expect(controller.mux.previewLoadingIDs.isEmpty)
        #expect(!controller.mux.isLoading)
    }

    @Test
    func fastPreviewAppearsWhileAnotherIsStillLoading() async throws {
        let controller = makeController(["slow", "fast"])
        let (slow, reply) = AsyncStream<SSHExecResult>.makeStream()
        let loading = Task {
            await controller.mux.loadPreviews { command in
                if command.contains("'slow'") {
                    for await result in slow { return result }
                    throw CancellationError()
                }
                return SSHExecResult(stdout: "ready", stderr: "", exitStatus: 0)
            }
        }
        defer { reply.finish() }
        try await waitUntil { controller.mux.previews["tmux:fast"] != nil }
        #expect(controller.mux.previewLoadingIDs == ["tmux:slow"])
        #expect(controller.mux.previews["tmux:slow"] == nil)
        await controller.mux.loadPreviews { _ in
            Issue.record("A second refresh must reuse the active request")
            throw SSHExecError.failed
        }

        reply.yield(SSHExecResult(stdout: "also ready", stderr: "", exitStatus: 0))
        reply.finish()
        await loading.value
        #expect(controller.mux.previews.count == 2)
        #expect(controller.mux.previewLoadingIDs.isEmpty)
    }

    @Test
    func previewRefreshKeepsSSHConcurrencyBounded() async throws {
        let controller = makeController((0..<7).map(String.init))
        var active = 0
        var peak = 0
        await controller.mux.loadPreviews { _ in
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            return SSHExecResult(stdout: "ready", stderr: "", exitStatus: 0)
        }
        #expect(peak == 3)
        #expect(controller.mux.previews.count == 7)
        #expect(controller.mux.previewLoadingIDs.isEmpty)
    }

    @Test
    func failedAndEmptyRefreshesKeepCachedPreviewsAndStopLoading() async {
        let controller = makeController(["main", "empty"])
        let cached = TerminalPreviewSnapshot(bytes: Array("cached".utf8))
        controller.mux.previews = ["tmux:main": cached, "tmux:removed": cached]
        for result in [
            SSHExecResult(stdout: "", stderr: "denied", exitStatus: 1),
            SSHExecResult(stdout: "", stderr: "", exitStatus: 0),
        ] {
            await controller.mux.loadPreviews { _ in result }
            #expect(controller.mux.previews == ["tmux:main": cached])
            #expect(controller.mux.previewLoadingIDs.isEmpty)
        }
        await controller.mux.loadPreviews { _ in throw SSHExecError.timedOut }
        #expect(controller.mux.previews == ["tmux:main": cached])
        #expect(controller.mux.previewLoadingIDs.isEmpty)

        controller.mux.catalog = MuxCatalog(
            agents: [], sessions: [], tmux: [], zellij: [ZellijSession(name: "work")]
        )
        await controller.mux.loadPreviews { _ in
            Issue.record("Unsupported previews must not start a request")
            throw SSHExecError.failed
        }
        #expect(controller.mux.previews.isEmpty)
        #expect(controller.mux.previewLoadingIDs.isEmpty)
    }

    @Test
    func oldConnectionCannotReplaceNewPreviewsOrClearTheirLoader() async throws {
        let controller = makeController(["main"])
        let catalog = controller.mux.catalog
        let (oldStream, oldReply) = AsyncStream<SSHExecResult>.makeStream()
        var oldStarted = false
        let oldLoad = Task {
            await controller.mux.loadPreviews { _ in
                oldStarted = true
                for await result in oldStream { return result }
                throw CancellationError()
            }
        }
        defer { oldReply.finish() }
        try await waitUntil { oldStarted }
        controller.disconnect()
        controller.mux.catalog = catalog
        let (newStream, newReply) = AsyncStream<SSHExecResult>.makeStream()
        var newStarted = false
        let newLoad = Task {
            await controller.mux.loadPreviews { _ in
                newStarted = true
                for await result in newStream { return result }
                throw CancellationError()
            }
        }
        defer { newReply.finish() }
        try await waitUntil { newStarted }
        oldReply.yield(SSHExecResult(stdout: "stale", stderr: "", exitStatus: 0))
        oldReply.finish()
        await oldLoad.value
        #expect(controller.mux.previews.isEmpty)
        #expect(controller.mux.previewLoadingIDs == ["tmux:main"])

        newReply.yield(SSHExecResult(stdout: "current", stderr: "", exitStatus: 0))
        newReply.finish()
        await newLoad.value
        #expect(controller.mux.previews["tmux:main"]?.bytes == Array("current".utf8))
        #expect(controller.mux.previewLoadingIDs.isEmpty)
    }

    @Test
    func changedCatalogGetsPreviewsAfterTheActiveRefresh() async throws {
        let controller = makeController(["old"])
        let (stream, reply) = AsyncStream<SSHExecResult>.makeStream()
        var started = false
        let loading = Task {
            await controller.mux.loadPreviews { command in
                if command.contains("'old'") {
                    started = true
                    for await result in stream { return result }
                    throw CancellationError()
                }
                return SSHExecResult(stdout: "new", stderr: "", exitStatus: 0)
            }
        }
        defer { reply.finish() }
        try await waitUntil { started }
        controller.mux.catalog = makeController(["new"]).mux.catalog
        await controller.mux.loadPreviews { _ in throw SSHExecError.failed }
        reply.yield(SSHExecResult(stdout: "old", stderr: "", exitStatus: 0))
        reply.finish()
        await loading.value
        #expect(Set(controller.mux.previews.keys) == ["tmux:new"])
        #expect(controller.mux.previewLoadingIDs.isEmpty)
    }

    @Test
    func previewsIncludeEveryTabAndReplaceNarrowerSnapshots() async throws {
        let controller = makeController([])
        var panes = try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2"}]}}"#)
        for index in panes.indices { panes[index].sessionName = "work" }
        controller.mux.catalog = MuxCatalog(agents: panes, sessions: [], tmux: [])
        let rows = panes.map(MuxRow.herdrAgent)
        controller.mux.previews[rows[0].id] = TerminalPreviewSnapshot(bytes: Array("old".utf8))
        var commands: [String] = []
        await controller.mux.loadPreviews { command in
            commands.append(command)
            return SSHExecResult(stdout: "current", stderr: "", exitStatus: 0)
        }
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.contains("herdr --session 'work' pane read") && $0.contains("--raw") })
        #expect(Set(controller.mux.previews.keys) == Set(rows.map(\.id)))
        #expect(controller.mux.previews[rows[0].id]?.bytes == Array("current".utf8))
    }

    private func makeController(_ names: [String]) -> TerminalController {
        let controller = TerminalController(host: Host(name: "Test", hostname: "test.invalid", username: "test"))
        controller.mux.catalog = MuxCatalog(
            agents: [], sessions: [],
            tmux: names.map { TmuxSession(name: $0, windowCount: 1, isAttached: false) }
        )
        return controller
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
