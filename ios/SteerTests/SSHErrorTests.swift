import Foundation
import NIOCore
import Testing
@testable import Steer

struct SSHErrorTests {
    @Test @MainActor func closedPortNamesTheUnreachableEndpoint() async throws {
        var message: String?
        let ssh = SSHSession(onBytes: { _ in }, onReady: { Issue.record("Port 1 should be closed") }, onError: { message = $0 })
        defer { ssh.disconnect() }
        ssh.connect(host: Host(name: "Unreachable", hostname: "127.0.0.1", username: "test", port: 1),
                    cols: 80, rows: 24, loadCredentials: { _ in ("test", nil) })
        let deadline = ContinuousClock.now + .seconds(10)
        while message == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let error = try #require(message)
        #expect(error.contains("can't reach"))
        #expect(error.contains("127.0.0.1:1"))
        #expect(error.contains("awake"))
        #expect(error.contains("Tailscale or VPN"))
        #expect(!error.lowercased().contains("connection closed"))
    }

    @Test func closedNIOChannelsProduceAnActionableMessage() {
        let message = sshUserMessage(for: ChannelError.eof)
        #expect(message == "The SSH connection closed. Reconnect and try again.")
        #expect(!message.contains("NIOCore"))
        #expect(!message.contains("Error 0"))
    }

    @Test func commandTimeoutHasAReadableMessage() {
        #expect(SSHExecError.timedOut.errorDescription == "The remote command timed out.")
    }
}
