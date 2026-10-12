import Foundation
import SwiftTerm
import Testing
@testable import Steer

/// Runs against a real OpenSSH server (and mosh-server) started by `scripts/e2e.sh`; skipped otherwise.
@Suite(.serialized, .enabled(if: LiveServer.port != nil))
@MainActor
struct LiveServerTests {
    @Test func rsaKeyLogsIn() async throws {
        let ssh = try await LiveServer.connect(Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!))
        defer { ssh.disconnect() }
        #expect(try await ssh.exec("echo rsa-ok").stdout.contains("rsa-ok"))
    }

    @Test func agentForwardingSignsForNestedSSH() async throws {
        let host = Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, forwardAgent: true)
        let ssh = try await LiveServer.connect(host)
        defer { ssh.disconnect() }
        #expect(try await ssh.exec("ssh-add -l", timeout: .seconds(10)).stdout.contains("RSA"))
        let nested = try await ssh.exec(
            "ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p \(LiveServer.port!) \(LiveServer.address) echo nested-ok",
            timeout: .seconds(15)
        )
        #expect(nested.stdout.contains("nested-ok"))
    }

    @Test func moshServerAcknowledgesEchoedInput() async throws {
        let ssh = try await LiveServer.connect(Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!))
        defer { ssh.disconnect() }
        let connect = try await MoshConnect.start(over: ssh, running: nil)
        let mosh = try #require(MoshSession(host: LiveServer.address, port: connect.port, key: connect.key) { _ in })
        defer { mosh.shutdown() }
        var echoed = 0
        mosh.onEchoAck = { echoed = max(echoed, $0) }
        mosh.start(cols: 80, rows: 24)
        try await Task.sleep(for: .seconds(1))
        mosh.send(Array("abc".utf8)[...])
        try await LiveServer.wait(5) { echoed >= mosh.eventCount }
    }

    @Test func moshTerminalSurvivesAnSSHDrop() async throws {
        let host = Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: .mosh)
        LiveServer.pin(host)
        try KeychainStore.save(password: "", privateKey: RSAFixture.privateKey, for: host.id)
        let controller = TerminalController(host: host)
        defer {
            controller.disconnect()
            KeychainStore.removeCredentials(for: host.id)
            SSHHostKeyStore.shared.remove(hostID: host.id)
        }
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        func screen() -> String { String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self) }
        try await LiveServer.wait(15) { (controller.phase == .connected && controller.isTerminalReady) || controller.phase == .failed }
        try #require(controller.phase == .connected, "\(controller.errorMessage ?? "")")
        try await Task.sleep(for: .seconds(1))

        #expect(controller.send(Array("echo mosh-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("mosh-42\n") }
        #expect(try await controller.execRemote("echo exec-ok").stdout.contains("exec-ok"))

        // Kill this SSH connection; recovery must replace SSH while the Mosh terminal carries on.
        _ = try? await controller.execRemote("kill -9 $PPID")
        await controller.recoverConnection()
        #expect(controller.phase == .connected)
        #expect(controller.send(Array("echo after-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("after-42\n") }
        var result: SSHExecResult?
        try await LiveServer.wait(10) {
            if result == nil { Task { result = try? await controller.execRemote("echo ssh-back") } }
            return result?.stdout.contains("ssh-back") == true
        }
    }

    @Test func etTerminalReplaysInputAcrossAReconnect() async throws {
        let (controller, screen) = try await LiveServer.open(Host(
            name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: .et
        ))

        #expect(controller.send(Array("echo et-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("et-42\n") }

        // Drop the TCP connection and type before it returns; the input must be replayed to etserver.
        let et = try #require(controller.detached as? ETSession)
        et.reopenSocket()
        #expect(controller.send(Array("echo after-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("after-42\n") }
        #expect(controller.phase == .connected)
        try await LiveServer.close(controller)
    }

    @Test func healthyETConnectionSurvivesRecoveryChecks() async throws {
        let (controller, screen) = try await LiveServer.open(Host(
            name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: .et
        ))
        let et = try #require(controller.detached as? ETSession)
        let connections = et.connectionCount
        for _ in 0..<5 { await controller.recoverConnection() }
        try await Task.sleep(for: .seconds(1))
        #expect(et.connectionCount == connections)
        #expect(controller.send(Array("echo healthy-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("healthy-42\n") }
        try await LiveServer.close(controller)
    }

    @Test func editingAutoSettingsRetriesMoshAfterSSHFallback() async throws {
        var host = Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: .auto)
        host.moshServerPath = "/nonexistent/mosh-server"
        host.etPort = 1
        let (controller, screen) = try await LiveServer.open(host, timeout: 30)
        try #require(controller.activeTransport == .ssh)
        host.moshServerPath = ""
        host.etPort = nil
        controller.updateHost(host)
        try await LiveServer.wait(30) { controller.isTerminalReady && controller.phase == .connected }
        #expect(controller.activeTransport == .mosh)
        #expect(controller.send(Array("echo updated-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("updated-42\n") }
        try await LiveServer.close(controller)
    }

    @Test(arguments: [HostTransport.ssh, .mosh, .et])
    func clientFlagReachesTheRemoteShell(transport: HostTransport) async throws {
        let settings = TerminalSettingsStore()
        let saved = settings.preferences
        settings.preferences.exportClientFlag = true
        defer { settings.preferences = saved }
        let (controller, screen) = try await LiveServer.open(Host(
            name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: transport
        ))
        #expect(controller.send(Array("echo flag=$STEER_CLIENT.\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("flag=1.\n") }
        try await LiveServer.close(controller)
    }

    @Test(arguments: [
        (HostTransport.mosh, "", nil as Int?),
        (.et, "/nonexistent/mosh-server", nil),
        (.ssh, "/nonexistent/mosh-server", 1),
    ])
    func autoFallsBackFromMoshToETToSSH(expected: HostTransport, moshPath: String, etPort: Int?) async throws {
        var host = Host(name: "live", hostname: LiveServer.address, username: LiveServer.user, port: LiveServer.port!, transport: .auto)
        host.moshServerPath = moshPath
        host.etPort = etPort
        let (controller, screen) = try await LiveServer.open(host, timeout: 30)
        #expect(controller.activeTransport == expected)
        #expect(controller.send(Array("echo auto-\(6 * 7)\r".utf8)[...]))
        try await LiveServer.wait(10) { screen().contains("auto-42\n") }
        try await LiveServer.close(controller)
    }
}

