import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
final class TerminalController {
    enum Phase: String {
        case idle
        case connecting
        case connected
        case failed
    }

    let id: UUID
    private(set) var host: Host
    var phase: Phase = .idle {
        didSet { if phase == .connected { connection.hasConnected = true } }
    }
    var errorMessage: String?
    var isControlArmed = false
    /// The next terminal tap becomes a right-button click for apps with mouse reporting on.
    var isRightClickArmed = false
    var isKeyboardOpen = false
    let mux = MuxCatalogLoader()
    var muxAttachError: String?
    var muxIsAttaching = false
    var pendingMux: MuxRow? {
        didSet { onTargetChange?() }
    }
    var onTargetChange: (() -> Void)?
    var onDeviceNameResolved: ((Host, String) -> Void)?
    private(set) var attachedMux: MuxRow?
    private(set) var currentDirectory: String?
    private(set) var recentDirectories: [String] = []
    let agentWatcher = HerdrAgentWatcher()

    private let connection: TerminalConnection
    private let liveAttachment: HerdrLiveAttachment
    let navigation: TerminalNavigation
    var detached: (any DetachedTerminal)? { connection.detached }
    var activeTransport: HostTransport { connection.activeTransport }
    var silentSince: Date? { connection.silentSince }
    /// A session this tab failed to open while its Mosh or ET shell kept working; Retry opens it again.
    private(set) var failedMux: MuxRow?
    private var muxAttachID = UUID()
    private var terminalActive = true
    private var phoneGrid: (cols: Int, rows: Int) {
        get { connection.phoneGrid }
        set { connection.phoneGrid = newValue }
    }
    @ObservationIgnored private weak var terminal: TerminalView?
    private var generation: Int { connection.generation }
    @ObservationIgnored let replay = TerminalReplay()
    private var lastMuxRetryAt: ContinuousClock.Instant?

    init(host: Host, id: UUID = UUID()) {
        self.id = id
        self.host = host
        connection = TerminalConnection(host: host)
        liveAttachment = HerdrLiveAttachment(replay: replay)
        navigation = TerminalNavigation(connection: connection, mux: mux, live: liveAttachment)
        connection.isConnected = { [weak self] in self?.phase == .connected }
        connection.isFailed = { [weak self] in self?.phase == .failed }
        connection.terminal = { [weak self] in self?.terminal }
        connection.onEvent = { [weak self] in self?.handleConnectionEvent($0) }
        liveAttachment.size = { [weak self] in self?.phoneGrid ?? (80, 24) }
        liveAttachment.isActive = { [weak self] in self?.terminalActive == true }
        liveAttachment.onError = { [weak self] error in
            self?.muxAttachError = Self.pickerMessage(for: error)
            self?.lastMuxRetryAt = .now
        }
        liveAttachment.terminal = { [weak self] in self?.terminal }
        liveAttachment.generation = { [weak self] in self?.generation ?? -1 }
        navigation.attachedTarget = { [weak self] in self?.attachedMux }
        navigation.selectedTarget = { [weak self] in
            guard let self else { return nil }
            return muxIsAttaching ? pendingMux : attachedMux
        }
        navigation.workspaceTarget = { [weak self] in self?.attachedMux ?? self?.pendingMux }
        navigation.loadMux = { [weak self] in await self?.loadMux() }
        navigation.attach = { [weak self] row in
            guard let self else { throw CancellationError() }
            try await attachMux(row)
        }
    }

    func attach(_ view: TerminalView, replay: Bool = true) {
        terminal = view
        phoneGrid = (view.getTerminal().cols, view.getTerminal().rows)
        if replay, (pendingMux ?? attachedMux)?.isHerdr != true, shouldFeedTerminal, !self.replay.bytes.isEmpty {
            view.feed(byteArray: self.replay.bytes[...])
        }
        ensureConnected()
        if phase == .connected { Task { await recoverConnection() } }
        startDetachedTerminalIfNeeded()
        hideKeyboard()
    }

    func ensureConnected() {
        switch phase {
        case .idle:
            connect()
        case .failed:
            reconnect()
        case .connecting:
            break
        case .connected:
            if mux.catalog == nil, !mux.isLoading {
                Task { await loadMux() }
            }
            attachPendingMuxIfSized()
        }
    }

    func detach() {
        hideKeyboard()
        releaseHerdrControl()
        terminal = nil
    }

    func setTerminalActive(_ active: Bool) {
        guard terminalActive != active else { return }
        terminalActive = active
        if active {
            startDetachedTerminalIfNeeded()
            attachPendingMuxIfSized()
        }
        else { releaseHerdrControl() }
    }

