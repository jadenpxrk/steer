import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm
import Testing
@testable import Steer

@Suite(.serialized)
@MainActor
struct SSHConnectionIntegrationTests {
    @Test
    func closedHerdrStreamShowsErrorAndRecoversOverTheSameSSH() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        try KeychainStore.save(password: "fixture", privateKey: "", for: host.id)
        let controller = TerminalController(host: host)
        defer { controller.disconnect(); KeychainStore.removeCredentials(for: host.id); server.stop(host: host) }
        let pane = try #require(try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"review-close","workspace_id":"work","tab_id":"tab"}]}}"#).first)
        controller.pendingMux = .herdrAgent(pane)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        try await waitUntil { controller.isTerminalReady }
        try await waitUntil { controller.muxAttachError != nil }
        #expect(controller.phase == .connected)
        #expect(!controller.isTerminalReady)
        #expect(!controller.send(Array("lost".utf8)[...]))
        #expect(controller.pendingMux == .herdrAgent(pane))
        await controller.recoverConnection()
        try await waitUntil { controller.isTerminalReady }
        #expect(controller.phase == .connected)
        #expect(controller.muxAttachError == nil)
        #expect(server.commands.withLockedValue { $0.filter { $0.contains("terminal session control") }.count } == 2)
        #expect(server.clients.withLockedValue { $0.count } == 1)
        #expect(controller.send(Array("ok".utf8)[...]))
    }

    @Test
    func failedInitialHerdrAttachKeepsTheSelectedTarget() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        try KeychainStore.save(password: "fixture", privateKey: "", for: host.id)
        let controller = TerminalController(host: host)
        defer { controller.disconnect(); KeychainStore.removeCredentials(for: host.id); server.stop(host: host) }
        let pane = try #require(try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"fail-attach","workspace_id":"work","tab_id":"tab"}]}}"#).first)
        controller.pendingMux = .herdrAgent(pane)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        try await waitUntil { controller.muxAttachError != nil }
        #expect(controller.phase == .connected)
        #expect(!controller.isTerminalReady)
        #expect(controller.pendingMux == .herdrAgent(pane))
        #expect(controller.attachedMux == nil)
    }

    @Test
    func leavingDuringStreamRecoveryReleasesControl() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        try KeychainStore.save(password: "fixture", privateKey: "", for: host.id)
        let controller = TerminalController(host: host)
        defer { controller.disconnect(); KeychainStore.removeCredentials(for: host.id); server.stop(host: host) }
        let pane = try #require(try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"review-close","workspace_id":"work","tab_id":"tab"}]}}"#).first)
        controller.pendingMux = .herdrAgent(pane)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        try await waitUntil { controller.muxAttachError != nil && !controller.isTerminalReady }
        let recovery = Task { await controller.recoverConnection() }
        try await waitUntil {
            server.commands.withLockedValue { $0.filter { $0.contains("terminal session control") }.count } >= 2
        }
        controller.detach()
        await recovery.value
        #expect(!controller.isTerminalReady)
        #expect(!controller.muxIsAttaching)
        #expect(controller.pendingMux == .herdrAgent(pane))
        try await waitUntil { server.input.withLockedValue { $0.contains("terminal.release") } }
    }

    @Test
    func phoneControlReleasesOnBackgroundAndExitAndReusesSSH() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        try KeychainStore.save(password: "fixture", privateKey: "", for: host.id)
        let controller = TerminalController(host: host)
        defer { controller.disconnect(); KeychainStore.removeCredentials(for: host.id); server.stop(host: host) }
        let pane = try #require(try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"native-pane","workspace_id":"work","tab_id":"tab"}]}}"#).first)
        controller.pendingMux = .herdrAgent(pane)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        try await waitUntil { controller.isTerminalReady }
        #expect(server.commands.withLockedValue { $0.filter { $0.contains("terminal session control") }.count } == 1)
        let payload: [UInt8] = [65, 0, 66, 13]
        controller.send(payload[...])
        let input = String(decoding: HerdrTerminalCommand.input(payload[...]), as: UTF8.self)
        try await waitUntil { server.input.withLockedValue { $0.contains(input) } }
        controller.setTerminalActive(false)
        try await waitUntil { server.input.withLockedValue { $0.contains("terminal.release") } }
        #expect(!controller.isTerminalReady)
        controller.setTerminalActive(true)
        try await waitUntil { controller.isTerminalReady }
        #expect(server.commands.withLockedValue { $0.filter { $0.contains("terminal session control") }.count } == 2)
        controller.detach()
        try await waitUntil { server.input.withLockedValue { $0.components(separatedBy: "terminal.release").count == 3 } }
        #expect(!controller.isTerminalReady)
        #expect(controller.pendingMux == .herdrAgent(pane))
        #expect(server.clients.withLockedValue { $0.count } == 1)
    }

    @Test
    func leavingDuringPhoneAttachReleasesTheUnfinishedStream() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        try KeychainStore.save(password: "fixture", privateKey: "", for: host.id)
        let controller = TerminalController(host: host)
        defer { controller.disconnect(); KeychainStore.removeCredentials(for: host.id); server.stop(host: host) }
        let pane = try #require(try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"stall","workspace_id":"work","tab_id":"tab"}]}}"#).first)
        controller.pendingMux = .herdrAgent(pane)
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        controller.attach(view)
        try await waitUntil { server.commands.withLockedValue { $0.contains { $0.contains("terminal session control") } } }
        controller.send(Array("PENDING_INPUT".utf8)[...])
        #expect(controller.muxAttachError != nil)
        controller.detach()
        try await waitUntil { server.input.withLockedValue { $0.contains("terminal.release") } }
        #expect(server.input.withLockedValue { !$0.contains("PENDING_INPUT") })
        #expect(!controller.isTerminalReady)
        #expect(!controller.muxIsAttaching)
        #expect(controller.attachedMux == nil)
    }

    @Test
    func stalledHandshakeStopsConnecting() async throws {
        let server = try await SSHTestServer.start(stallHandshake: true)
        var errors: [String] = []
        let host = server.host()
        let session = SSHSession(onBytes: { _ in }, onReady: {
            Issue.record("A silent server cannot finish the SSH handshake")
        }, onError: { errors.append($0) }, handshakeTimeout: .milliseconds(100))
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { !errors.isEmpty }
        #expect(errors == ["The SSH handshake timed out. Reconnect and try again."])
    }

    @Test
    func hostKeyApprovalPausesTheHandshakeDeadline() async throws {
        let server = try await SSHTestServer.start()
        let suite = "SSHConnectionIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let hostKeys = SSHHostKeyStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        var ready = false
        var errors: [String] = []
        let host = server.host(pinKey: false)
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) },
                                 handshakeTimeout: .milliseconds(200), hostKeyStore: hostKeys)
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { hostKeys.pending?.host.id == host.id || !errors.isEmpty }
        try #require(hostKeys.pending?.host.id == host.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(errors.isEmpty)
        hostKeys.resolve(accept: true)
        try await waitUntil { ready || !errors.isEmpty }
        #expect(ready)
        #expect(errors.isEmpty)
    }

    @Test
    func healthChecksAndAttachesReuseOneAuthenticatedConnection() async throws {
        let server = try await SSHTestServer.start()
        var ready = false
        var errors: [String] = []
        let host = server.host()
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { ready || !errors.isEmpty }
        try #require(ready)
        try await session.checkConnection()
        try await session.attachInteractive(command: "attach", cols: 80, rows: 24)
        try await session.checkConnection()
        #expect(server.clients.withLockedValue { $0.count } == 1)
        #expect(errors.isEmpty)

        let parent = try #require(server.clients.withLockedValue { $0.first })
        try await parent.close().get()
        try await waitUntil { !errors.isEmpty }
        await #expect(throws: SSHExecError.notConnected) { try await session.checkConnection() }
    }

    @Test
    func stalledRequestsTimeOutWithoutBreakingTheExistingTerminal() async throws {
        let server = try await SSHTestServer.start()
        var ready = false
        var errors: [String] = []
        let host = server.host()
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { ready || !errors.isEmpty }
        try #require(ready)

        await #expect(throws: SSHExecError.timedOut) {
            _ = try await session.exec("stall", timeout: .milliseconds(50))
        }
        await #expect(throws: SSHExecError.timedOut) {
            try await session.attachInteractive(command: "stall", cols: 80, rows: 24, timeout: .milliseconds(50))
        }
        try await session.checkConnection()
        try await session.attachInteractive(command: "attach", cols: 80, rows: 24)
        #expect(server.clients.withLockedValue { $0.count } == 1)
        #expect(errors.isEmpty)
    }

    @Test
    func execStreamStaysOpenUntilClosed() async throws {
        let server = try await SSHTestServer.start()
        var ready = false
        var errors: [String] = []
        var closed = false
        let host = server.host()
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { ready || !errors.isEmpty }
        try #require(ready)
        let stream = try await session.openExecStream(
            command: "attach",
            onBytes: { _ in },
            onClose: { _ in closed = true }
        )
        #expect(stream.isActive)
        stream.send(Array("abc".utf8)[...])
        stream.close()
        try await waitUntil { closed || !errors.isEmpty }
        #expect(closed)
        #expect(errors.isEmpty)
        try await session.checkConnection()
    }

    @Test
    func authenticatesWithAnRSAKey() async throws {
        let server = try await SSHTestServer.start()
        let host = server.host()
        let key = try OpenSSHPrivateKeyParser.parse(RSAFixture.privateKey)
        var ready = false
        var errors: [String] = []
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("", key) })
        try await waitUntil { ready || !errors.isEmpty }
        #expect(errors.isEmpty)
        #expect(ready)
    }

    @Test
    func connectsThroughAJumpHost() async throws {
        let server = try await SSHTestServer.start()
        let bastion = server.host()
        let target = Host(name: "Inner", hostname: "inner.invalid", username: "fixture", port: 2222, jump: JumpHost(bastion))
        UserDefaults.standard.set(String(openSSHPublicKey: server.key.publicKey), forKey: "ssh-host-key.\(target.id.uuidString)")
        var ready = false
        var errors: [String] = []
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer {
            session.disconnect()
            SSHHostKeyStore.shared.remove(hostID: target.id)
            server.stop(host: bastion)
        }
        session.connect(host: target, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { ready || !errors.isEmpty }
        #expect(errors.isEmpty)
        try #require(ready)
        #expect(server.tunnels.withLockedValue { $0 } == ["inner.invalid:2222"])
        let result = try await session.exec("echo")
        #expect(result.exitStatus == 0)
        #expect(server.clients.withLockedValue { $0.count } == 1)
    }

    @Test
    func execStreamTimesOutWithoutBreakingTheConnection() async throws {
        let server = try await SSHTestServer.start()
        var ready = false
        var errors: [String] = []
        let host = server.host()
        let session = SSHSession(onBytes: { _ in }, onReady: { ready = true }, onError: { errors.append($0) })
        defer { session.disconnect(); server.stop(host: host) }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in ("fixture", nil) })
        try await waitUntil { ready || !errors.isEmpty }
        try #require(ready)
        await #expect(throws: SSHExecError.timedOut) {
            _ = try await session.openExecStream(
                command: "stall",
                timeout: .milliseconds(50),
                onBytes: { _ in },
                onClose: { _ in }
            )
        }
        try await session.checkConnection()
        #expect(errors.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

