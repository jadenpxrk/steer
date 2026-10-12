import Foundation

@MainActor
final class AgentCompanion: ObservableObject {
    @Published private(set) var sessions: [CompanionSession] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    let controller: TerminalController
    private var connection: Task<Connection, Error>?
    private let network: URLSession

    private struct Connection {
        let forward: SSHLocalForward
        let token: String
    }

    init(controller: TerminalController) {
        self.controller = controller
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        network = URLSession(configuration: configuration, delegate: CompanionRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        connection?.cancel()
        network.invalidateAndCancel()
        if let connection {
            Task { if let value = try? await connection.value { value.forward.close() } }
        }
    }

    func reset() async {
        let previous = connection
        connection = nil
        previous?.cancel()
        if let previous, let value = try? await previous.value { value.forward.close() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Listing: Decodable, Sendable {
                let sessions: [CompanionSession]
            }
            let listing: Listing = try await request("/v1/sessions")
            sessions = listing.sessions
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            await reset()
        }
    }

    func conversation(sessionID: String) async throws -> AgentConversation {
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw CompanionError(message: "Invalid session identifier.")
        }
        return try await request("/v1/conversations/\(encoded)")
    }

    func decide(_ approval: CompanionApproval, sessionID: String, allow: Bool) async throws {
        guard approval.expires > Date() else { throw CompanionError(message: "This request has expired. Check the terminal for the current prompt.") }
        let _: Empty = try await request("/v1/decisions", method: "POST", body: [
            "id": approval.id, "sessionID": sessionID, "decision": allow ? "allow" : "deny",
        ])
        await refresh()
    }

    func archive(_ session: CompanionSession) async throws {
        let _: Empty = try await request("/v1/archive", method: "POST", body: ["sessionID": session.id, "archived": !session.archived])
        await refresh()
    }

    func answer(_ approval: CompanionApproval, sessionID: String, answers: [String: String]) async throws {
        guard approval.expires > Date() else { throw CompanionError(message: "This question has expired. Check the terminal for the current prompt.") }
        let _: Empty = try await request("/v1/answers", method: "POST", body: [
            "id": approval.id, "sessionID": sessionID, "answers": answers,
        ])
        await refresh()
    }

    func createConversation(cwd: String, text: String, requestID: UUID) async throws -> String {
        struct Created: Decodable, Sendable { let session: CompanionSession }
        try validatePrompt(text)
        let value: Created = try await request("/v1/conversations", method: "POST", body: [
            "cwd": cwd, "text": text, "requestID": requestID.uuidString.lowercased(),
        ])
        await refresh()
        return value.session.id
    }

    func sendPrompt(_ text: String, sessionID: String, requestID: UUID) async throws {
        try validatePrompt(text)
        let _: Empty = try await request("/v1/messages", method: "POST", body: [
            "text": text, "sessionID": sessionID, "requestID": requestID.uuidString.lowercased(),
        ])
    }

    func stopTurn(sessionID: String) async throws {
        let _: Empty = try await request("/v1/stop", method: "POST", body: ["sessionID": sessionID])
    }

    private func validatePrompt(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 16000 else {
            throw CompanionError(message: "Enter a prompt of at most 16,000 characters.")
        }
    }

    private struct Empty: Decodable, Sendable {}
    private struct Failure: Decodable { let error: String }

    private func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard controller.phase == .connected else { throw SSHExecError.notConnected }
        if connection == nil {
            connection = Task { [controller] in
                let result = try await controller.execRemote("head -c 4096 \"$HOME/.steer/companion.json\"")
                guard result.exitStatus == 0,
                      let config = try? JSONDecoder().decode(CompanionConfiguration.self, from: Data(result.stdout.utf8)),
                      config.isValid else {
                    throw CompanionError(message: "Start the Steer companion on this host first. See companion/README.md in the Steer project.")
                }
                try Task.checkCancellation()
                let forward = try await controller.openWebPreview(remoteHost: "127.0.0.1", remotePort: config.port)
                if Task.isCancelled { forward.close(); throw CancellationError() }
                return Connection(forward: forward, token: config.token)
            }
        }
        guard let connection else { throw SSHExecError.notConnected }
        let value = try await connection.value
        try Task.checkCancellation()
        guard let url = URL(string: "http://127.0.0.1:\(value.forward.localPort)\(path)") else {
            throw CompanionError(message: "Invalid companion address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(value.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSHExecError.failed }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw CompanionError(message: message ?? "The companion could not complete this request.")
        }
        guard data.count <= 16 * 1024 * 1024 else { throw CompanionError(message: "Conversation is too large to display.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private final class CompanionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CompanionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