    private func releaseHerdrControl() {
        muxAttachID = UUID()
        liveAttachment.stop()
        if (pendingMux ?? attachedMux)?.isHerdr == true { muxIsAttaching = false }
    }

    func toggleKeyboard() {
        isKeyboardOpen.toggle()
    }

    func hideKeyboard() {
        isKeyboardOpen = false
    }

    var canAcceptInput: Bool {
        if (pendingMux ?? attachedMux)?.isHerdr == true {
            return liveAttachment.acceptsInput
        }
        return phase == .connected && connection.canSend
    }

    @discardableResult
    func send(_ data: ArraySlice<UInt8>) -> Bool {
        if liveAttachment.hasSession {
            guard liveAttachment.send(data) else {
                muxAttachError = Self.pickerMessage(for: HerdrSessionError.disconnected)
                return false
            }
            return true
        }
        if (pendingMux ?? attachedMux)?.isHerdr == true {
            muxAttachError = Self.pickerMessage(for: HerdrSessionError.disconnected)
            return false
        }
        guard phase == .connected, connection.send(data) else {
            errorMessage = Self.pickerMessage(for: SSHExecError.notConnected)
            return false
        }
        return true
    }

    func sendFromTerminal(_ data: ArraySlice<UInt8>) {
        guard isControlArmed, let first = data.first else {
            send(data)
            return
        }
        isControlArmed = false
        var bytes = Array(data)
        if (0x40...0x7f).contains(first) {
            bytes[0] = first & 0x1f
        }
        send(bytes[...])
    }

    func toggleControl() {
        isControlArmed.toggle()
    }

    func resize(cols: Int, rows: Int) {
        let changed = phoneGrid.cols != cols || phoneGrid.rows != rows
        phoneGrid = (cols: cols, rows: rows)
        if liveAttachment.hasSession {
            liveAttachment.resize(changed: changed)
            return
        }
        connection.resize(cols: cols, rows: rows, changed: changed)
        attachPendingMuxIfSized()
    }

    var isTerminalReady: Bool {
        if (pendingMux ?? attachedMux)?.isHerdr == true {
            return liveAttachment.acceptsInput
        }
        if !connection.isReady { return false }
        return pendingMux == nil || attachedMux != nil
    }

    var sessionTitle: String { navigation.sessionTitle(target: pendingMux ?? attachedMux, hostName: host.displayName) }
    var workspaceTabs: [HerdrTab] { navigation.workspaceTabs }
    var selectedTabID: String? { navigation.selectedTabID }

    private var shouldFeedTerminal: Bool {
        pendingMux == nil || attachedMux != nil || muxIsAttaching
    }

    private var needsMuxAttach: Bool {
        guard let pendingMux else { return false }
        return attachedMux?.id != pendingMux.id || (pendingMux.isHerdr && !liveAttachment.acceptsInput)
    }

    private func attachPendingMuxIfSized() {
        guard connection.isReady else { return }
        guard phase == .connected, terminalActive,
              let pendingMux,
              needsMuxAttach,
              !muxIsAttaching,
              !connection.connectionCheckInProgress,
              let terminal else { return }
        if muxAttachError != nil, let lastMuxRetryAt, ContinuousClock.now - lastMuxRetryAt < .seconds(2) {
            return
        }
        guard terminal.bounds.width >= 80, terminal.bounds.height >= 80 else { return }
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        guard cols >= 1, rows >= 1 else { return }
        Task {
            guard !muxIsAttaching, self.pendingMux?.id == pendingMux.id,
                  needsMuxAttach, terminalActive, self.terminal != nil else { return }
            try? await attachMux(pendingMux)
        }
    }

