import Crypto
import Foundation

enum SSHHostKeyError: LocalizedError {
    case rejected
    case changed
    case invalid

    var errorDescription: String? {
        switch self {
        case .rejected: "The SSH server identity was not approved."
        case .changed: "The SSH host key has changed. Connection blocked. Verify the server identity before removing and adding this host again."
        case .invalid: "The server supplied an invalid SSH host key."
        }
    }
}

@MainActor
final class SSHHostKeyStore: ObservableObject {
    static let shared = SSHHostKeyStore()

    struct Request: Identifiable {
        let id: UUID
        let host: Host
        let key: String
        let fingerprint: String
        let continuation: CheckedContinuation<Void, Error>
    }

    @Published private(set) var requests: [Request] = []
    var pending: Request? { requests.first }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func validate(_ key: String, for host: Host, connectionID: UUID) async throws {
        if let saved = defaults.string(forKey: storageKey(host.id)) {
            guard saved == key else { throw SSHHostKeyError.changed }
            return
        }
        let fields = key.split(separator: " ")
        guard fields.count == 2, let bytes = Data(base64Encoded: String(fields[1])) else {
            throw SSHHostKeyError.invalid
        }
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(
                id: connectionID, host: host, key: key, fingerprint: fingerprint,
                continuation: continuation
            ))
        }
    }

    func resolve(accept: Bool) {
        guard let request = pending else { return }
        requests.removeFirst()
        if accept {
            defaults.set(request.key, forKey: storageKey(request.host.id))
            request.continuation.resume()
        } else {
            request.continuation.resume(throwing: SSHHostKeyError.rejected)
        }
        resolveKnownRequests()
    }

    private func resolveKnownRequests() {
        while let request = pending,
              let saved = defaults.string(forKey: storageKey(request.host.id)) {
            requests.removeFirst()
            if saved == request.key {
                request.continuation.resume()
            } else {
                request.continuation.resume(throwing: SSHHostKeyError.changed)
            }
        }
    }

    func cancel(connectionID: UUID) {
        let cancelled = requests.filter { $0.id == connectionID }
        requests.removeAll { $0.id == connectionID }
        for request in cancelled {
            request.continuation.resume(throwing: SSHHostKeyError.rejected)
        }
        resolveKnownRequests()
    }

    func remove(hostID: UUID) {
        defaults.removeObject(forKey: storageKey(hostID))
    }

    private func storageKey(_ hostID: UUID) -> String {
        "ssh-host-key.\(hostID.uuidString)"
    }
}
