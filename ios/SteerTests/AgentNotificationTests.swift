import Foundation
import Testing
@testable import Steer

struct AgentNotificationTests {
    @Test
    func notifiesOnPermissionAndTurnEnd() {
        #expect(SteerNotifications.agentTransitionTitle(agentName: "claude", from: "working", to: "blocked") == "claude needs permission")
        #expect(SteerNotifications.agentTransitionTitle(agentName: "claude", from: "working", to: "done") == "claude finished")
        #expect(SteerNotifications.agentTransitionTitle(agentName: "claude", from: "working", to: "idle") == "claude finished")
        #expect(SteerNotifications.agentTransitionTitle(agentName: "claude", from: "idle", to: "working") == nil)
        #expect(SteerNotifications.agentTransitionTitle(agentName: "claude", from: "blocked", to: "idle") == nil)
    }

    @Test @MainActor
    func transientAgentStatusFailureRetriesThenStopsOnDisconnect() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        let json = """
        {"id":"req-1","result":{"type":"agent_list","agents":[{"agent":"codex","pane_id":"%1","agent_status":"running"}]}}
        """
        var calls = 0
        let watch = Task {
            await controller.watchAgents(interval: .milliseconds(5), retryDelay: .milliseconds(5)) { _ in
                calls += 1
                if calls == 1 { throw SSHExecError.timedOut }
                return SSHExecResult(stdout: json, stderr: "", exitStatus: 0)
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.agentWatcher.statuses.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.agentWatcher.statuses.contains { $0.paneID == "%1" })
        #expect(calls >= 2)
        controller.disconnect()
        await watch.value
        let finished = calls
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls == finished)
    }

    @Test @MainActor
    func missingHerdrAgentCommandStopsWatching() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        var calls = 0
        await controller.watchAgents(interval: .milliseconds(5), retryDelay: .milliseconds(5)) { _ in
            calls += 1
            return SSHExecResult(stdout: "", stderr: "command not found: herdr", exitStatus: 127)
        }
        #expect(calls == 1)
        #expect(controller.agentWatcher.statuses.isEmpty)
    }

    @Test @MainActor
    func closedExecChildRetriesOnTheSameConnection() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        let json = """
        {"id":"req-1","result":{"type":"agent_list","agents":[{"agent":"codex","pane_id":"%1","agent_status":"running"}]}}
        """
        var calls = 0
        let watch = Task {
            await controller.watchAgents(interval: .milliseconds(5), retryDelay: .milliseconds(5)) { _ in
                calls += 1
                if calls == 1 { throw SSHExecError.closed }
                return SSHExecResult(stdout: json, stderr: "", exitStatus: 0)
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.agentWatcher.statuses.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.agentWatcher.statuses.contains { $0.paneID == "%1" })
        #expect(calls >= 2)
        controller.disconnect()
        await watch.value
    }

    @Test @MainActor
    func cancellingInFlightSuccessDoesNotPublishStatuses() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        let json = """
        {"id":"req-1","result":{"type":"agent_list","agents":[{"agent":"codex","pane_id":"%1","agent_status":"running"}]}}
        """
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (released, releaseSignal) = AsyncStream<Void>.makeStream()
        defer { startSignal.finish(); releaseSignal.finish() }
        let watch = Task {
            await controller.watchAgents(interval: .milliseconds(5), retryDelay: .milliseconds(5)) { _ in
                startSignal.yield()
                for await _ in released { break }
                return SSHExecResult(stdout: json, stderr: "", exitStatus: 0)
            }
        }
        for await _ in started { break }
        watch.cancel()
        releaseSignal.yield()
        await watch.value
        #expect(controller.agentWatcher.statuses.isEmpty)
    }

    @Test @MainActor
    func successfulAgentJSONWithUnrecognizedDoesNotStopWatching() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        let json = """
        {"id":"req-1","result":{"type":"agent_list","agents":[{"agent":"codex","pane_id":"%1","agent_status":"unrecognized"}]}}
        """
        var calls = 0
        let watch = Task {
            await controller.watchAgents(interval: .milliseconds(5), retryDelay: .milliseconds(5)) { _ in
                calls += 1
                return SSHExecResult(stdout: json, stderr: "", exitStatus: 0)
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while calls < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(calls >= 2)
        #expect(controller.agentWatcher.statuses.contains { $0.status == "unrecognized" })
        controller.disconnect()
        await watch.value
    }

    @Test @MainActor
    func cancellingAgentWatchStopsRetries() async throws {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        controller.phase = .connected
        var calls = 0
        let watch = Task {
            await controller.watchAgents(interval: .seconds(2), retryDelay: .milliseconds(5)) { _ in
                calls += 1
                throw SSHExecError.timedOut
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while calls == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        watch.cancel()
        await watch.value
        let finished = calls
        try await Task.sleep(for: .milliseconds(40))
        #expect(calls == finished)
        #expect(calls >= 1)
    }
}