@MainActor
enum LiveServer {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated static let port = environment["STEER_LIVE_SSH_PORT"].flatMap(Int.init)
    nonisolated static let user = environment["STEER_LIVE_SSH_USER"] ?? ""
    nonisolated static let hostKey = environment["STEER_LIVE_SSH_HOSTKEY"] ?? ""
    nonisolated static let address = environment["STEER_E2E_ADDRESS"] ?? "127.0.0.1"

    static func pin(_ host: Host) {
        UserDefaults.standard.set(hostKey, forKey: "ssh-host-key.\(host.id.uuidString)")
    }

    static func connect(_ host: Host) async throws -> SSHSession {
        pin(host)
        let key = try OpenSSHPrivateKeyParser.parse(RSAFixture.privateKey)
        var ready = false
        var error: String?
        let ssh = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { error = $0 })
        ssh.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("", key) })
        try await wait(10) { ready || error != nil }
        try #require(ready, "\(error ?? "")")
        return ssh
    }

    /// Connects a controller to the live server and returns it with a reader for its screen.
    static func open(_ host: Host, timeout: Int = 15) async throws -> (TerminalController, () -> String) {
        pin(host)
        try KeychainStore.save(password: "", privateKey: RSAFixture.privateKey, for: host.id)
        let controller = TerminalController(host: host)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        // Connected means SSH is up; a Mosh or ET terminal follows once its server answers.
        try await wait(timeout) { (controller.phase == .connected && controller.isTerminalReady) || controller.phase == .failed }
        try #require(controller.phase == .connected, "\(controller.errorMessage ?? "")")
        try await Task.sleep(for: .seconds(1))
        return (controller, { String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self) })
    }

    /// Closes the session and waits until the host shows nothing left running: ET ends its etterminal over SSH in
    /// the background, and the test host process may exit before that finishes.
    static func close(_ controller: TerminalController) async throws {
        controller.disconnect()
        KeychainStore.removeCredentials(for: controller.host.id)
        SSHHostKeyStore.shared.remove(hostID: controller.host.id)
        guard let state = environment["STEER_E2E_CONTROL"].flatMap(URL.init)?.appendingPathComponent("state") else { return }
        var remaining = -1
        for _ in 0..<50 {
            // Unreachable (e.g. from a phone): the harness checks the host after the run instead.
            guard let data = try? await URLSession.shared.data(from: state).0 else { return }
            let counts = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            remaining = (counts?["moshServers"] as? Int ?? 0) + (counts?["etterminals"] as? Int ?? 0)
            if remaining == 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(remaining) mosh-server/etterminal processes still running after closing the session")
    }

    static func wait(_ seconds: Int, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }
}
