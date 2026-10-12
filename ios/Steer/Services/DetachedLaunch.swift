import Foundation

/// A terminal carried by a roaming transport (Mosh or Eternal Terminal) instead of the SSH channel.
@MainActor
protocol DetachedTerminal: AnyObject {
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    /// When the server last sent anything; both servers send at least every few seconds while the session lives.
    var lastHeard: ContinuousClock.Instant? { get }
    /// Replaces the network connection; the remote session survives.
    func reopenSocket()
    /// Leaves the session: Mosh ends mosh-server; ET only disconnects.
    func shutdown()
}

/// Runs a command over SSH that prints connection details and then daemonizes, like mosh-server or etterminal.
/// The daemon keeps the channel's output open, so the channel is closed as soon as `parse` recognizes the output,
/// as mosh's and ET's own launchers do.
@MainActor
final class DetachedLaunch<Value: Sendable> {
    private let parse: (String) -> Value?
    private let failure: (String) -> Error
    private var output = ""
    private var stream: SSHExecStream?
    private var continuation: CheckedContinuation<Value, Error>?

    init(parse: @escaping (String) -> Value?, failure: @escaping (String) -> Error) {
        self.parse = parse
        self.failure = failure
    }

    func run(_ ssh: SSHSession, command: String) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task {
                do {
                    stream = try await ssh.openExecStream(command: command, onBytes: { [self] bytes in
                        output += String(decoding: bytes, as: UTF8.self)
                        if let value = parse(output) { finish(.success(value)) }
                    }, onClose: { [self] _ in
                        finish(parse(output).map(Result.success) ?? .failure(failure(output)))
                    })
                    if self.continuation == nil { stream?.close() }
                } catch {
                    finish(.failure(error))
                }
                try? await Task.sleep(for: .seconds(15))
                finish(.failure(failure(output)))
            }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stream?.close()
        continuation.resume(with: result)
    }
}
