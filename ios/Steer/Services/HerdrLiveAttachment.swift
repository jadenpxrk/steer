import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
final class HerdrLiveAttachment {
    private(set) var live: HerdrLiveSession?
    private var pending: HerdrLiveSession?
    private var resizeTask: Task<Void, Never>?
    @ObservationIgnored var size: () -> (cols: Int, rows: Int) = { (80, 24) }
    @ObservationIgnored var isActive: () -> Bool = { false }
    private let replay: TerminalReplay
    @ObservationIgnored var terminal: () -> TerminalView? = { nil }
    @ObservationIgnored var generation: () -> Int = { -1 }
    @ObservationIgnored var onError: (Error) -> Void = { _ in }

    init(replay: TerminalReplay) {
        self.replay = replay
    }

    var acceptsInput: Bool { live?.acceptsInput == true }
    var hasSession: Bool { live != nil }

    func send(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let live, live.acceptsInput else { return false }
        live.send(bytes)
        return true
    }

    func resize(changed: Bool) {
        guard let live, changed else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self, weak live] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            guard let self, let live, self.live === live, isActive() else { return }
            let grid = size()
            live.resize(cols: grid.cols, rows: grid.rows)
        }
    }

    func attach(_ agent: HerdrAgent, over ssh: SSHSession, token: Int, isCurrent: @escaping () -> Bool) async throws {
        let previous = live
        let phoneGrid = size()
        let live = HerdrLiveSession(paneID: agent.paneID, generation: token, cols: phoneGrid.cols, rows: phoneGrid.rows)
        pending?.close()
        pending = live
        defer { if pending === live { pending = nil } }
        do {
            let control = try await ssh.openExecStream(
                command: MuxCommands.herdrControl(target: agent.paneID, cols: live.cols, rows: live.rows, session: agent.sessionName),
                onBytes: { [weak self, weak live] bytes in
                    guard let self, let live, !live.isDead else { return }
                    self.handleHerdrBytes(bytes, session: live)
                },
                onClose: { [weak self, weak live] result in
                    guard let self, let live, !live.isDead else { return }
                    let error: Error
                    switch result {
                    case .success: error = HerdrSessionError.observeClosed(nil)
                    case .failure(let failure): error = Self.herdrCapabilityError(from: failure)
                    }
                    live.fail(error)
                    if self.live === live {
                        onError(error)
                    }
                }
            )
            guard !live.isDead, isCurrent() else {
                control.close(sending: HerdrTerminalCommand.release[...])
                if let failure = live.failure, !(failure is CancellationError) { throw failure }
                throw CancellationError()
            }
            live.control = control
            try await live.waitUntilReady(timeout: .seconds(8))
            try Task.checkCancellation()
            guard isCurrent() else {
                if let failure = live.failure, !(failure is CancellationError) { throw failure }
                throw CancellationError()
            }
        } catch {
            live.close()
            throw error
        }
        previous?.close()
        self.live = live
        let terminal = terminal()
        replay.replace()
        terminal?.getTerminal().resetToInitialState()
        terminal?.allowMouseReporting = false
        (terminal as? SteerTerminalView)?.onRemoteScroll = { [weak live] lines, column, row in
            live?.scroll(lines: lines, column: column, row: row)
        }
        let grid = size()
        live.resize(cols: grid.cols, rows: grid.rows)
        renderHerdrFrames(live)
    }

    private func handleHerdrBytes(_ bytes: ArraySlice<UInt8>, session: HerdrLiveSession) {
        for event in session.parser.push(bytes) {
            switch event {
            case .frame(let frame):
                guard session.enqueue(frame) else {
                    if self.live === session {
                        onError(HerdrSessionError.streamTruncated)
                    }
                    return
                }
            case .closed(let reason):
                session.fail(HerdrSessionError.observeClosed(reason))
                if self.live === session {
                    onError(HerdrSessionError.observeClosed(reason))
                }
                return
            case .ignored:
                break
            }
        }
        if self.live === session { renderHerdrFrames(session) }
    }

    private func renderHerdrFrames(_ live: HerdrLiveSession) {
        live.renderPendingFrames { [weak self, weak live] frames in
            guard let self, let live, self.live === live else { return }
            guard generation() == live.generation, let terminal = terminal(), isActive() else { return }
            let matching = frames.filter { $0.width == terminal.getTerminal().cols && $0.height == terminal.getTerminal().rows }
            for frame in matching {
                if frame.full { replay.replace() }
                replay.append(frame.bytes[...])
            }
            terminal.feedHerdrFrames(matching)
        }
    }

    func stop() {
        resizeTask?.cancel()
        resizeTask = nil
        pending?.close()
        pending = nil
        self.live?.close()
        self.live = nil
        let terminal = terminal()
        (terminal as? SteerTerminalView)?.onRemoteScroll = nil
        terminal?.allowMouseReporting = true
    }

    private static func herdrCapabilityError(from error: Error) -> Error {
        if error is HerdrSessionError { return error }
        if let exec = error as? SSHExecError, exec == .rejected { return HerdrSessionError.observeUnavailable }
        let text = (error as? LocalizedError)?.errorDescription?.lowercased() ?? ""
        if text.contains("not found") || text.contains("unknown") || text.contains("unrecognized") {
            return HerdrSessionError.observeUnavailable
        }
        return error
    }
}
