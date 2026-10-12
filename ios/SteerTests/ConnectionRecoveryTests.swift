import Foundation
import Testing
@testable import Steer

@MainActor
struct ConnectionRecoveryTests {
    @Test
    func healthySessionKeepsItsConnectionAndCatalog() async {
        let controller = makeController()
        let catalog = MuxCatalog(agents: [], sessions: [], tmux: [])
        controller.phase = .connected
        controller.mux.catalog = catalog
        var checks = 0
        var reconnects = 0

        await controller.recoverConnection(check: { checks += 1 }, reconnect: { reconnects += 1 })

        #expect(checks == 1)
        #expect(reconnects == 0)
        #expect(controller.phase == .connected)
        #expect(controller.mux.catalog == catalog)
    }

    @Test
    func staleConnectionRecoversWithoutLosingTheSelectedTarget() async {
        let controller = makeController()
        let target = MuxRow.tmux(TmuxSession(name: "work", windowCount: 1, isAttached: true))
        controller.phase = .connected
        controller.pendingMux = target
        var reconnects = 0

        await controller.recoverConnection(check: { throw SSHExecError.timedOut }, reconnect: {
            reconnects += 1
            controller.disconnect(clearMuxTarget: false)
        })

        #expect(reconnects == 1)
        #expect(controller.pendingMux?.id == target.id)
    }

    @Test
    func failedAuthenticationDoesNotAutomaticallyRetry() async {
        let controller = makeController()
        controller.phase = .failed
        await controller.recoverConnection(check: {
            Issue.record("A session that never connected must not be probed")
        }, reconnect: {
            Issue.record("Failed credentials must not be retried on every network change")
        })
    }

    @Test
    func droppedPreviouslyConnectedSessionRecoversImmediately() async {
        let controller = makeController()
        controller.phase = .connected
        controller.phase = .failed
        var reconnects = 0
        await controller.recoverConnection(check: {
            Issue.record("A known closed connection does not need a probe")
        }, reconnect: { reconnects += 1 })
        #expect(reconnects == 1)
    }

    @Test
    func simultaneousRecoveryRequestsShareOneCheckAndRespectDisconnect() async throws {
        let controller = makeController()
        controller.phase = .connected
        let (stream, release) = AsyncStream<Void>.makeStream()
        var started = false
        var reconnects = 0
        let recovery = Task {
            await controller.recoverConnection(check: {
                started = true
                for await _ in stream { break }
                throw SSHExecError.timedOut
            }, reconnect: { reconnects += 1 })
        }
        defer { release.finish() }
        try await waitUntil { started }
        await controller.recoverConnection(check: {
            Issue.record("A recovery check is already running")
        }, reconnect: { reconnects += 1 })
        controller.disconnect()
        release.finish()
        await recovery.value

        #expect(reconnects == 0)
        #expect(controller.phase == .idle)
    }

    @Test
    func credentialLoadingDoesNotBlockUIOrReviveADisconnectedSession() async throws {
        var errors: [String] = []
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let session = SSHSession(onBytes: { _ in }, onReady: {}, onError: { errors.append($0) })
        defer { release.signal(); session.disconnect() }
        let start = ContinuousClock.now
        session.connect(host: makeController().host, cols: 80, rows: 24, loadCredentials: { _ in
            signal.yield(())
            signal.finish()
            _ = release.wait(timeout: .now() + 2)
            throw SSHAuthError.noCredentials
        })
        #expect(ContinuousClock.now - start < .milliseconds(500))
        for await _ in started { break }
        session.disconnect()
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(errors.isEmpty)
    }

    @Test
    func supersededCredentialFailureCannotOverwriteTheNextAttempt() async throws {
        var errors: [String] = []
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let session = SSHSession(onBytes: { _ in }, onReady: {}, onError: { errors.append($0) })
        defer { release.signal(); session.disconnect() }
        let host = makeController().host
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in
            signal.yield(())
            signal.finish()
            _ = release.wait(timeout: .now() + 2)
            throw SSHAuthError.noCredentials
        })
        for await _ in started { break }
        session.connect(host: host, cols: 80, rows: 24, loadCredentials: { _ in throw SSHExecError.notConnected })
        try await waitUntil { !errors.isEmpty }
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(errors == [SSHExecError.notConnected.localizedDescription])
    }

    private func makeController() -> TerminalController {
        TerminalController(host: Host(name: "Test", hostname: "test.invalid", username: "test"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
