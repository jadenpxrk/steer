import Foundation
import Security
import Testing
@testable import Steer

struct KeychainStoreTests {
    @Test
    func replacesAllCredentialsTogetherAndCanClearThem() throws {
        let id = UUID()
        defer { KeychainStore.removeCredentials(for: id) }
        try KeychainStore.save(password: "test-fixture", privateKey: "", for: id)
        try KeychainStore.save(password: "", privateKey: "key-fixture", for: id)
        let saved = try KeychainStore.credentials(for: id)
        #expect(saved.password.isEmpty)
        #expect(saved.privateKey == "key-fixture")
        try KeychainStore.save(password: "", privateKey: "", for: id)
        #expect(try KeychainStore.credentials(for: id) == .init(password: "", privateKey: ""))
    }

    @Test
    func readsLegacyCredentialsAndMigratesOnSave() throws {
        let id = UUID()
        defer { KeychainStore.removeCredentials(for: id) }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "app.steer.ios",
            kSecAttrAccount: "password.\(id.uuidString)",
        ]
        let item = query.merging([kSecValueData: Data("legacy-fixture".utf8)]) { _, new in new }
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        #expect(try KeychainStore.credentials(for: id).password == "legacy-fixture")
        try KeychainStore.save(password: "updated-fixture", privateKey: "", for: id)
        #expect(try KeychainStore.credentials(for: id).password == "updated-fixture")
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    }
}
