import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct SSHExecResult: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitStatus: Int?
    var stdoutData = Data()
}

enum SSHExecError: LocalizedError, Equatable {
    case notConnected
    case rejected
    case failed
    case closed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected."
        case .rejected:
            return "The SSH server rejected the command."
        case .failed:
            return "The remote command failed."
        case .closed:
            return "The command channel closed before it finished."
        case .timedOut:
            return "The remote command timed out."
        }
    }
}

func sshUserMessage(for error: Error, host: String? = nil, port: Int? = nil) -> String {
    let connectionError = error as? NIOConnectionError
    let timedOut: Bool
    if case .connectTimeout = error as? ChannelError { timedOut = true } else { timedOut = false }
    let unreachable = (error as? IOError).map {
        [ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, ENETDOWN, ETIMEDOUT, EHOSTDOWN].contains($0.errnoCode)
    } ?? false
    if connectionError != nil || timedOut || unreachable {
        let address = host ?? connectionError?.host
        let port = port ?? connectionError?.port
        let endpoint = address.map { address in port.map { "\(address):\($0)" } ?? address } ?? "the host"
        return "Steer can't reach \(endpoint). Check that the machine is awake and reachable, and that Tailscale or VPN is running if this address uses one."
    }
    if error is ChannelError {
        return "The SSH connection closed. Reconnect and try again."
    }
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }
    return "The SSH connection failed. Reconnect and try again."
}

final class SSHLocalForward: @unchecked Sendable, Identifiable {
    let id = UUID()
    let localPort: Int
    private let serverChannel: Channel

    init(localPort: Int, serverChannel: Channel) {
        self.localPort = localPort
        self.serverChannel = serverChannel
    }

    func close() {
        serverChannel.close(promise: nil)
    }
}

private enum InteractiveKind {
    case loginShell
    case attached
}

private final class ClientBootstrapBox: @unchecked Sendable {
    let value: ClientBootstrap

    init(_ value: ClientBootstrap) {
        self.value = value
    }
}

/// One SSH connection + session channel with a PTY.
@MainActor
final class SSHSession {
    private let onBytes: @MainActor (ArraySlice<UInt8>) -> Void
    private let onReady: @MainActor () -> Void
    private let onError: @MainActor (String) -> Void
    private let hostKeyStore: SSHHostKeyStore

    private var group: EventLoopGroup?
    private var channel: Channel?
    /// The TCP connection to the jump host when the target is reached through one.
    private var jumpChannel: Channel?
    private var sessionChannel: Channel?
    private var execChannels: [Channel] = []
    private var pendingExecs: [ChannelWaiter<SSHExecResult>] = []
    private var pendingStreams: [ChannelWaiter<Channel>] = []
    private var pendingAttaches: [ChannelWaiter<Void>] = []
    private var pendingAttachChannels: [Channel] = []
    private var localForwards: [SSHLocalForward] = []
    private var isDisconnecting = false
    private var didReportFailure = false
    private var discardedInteractive: ObjectIdentifier?
    private var term = "xterm-256color"
    private var window = (cols: 80, rows: 24)
    private var interactiveKind = InteractiveKind.loginShell
    private var connectionID = UUID()
    private let handshakeTimeout: Duration
    private var connectionDeadline: Task<Void, Never>?
    private var waitingForHostKey = false
    /// Every session channel on this connection asks the server to forward Steer's agent.
    private var forwardAgent = false
    /// False when another transport (Mosh) provides the terminal; the connection then serves exec, streams, and forwards.
    private var opensShell = true
    /// Starts the login shell with STEER_CLIENT=1 exported.
    var exportsClientFlag = false

    /// The address the TCP connection reached, for transports that must contact the same machine. Nil through a jump host.
    var connectedAddress: String? {
        jumpChannel == nil ? channel?.remoteAddress?.ipAddress : nil
    }

    init(
        onBytes: @escaping @MainActor (ArraySlice<UInt8>) -> Void,
        onReady: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void,
        handshakeTimeout: Duration = .seconds(15),
        hostKeyStore: SSHHostKeyStore = .shared
    ) {
        self.onBytes = onBytes
        self.onReady = onReady
        self.onError = onError
        self.handshakeTimeout = handshakeTimeout
        self.hostKeyStore = hostKeyStore
    }

