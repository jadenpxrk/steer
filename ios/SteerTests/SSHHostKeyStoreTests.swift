import Foundation
import Testing
@testable import Steer

struct SSHHostKeyStoreTests {
    @Test @MainActor
    func queuedConnectionsCannotOverwriteAnApprovedKey() async throws {
        let suite = "SSHHostKeyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostKeyStore(defaults: defaults)
        let host = Host(name: "Test", hostname: "test.invalid", username: "test")
        let firstID = UUID()
        let secondID = UUID()
        defer {
            store.cancel(connectionID: firstID)
            store.cancel(connectionID: secondID)
        }
        let first = Task { try await store.validate("ssh-ed25519 Zmlyc3Q=", for: host, connectionID: firstID) }
        for _ in 0..<100 where store.pending == nil { await Task.yield() }
        _ = try #require(store.pending)
        let second = Task { try await store.validate("ssh-ed25519 c2Vjb25k", for: host, connectionID: secondID) }
        for _ in 0..<100 where store.requests.count < 2 { await Task.yield() }
        #expect(store.requests.count == 2)
        store.resolve(accept: true)
        try await first.value
        await #expect(throws: SSHHostKeyError.self) { try await second.value }
        #expect(store.pending == nil)
    }

    @Test @MainActor
    func requiresApprovalThenRemembersKeyAndRejectsChanges() async throws {
        let suite = "SSHHostKeyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostKeyStore(defaults: defaults)
        let host = Host(name: "Test", hostname: "test.invalid", username: "test")
        let key = "ssh-ed25519 " + Data("public-key-fixture".utf8).base64EncodedString()
        let id = UUID()
        defer { store.cancel(connectionID: id) }
        let validation = Task { try await store.validate(key, for: host, connectionID: id) }
        for _ in 0..<100 where store.pending == nil { await Task.yield() }
        let pending = try #require(store.pending)
        #expect(pending.host == host)
        #expect(pending.fingerprint.hasPrefix("SHA256:"))
        store.resolve(accept: true)
        try await validation.value

        let restored = SSHHostKeyStore(defaults: defaults)
        try await restored.validate(key, for: host, connectionID: UUID())
        #expect(restored.pending == nil)
        await #expect(throws: SSHHostKeyError.self) {
            try await restored.validate("ssh-ed25519 Y2hhbmdlZA==", for: host, connectionID: UUID())
        }
    }

    @Test @MainActor
    func cancelledConnectionDoesNotTrustTheKey() async throws {
        let suite = "SSHHostKeyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostKeyStore(defaults: defaults)
        let host = Host(name: "Test", hostname: "test.invalid", username: "test")
        let id = UUID()
        let validation = Task { try await store.validate("ssh-ed25519 Zml4dHVyZQ==", for: host, connectionID: id) }
        defer { store.cancel(connectionID: id) }
        for _ in 0..<100 where store.pending == nil { await Task.yield() }
        _ = try #require(store.pending)
        store.cancel(connectionID: id)
        await #expect(throws: SSHHostKeyError.self) { try await validation.value }
        #expect(defaults.string(forKey: "ssh-host-key.\(host.id.uuidString)") == nil)
        #expect(store.pending == nil)
    }
}