private struct SSHTestServer {
    let group: MultiThreadedEventLoopGroup
    let listener: Channel
    let key: NIOSSHPrivateKey
    let clients: NIOLockedValueBox<[Channel]>
    let commands: NIOLockedValueBox<[String]>
    let input: NIOLockedValueBox<String>
    /// `host:port` of every direct-tcpip request; each is served by a nested in-process SSH server.
    let tunnels: NIOLockedValueBox<[String]>

    static func start(stallHandshake: Bool = false) async throws -> SSHTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        let clients = NIOLockedValueBox<[Channel]>([])
        let commands = NIOLockedValueBox<[String]>([])
        let input = NIOLockedValueBox("")
        let tunnels = NIOLockedValueBox<[String]>([])
        func serverHandler(_ channel: Channel) -> NIOSSHHandler {
            NIOSSHHandler(
                role: .server(.init(hostKeys: [key], userAuthDelegate: SSHTestAuthentication())),
                allocator: channel.allocator,
                inboundChildChannelInitializer: { child, type in
                    child.eventLoop.makeCompletedFuture {
                        if case .directTCPIP(let target) = type {
                            tunnels.withLockedValue { $0.append("\(target.targetHost):\(target.targetPort)") }
                            try child.pipeline.syncOperations.addHandler(SSHTestTunnelWrapper())
                            try child.pipeline.syncOperations.addHandler(serverHandler(child))
                        } else {
                            try child.pipeline.syncOperations.addHandler(SSHTestShell(commands: commands, input: input))
                        }
                    }
                }
            )
        }
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                clients.withLockedValue { $0.append(channel) }
                if stallHandshake { return channel.eventLoop.makeSucceededVoidFuture() }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(serverHandler(channel))
                }
            }
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .bind(host: "127.0.0.1", port: 0).get()
        return SSHTestServer(
            group: group, listener: listener, key: key, clients: clients, commands: commands, input: input, tunnels: tunnels
        )
    }

    @MainActor
    func host(pinKey: Bool = true) -> Host {
        let host = Host(name: "SSH fixture", hostname: "127.0.0.1", username: "fixture", port: listener.localAddress!.port!)
        if pinKey {
            UserDefaults.standard.set(String(openSSHPublicKey: key.publicKey), forKey: "ssh-host-key.\(host.id.uuidString)")
        }
        return host
    }

    @MainActor
    func stop(host: Host) {
        SSHHostKeyStore.shared.remove(hostID: host.id)
        clients.withLockedValue { $0 }.forEach { $0.close(promise: nil) }
        listener.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}