    func connect(
        host: Host, cols: Int, rows: Int, shell: Bool = true,
        loadCredentials: @escaping @Sendable (Host) throws -> (password: String, key: NIOSSHPrivateKey?) = SSHCredentials.load
    ) {
        disconnect()
        opensShell = shell
        isDisconnecting = false
        didReportFailure = false
        let connectionID = self.connectionID
        Task { [weak self] in
            do {
                let (credentials, jumpCredentials) = try await Task.detached(priority: .userInitiated) {
                    (try loadCredentials(host), try host.jump.map { try loadCredentials($0.host) })
                }.value
                guard let self, self.connectionID == connectionID, !self.isDisconnecting else { return }
                self.connect(host: host, cols: cols, rows: rows, credentials: credentials, jumpCredentials: jumpCredentials)
            } catch {
                guard let self, self.connectionID == connectionID else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func connect(
        host: Host, cols: Int, rows: Int,
        credentials: (password: String, key: NIOSSHPrivateKey?),
        jumpCredentials: (password: String, key: NIOSSHPrivateKey?)?
    ) {
        for creds in [credentials, jumpCredentials].compactMap({ $0 }) where creds.password.isEmpty && creds.key == nil {
            fail(SSHAuthError.noCredentials.localizedDescription)
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let connectionID = self.connectionID
        forwardAgent = host.forwardAgent
        let agent = host.forwardAgent ? SSHAgent(key: credentials.key, comment: "steer:\(host.displayName)") : nil
        let reportError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID, self?.channel != nil else { return }
                self?.fail(sshUserMessage(for: error))
            }
        }
        let reportClosed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID, self?.channel != nil else { return }
                self?.fail("Connection closed.")
            }
        }
        let reportReady: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID, !self.isDisconnecting else { return }
                self.connectionDeadline?.cancel()
                self.connectionDeadline = nil
                self.onReady()
            }
        }
        let feed: @Sendable (ArraySlice<UInt8>) -> Void = { [weak self] bytes in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID else { return }
                self?.onBytes(bytes)
            }
        }
        let reportInteractiveClosed: @Sendable (Channel) -> Void = { [weak self] child in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID else { return }
                self?.interactiveChildDidClose(child)
            }
        }
        let reportInteractiveError: @Sendable (Channel, Error) -> Void = { [weak self] child, error in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID else { return }
                self?.interactiveChildDidError(child, error)
            }
        }
        let startup = host.startupCommand
        let loginCommand = exportsClientFlag ? SteerClientFlag.loginShell : nil
        self.term = "xterm-256color"
        self.window = (cols: max(cols, 1), rows: max(rows, 1))
        self.interactiveKind = .loginShell
        let term = self.term
        let window = self.window
        let validateHostKey: @MainActor @Sendable (String, Host) async throws -> Void = { [weak self] key, host in
            guard let self, self.connectionID == connectionID, !self.isDisconnecting else { throw SSHHostKeyError.rejected }
            self.waitingForHostKey = true
            self.connectionDeadline?.cancel()
            defer {
                if self.connectionID == connectionID {
                    self.waitingForHostKey = false
                    self.startConnectionDeadline()
                }
            }
            try await self.hostKeyStore.validate(key, for: host, connectionID: connectionID)
            guard self.connectionID == connectionID, !self.isDisconnecting else { throw SSHHostKeyError.rejected }
        }

        let addClient: @Sendable (Channel, Host, (password: String, key: NIOSSHPrivateKey?), SSHAgent?) throws -> Void = { channel, target, creds, agent in
            try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                role: .client(.init(
                    userAuthDelegate: SSHAuthDelegate(username: target.username, password: creds.password, key: creds.key),
                    serverAuthDelegate: VerifyHostKey(validate: { key in try await validateHostKey(key, target) })
                )),
                allocator: channel.allocator,
                inboundChildChannelInitializer: agent.map { agent in
                    { child, type in
                        guard type == .agentForwarding else {
                            return child.eventLoop.makeFailedFuture(SSHSessionError.badChannel)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(SSHAgentChannelHandler(agent: agent))
                        }
                    }
                }
            ))
            try channel.pipeline.syncOperations.addHandler(
                SSHChannelMonitor(onError: reportError, onClosed: reportClosed)
            )
        }
        let first = host.jump?.host ?? host
        let firstCredentials = jumpCredentials ?? credentials
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try addClient(channel, first, firstCredentials, host.jump == nil ? agent : nil)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)

        let configureShell: @Sendable (Channel) throws -> Void = { child in
            try child.pipeline.syncOperations.addHandler(
                SSHShellHandler(feed: feed, onReady: reportReady, onError: reportError, term: term, window: window, startup: startup, loginCommand: loginCommand)
            )
            try child.pipeline.syncOperations.addHandler(
                SSHChannelMonitor(
                    onError: { error in reportInteractiveError(child, error) },
                    onClosed: { reportInteractiveClosed(child) }
                )
            )
        }
        // Through a jump host, the target's SSH runs inside a direct-tcpip channel on the jump connection.
        var tunnel: (@Sendable (Channel) -> EventLoopFuture<Channel>)?
        if host.jump != nil, let origin = try? SocketAddress(ipAddress: "127.0.0.1", port: 0) {
            tunnel = { jump in
                jump.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let promise = jump.eventLoop.makePromise(of: Channel.self)
                    let target = SSHChannelType.DirectTCPIP(targetHost: host.hostname, targetPort: host.port, originatorAddress: origin)
                    ssh.createChannel(promise, channelType: .directTCPIP(target)) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(SSHForwardWrapperHandler())
                            try addClient(child, host, credentials, agent)
                        }
                    }
                    return promise.futureResult
                }
            }
        }
        connect(
            bootstrap: ClientBootstrapBox(bootstrap),
            addresses: first.connectionHostnames,
            port: first.port,
            index: 0,
            connectionID: connectionID,
            configureShell: configureShell,
            tunnel: tunnel
        )
    }

    private func connect(
        bootstrap: ClientBootstrapBox,
        addresses: [String],
        port: Int,
        index: Int,
        connectionID: UUID,
        configureShell: @escaping @Sendable (Channel) throws -> Void,
        tunnel: (@Sendable (Channel) -> EventLoopFuture<Channel>)?
    ) {
        guard addresses.indices.contains(index), self.connectionID == connectionID, !isDisconnecting else { return }
        bootstrap.value.connect(host: addresses[index], port: port).whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID, !self.isDisconnecting else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                if case .failure = result, addresses.indices.contains(index + 1) {
                    self.connect(
                        bootstrap: bootstrap,
                        addresses: addresses,
                        port: port,
                        index: index + 1,
                        connectionID: connectionID,
                        configureShell: configureShell,
                        tunnel: tunnel
                    )
                    return
                }
                if case .failure(let error) = result {
                    self.fail(sshUserMessage(for: error, host: addresses[index], port: port))
                    return
                }
                self.didConnect(result, configureShell: configureShell, tunnel: tunnel)
            }
        }
    }

    var canSend: Bool {
        !isDisconnecting && channel?.isActive == true && sessionChannel?.isActive == true
    }

    func send(_ data: ArraySlice<UInt8>) {
        write(data, to: sessionChannel)
    }

    fileprivate func write(_ data: ArraySlice<UInt8>, to channel: Channel?, closeAfterWrite: Bool = false) {
        guard let channel, !data.isEmpty else { return }
        let copy = Array(data)
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: copy.count)
            buffer.writeBytes(copy)
            let write = channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
            if closeAfterWrite { write.whenComplete { _ in channel.close(promise: nil) } }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        window = (cols: cols, rows: rows)
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            sessionChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    /// Runs `command` on a new session child of the existing authenticated connection.
    /// Does not allocate a PTY or write to the interactive shell.
    func exec(_ command: String, stdin: Data? = nil, timeout: Duration = .seconds(15)) async throws -> SSHExecResult {
        guard !isDisconnecting, let parent = channel, parent.isActive else {
            throw SSHExecError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = ChannelWaiter<SSHExecResult>(continuation)
            pendingExecs.append(waiter)
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                waiter.closeChannel()
                waiter.resume(.failure(SSHExecError.timedOut))
                self?.pendingExecs.removeAll { $0 === waiter }
                self?.execChannels.removeAll { !$0.isActive }
            }
            let stdin = stdin.map(Array.init)
            let complete: @Sendable (Result<SSHExecResult, Error>) -> Void = { result in
                Task { @MainActor [weak self] in
                    deadline.cancel()
                    waiter.resume(result.mapError { error in
                        error as? SSHExecError ?? SSHExecError.failed
                    })
                    self?.pendingExecs.removeAll { $0 === waiter }
                    self?.execChannels.removeAll { !$0.isActive }
                }
            }
            let forwardAgent = forwardAgent
            parent.eventLoop.execute {
                openSessionChild(on: parent, forwardAgent: forwardAgent, configure: { child in
                    try child.pipeline.syncOperations.addHandler(
                        SSHExecHandler(command: command, stdin: stdin, onComplete: complete)
                    )
                }, onFailure: { complete(.failure($0)) }, didOpen: { child in
                    Task { @MainActor [weak self] in
                        waiter.setChannel(child)
                        self?.execChannels.append(child)
                    }
                })
            }
        }
    }

    func openExecStream(
        command: String,
        timeout: Duration = .seconds(15),
        onBytes: @escaping @MainActor (ArraySlice<UInt8>) -> Void,
        onClose: @escaping @MainActor (Result<Int?, Error>) -> Void
    ) async throws -> SSHExecStream {
        try Task.checkCancellation()
        guard !isDisconnecting, let parent = channel, parent.isActive else {
            throw SSHExecError.notConnected
        }
        let connectionID = self.connectionID
        let feed: @Sendable (ArraySlice<UInt8>) -> Void = { bytes in
            DispatchQueue.main.async { [weak self] in
                guard self?.connectionID == connectionID else { return }
                onBytes(bytes)
            }
        }
        let closed: @Sendable (Result<Int?, Error>) -> Void = { result in
            DispatchQueue.main.async { [weak self] in
                guard self?.connectionID == connectionID else { return }
                onClose(result)
            }
        }
        let waiterBox = StreamWaiterBox()
        let child = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Channel, Error>) in
            let waiter = ChannelWaiter<Channel>(continuation)
            waiterBox.install(waiter)
            guard waiter.isPending else { return }
            pendingStreams.append(waiter)
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.pendingStreams.contains(where: { $0 === waiter }) else { return }
                self.pendingStreams.removeAll { $0 === waiter }
                waiter.closeChannel()
                waiter.resume(.failure(SSHExecError.timedOut))
                self.execChannels.removeAll { !$0.isActive }
            }
            let forwardAgent = forwardAgent
            parent.eventLoop.execute {
                let onHandshakeFailed: @Sendable (Error) -> Void = { error in
                    deadline.cancel()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.pendingStreams.contains(where: { $0 === waiter }) else { return }
                        self.pendingStreams.removeAll { $0 === waiter }
                        waiter.resume(.failure(error as? SSHExecError ?? SSHExecError.failed))
                    }
                }
                openSessionChild(on: parent, forwardAgent: forwardAgent, configure: { child in
                    try child.pipeline.syncOperations.addHandler(
                        SSHStreamHandler(command: command, feed: feed, onAccepted: {
                            deadline.cancel()
                            DispatchQueue.main.async { [weak self] in
                                self?.finishStream(waiter: waiter, child: child)
                            }
                        }, onHandshakeFailed: onHandshakeFailed, onClosed: { result in
                            Task { @MainActor [weak self] in
                                self?.execChannels.removeAll { !$0.isActive }
                            }
                            closed(result)
                        })
                    )
                }, onFailure: onHandshakeFailed, didOpen: { child in
                    Task { @MainActor in
                        waiter.setChannel(child)
                    }
                })
            }
        }
        } onCancel: {
            waiterBox.cancel()
        }
        return SSHExecStream(session: self, channel: child)
    }

    func checkConnection() async throws {
        do {
            _ = try await exec("true", timeout: .seconds(4))
        } catch SSHExecError.rejected {
            // A server rejection still proves that the SSH transport is responding.
        }
    }

    func openLocalForward(remoteHost: String, remotePort: Int) async throws -> SSHLocalForward {
        guard !isDisconnecting, let parent = channel, parent.isActive, let group else {
            throw SSHExecError.notConnected
        }
        guard (1...65_535).contains(remotePort) else {
            throw SSHForwardError.invalidPort
        }
        let forward = try await withCheckedThrowingContinuation { continuation in
            startLocalForward(
                group: group,
                parent: parent,
                remoteHost: remoteHost,
                remotePort: remotePort
            ) { result in
                continuation.resume(with: result)
            }
        }
        localForwards.append(forward)
        return forward
    }

    /// Opens a fresh PTY child and runs `command` via SSH exec. Replaces the interactive child only after both requests are accepted.
    func attachInteractive(command: String, cols: Int, rows: Int, timeout: Duration = .seconds(15)) async throws {
        guard !isDisconnecting, let parent = channel, parent.isActive else {
            throw SSHExecError.notConnected
        }
        if cols > 0, rows > 0 {
            window = (cols: cols, rows: rows)
        }
        let term = term
        let window = window
        let command = command
        let connectionID = self.connectionID
        let feed: @Sendable (ArraySlice<UInt8>) -> Void = { [weak self] bytes in
            Task { @MainActor [weak self] in
                guard self?.connectionID == connectionID else { return }
                self?.onBytes(bytes)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waiter = ChannelWaiter<Void>(continuation)
            pendingAttaches.append(waiter)
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.failAttach(waiter: waiter, error: SSHExecError.timedOut)
            }
            let forwardAgent = forwardAgent
            parent.eventLoop.execute {
                let onHandshakeFailed: @Sendable (Error) -> Void = { error in
                    deadline.cancel()
                    Task { @MainActor [weak self] in
                        self?.failAttach(waiter: waiter, error: error)
                    }
                }
                openSessionChild(
                    on: parent,
                    forwardAgent: forwardAgent,
                    configure: { child in
                        try child.pipeline.syncOperations.addHandler(
                            SSHAttachHandler(
                                command: command,
                                feed: feed,
                                onAccepted: {
                                    deadline.cancel()
                                    Task { @MainActor [weak self] in
                                        self?.finishAttach(waiter: waiter, child: child)
                                    }
                                },
                                onHandshakeFailed: onHandshakeFailed,
                                term: term,
                                window: window
                            )
                        )
                        try child.pipeline.syncOperations.addHandler(
                            SSHChannelMonitor(
                                onError: { [weak self] error in
                                    Task { @MainActor [weak self] in self?.interactiveChildDidError(child, error) }
                                },
                                onClosed: { [weak self] in
                                    Task { @MainActor [weak self] in self?.interactiveChildDidClose(child) }
                                }
                            )
                        )
                    },
                    onFailure: onHandshakeFailed,
                    didOpen: { child in
                        waiter.setChannel(child)
                        Task { @MainActor [weak self] in
                            guard let self, self.connectionID == connectionID,
                                  self.pendingAttaches.contains(where: { $0 === waiter }) else { return }
                            self.pendingAttachChannels.append(child)
                        }
                    }
                )
            }
        }
    }

    func disconnect() {
        isDisconnecting = true
        connectionDeadline?.cancel()
        connectionDeadline = nil
        waitingForHostKey = false
        hostKeyStore.cancel(connectionID: connectionID)
        connectionID = UUID()
        let execs = execChannels
        execChannels.removeAll()
        for waiter in pendingExecs {
            waiter.resume(.failure(SSHExecError.closed))
        }
        pendingExecs.removeAll()
        for waiter in pendingStreams {
            waiter.resume(.failure(SSHExecError.closed))
        }
        pendingStreams.removeAll()
        for waiter in pendingAttaches {
            waiter.resume(.failure(SSHExecError.closed))
        }
        pendingAttaches.removeAll()
        let attaching = pendingAttachChannels
        pendingAttachChannels.removeAll()
        for child in execs + attaching {
            child.close(promise: nil)
        }
        localForwards.forEach { $0.close() }
        localForwards.removeAll()
        let channel = channel
        let jump = jumpChannel
        let group = group
        self.channel = nil
        jumpChannel = nil
        sessionChannel = nil
        self.group = nil
        if let tcp = jump ?? channel, let group {
            tcp.closeFuture.whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
            channel?.close(promise: nil)
            jump?.close(promise: nil)
        } else if let group {
            group.shutdownGracefully { _ in }
        }
    }

    private func didConnect(
        _ result: Result<Channel, Error>,
        configureShell: @escaping @Sendable (Channel) throws -> Void,
        tunnel: (@Sendable (Channel) -> EventLoopFuture<Channel>)?
    ) {
        switch result {
        case .failure(let error):
            fail(sshUserMessage(for: error))
        case .success(let channel):
            guard group != nil else {
                channel.close(promise: nil)
                return
            }
            self.channel = channel
            startConnectionDeadline()
            guard let tunnel else {
                startTerminal(on: channel, configure: configureShell)
                return
            }
            jumpChannel = channel
            let connectionID = connectionID
            tunnel(channel).whenComplete { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.connectionID == connectionID, !self.isDisconnecting else {
                        if case .success(let target) = result { target.close(promise: nil) }
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.fail("The jump host couldn't reach this server. \(sshUserMessage(for: error))")
                    case .success(let target):
                        self.channel = target
                        self.startTerminal(on: target, configure: configureShell)
                    }
                }
            }
        }
    }

    private func startTerminal(on channel: Channel, configure: @escaping @Sendable (Channel) throws -> Void) {
        guard !opensShell else {
            openLoginShell(on: channel, configure: configure)
            return
        }
        // Without a shell, the first exec completing proves authentication finished.
        let connectionID = connectionID
        Task { [weak self] in
            do {
                do {
                    _ = try await self?.exec("true", timeout: .seconds(120))
                } catch SSHExecError.rejected {
                    // A rejected exec still came from an authenticated server.
                }
                guard let self, self.connectionID == connectionID, !self.isDisconnecting else { return }
                self.connectionDeadline?.cancel()
                self.connectionDeadline = nil
                self.onReady()
            } catch {
                guard let self, self.connectionID == connectionID else { return }
                self.fail(sshUserMessage(for: error))
            }
        }
    }

    private func openLoginShell(on channel: Channel, configure: @escaping @Sendable (Channel) throws -> Void) {
        let connectionID = self.connectionID
        let finish: @Sendable (Result<Channel, Error>) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == connectionID, !self.isDisconnecting else {
                    if case .success(let child) = result { child.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error):
                    self.fail(sshUserMessage(for: error))
                case .success(let child):
                    self.sessionChannel = child
                    self.interactiveKind = .loginShell
                }
            }
        }
        openSessionChild(
            on: channel,
            forwardAgent: forwardAgent,
            configure: configure,
            onFailure: { finish(.failure($0)) },
            didOpen: { finish(.success($0)) }
        )
    }

    private func finishStream(waiter: ChannelWaiter<Channel>, child: Channel) {
        guard pendingStreams.contains(where: { $0 === waiter }), waiter.isPending else {
            pendingStreams.removeAll { $0 === waiter }
            child.close(promise: nil)
            return
        }
        pendingStreams.removeAll { $0 === waiter }
        guard !isDisconnecting, channel?.isActive == true, child.isActive else {
            child.close(promise: nil)
            waiter.resume(.failure(SSHExecError.closed))
            return
        }
        execChannels.append(child)
        waiter.setChannel(child)
        waiter.resume(.success(child))
    }

    private func finishAttach(waiter: ChannelWaiter<Void>, child: Channel) {
        guard pendingAttaches.contains(where: { $0 === waiter }) else {
            child.close(promise: nil)
            return
        }
        pendingAttachChannels.removeAll { $0 === child }
        pendingAttaches.removeAll { $0 === waiter }
        guard !isDisconnecting, channel?.isActive == true, child.isActive else {
            child.close(promise: nil)
            waiter.resume(.failure(SSHExecError.closed))
            return
        }
        let old = sessionChannel
        if let old {
            discardedInteractive = ObjectIdentifier(old)
        }
        sessionChannel = child
        interactiveKind = .attached
        waiter.resume(.success(()))
        old?.close(promise: nil)
    }

    private func failAttach(waiter: ChannelWaiter<Void>, error: Error) {
        guard pendingAttaches.contains(where: { $0 === waiter }) else { return }
        waiter.closeChannel()
        pendingAttaches.removeAll { $0 === waiter }
        pendingAttachChannels.removeAll { !$0.isActive }
        if error is SSHExecError || error is SSHRequestError {
            waiter.resume(.failure(error))
        } else {
            waiter.resume(.failure(SSHExecError.failed))
        }
    }

    private func interactiveChildDidClose(_ child: Channel) {
        guard !isDisconnecting else { return }
        if discardedInteractive == ObjectIdentifier(child) {
            discardedInteractive = nil
            return
        }
        guard child === sessionChannel else { return }
        if !pendingAttaches.isEmpty { return }
        sessionChannel = nil
        if channel?.isActive == true {
            switch interactiveKind {
            case .loginShell:
                fail("Connection closed.")
            case .attached:
                fail("The attached session ended. Reconnect to open a new shell.")
            }
        } else {
            fail("Connection closed.")
        }
    }

    private func interactiveChildDidError(_ child: Channel, _ error: Error) {
        guard !isDisconnecting else { return }
        if discardedInteractive == ObjectIdentifier(child) { return }
        guard child === sessionChannel else { return }
        if !pendingAttaches.isEmpty { return }
        fail(sshUserMessage(for: error))
    }

    private func fail(_ message: String) {
        guard !isDisconnecting, !didReportFailure else { return }
        connectionDeadline?.cancel()
        connectionDeadline = nil
        didReportFailure = true
        disconnect()
        onError(message)
    }

    private func startConnectionDeadline() {
        guard !isDisconnecting, !waitingForHostKey, channel?.isActive == true else { return }
        connectionDeadline?.cancel()
        let connectionID = self.connectionID
        connectionDeadline = Task { [weak self, handshakeTimeout] in
            do { try await Task.sleep(for: handshakeTimeout) } catch { return }
            guard let self, self.connectionID == connectionID, !Task.isCancelled else { return }
            self.fail("The SSH handshake timed out. Reconnect and try again.")
        }
    }
}

