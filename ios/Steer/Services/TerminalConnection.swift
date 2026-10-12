import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
final class TerminalConnection {
    enum Event {
        case bytes(ArraySlice<UInt8>)
        case ready
        case failure(String)
        case sshFailure(String)
        case sshReady
        case reconnect
        case predictions([MoshPredictor.Cell])
    }

    var host: Host
    private(set) var generation = 0
    var hasConnected = false
    private(set) var connectionCheckInProgress = false
    private(set) var ssh: SSHSession?
    /// Carries the terminal when the host uses Mosh or ET; SSH then serves discovery, tools, and forwards, and may drop and return.
    private(set) var detached: (any DetachedTerminal)?
    /// What carries the terminal on this connection; Auto resolves to Mosh, ET, or SSH.
    private(set) var activeTransport = HostTransport.ssh
    /// When the Mosh or ET server was last heard from, once it has been silent long enough to tell the user.
    private(set) var silentSince: Date?
    private var startingDetached = false
    /// Set when Auto found neither Mosh nor ET, so reconnects go straight to SSH until the host or session changes.
    var autoUsesSSH = false
    private(set) var sshReconnectInProgress = false
    var phoneGrid = (cols: 80, rows: 24)
    @ObservationIgnored private var predictor = MoshPredictor()
    @ObservationIgnored var terminal: () -> TerminalView? = { nil }
    @ObservationIgnored var isFailed: () -> Bool = { false }
    @ObservationIgnored var isConnected: () -> Bool = { false }
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }

    init(host: Host) {
        self.host = host
    }

    func updateHost(_ host: Host) -> Bool {
        let connectionChanged = self.host.hostname != host.hostname
            || self.host.username != host.username
            || self.host.port != host.port
            || self.host.fallbackHostnames != host.fallbackHostnames
            || self.host.startupCommand != host.startupCommand
            || self.host.jump != host.jump
            || self.host.forwardAgent != host.forwardAgent
            || self.host.transport != host.transport
            || self.host.moshPorts != host.moshPorts
            || self.host.moshServerPath != host.moshServerPath
            || self.host.etPort != host.etPort
        self.host = host
        return connectionChanged
    }

    var readySSH: SSHSession? { isConnected() ? ssh : nil }
    var canSend: Bool { detached != nil || ssh?.canSend == true }
    var isReady: Bool { activeTransport == .ssh || detached != nil }
    var needsDetachedTerminal: Bool { activeTransport != .ssh && detached == nil }

    func connect(cols: Int, rows: Int) {
        generation += 1
        connectionCheckInProgress = false
        let token = generation
        let transport = host.terminalTransport == .auto && autoUsesSSH ? .ssh : host.terminalTransport
        activeTransport = transport
        let session = SSHSession(
            onBytes: { [weak self] bytes in
                guard let self, self.generation == token else { return }
                self.onEvent(.bytes(bytes))
            },
            onReady: { [weak self] in
                guard let self, self.generation == token else { return }
                self.onEvent(.ready)
            },
            onError: { [weak self] message in
                guard let self, self.generation == token else { return }
                // Mosh and ET keep the terminal alive without SSH; the SSH side is renewed on the next recovery check.
                if self.detached != nil, self.isConnected() {
                    self.reconnectSSHKeepingTerminal()
                    return
                }
                self.onEvent(.sshFailure(message))
            }
        )
        ssh = session
        session.exportsClientFlag = SteerClientFlag.enabled
        session.connect(host: host, cols: cols, rows: rows, shell: transport == .ssh)
    }

    func disconnect(clearFallback: Bool) {
        generation += 1
        connectionCheckInProgress = false
        sshReconnectInProgress = false
        if clearFallback {
            hasConnected = false
            autoUsesSSH = false
        }
        retire(detached, over: ssh, thenDisconnect: true)
        ssh = nil
        detached = nil
        silentSince = nil
    }

    @discardableResult
    func send(_ data: ArraySlice<UInt8>) -> Bool {
        if let detached {
            detached.send(data)
            if let mosh = detached as? MoshSession { predict(data, eventCount: mosh.eventCount) }
            return true
        }
        guard let ssh, ssh.canSend else { return false }
        ssh.send(data)
        return true
    }

    func resize(cols: Int, rows: Int, changed: Bool) {
        if changed { detached?.resize(cols: cols, rows: rows) }
        ssh?.resize(cols: cols, rows: rows)
    }

    func exec(_ command: String, stdin: Data? = nil) async throws -> SSHExecResult {
        guard let ssh = readySSH else { throw SSHExecError.notConnected }
        return try await ssh.exec(command, stdin: stdin)
    }

    func openLocalForward(remoteHost: String, remotePort: Int) async throws -> SSHLocalForward {
        guard let ssh = readySSH else { throw SSHExecError.notConnected }
        return try await ssh.openLocalForward(remoteHost: remoteHost, remotePort: remotePort)
    }

    func attach(command: String, cols: Int, rows: Int, token: Int) async throws {
        guard let ssh = readySSH else { throw SSHExecError.notConnected }
        switch activeTransport {
        case .mosh: try await startMosh(running: command, token: token)
        case .et: try await startET(running: command, token: token)
        case .ssh, .auto: try await ssh.attachInteractive(command: command, cols: cols, rows: rows)
        }
    }

    func recover() async {
        guard let detached, !connectionCheckInProgress, !sshReconnectInProgress else { return }
        let token = generation
        connectionCheckInProgress = true
        defer { if generation == token { connectionCheckInProgress = false } }
        if let et = detached as? ETSession {
            et.recoverConnection()
        } else {
            detached.reopenSocket()
        }
        if let ssh, (try? await ssh.checkConnection()) != nil { return }
        guard generation == token, !Task.isCancelled else { return }
        reconnectSSHKeepingTerminal()
    }

    func recover(check: () async throws -> Void, reconnect: () -> Void, restoreTerminal: () async -> Void) async {
        guard hasConnected, !connectionCheckInProgress else { return }
        if isFailed() {
            reconnect()
            return
        }
        guard isConnected() else { return }
        let token = generation
        connectionCheckInProgress = true
        defer {
            if generation == token { connectionCheckInProgress = false }
        }
        do {
            try await check()
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            reconnect()
            return
        }
        if generation == token, isFailed(), !Task.isCancelled {
            reconnect()
            return
        }
        guard generation == token, isConnected(), !Task.isCancelled else { return }
        await restoreTerminal()
    }

    func startTerminalIfNeeded(visible: Bool, command: @escaping () -> String?, onStarted: @escaping () -> Void) {
        guard needsDetachedTerminal, isConnected(), !startingDetached, visible else { return }
        startingDetached = true
        let token = generation
        Task {
            await startDetachedTerminal(running: command(), token: token, onStarted: onStarted)
            startingDetached = false
        }
    }

    private func startDetachedTerminal(running command: String?, token: Int, onStarted: () -> Void) async {
        do {
            switch host.terminalTransport {
            case .et: try await startET(running: command, token: token)
            case .mosh: try await startMosh(running: command, token: token)
            default: guard try await startAutoTerminal(running: command, token: token) else { return }
            }
            activeTransport = detached is ETSession ? .et : .mosh
            guard generation == token else { return }
            onStarted()
            Task { await watchSilence(token: token) }
        } catch is CancellationError {
        } catch {
            guard generation == token else { return }
            onEvent(.failure(TerminalController.pickerMessage(for: error)))
        }
    }

    /// Starts mosh-server over SSH and moves the terminal onto a Mosh session, replacing any previous one.
    private func startMosh(running command: String?, token: Int) async throws {
        guard let ssh else { throw SSHExecError.notConnected }
        let connect = try await MoshConnect.start(over: ssh, running: command, host: host)
        let address = ssh.connectedAddress ?? host.hostname
        guard generation == token else {
            // Closed while the server was starting: tell it to exit rather than leave it on the host.
            let abandoned = MoshSession(host: address, port: connect.port, key: connect.key) { _ in }
            abandoned?.start(cols: phoneGrid.cols, rows: phoneGrid.rows)
            abandoned?.shutdown()
            throw CancellationError()
        }
        // Output is held back until the new server has answered and replaced the current session.
        let early = PendingOutput()
        guard let session = MoshSession(host: address, port: connect.port, key: connect.key, onBytes: { [weak self] bytes in
            guard let self, self.generation == token else { return }
            guard early.isReleased else { early.bytes += bytes; return }
            self.onEvent(.bytes(bytes))
            self.showPredictions()
        }) else { throw MoshError.serverUnavailable("mosh-server returned an invalid key.") }
        session.onEchoAck = { [weak self] count in
            guard let self, let terminal = self.terminal()?.getTerminal() else { return }
            self.predictor.confirm(echoedEventCount: count) { terminal.getCharacter(col: $0, row: $1) }
            self.showPredictions()
        }
        session.start(cols: phoneGrid.cols, rows: phoneGrid.rows)
        // mosh-server answers at once; silence means UDP is blocked somewhere between here and the host. Until it
        // answers, the current session stays in place, so a failed switch leaves the tab working.
        let deadline = ContinuousClock.now + .seconds(5)
        while session.lastHeard == nil {
            guard generation == token, ContinuousClock.now < deadline else {
                session.shutdown()
                throw generation == token ? MoshError.noReply : CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        predictor.resetEpoch()
        retire(detached, over: ssh)
        detached = session
        early.isReleased = true
        onEvent(.bytes(early.bytes[...]))
        showPredictions()
    }

    /// Starts etterminal over SSH and moves the terminal onto an ET session, replacing any previous one.
    private func startET(running command: String?, token: Int) async throws {
        guard let ssh else { throw SSHExecError.notConnected }
        let connect = try await ETConnect.start(over: ssh)
        guard generation == token else { throw CancellationError() }
        let address = ssh.connectedAddress ?? host.hostname
        guard let session = ETSession(host: address, port: host.etPort ?? ETSession.defaultPort, id: connect.id,
                                      passkey: connect.passkey, tag: connect.tag, onBytes: { [weak self] bytes in
            guard let self, self.generation == token else { return }
            self.onEvent(.bytes(bytes))
        }) else { throw ETError.rejected("etterminal returned an invalid key.") }
        session.onEnd = { [weak self] in
            guard let self, self.generation == token else { return }
            self.onEvent(.failure(ETError.sessionEnded.localizedDescription))
        }
        let environment = SteerClientFlag.enabled ? [SteerClientFlag.name: "1"] : [:]
        do {
            try await session.start(cols: phoneGrid.cols, rows: phoneGrid.rows, environment: environment)
        } catch {
            // Finished before returning: Auto's fallback reconnects right after, closing this SSH connection.
            await end(session, over: ssh)
            throw error
        }
        guard generation == token else {
            retire(session, over: ssh)
            throw CancellationError()
        }
        retire(detached, over: ssh)
        detached = session
        // ET always starts the login shell; a command is typed into it, replacing the shell like mosh-server's command.
        if let command { session.send(Array("exec sh -c \(ShellQuote.posixSingle(command))\r".utf8)[...]) }
    }

    /// Mosh shows local echo only when the round trip is noticeable (its 30 ms trigger).
    private func predict(_ bytes: ArraySlice<UInt8>, eventCount: Int) {
        guard let terminal = terminal()?.getTerminal(), !terminal.isCurrentBufferAlternate else { return }
        let cursor = terminal.getCursorLocation()
        predictor.typed(Array(bytes), cursor: (col: cursor.x, row: cursor.y), cols: terminal.cols, eventCount: eventCount)
        showPredictions()
    }

    private func showPredictions() {
        let cells = ((detached as? MoshSession)?.roundTrip ?? 0) > 30 ? predictor.visible : []
        onEvent(.predictions(cells))
    }

    /// Mosh and ET keep retrying silently, so a server that is gone (host rebooted, process killed) would otherwise
    /// look connected forever. Mosh shows a similar "last contact" notice.
    private func watchSilence(token: Int) async {
        while generation == token {
            try? await Task.sleep(for: .seconds(1))
            guard generation == token else { return }
            guard let heard = detached?.lastHeard, ContinuousClock.now - heard >= .seconds(10) else {
                if silentSince != nil { silentSince = nil }
                continue
            }
            // Set once per silence, so the banner doesn't redraw every second.
            if silentSince == nil {
                let seconds = (ContinuousClock.now - heard).components.seconds
                silentSince = Date().addingTimeInterval(-TimeInterval(seconds))
            }
        }
    }

    /// Auto tries Mosh, then ET; if neither works, it reconnects with a plain SSH terminal and returns false.
    private func startAutoTerminal(running command: String?, token: Int) async throws -> Bool {
        for start in [startMosh, startET] {
            do {
                try await start(command, token)
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard generation == token else { throw CancellationError() }
            }
        }
        autoUsesSSH = true
        onEvent(.reconnect)
        return false
    }

    /// Ends a Mosh or ET session. Mosh tells mosh-server itself; ET is ended over SSH (see `ETConnect.endCommand`),
    /// after which `thenDisconnect` closes that SSH connection.
    private func retire(_ session: (any DetachedTerminal)?, over ssh: SSHSession?, thenDisconnect: Bool = false) {
        session?.shutdown()
        guard let et = session as? ETSession, let ssh else {
            if thenDisconnect { ssh?.disconnect() }
            return
        }
        Task {
            await end(et, over: ssh)
            if thenDisconnect { ssh.disconnect() }
        }
    }

    private func end(_ session: ETSession, over ssh: SSHSession) async {
        session.shutdown()
        _ = try? await ssh.exec(ETConnect.endCommand(tag: session.tag), timeout: .seconds(5))
    }

    /// Replaces a dropped SSH connection without touching the Mosh or ET terminal.
    private func reconnectSSHKeepingTerminal() {
        guard !sshReconnectInProgress else { return }
        sshReconnectInProgress = true
        let token = generation
        ssh?.disconnect()
        let session = SSHSession(
            onBytes: { _ in },
            onReady: { [weak self] in
                guard let self, self.generation == token else { return }
                self.sshReconnectInProgress = false
                self.onEvent(.sshReady)
            },
            onError: { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.sshReconnectInProgress = false
                self.ssh = nil
            }
        )
        ssh = session
        session.connect(host: host, cols: phoneGrid.cols, rows: phoneGrid.rows, shell: false)
    }
}

/// Output from a Mosh session that is not yet the terminal's.
@MainActor
private final class PendingOutput {
    var bytes: [UInt8] = []
    var isReleased = false
}
