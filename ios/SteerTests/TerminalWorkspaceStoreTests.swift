import Foundation
import Observation
import Testing
@testable import Steer

struct TerminalWorkspaceStoreTests {
    @Test @MainActor
    func readingTheCurrentHostDoesNotPublishAnotherWorkspaceUpdate() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let controller = store.controller(for: host)
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = store.controllers
            _ = store.recentSessionIDs
        } onChange: {
            changed = true
        }
        for _ in 0..<100 {
            #expect(store.controller(for: host) === controller)
        }
        #expect(!changed)
    }

    @Test @MainActor
    func firstTabTapShowsSelectionAndLaterTapIsNotDropped() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.local", username: "me"))
        let first = HerdrTab(tabID: "one", workspaceID: "work", label: nil, number: 1, focused: false)
        let second = HerdrTab(tabID: "two", workspaceID: "work", label: nil, number: 2, focused: false)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var attached: [String] = []
        let switching = Task {
            await controller.navigation.switchToTab(first) { tab in
                attached.append(tab.id)
                if tab.id == first.id { for await _ in stream { break } }
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while attached.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(controller.selectedTabID == first.id)
        await controller.navigation.switchToTab(second) { _ in Issue.record("Concurrent attach") }
        #expect(controller.selectedTabID == second.id)
        release.finish()
        await switching.value
        #expect(attached == [first.id, second.id])
        #expect(controller.navigation.requestedTab == nil)
        await controller.navigation.switchToTab(first) { attached.append($0.id) }
        #expect(attached == [first.id, second.id, first.id])
    }

    @Test @MainActor
    func tabsKeepIndependentSavedTargetsAndNamedServers() throws {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        var panes = try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2"}]}}"#)
        for index in panes.indices { panes[index].sessionName = "main" }
        var other = panes[0]
        other.sessionName = "other"
        let targets = (panes + [other]).map(MuxRow.herdrAgent)
        let controllers = targets.map { store.session(for: host, mux: $0) }
        #expect(Set(controllers.map(\.id)).count == 3)
        #expect(store.session(for: host, mux: targets[1]) === controllers[1])
        #expect(controllers.map(\.pendingMux) == targets)
        let restored = TerminalWorkspaceStore(defaults: defaults)
        restored.restore(hosts: [host])
        for controller in controllers {
            #expect(restored.controllers[controller.id]?.pendingMux == controller.pendingMux)
        }
    }

    @Test
    func oldSavedHerdrTargetsStillDecode() throws {
        let json = #"{"paneID":"w1:p1","agent":"","focused":false,"workspaceID":"w1","tabID":"w1:t1"}"#
        let pane = try JSONDecoder().decode(HerdrAgent.self, from: Data(json.utf8))
        #expect(pane.sessionName == nil)
        #expect(pane.id == "w1:p1")
    }

    @Test @MainActor
    func changingTmuxMetadataReusesTheExistingSession() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let original = MuxRow.tmux(TmuxSession(name: "work", windowCount: 1, isAttached: false))
        let updated = MuxRow.tmux(TmuxSession(name: "work", windowCount: 3, isAttached: true))

        let first = store.session(for: host, mux: original)
        let reopened = store.session(for: host, mux: updated)

        #expect(reopened === first)
        #expect(store.sessions(for: host.id).count == 1)
    }

    @Test @MainActor
    func phoneTabSelectionDoesNotFollowDesktopFocus() {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.local", username: "me"))
        let agent = HerdrAgent(
            paneID: "phone-pane", agent: "codex", status: nil, cwd: nil, foregroundCWD: nil,
            terminalTitle: nil, focused: false, workspaceID: "work", tabID: "phone-tab", terminalID: nil
        )
        controller.pendingMux = .herdrAgent(agent)
        controller.muxIsAttaching = true
        controller.navigation.jumpTargets = [
            .herdrTab(HerdrTab(tabID: "desktop-tab", workspaceID: "work", label: nil, number: 1, focused: true)),
            .herdrTab(HerdrTab(tabID: "phone-tab", workspaceID: "work", label: nil, number: 2, focused: false))
        ]

        #expect(controller.selectedTabID == "phone-tab")
        #expect(controller.workspaceTabs.first?.focused == true)
    }

    @Test @MainActor
    func unavailableTabSwitchReportsFailureAndClearsPendingSelection() async {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.local", username: "me"))
        let tab = HerdrTab(tabID: "missing", workspaceID: "work", label: nil, number: nil, focused: false)

        await controller.navigation.switchToTab(tab)

        #expect(controller.navigation.requestedTab == nil)
        #expect(controller.navigation.jumpError != nil)
    }

    @Test @MainActor
    func renamingHostDoesNotDisconnectItsSession() {
        var host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let controller = TerminalController(host: host)
        controller.phase = .connected
        host.name = "Work Mac"
        controller.updateHost(host)
        #expect(controller.phase == .connected)
        #expect(controller.host.displayName == "Work Mac")
    }

    @Test @MainActor
    func updatesExistingSessionWhenHostChanges() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        var host = Host(name: "Mac", hostname: "old.local", username: "me")
        let original = store.controller(for: host)
        host.hostname = "new.local"
        host.username = "other"
        host.port = 2222

        let updated = store.controller(for: host)

        #expect(updated === original)
        #expect(updated.host == host)
    }

    @Test @MainActor
    func closesSessionsBeyondTheRecentLimit() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let sessions = (0..<14).map { _ in store.openNewSession(for: host) }
        for session in sessions { session.phase = .connected }

        #expect(store.recentSessionIDs.count == 12)
        #expect(store.sessions(for: host.id).count == 14)
        store.closeSessions(for: host.id)

        #expect(store.controllers.isEmpty)
        #expect(sessions.allSatisfy { $0.phase == .idle })
    }

    @Test @MainActor
    func restoresOpenedSessionAndLatestTargetUsingCurrentHost() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        var host = Host(name: "Mac", hostname: "old.local", username: "me")
        let controller = store.controller(for: host)
        store.markOpened(controller)
        let target = MuxRow.tmux(TmuxSession(name: "work", windowCount: 1, isAttached: false))
        controller.pendingMux = target
        // Background discovery must not replace the terminal the user chose.
        _ = store.openNewSession(for: host)
        host.hostname = "new.local"

        let restored = TerminalWorkspaceStore(defaults: defaults)
        restored.restore(hosts: [host])

        #expect(restored.lastOpenedSession?.id == controller.id)
        #expect(restored.lastOpenedSession?.host == host)
        #expect(restored.lastOpenedSession?.pendingMux == target)
        #expect(restored.lastOpenedSession?.phase == .idle)
        restored.close(sessionID: controller.id)
        #expect(restored.lastOpenedSession == nil)
    }

    @Test @MainActor
    func doesNotRestoreDeletedHosts() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        store.markOpened(store.controller(for: host))
        let restored = TerminalWorkspaceStore(defaults: defaults)
        restored.restore(hosts: [])
        #expect(restored.controllers.isEmpty)
        #expect(restored.recentSessionIDs.isEmpty)
        #expect(restored.lastOpenedSession == nil)
    }

    @Test @MainActor
    func disconnectPreservesTargetOnlyForReconnect() {
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let controller = TerminalController(host: host)
        let target = MuxRow.tmux(TmuxSession(name: "work", windowCount: 1, isAttached: false))
        controller.pendingMux = target
        controller.disconnect(clearMuxTarget: false)
        #expect(controller.pendingMux == target)
        #expect(controller.attachedMux == nil)
        #expect(!controller.isTerminalReady)
        controller.disconnect()
        #expect(controller.pendingMux == nil)
    }

    @Test @MainActor
    func keepsRecentHostsOrderedAndBounded() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let hosts = (0..<14).map { index in
            Host(name: "Host \(index)", hostname: "host-\(index)", username: "me")
        }

        for host in hosts {
            _ = store.controller(for: host)
        }

        #expect(store.recentHostIDs.count == 12)
        #expect(store.recentHostIDs.first == hosts.last?.id)
        #expect(store.recentHostIDs.last == hosts[2].id)
    }

    @Test @MainActor
    func reusesLatestSessionForTheSameHost() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "old.local", username: "me")
        let original = store.controller(for: host)

        let reused = store.controller(for: host)

        #expect(original === reused)
    }

    @Test @MainActor
    func opensIndependentSessionsOnTheSameHost() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let first = store.controller(for: host)
        let second = store.openNewSession(for: host)

        #expect(first !== second)
        #expect(store.sessions(for: host.id).count == 2)
        #expect(store.sessions(for: host.id).first === second)
    }

    @Test @MainActor
    func reusesSessionForTheSameMuxTarget() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let mux = MuxRow.herdrAgent(
            HerdrAgent(
                paneID: "%1",
                agent: "grok",
                status: "idle",
                cwd: "/tmp",
                foregroundCWD: nil,
                terminalTitle: "work",
                focused: false,
                workspaceID: nil,
                tabID: nil,
                terminalID: nil
            )
        )

        let first = store.session(for: host, mux: mux)
        let reused = store.session(for: host, mux: mux)

        #expect(first === reused)
        #expect(first.pendingMux == mux)
    }

    @Test @MainActor
    func opensIndependentSessionsForDifferentMuxTargets() {
        let suite = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalWorkspaceStore(defaults: defaults)
        let host = Host(name: "Mac", hostname: "mac.local", username: "me")
        let alpha = MuxRow.herdrAgent(
            HerdrAgent(
                paneID: "%1",
                agent: "grok",
                status: "idle",
                cwd: "/tmp/alpha",
                foregroundCWD: nil,
                terminalTitle: "alpha",
                focused: false,
                workspaceID: nil,
                tabID: nil,
                terminalID: nil
            )
        )
        let beta = MuxRow.herdrAgent(
            HerdrAgent(
                paneID: "%2",
                agent: "grok",
                status: "idle",
                cwd: "/tmp/beta",
                foregroundCWD: nil,
                terminalTitle: "beta",
                focused: false,
                workspaceID: nil,
                tabID: nil,
                terminalID: nil
            )
        )

        let first = store.session(for: host, mux: alpha)
        let second = store.session(for: host, mux: beta)

        #expect(first !== second)
        #expect(store.sessions(for: host.id).count == 2)
    }
}