/// Runs under sh so POSIX syntax (`VAR=x; export VAR`, `$(...)`) works when the login shell is fish or csh.
private func posixShell(_ command: String) -> String {
    "sh -c " + ShellQuote.posixSingle(command)
}

/// Opens a session child on the connection; `configure` adds its handlers on the event loop.
private func openSessionChild(
    on parent: Channel,
    forwardAgent: Bool,
    configure: @escaping @Sendable (Channel) throws -> Void,
    onFailure: @escaping @Sendable (Error) -> Void,
    didOpen: @escaping @Sendable (Channel) -> Void
) {
    parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
        let promise = parent.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(promise, channelType: .session) { child, channelType in
            guard channelType == .session else {
                return child.eventLoop.makeFailedFuture(SSHSessionError.badChannel)
            }
            return child.eventLoop.makeCompletedFuture {
                if forwardAgent { try child.pipeline.syncOperations.addHandler(SSHAgentRequestHandler()) }
                try configure(child)
            }
        }
        return promise.futureResult
    }.whenComplete { result in
        switch result {
        case .failure(let error):
            onFailure(error)
        case .success(let child):
            didOpen(child)
        }
    }
}

private enum SSHSessionError: Error {
    case badChannel
}

private enum SSHForwardError: LocalizedError {
    case invalidPort
    case missingLocalPort
    case invalidChannel

