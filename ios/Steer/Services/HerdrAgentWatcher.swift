import Foundation
import Observation

/// Polls `herdr agent list` over the exec channel and raises local alerts when an agent's status changes.
@MainActor
@Observable
final class HerdrAgentWatcher {
    private(set) var statuses: [HerdrAgent] = []

    func clear() {
        statuses = []
    }

    /// Runs until `isActive` turns false, the task is cancelled, or the host lacks `agent list`.
    func run(
        hostName: @escaping @MainActor () -> String,
        sessionName: @escaping @MainActor () -> String?,
        isActive: @escaping @MainActor () -> Bool,
        interval: Duration,
        retryDelay: Duration,
        exec: @escaping @MainActor (String) async throws -> SSHExecResult
    ) async {
        var last: [String: String]?
        var currentRetry = retryDelay
        while isActive() {
            do { try Task.checkCancellation() } catch { return }
            let session = sessionName()
            do {
                let result = try await exec(MuxCommands.herdr("agent list", session: session))
                do { try Task.checkCancellation() } catch { return }
                guard isActive() else { return }
                if MuxDiscovery.isMissingCommand(result) || Self.isUnsupportedAgentList(result) { return }
                if let stdout = try? MuxDiscovery.stdoutForDiscovery(result),
                   var agents = try? MuxDiscovery.parseHerdrAgents(stdout) {
                    for index in agents.indices { agents[index].sessionName = session }
                    if agents != statuses { statuses = agents }
                    var next: [String: String] = [:]
                    for agent in agents {
                        let status = agent.status ?? "unknown"
                        next[agent.id] = status
                        if let last, last[agent.id] != status {
                            SteerNotifications.agentStatusChanged(hostName: hostName(), agent: agent, from: last[agent.id], to: status)
                        }
                    }
                    last = next
                }
                currentRetry = retryDelay
            } catch is CancellationError {
                return
            } catch let error as SSHExecError where error == .notConnected {
                return
            } catch {
                guard isActive() else { return }
                do { try await Task.sleep(for: currentRetry) } catch { return }
                currentRetry = min(currentRetry * 2, .seconds(8))
                continue
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    private static func isUnsupportedAgentList(_ result: SSHExecResult) -> Bool {
        if result.exitStatus == 0 { return false }
        let stderr = result.stderr.lowercased()
        return stderr.contains("unknown command")
            || stderr.contains("unrecognized")
            || stderr.contains("no such command")
    }
}
