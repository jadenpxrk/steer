import Foundation
import Testing
@testable import Steer

struct MuxOrchestrationTests {
    @Test @MainActor
    func herdrMetadataRequestsOverlapAfterDetection() async throws {
        let (stream, release) = AsyncStream<Void>.makeStream()
        var commands: [String] = []
        let discovery = Task {
            try await MuxDiscovery.discover { command in
                commands.append(command)
                if command == MuxCommands.herdrSessionList {
                    return SSHExecResult(stdout: #"{"sessions":[{"name":"main","running":true}]}"#, stderr: "", exitStatus: 0)
                }
                for await _ in stream { break }
                let key = command.contains("pane list") ? "panes"
                    : command.contains("workspace list") ? "workspaces" : "tabs"
                return SSHExecResult(stdout: "{\"result\":{\"\(key)\":[]}}", stderr: "", exitStatus: 0)
            }
        }
        defer { release.finish() }
        let deadline = ContinuousClock.now + .seconds(3)
        while commands.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(commands.first == MuxCommands.herdrSessionList)
        #expect(Set(commands.dropFirst()) == Set(["pane list", "workspace list", "tab list"].map {
            MuxCommands.herdr($0, session: "main")
        }))
        release.finish()
        let catalog = try await discovery.value
    }

    @Test @MainActor
    func discoversEveryRunningServerAndPlainShellTabWithoutIDCollisions() async throws {
        var commands: [String] = []
        let catalog = try await MuxDiscovery.discover { command in
            commands.append(command)
            let output: String
            if command == MuxCommands.herdrSessionList {
                output = #"{"sessions":[{"name":"default","running":false,"default":true},{"name":"main","running":true},{"name":"other","running":true}]}"#
            } else if command == MuxCommands.tmuxList {
                return SSHExecResult(stdout: "", stderr: "no server running on /tmp/tmux-501/default", exitStatus: 1)
            } else if command.contains("pane list") {
                output = #"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","agent":"codex"}]}}"#
            } else if command.contains("workspace list") {
                output = #"{"result":{"workspaces":[{"workspace_id":"w1","label":"Workspace"}]}}"#
            } else {
                output = #"{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Shell"},{"tab_id":"w1:t2","workspace_id":"w1","label":"Build"}]}}"#
            }
            return SSHExecResult(stdout: output, stderr: "", exitStatus: 0)
        }
        #expect(commands.count == 8)
        #expect(!commands.contains { $0.contains("--session 'default'") })
        #expect(catalog.listings.count == 2)
        #expect(Set(catalog.listings.map(\.id)).count == 2)
        #expect(catalog.agents.count == 4)
        #expect(Set(catalog.rows.map(\.id)).count == 4)
        #expect(catalog.agents.first?.agent == "")
        #expect(catalog.listings.map(\.title) == ["Workspace", "Workspace"])
        for listing in catalog.listings {
            #expect(listing.tabs.map(\.title) == ["Shell", "Build"])
            #expect(listing.tabs.map(\.attach.paneID) == ["w1:p1", "w1:p2"])
        }
        #expect(Set(catalog.previewTargets.map(\.id)).count == 4)
        #expect(catalog.rows.allSatisfy { $0.previewCommand != nil })
    }

    @Test @MainActor
    func oneUnavailableServerDoesNotHideOtherWorkspaces() async throws {
        let catalog = try await MuxDiscovery.discover { command in
            let output: String
            if command == MuxCommands.herdrSessionList {
                output = #"{"sessions":[{"name":"broken","running":true},{"name":"ok","running":true}]}"#
            } else if command.contains("'broken'") {
                throw SSHExecError.failed
            } else if command.contains("pane list") {
                output = #"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"}]}}"#
            } else if command.contains("workspace list") {
                output = #"{"result":{"workspaces":[{"workspace_id":"w1"}]}}"#
            } else {
                output = #"{"result":{"tabs":[]}}"#
            }
            return SSHExecResult(stdout: output, stderr: "", exitStatus: 0)
        }
        #expect(catalog.listings.count == 1)
        #expect(catalog.unavailableSessions == ["broken"])
    }

    @Test @MainActor
    func emptyHerdrListsAreEmptyState() async throws {
        let catalog = try await MuxDiscovery.discover { command in
            if command == MuxCommands.tmuxList {
                return SSHExecResult(stdout: "", stderr: "no server running on /tmp/tmux-501/default", exitStatus: 1)
            }
            #expect(command == MuxCommands.herdrSessionList)
            return SSHExecResult(stdout: #"{"sessions":[]}"#, stderr: "", exitStatus: 0)
        }
        #expect(catalog.isEmpty)
    }

    @Test @MainActor
    func listsTmuxSessionsAlongsideHerdr() async throws {
        let catalog = try await MuxDiscovery.discover { command in
            if command == MuxCommands.herdrSessionList {
                return SSHExecResult(stdout: #"{"sessions":[]}"#, stderr: "", exitStatus: 0)
            }
            #expect(command == MuxCommands.tmuxList)
            return SSHExecResult(stdout: "dev: 2 windows (created Sun Sep  1 00:00:00 2026)\n", stderr: "", exitStatus: 0)
        }
        #expect(catalog.tmux.map(\.name) == ["dev"])
    }

    @Test @MainActor
    func fallsBackToTmuxOnlyWhenHerdrIsMissing() async throws {
        var commands: [String] = []
        let catalog = try await MuxDiscovery.discover { command in
            commands.append(command)
            if command == MuxCommands.herdrSessionList {
                return SSHExecResult(stdout: "", stderr: "zsh: command not found: herdr", exitStatus: 127)
            }
            #expect(command == MuxCommands.tmuxList)
            return SSHExecResult(
                stdout: "dev: 2 windows (created Sun Sep  1 00:00:00 2026) (attached)\n",
                stderr: "",
                exitStatus: 0
            )
        }
        #expect(commands == [MuxCommands.herdrSessionList, MuxCommands.tmuxList])
        #expect(catalog.tmux.map(\.name) == ["dev"])
        #expect(catalog.agents.isEmpty)
    }

    @Test @MainActor
    func doesNotFallBackToTmuxOnInvalidHerdrJSON() async {
        var commands: [String] = []
        await #expect(throws: MuxDiscoveryError.invalidJSON) {
            try await MuxDiscovery.discover { command in
                commands.append(command)
                return SSHExecResult(stdout: "{", stderr: "", exitStatus: 0)
            }
        }
        #expect(commands == [MuxCommands.herdrSessionList])
    }

    @Test @MainActor
    func doesNotFallBackToTmuxOnHerdrPermissionFailure() async {
        var commands: [String] = []
        await #expect(throws: MuxDiscoveryError.execFailed) {
            try await MuxDiscovery.discover { command in
                commands.append(command)
                return SSHExecResult(stdout: "", stderr: "denied", exitStatus: 1)
            }
        }
        #expect(commands == [MuxCommands.herdrSessionList])
    }

    @Test @MainActor
    func doesNotFallBackToTmuxOnRejectedExec() async {
        var commands: [String] = []
        await #expect(throws: MuxDiscoveryError.execRejected) {
            try await MuxDiscovery.discover { _ in
                commands.append("called")
                throw SSHExecError.rejected
            }
        }
        #expect(commands == ["called"])
    }

    @Test @MainActor
    func tmuxNoServerIsEmptyCatalogEvenWhenExitIsNonzero() async throws {
        let catalog = try await MuxDiscovery.discover { command in
            if command == MuxCommands.herdrSessionList {
                return SSHExecResult(stdout: "", stderr: "command not found", exitStatus: 127)
            }
            return SSHExecResult(
                stdout: "",
                stderr: "no server running on /tmp/tmux-501/default",
                exitStatus: 1
            )
        }
        #expect(catalog.isEmpty)
    }

    @Test @MainActor
    func tmuxMissingAfterHerdrMissingIsAClearError() async {
        await #expect(throws: MuxDiscoveryError.neitherMuxAvailable) {
            try await MuxDiscovery.discover { command in
                SSHExecResult(stdout: "", stderr: "command not found", exitStatus: 127)
            }
        }
        #expect(MuxDiscoveryError.neitherMuxAvailable.errorDescription?.contains("Herdr") == true)
        #expect(MuxDiscoveryError.neitherMuxAvailable.errorDescription?.contains("tmux") == true)
        #expect(MuxDiscoveryError.neitherMuxAvailable.errorDescription?.contains("Zellij") == true)
    }

    @Test @MainActor
    func fallsBackToZellijWhenHerdrAndTmuxAreMissing() async throws {
        var commands: [String] = []
        let catalog = try await MuxDiscovery.discover { command in
            commands.append(command)
            if command == MuxCommands.zellijList {
                return SSHExecResult(stdout: "agents\nwork\n", stderr: "", exitStatus: 0)
            }
            return SSHExecResult(stdout: "", stderr: "command not found", exitStatus: 127)
        }
        #expect(commands == [
            MuxCommands.herdrSessionList,
            MuxCommands.tmuxList,
            MuxCommands.zellijList,
        ])
        #expect(catalog.zellij.map(\.name) == ["agents", "work"])
    }

    @Test
    func attachCommandsQuoteTargetsSafely() {
        let agent = HerdrAgent(
            paneID: "%1; rm -rf /",
            agent: "codex",
            status: nil,
            cwd: nil,
            foregroundCWD: nil,
            terminalTitle: nil,
            focused: false,
            workspaceID: nil,
            tabID: nil,
            terminalID: nil
        )
        let session = HerdrSession(name: "it's main", isRunning: true, isDefault: false)
        let tmux = TmuxSession(name: "-n weird $name", windowCount: 1, isAttached: false)
        let zellij = ZellijSession(name: "it's work")

        #expect(
            MuxRow.herdrAgent(agent).attachCommand
                == MuxCommands.withUserPath("herdr agent attach '%1; rm -rf /' --takeover")
        )
        #expect(
            MuxRow.herdrSession(session).attachCommand
                == MuxCommands.withUserPath("herdr session attach 'it'\\''s main'")
        )
        #expect(MuxRow.tmux(tmux).attachCommand == MuxCommands.withUserPath("tmux attach -t '-n weird $name'"))
        #expect(MuxRow.zellij(zellij).attachCommand == MuxCommands.withUserPath("zellij attach 'it'\\''s work'"))
        #expect(MuxRow.herdrAgent(agent).attachCommand.contains("--takeover"))
        #expect(MuxCommands.herdrControl(target: agent.paneID, cols: 43, rows: 24).contains("--takeover"))
        #expect(MuxCommands.herdrControl(target: agent.paneID, cols: 43, rows: 24).contains("terminal session control"))
        #expect(
            MuxRow.herdrAgent(agent).previewCommand
                == MuxCommands.withUserPath("herdr pane read '%1; rm -rf /' --source visible --format ansi --raw")
        )
    }

    @Test
    func posixSingleQuoteHandlesSpacesDashesUnicodeAndMetacharacters() {
        #expect(ShellQuote.posixSingle("plain") == "'plain'")
        #expect(ShellQuote.posixSingle("has space") == "'has space'")
        #expect(ShellQuote.posixSingle("-n") == "'-n'")
        #expect(ShellQuote.posixSingle("日本語") == "'日本語'")
        #expect(ShellQuote.posixSingle("a`b$(c)|d") == "'a`b$(c)|d'")
        #expect(ShellQuote.posixSingle("it's") == "'it'\\''s'")
    }

    @Test
    func pickerRowsDoNotExposeSocketPathsOrCommandsAsTitles() {
        let session = HerdrSession(name: "main", isRunning: true, isDefault: true)
        let row = MuxRow.herdrSession(session)
        #expect(row.title == "main")
        #expect(row.subtitle == "Default · Running")
        #expect(row.subtitle?.contains("sock") != true)
    }

    @Test
    func agentRowsUseWorkspaceAsThePrimaryLabel() {
        let agent = HerdrAgent(
            paneID: "%1",
            agent: "codex",
            status: "running",
            cwd: "/Users/me/proj",
            foregroundCWD: "/Users/me/proj",
            terminalTitle: "codex · Mobile Apps",
            focused: true,
            workspaceID: "ws-1",
            tabID: "tab-1",
            terminalID: "term-1"
        )
        let row = MuxRow.herdrAgent(agent)

        #expect(row.title == "proj")
        #expect(row.subtitle == "codex · Mobile Apps")
    }

    @Test
    func agentRowsFallBackToTerminalWorkspaceThenAgentName() {
        let terminalWorkspace = HerdrAgent(
            paneID: "%1",
            agent: "codex",
            status: nil,
            cwd: nil,
            foregroundCWD: nil,
            terminalTitle: "codex · Steer",
            focused: false,
            workspaceID: nil,
            tabID: nil,
            terminalID: nil
        )
        let agentOnly = HerdrAgent(
            paneID: "%2",
            agent: "grok",
            status: nil,
            cwd: nil,
            foregroundCWD: nil,
            terminalTitle: nil,
            focused: false,
            workspaceID: nil,
            tabID: nil,
            terminalID: nil
        )

        #expect(MuxRow.herdrAgent(terminalWorkspace).title == "Steer")
        #expect(MuxRow.herdrAgent(terminalWorkspace).subtitle == "codex · Steer")
        #expect(MuxRow.herdrAgent(agentOnly).title == "grok")
        #expect(MuxRow.herdrAgent(agentOnly).subtitle == nil)
    }

    @Test @MainActor
    func attachRequiresActiveParentConnection() async {
        let session = SSHSession(onBytes: { _ in }, onReady: {}, onError: { _ in })
        await #expect(throws: SSHExecError.notConnected) {
            try await session.attachInteractive(command: "tmux attach -t 'main'", cols: 80, rows: 24)
        }
    }
}