    var errorDescription: String? {
        switch self {
        case .invalidPort: "Enter a port from 1 to 65535."
        case .missingLocalPort: "Couldn't open the local preview port."
        case .invalidChannel: "The SSH server rejected TCP forwarding."
        }
    }
}

/// Resumes a continuation once and owns the child channel until the caller takes it.
private final class ChannelWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var channel: Channel?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Closes a channel that opens after the waiter already finished.
    func setChannel(_ channel: Channel) {
        lock.lock()
        if continuation == nil, self.channel == nil {
            lock.unlock()
            channel.close(promise: nil)
            return
        }
        self.channel = channel
        lock.unlock()
    }

    func closeChannel() {
        lock.lock()
        let channel = self.channel
        self.channel = nil
        lock.unlock()
        channel?.close(promise: nil)
    }
}

@MainActor
final class SSHExecStream {
    private let session: SSHSession
    private let channel: Channel
    private var closed = false

    init(session: SSHSession, channel: Channel) {
        self.session = session
        self.channel = channel
    }

    var isActive: Bool { !closed && channel.isActive }

    func send(_ data: ArraySlice<UInt8>) {
        guard isActive else { return }
        session.write(data, to: channel)
    }

    func close() {
        closed = true
        channel.close(promise: nil)
    }

    func close(sending data: ArraySlice<UInt8>) {
        guard isActive, !data.isEmpty else { close(); return }
        closed = true
        session.write(data, to: channel, closeAfterWrite: true)
    }
}

