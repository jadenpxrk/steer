import Foundation
import Testing
@testable import Steer

struct MuxDiscoveryTests {
    @Test
    func missingTabPaneNeverFallsBackToAnotherTab() throws {
        let panes = try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"}]}}"#)
        let tabs = try MuxDiscovery.parseHerdrTabs(#"{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1"},{"tab_id":"w1:t2","workspace_id":"w1"}]}}"#)
        let catalog = MuxCatalog(agents: panes, sessions: [], tmux: [], tabs: tabs)
        #expect(catalog.listings.first?.tabs.map(\.tab.tabID) == ["w1:t1"])
    }

    @Test
    func allPaneCommandsKeepTheirNamedSession() {
        let session = "team's"
        let prefix = "herdr --session 'team'\\''s'"
        for command in [
            MuxCommands.herdrPaneRead("w1:p1", session: session, source: "visible"),
            MuxCommands.herdrControl(target: "w1:p1", cols: 43, rows: 24, session: session),
        ] {
            #expect(command.contains(prefix))
        }
    }

    @Test
    func parsesHerdrWorkspaceAndTabLists() throws {
        let workspaces = try MuxDiscovery.parseHerdrWorkspaces(
            #"{"id":"1","result":{"type":"workspace_list","workspaces":[{"workspace_id":"ws-1","label":"Steer","number":2,"tab_count":3,"focused":true}]}}"#
        )
        let tabs = try MuxDiscovery.parseHerdrTabs(
            #"{"id":"2","result":{"type":"tab_list","tabs":[{"tab_id":"tab-1","workspace_id":"ws-1","label":"Codex","number":4,"focused":false}]}}"#
        )

        #expect(workspaces == [
            HerdrWorkspace(
                workspaceID: "ws-1",
                label: "Steer",
                number: 2,
                tabCount: 3,
                focused: true
            )
        ])
        #expect(tabs == [
            HerdrTab(
                tabID: "tab-1",
                workspaceID: "ws-1",
                label: "Codex",
                number: 4,
                focused: false
            )
        ])
    }

    @Test
    func parsesTmuxWindowsAndBuildsSafeJumpCommands() {
        // Output of real tmux for this format, including a name with a colon.
        let windows = MuxDiscovery.parseTmuxWindows(
            "0:1:editor\n2:0:notes: todo\n",
            session: "it's main"
        )

        #expect(windows.count == 2)
        #expect(windows[0].name == "editor")
        #expect(windows[0].active)
        #expect(windows[1].index == 2)
        #expect(windows[1].name == "notes: todo")
        #expect(!windows[1].active)
        #expect(
            MuxJumpTarget.tmuxWindow(windows[1]).focusCommand
                == MuxCommands.withUserPath("tmux select-window -t 'it'\\''s main:2'")
        )
        #expect(
            MuxCommands.tmuxWindowList(session: "it's main")
                == MuxCommands.withUserPath(
                    "tmux list-windows -t 'it'\\''s main' -F '#{window_index}:#{window_active}:#{window_name}'"
                )
        )
    }

    @Test
    func herdrJumpCommandsQuoteIdentifiers() {
        let workspace = HerdrWorkspace(
            workspaceID: "ws;$(bad)",
            label: nil,
            number: nil,
            tabCount: nil,
            focused: false
        )
        let tab = HerdrTab(
            tabID: "tab'one",
            workspaceID: nil,
            label: nil,
            number: nil,
            focused: false
        )

        #expect(
            MuxJumpTarget.herdrWorkspace(workspace).focusCommand
                == MuxCommands.withUserPath("herdr workspace focus 'ws;$(bad)'")
        )
        #expect(
            MuxJumpTarget.herdrTab(tab).focusCommand
                == MuxCommands.withUserPath("herdr tab focus 'tab'\\''one'")
        )
    }

    @Test
    func parsesVerifiedHerdrAgentListEnvelope() throws {
        let json = """
        {
          "id": "req-1",
          "result": {
            "type": "agent_list",
            "agents": [
              {
                "agent": "codex",
                "agent_status": "running",
                "cwd": "/Users/me/proj",
                "focused": true,
                "foreground_cwd": "/Users/me/proj",
                "pane_id": "%1",
                "revision": 3,
                "state_change_seq": 9,
                "tab_id": "tab-a",
                "terminal_id": "term-a",
                "terminal_title": "codex · proj",
                "terminal_title_stripped": "codex",
                "workspace_id": "ws-1"
              },
              {
                "agent": "grok",
                "pane_id": "%2"
              }
            ]
          }
        }
        """

        let agents = try MuxDiscovery.parseHerdrAgents(json)

        #expect(agents.count == 2)
        #expect(agents[0].paneID == "%1")
        #expect(agents[0].agent == "codex")
        #expect(agents[0].status == "running")
        #expect(agents[0].cwd == "/Users/me/proj")
        #expect(agents[0].foregroundCWD == "/Users/me/proj")
        #expect(agents[0].terminalTitle == "codex · proj")
        #expect(agents[0].focused == true)
        #expect(agents[0].workspaceID == "ws-1")
        #expect(agents[0].tabID == "tab-a")
        #expect(agents[0].terminalID == "term-a")
        #expect(agents[1].paneID == "%2")
        #expect(agents[1].agent == "grok")
        #expect(agents[1].focused == false)
        #expect(agents[1].cwd == nil)
        #expect(agents[1].status == nil)
    }

    @Test
    func groupsRowsByWorkspaceMembership() {
        let first = HerdrAgent(
            paneID: "%1",
            agent: "grok",
            status: nil,
            cwd: "/tmp/alpha",
            foregroundCWD: nil,
            terminalTitle: "alpha",
            focused: false,
            workspaceID: "ws-a",
            tabID: nil,
            terminalID: nil
        )
        let second = HerdrAgent(
            paneID: "%2",
            agent: "grok",
            status: nil,
            cwd: "/tmp/beta",
            foregroundCWD: nil,
            terminalTitle: "beta",
            focused: false,
            workspaceID: "ws-b",
            tabID: nil,
            terminalID: nil
        )
        let catalog = MuxCatalog(
            agents: [first, second],
            sessions: [],
            tmux: [],
            workspaceNames: ["ws-a": "Alpha", "ws-b": "Beta"]
        )

        #expect(catalog.listings.map(\.title) == ["Alpha", "Beta"])
    }

    @Test
    func collapsesAgentsInTheSameWorkspaceToOneListing() {
        let first = HerdrAgent(
            paneID: "%1",
            agent: "grok",
            status: nil,
            cwd: "/tmp/alpha",
            foregroundCWD: nil,
            terminalTitle: "one",
            focused: true,
            workspaceID: "ws-a",
            tabID: "tab-a",
            terminalID: nil
        )
        let second = HerdrAgent(
            paneID: "%2",
            agent: "codex",
            status: nil,
            cwd: "/tmp/alpha",
            foregroundCWD: nil,
            terminalTitle: "two",
            focused: false,
            workspaceID: "ws-a",
            tabID: "tab-b",
            terminalID: nil
        )
        let catalog = MuxCatalog(
            agents: [first, second],
            sessions: [],
            tmux: [],
            workspaceNames: ["ws-a": "Alpha"],
            tabs: [
                HerdrTab(tabID: "tab-a", workspaceID: "ws-a", label: "Main", number: 1, focused: true),
                HerdrTab(tabID: "tab-b", workspaceID: "ws-a", label: "Build", number: 2, focused: false),
            ]
        )

        #expect(catalog.listings.count == 1)
        #expect(catalog.listings[0].title == "Alpha")
        #expect(catalog.listings[0].tabCount == 2)
        #expect(catalog.listings[0].tabs.map(\.title) == ["Main", "Build"])
        #expect(catalog.listings[0].tabs.map(\.attach) == [
            MuxRow.herdrAgent(first),
            MuxRow.herdrAgent(second),
        ])
        #expect(catalog.listings[0].attach == MuxRow.herdrAgent(first))
    }

    @Test
    func tabDisplayTitleUsesPaneTitleWhenMuxLabelIsJunk() {
        let tab = HerdrTab(tabID: "tab-2", workspaceID: "ws-a", label: "'", number: 2, focused: true)
        let agent = HerdrAgent(
            paneID: "%2",
            agent: "codex",
            status: nil,
            cwd: "/tmp/alpha",
            foregroundCWD: nil,
            terminalTitle: "Review auth tokens in login",
            focused: true,
            workspaceID: "ws-a",
            tabID: "tab-2",
            terminalID: nil
        )
        #expect(tab.displayTitle(agent: agent) == "Review auth tokens")
        #expect(HerdrTab(tabID: "tab-1", workspaceID: "ws-a", label: "1", number: 1, focused: false)
            .displayTitle(agent: nil) == "Tab 1")
        #expect(HerdrTab(tabID: "tab-3", workspaceID: "ws-a", label: "Build", number: 3, focused: false)
            .displayTitle(agent: agent) == "Build")
    }

    @Test
    func parsesVerifiedHerdrSessionListEnvelope() throws {
        let json = """
        {
          "sessions": [
            {
              "default": true,
              "name": "main",
              "running": true,
              "session_dir": "/tmp/herdr/main",
              "socket_path": "/tmp/herdr/main.sock"
            },
            {
              "default": false,
              "name": "side",
              "running": false
            }
          ]
        }
        """

        let sessions = try MuxDiscovery.parseHerdrSessions(json)

        #expect(sessions.count == 2)
        #expect(sessions[0].name == "main")
        #expect(sessions[0].isDefault == true)
        #expect(sessions[0].isRunning == true)
        #expect(sessions[1].name == "side")
        #expect(sessions[1].isDefault == false)
        #expect(sessions[1].isRunning == false)
    }

    @Test
    func ignoresUnknownJSONKeys() throws {
        let agentsJSON = """
        {
          "extra": true,
          "result": {
            "agents": [
              {
                "pane_id": "%9",
                "agent": "codex",
                "mystery": { "nested": 1 }
              }
            ],
            "future_field": "ok"
          }
        }
        """
        let sessionsJSON = """
        {
          "sessions": [
            { "name": "keep", "running": true, "default": false, "color": "blue" }
          ],
          "cursor": "next"
        }
        """

        let agents = try MuxDiscovery.parseHerdrAgents(agentsJSON)
        let sessions = try MuxDiscovery.parseHerdrSessions(sessionsJSON)

        #expect(agents.map(\.paneID) == ["%9"])
        #expect(sessions.map(\.name) == ["keep"])
    }

    @Test
    func failsWhenHerdrAgentTargetIsMissing() {
        let json = """
        { "result": { "agents": [ { "agent": "codex", "cwd": "/tmp" } ] } }
        """
        #expect(throws: MuxDiscoveryError.missingTarget) {
            try MuxDiscovery.parseHerdrAgents(json)
        }
    }

    @Test
    func failsWhenHerdrSessionNameIsMissing() {
        let json = """
        { "sessions": [ { "running": true, "default": true } ] }
        """
        #expect(throws: MuxDiscoveryError.missingTarget) {
            try MuxDiscovery.parseHerdrSessions(json)
        }
    }

    @Test
    func failsOnMalformedHerdrJSON() {
        #expect(throws: MuxDiscoveryError.invalidJSON) {
            try MuxDiscovery.parseHerdrAgents("{")
        }
        #expect(throws: MuxDiscoveryError.invalidJSON) {
            try MuxDiscovery.parseHerdrSessions("not json")
        }
        #expect(throws: MuxDiscoveryError.unusableOutput) {
            try MuxDiscovery.parseHerdrAgents(#"{ "id": 1, "result": { "type": "agent_list" } }"#)
        }
    }

    @Test
    func parsesTmuxLsLinesAndIgnoresDiagnostics() {
        let output = """

        main: 2 windows (created Sun Sep  1 00:00:00 2026) [80x24] (attached)
        extra text that is not a session

        side: 1 windows (created Sun Sep  1 00:00:00 2026)
        no server running on /tmp/tmux-501/default
        """

        let sessions = MuxDiscovery.parseTmuxSessions(output)

        #expect(sessions.count == 2)
        #expect(sessions[0].name == "main")
        #expect(sessions[0].windowCount == 2)
        #expect(sessions[0].isAttached == true)
        #expect(sessions[1].name == "side")
        #expect(sessions[1].windowCount == 1)
        #expect(sessions[1].isAttached == false)
    }

    @Test
    func tmuxNoServerRunningIsNotASession() {
        let sessions = MuxDiscovery.parseTmuxSessions("no server running on /tmp/tmux-501/default\n")
        #expect(sessions.isEmpty)
    }

    @Test
    func classifiesExecResultsForFallback() throws {
        let ok = try MuxDiscovery.stdoutForDiscovery(
            SSHExecResult(stdout: #"{"sessions":[]}"#, stderr: "", exitStatus: 0)
        )
        #expect(ok.contains("sessions"))

        #expect(throws: MuxDiscoveryError.commandMissing) {
            try MuxDiscovery.stdoutForDiscovery(
                SSHExecResult(stdout: "", stderr: "zsh: command not found: herdr\n", exitStatus: 127)
            )
        }
        #expect(throws: MuxDiscoveryError.execFailed) {
            try MuxDiscovery.stdoutForDiscovery(
                SSHExecResult(stdout: "", stderr: "denied", exitStatus: 1)
            )
        }
        #expect(MuxDiscovery.mapExecError(SSHExecError.rejected) == .execRejected)
        #expect(MuxDiscovery.mapExecError(SSHExecError.closed) == .execFailed)
        #expect(MuxDiscovery.isMissingCommand(SSHExecResult(stdout: "", stderr: "", exitStatus: 127)))
    }

    @Test
    func discoveryCommandsAreTheVerifiedCLI() {
        let prefix = #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; "#
        #expect(MuxCommands.herdrSessionList == prefix + "herdr session list --json")
        #expect(MuxCommands.tmuxList == prefix + "tmux ls")
        #expect(MuxCommands.zellijList == prefix + "zellij list-sessions --short --no-formatting")
    }

    @Test @MainActor
    func execRequiresActiveParentConnection() async {
        let session = SSHSession(onBytes: { _ in }, onReady: {}, onError: { _ in })
        await #expect(throws: SSHExecError.notConnected) {
            try await session.exec("herdr agent list")
        }
    }
}