    func recordDirectory(_ directory: String?) {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return }
        currentDirectory = directory
        recentDirectories.removeAll { $0 == directory }
        recentDirectories.insert(directory, at: 0)
        if recentDirectories.count > 20 {
            recentDirectories.removeLast(recentDirectories.count - 20)
        }
    }

    func handleBell() {
        SteerNotifications.terminalBell(hostName: host.displayName)
    }

    func execRemote(_ command: String, stdin: Data? = nil) async throws -> SSHExecResult {
        try await connection.exec(command, stdin: stdin)
    }

    func openWebPreview(remoteHost: String, remotePort: Int) async throws -> SSHLocalForward {
        try await connection.openLocalForward(remoteHost: remoteHost, remotePort: remotePort)
    }

    func reconnect() {
        disconnect(clearMuxTarget: false)
        errorMessage = nil
        connect()
    }

    func recoverConnection() async {
        if detached != nil, phase == .connected {
            await connection.recover()
            return
        }
        guard let ssh = connection.ssh else { return }
        await recoverConnection(check: { try await ssh.checkConnection() }, reconnect: reconnect)
    }

    func recoverConnection(check: () async throws -> Void, reconnect: () -> Void) async {
        await connection.recover(check: check, reconnect: reconnect) { await recoverTerminalStreamIfNeeded(force: true) }
    }

    func retryTerminalAttach() async {
        if pendingMux == nil, let failedMux {
            pendingMux = failedMux
            self.failedMux = nil
        }
        lastMuxRetryAt = nil
        await recoverTerminalStreamIfNeeded(force: true)
    }

    private func recoverTerminalStreamIfNeeded(force: Bool = false) async {
        guard terminalActive, phase == .connected, needsMuxAttach, !muxIsAttaching else { return }
        guard let pendingMux else { return }
        if !force, let lastMuxRetryAt, ContinuousClock.now - lastMuxRetryAt < .seconds(1) { return }
        lastMuxRetryAt = ContinuousClock.now
        try? await attachMux(pendingMux)
    }

    func resolveDeviceName(exec: @MainActor (String) async throws -> SSHExecResult) async {
        guard host.needsDeviceName, onDeviceNameResolved != nil else { return }
        let original = host
        let token = generation
        guard let result = try? await exec("/usr/sbin/scutil --get ComputerName 2>/dev/null || hostname"),
              result.exitStatus == 0, generation == token, host == original,
              !Task.isCancelled else { return }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        var resolved = original
        resolved.name = name
        guard !resolved.needsDeviceName else { return }
        updateHost(resolved)
        onDeviceNameResolved?(original, name)
    }

    func updateHost(_ host: Host) {
        guard self.host != host else { return }
        let connectionChanged = connection.updateHost(host)
        self.host = host
        guard connectionChanged else { return }
        connection.autoUsesSSH = false
        let shouldReconnect = phase != .idle
        disconnect(clearMuxTarget: false)
        currentDirectory = nil
        recentDirectories = []
        replay.replace()
        terminal?.getTerminal().resetToInitialState()
        if shouldReconnect { connect() }
    }

    func disconnect(clearMuxTarget: Bool = true) {
        connection.disconnect(clearFallback: clearMuxTarget)
        failedMux = nil
        isControlArmed = false
        mux.reset(keepingCatalog: false)
        muxAttachError = nil
        muxIsAttaching = false
        liveAttachment.stop()
        navigation.reset()
        agentWatcher.clear()
        pendingMux = clearMuxTarget ? nil : (pendingMux ?? attachedMux)
        attachedMux = nil
        phase = .idle
    }

    func loadMux() async {
        guard let ssh = connection.readySSH else {
            mux.fail(SSHExecError.notConnected.localizedDescription)
            return
        }
        await mux.load { try await ssh.exec($0) }
    }

    func loadMuxPreviews() async {
        guard let ssh = connection.readySSH else { return }
        await mux.loadPreviews { try await ssh.exec($0) }
    }

    func attachMux(_ row: MuxRow) async throws {
        guard let ssh = connection.readySSH else {
            throw SSHExecError.notConnected
        }
        if row.isHerdr, terminal == nil || !terminalActive { throw CancellationError() }
        // A Mosh or ET tab without a server starts one with this session's command; only that path starts servers,
        // so a recovery retry can't launch a second one alongside it.
        if !row.isHerdr, connection.needsDetachedTerminal {
            pendingMux = row
            startDetachedTerminalIfNeeded()
            return
        }
        let token = generation
        let attachID = UUID()
        muxAttachID = attachID
        let previousAttachedMux = attachedMux
        let previousReplay = replay.bytes
        failedMux = nil
        pendingMux = row
        muxIsAttaching = true
        muxAttachError = nil
        let cols = max(terminal?.getTerminal().cols ?? phoneGrid.cols, 20)
        let rows = max(terminal?.getTerminal().rows ?? phoneGrid.rows, 8)
        do {
            switch row {
            case .herdrAgent(let agent):
                try await liveAttachment.attach(agent, over: ssh, token: token) { [weak self] in
                    guard let self else { return false }
                    return generation == token && muxAttachID == attachID && terminal != nil && terminalActive
                }
            case .herdrSession:
                throw HerdrSessionError.paneRequired
            default:
                liveAttachment.stop()
                replay.replace()
                terminal?.getTerminal().resetToInitialState()
                try await connection.attach(command: row.attachCommand, cols: cols, rows: rows, token: token)
            }
            guard generation == token, muxAttachID == attachID else { return }
            attachedMux = row
            muxIsAttaching = false
            lastMuxRetryAt = nil
        } catch is CancellationError {
            if generation == token, muxAttachID == attachID {
                restoreTerminalAfterFailedAttach(target: previousAttachedMux, replay: previousReplay)
            }
            throw CancellationError()
        } catch {
            guard generation == token, muxAttachID == attachID else { throw error }
            restoreTerminalAfterFailedAttach(target: previousAttachedMux, replay: previousReplay)
            if previousAttachedMux == nil, detached != nil, !row.isHerdr {
                // The shell this tab had is still there; go back to it instead of waiting on the session.
                pendingMux = nil
                failedMux = row
            }
            muxAttachError = Self.pickerMessage(for: error)
            throw error
        }
    }

    private func restoreTerminalAfterFailedAttach(target: MuxRow?, replay: [UInt8]) {
        muxIsAttaching = false
        lastMuxRetryAt = .now
        if let target {
            pendingMux = target
            if liveAttachment.acceptsInput { return }
            liveAttachment.stop()
            self.replay.replace(with: replay)
            terminal?.getTerminal().resetToInitialState()
            if !replay.isEmpty { terminal?.feed(byteArray: replay[...]) }
            return
        }
        if liveAttachment.acceptsInput { return }
        liveAttachment.stop()
    }

    private func connect() {
        phase = .connecting
        errorMessage = nil
        mux.reset(keepingCatalog: true)
        muxAttachError = nil
        connection.connect(cols: terminal?.getTerminal().cols ?? 80, rows: terminal?.getTerminal().rows ?? 24)
    }

    private func handleConnectionEvent(_ event: TerminalConnection.Event) {
        switch event {
        case .bytes(let bytes): feedTerminal(bytes)
        case .ready:
            phase = .connected
            // Mosh and ET servers start only with a terminal on screen; until then SSH serves discovery,
            // so the home screen's background connections start nothing on the host.
            startDetachedTerminalIfNeeded()
            attachPendingMuxIfSized()
            let token = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                await self.resolveDeviceName { try await self.execRemote($0) }
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                await self.loadMux()
                await self.watchAgents(token: token)
            }
        case .sshFailure(let message):
            let wasConnected = phase == .connected
            phase = .failed
            errorMessage = message
            if wasConnected { SteerNotifications.connectionDropped(hostName: host.displayName) }
        case .failure(let message):
            phase = .failed
            errorMessage = message
        case .sshReady: Task { await loadMux() }
        case .reconnect: reconnect()
        case .predictions(let cells): (terminal as? SteerTerminalView)?.showPredictions(cells)
        }
    }

    private func startDetachedTerminalIfNeeded() {
        var target: MuxRow?
        connection.startTerminalIfNeeded(visible: terminal != nil && terminalActive, command: { [weak self] in
            guard let self else { return nil }
            // A tab opened on a tmux or Zellij session starts its server with the attach command, rather than a login
            // shell followed by a second server for the session.
            target = pendingMux.flatMap { $0.isHerdr ? nil : $0 }
            if target != nil {
                replay.replace()
                terminal?.getTerminal().resetToInitialState()
            }
            return target?.attachCommand
        }, onStarted: { [weak self] in
            guard let self else { return }
            if let target { attachedMux = target }
            else if !host.startupCommand.isEmpty { detached?.send(Array((host.startupCommand + "\r").utf8)[...]) }
            attachPendingMuxIfSized()
        })
    }

    private func feedTerminal(_ bytes: ArraySlice<UInt8>) {
        if (pendingMux ?? attachedMux)?.isHerdr == true { return }
        if !shouldFeedTerminal { return }
        replay.append(bytes)
        terminal?.feed(byteArray: bytes)
    }

    func loadUsage() async throws -> [UsageDay] {
        guard let ssh = connection.readySSH else { throw SSHExecError.notConnected }
        return AgentUsage.parse(try await ssh.exec(AgentUsage.command).stdout)
    }

    /// Polls herdr over the exec channel until this connection ends.
    private func watchAgents(token: Int) async {
        await watchAgents(token: token, interval: .seconds(3), retryDelay: .seconds(1)) { [weak self] command in
            guard let self else { throw SSHExecError.notConnected }
            return try await self.execRemote(command)
        }
    }

    func watchAgents(
        token: Int? = nil,
        interval: Duration = .seconds(3),
        retryDelay: Duration = .seconds(1),
        exec: @escaping @MainActor (String) async throws -> SSHExecResult
    ) async {
        let token = token ?? generation
        await agentWatcher.run(
            hostName: { [unowned self] in host.displayName },
            sessionName: { [unowned self] in (attachedMux ?? pendingMux)?.herdrSessionName },
            isActive: { [unowned self] in generation == token && phase == .connected },
            interval: interval,
            retryDelay: retryDelay,
            exec: exec
        )
    }

    static func pickerMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return "Couldn't complete that request."
    }
}