private final class StreamWaiterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: ChannelWaiter<Channel>?
    private var cancelled = false

    func install(_ waiter: ChannelWaiter<Channel>) {
        lock.lock()
        self.waiter = waiter
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            waiter.closeChannel()
            waiter.resume(.failure(CancellationError()))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiter = self.waiter
        lock.unlock()
        waiter?.closeChannel()
        waiter?.resume(.failure(CancellationError()))
    }
}

private final class SSHStreamHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let feed: @Sendable (ArraySlice<UInt8>) -> Void
    private let onAccepted: @Sendable () -> Void
    private let onHandshakeFailed: @Sendable (Error) -> Void
    private let onClosed: @Sendable (Result<Int?, Error>) -> Void
    private var didRequest = false
    private var accepted = false
    private var handshakeFinished = false
    private var finished = false
    private var exitStatus: Int?

    init(
        command: String,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        onAccepted: @escaping @Sendable () -> Void,
        onHandshakeFailed: @escaping @Sendable (Error) -> Void,
        onClosed: @escaping @Sendable (Result<Int?, Error>) -> Void
    ) {
        self.command = command
        self.feed = feed
        self.onAccepted = onAccepted
        self.onHandshakeFailed = onHandshakeFailed
        self.onClosed = onClosed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        if context.channel.isActive {
            requestExec(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        requestExec(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        if payload.type == .channel {
            feed(bytes[...])
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            accepted = true
            finishHandshake(.success(()))
        case is ChannelFailureEvent:
            finishHandshake(.failure(SSHExecError.rejected))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishClose()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finishClose()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !accepted {
            finishHandshake(.failure(error))
        }
        finishClose(error)
        context.close(promise: nil)
    }

    private func requestExec(context: ChannelHandlerContext) {
        guard !didRequest else { return }
        didRequest = true
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            promise: nil
        )
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: posixShell(command), wantReply: true),
            promise: nil
        )
    }

    private func finishHandshake(_ result: Result<Void, Error>) {
        guard !handshakeFinished else { return }
        handshakeFinished = true
        switch result {
        case .success:
            onAccepted()
        case .failure(let error):
            onHandshakeFailed(error)
        }
    }

    private func finishClose(_ error: Error? = nil) {
        guard !finished else { return }
        finished = true
        if !handshakeFinished {
            finishHandshake(.failure(error ?? SSHExecError.closed))
        }
        if let error {
            onClosed(.failure(error))
        } else if accepted {
            onClosed(.success(exitStatus))
        } else {
            onClosed(.failure(SSHExecError.closed))
        }
    }
}