/// Carries the nested SSH connection's bytes over a direct-tcpip child channel.
private final class SSHTestTunnelWrapper: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

private final class SSHTestAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]

    /// Password "fixture", or the RSA fixture key (NIOSSH has already verified its signature).
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == "fixture" else {
            responsePromise.succeed(.failure)
            return
        }
        switch request.request {
        case .password(let password) where password.password == "fixture":
            responsePromise.succeed(.success)
        case .publicKey(let key) where String(openSSHPublicKey: key.publicKey) == RSAFixture.publicKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

private final class SSHTestShell: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let commands: NIOLockedValueBox<[String]>
    let input: NIOLockedValueBox<String>

    init(commands: NIOLockedValueBox<[String]>, input: NIOLockedValueBox<String>) {
        self.commands = commands
        self.input = input
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .byteBuffer(let buffer) = unwrapInboundIn(data).data {
            input.withLockedValue { $0 += String(decoding: buffer.readableBytesView, as: UTF8.self) }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is SSHChannelRequestEvent.PseudoTerminalRequest, is SSHChannelRequestEvent.ShellRequest:
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        case let exec as SSHChannelRequestEvent.ExecRequest:
            let command = unwrapPOSIXShell(exec.command)
            commands.withLockedValue { $0.append(command) }
            guard command != "stall" else { return }
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            if command.contains("terminal session control") {
                guard !command.contains("'stall'") else { return }
                if command.contains("'fail-attach'") {
                    context.channel.close(promise: nil)
                    return
                }
                let args = command.split(separator: " ")
                let cols = Int(args[args.firstIndex(of: "--cols")! + 1])!
                let rows = Int(args[args.firstIndex(of: "--rows")! + 1])!
                let bytes = Data("\u{1b}[H\u{1b}[32mNATIVE".utf8).base64EncodedString()
                var buffer = context.channel.allocator.buffer(capacity: 256)
                buffer.writeString("{\"type\":\"terminal.frame\",\"seq\":1,\"width\":\(cols),\"height\":\(rows),\"full\":true,\"bytes\":\"\(bytes)\"}\n")
                context.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
                let reviewCloses = command.contains("'review-close'")
                    && self.commands.withLockedValue {
                        $0.filter { $0.contains("terminal session control") && $0.contains("'review-close'") }.count
                    } == 1
                if reviewCloses {
                    let channel = context.channel
                    channel.eventLoop.scheduleTask(in: .milliseconds(300)) { channel.close(promise: nil) }
                }
                return
            }
            if command != "attach" {
                let channel = context.channel
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Inverse of the client's `sh -c '<command>'` wrapping; fails loudly if the wrapping changes.
private func unwrapPOSIXShell(_ command: String) -> String {
    precondition(command.hasPrefix("sh -c '") && command.hasSuffix("'"), "unwrapped exec: \(command)")
    return String(command.dropFirst(7).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
}
