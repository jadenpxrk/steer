import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    private static let service = "app.steer.ios"

    struct Credentials: Codable, Equatable {
        var password: String
        var privateKey: String
    }

    static func credentials(for hostID: UUID, prompt: String? = nil) throws -> Credentials {
        let context: LAContext?
        if let prompt {
            let authenticationContext = LAContext()
            authenticationContext.localizedReason = prompt
            context = authenticationContext
        } else {
            context = nil
        }
        if let data = try data(account: "credentials.\(hostID.uuidString)", context: context) {
            return try JSONDecoder().decode(Credentials.self, from: data)
        }
        return try Credentials(
            password: value(account: "password.\(hostID.uuidString)", context: context),
            privateKey: value(account: "private-key.\(hostID.uuidString)", context: context)
        )
    }

    static func save(
        password: String,
        privateKey: String,
        for hostID: UUID,
        requiresUserPresence: Bool = false
    ) throws {
        let credentials = Credentials(password: password, privateKey: privateKey)
        try set(
            JSONEncoder().encode(credentials),
            account: "credentials.\(hostID.uuidString)",
            requiresUserPresence: requiresUserPresence
        )
        // Remove the per-field items only after the combined item is stored.
        remove(account: "password.\(hostID.uuidString)")
        remove(account: "private-key.\(hostID.uuidString)")
        remove(account: "key-passphrase.\(hostID.uuidString)")
    }

    static func removeCredentials(for hostID: UUID) {
        remove(account: "credentials.\(hostID.uuidString)")
        remove(account: "password.\(hostID.uuidString)")
        remove(account: "private-key.\(hostID.uuidString)")
        remove(account: "key-passphrase.\(hostID.uuidString)")
    }

    private static func value(account: String, context: LAContext?) throws -> String {
        String(decoding: try data(account: account, context: context) ?? Data(), as: UTF8.self)
    }

    private static func data(account: String, context: LAContext?) throws -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        if let context {
            query[kSecUseAuthenticationContext] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private static func set(_ data: Data, account: String, requiresUserPresence: Bool) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            requiresUserPresence ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            requiresUserPresence ? .userPresence : [],
            &accessError
        ) else {
            if let accessError { throw accessError.takeRetainedValue() }
            throw KeychainError(status: errSecParam)
        }
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessControl: accessControl,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func remove(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