/// Exec child only. Must not use `SSHChannelMonitor` — closing this channel is not a PTY/parent drop.
private final class SSHExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdin: [UInt8]?
    private let onComplete: @Sendable (Result<SSHExecResult, Error>) -> Void
    private var stdout = [UInt8]()
    private var stderr = [UInt8]()
    private var exitStatus: Int?
    private var didRequest = false
    private var accepted = false
    private var completed = false

    init(
        command: String,
        stdin: [UInt8]?,
        onComplete: @escaping @Sendable (Result<SSHExecResult, Error>) -> Void
    ) {
        self.command = command
        self.stdin = stdin
        self.onComplete = onComplete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        if context.channel.isActive {
            requestExec(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        requestExec(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        switch payload.type {
        case .channel:
            stdout.append(contentsOf: bytes)
        case .stdErr:
            stderr.append(contentsOf: bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            accepted = true
            if let stdin, !stdin.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: stdin.count)
                buffer.writeBytes(stdin)
                let channel = context.channel
                context.writeAndFlush(
                    wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
                ).whenComplete { _ in
                    channel.close(mode: .output, promise: nil)
                }
            } else {
                context.close(mode: .output, promise: nil)
            }
        case is ChannelFailureEvent:
            finish(.failure(SSHExecError.rejected))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishExec()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finishExec()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    private func requestExec(context: ChannelHandlerContext) {
        guard !didRequest else { return }
        didRequest = true
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: posixShell(command), wantReply: true),
            promise: nil
        )
    }

    private func finishExec() {
        if accepted {
            finish(
                .success(
                    SSHExecResult(
                        stdout: String(decoding: stdout, as: UTF8.self),
                        stderr: String(decoding: stderr, as: UTF8.self),
                        exitStatus: exitStatus,
                        stdoutData: Data(stdout)
                    )
                )
            )
        } else {
            finish(.failure(SSHExecError.closed))
        }
    }

    private func finish(_ result: Result<SSHExecResult, Error>) {
        guard !completed else { return }
        completed = true
        onComplete(result)
    }
}

private func startLocalForward(
    group: EventLoopGroup,
    parent: Channel,
    remoteHost: String,
    remotePort: Int,
    complete: @escaping @Sendable (Result<SSHLocalForward, Error>) -> Void
) {
    ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { inbound in
            let origin = inbound.remoteAddress ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
            guard let origin else {
                return inbound.eventLoop.makeFailedFuture(SSHForwardError.invalidChannel)
            }
            return parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                let target = SSHChannelType.DirectTCPIP(
                    targetHost: remoteHost,
                    targetPort: remotePort,
                    originatorAddress: origin
                )
                sshHandler.createChannel(promise, channelType: .directTCPIP(target)) { child, channelType in
                    guard case .directTCPIP = channelType else {
                        return child.eventLoop.makeFailedFuture(SSHForwardError.invalidChannel)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        let (localGlue, sshGlue) = SSHForwardGlueHandler.matchedPair()
                        try child.pipeline.syncOperations.addHandler(SSHForwardWrapperHandler())
                        try child.pipeline.syncOperations.addHandler(sshGlue)
                        try inbound.pipeline.syncOperations.addHandler(localGlue)
                    }
                }
                return promise.futureResult.map { _ in () }
            }
        }
        .bind(host: "127.0.0.1", port: 0)
        .whenComplete { result in
            switch result {
            case .failure(let error):
                complete(.failure(error))
            case .success(let server):
                guard let port = server.localAddress?.port else {
                    server.close(promise: nil)
                    complete(.failure(SSHForwardError.missingLocalPort))
                    return
                }
                complete(.success(SSHLocalForward(localPort: port, serverChannel: server)))
            }
        }
}

/// Adapts SSH channel payloads to ordinary TCP byte buffers for direct forwarding.
private final class SSHForwardWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .channel = payload.type, case .byteBuffer(let buffer) = payload.data else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }
}

/// Backpressure-aware pair that joins a loopback TCP socket to an SSH direct-tcpip child.
private final class SSHForwardGlueHandler {
    private var partner: SSHForwardGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (SSHForwardGlueHandler, SSHForwardGlueHandler) {
        let first = SSHForwardGlueHandler()
        let second = SSHForwardGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerClose() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension SSHForwardGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        context = nil
        partner = nil
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context _: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClose()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        partner?.partnerClose()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

private final class VerifyHostKey: NIOSSHClientServerAuthenticationDelegate {
    let validate: @MainActor @Sendable (String) async throws -> Void

    init(validate: @escaping @MainActor @Sendable (String) async throws -> Void) {
        self.validate = validate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let validate = validate
        Task { @MainActor in
            do {
                try await validate(key)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

/// Reports errors and closure of the channel it is added to.
private final class SSHChannelMonitor: ChannelInboundHandler {
    typealias InboundIn = Any
    private let onError: @Sendable (Error) -> Void
    private let onClosed: @Sendable () -> Void

    init(onError: @escaping @Sendable (Error) -> Void, onClosed: @escaping @Sendable () -> Void) {
        self.onError = onError
        self.onClosed = onClosed
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClosed()
        context.fireChannelInactive()
    }
}

private final class SSHShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let feed: @Sendable (ArraySlice<UInt8>) -> Void
    private let onReady: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let term: String
    private let window: (cols: Int, rows: Int)
    private let startup: String
    private let loginCommand: String?
    private var requestState = RequestState.awaitingPTY

    init(
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        onReady: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        term: String,
        window: (cols: Int, rows: Int),
        startup: String,
        loginCommand: String? = nil
    ) {
        self.loginCommand = loginCommand
        self.feed = feed
        self.onReady = onReady
        self.onError = onError
        self.term = term
        self.window = window
        self.startup = startup
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: term,
                terminalCharacterWidth: window.cols,
                terminalRowHeight: window.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            ),
            promise: nil
        )
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        feed(bytes[...])
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch requestState {
            case .awaitingPTY:
                requestShell(context: context)
            case .awaitingShell:
                shellIsReady(context: context)
            case .ready:
                context.fireUserInboundEventTriggered(event)
            }
        case is ChannelFailureEvent:
            let error: SSHRequestError = requestState == .awaitingPTY ? .ptyRejected : .shellRejected
            onError(error)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func requestShell(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            promise: nil
        )
        requestState = .awaitingShell
        if let loginCommand {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: posixShell(loginCommand), wantReply: true),
                promise: nil
            )
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
    }

    private func shellIsReady(context: ChannelHandlerContext) {
        requestState = .ready
        onReady()
        guard !startup.isEmpty else { return }
        var buffer = context.channel.allocator.buffer(capacity: startup.utf8.count + 1)
        buffer.writeString(startup)
        buffer.writeInteger(UInt8(ascii: "\n"))
        context.writeAndFlush(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: nil
        )
    }

    private enum RequestState {
        case awaitingPTY
        case awaitingShell
        case ready
    }
}

private enum SSHRequestError: LocalizedError {
    case ptyRejected
    case shellRejected
    case execRejected

    var errorDescription: String? {
        switch self {
        case .ptyRejected:
            return "The SSH server rejected the terminal request."
        case .shellRejected:
            return "The SSH server rejected the shell request."
        case .execRejected:
            return "The SSH server rejected the attach request."
        }
    }
}

private final class SSHAttachHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let feed: @Sendable (ArraySlice<UInt8>) -> Void
    private let onAccepted: @Sendable () -> Void
    private let onHandshakeFailed: @Sendable (Error) -> Void
    private let term: String
    private let window: (cols: Int, rows: Int)
    private var requestState = RequestState.awaitingPTY
    private var handshakeFinished = false

    init(
        command: String,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void,
        onAccepted: @escaping @Sendable () -> Void,
        onHandshakeFailed: @escaping @Sendable (Error) -> Void,
        term: String,
        window: (cols: Int, rows: Int)
    ) {
        self.command = command
        self.feed = feed
        self.onAccepted = onAccepted
        self.onHandshakeFailed = onHandshakeFailed
        self.term = term
        self.window = window
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: term,
                terminalCharacterWidth: window.cols,
                terminalRowHeight: window.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            ),
            promise: nil
        )
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        feed(bytes[...])
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch requestState {
            case .awaitingPTY:
                requestExec(context: context)
            case .awaitingExec:
                requestState = .ready
                finishHandshake(.success(()))
            case .ready:
                context.fireUserInboundEventTriggered(event)
            }
        case is ChannelFailureEvent:
            let error: SSHRequestError = requestState == .awaitingPTY ? .ptyRejected : .execRejected
            finishHandshake(.failure(error))
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if requestState != .ready {
            finishHandshake(.failure(SSHExecError.closed))
        }
        context.fireChannelInactive()
    }

    private func requestExec(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            promise: nil
        )
        requestState = .awaitingExec
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: posixShell(command), wantReply: true),
            promise: nil
        )
    }

    private func finishHandshake(_ result: Result<Void, Error>) {
        guard !handshakeFinished else { return }
        handshakeFinished = true
        switch result {
        case .success:
            onAccepted()
        case .failure(let error):
            onHandshakeFailed(error)
        }
    }

    private enum RequestState {
        case awaitingPTY
        case awaitingExec
        case ready
    }
}
