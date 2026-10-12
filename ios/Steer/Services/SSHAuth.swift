import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSH

enum SSHCredentials {
    static func load(for host: Host) throws -> (password: String, key: NIOSSHPrivateKey?) {
        let stored = try KeychainStore.credentials(
            for: host.id,
            prompt: host.protectCredentials ? "Unlock credentials for \(host.displayName)" : nil
        )
        let password = stored.password
        let pem = stored.privateKey
        let key = pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : try OpenSSHPrivateKeyParser.parse(pem)
        if password.isEmpty, key == nil {
            throw SSHAuthError.noCredentials
        }
        return (password, key)
    }
}

enum SSHAuthError: LocalizedError {
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Add a password or a supported OpenSSH private key for this host."
        }
    }
}

enum OpenSSHPrivateKeyParser {
    static func parse(_ pem: String) throws -> NIOSSHPrivateKey {
        var lines = pem
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let begin = lines.firstIndex(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = lines[(begin + 1)...].firstIndex(of: "-----END OPENSSH PRIVATE KEY-----"),
              begin < end else {
            throw OpenSSHKeyError.invalidEnvelope
        }
        lines = Array(lines[(begin + 1)..<end])
        guard let decoded = Data(base64Encoded: lines.joined()) else {
            throw OpenSSHKeyError.invalidBase64
        }

        var container = SSHKeyReader(data: decoded)
        try container.consume(Array("openssh-key-v1\0".utf8))
        let cipher = try container.readString()
        let kdf = try container.readString()
        let kdfOptions = try container.readStringData()
        guard try container.readUInt32() == 1 else {
            throw OpenSSHKeyError.multipleKeysUnsupported
        }

        let publicBlob = try container.readStringData()
        let privateBlob = try container.readStringData()
        guard container.isAtEnd else {
            throw OpenSSHKeyError.invalidFormat
        }
        guard cipher == "none", kdf == "none", kdfOptions.isEmpty else {
            throw OpenSSHKeyError.encryptedKeyUnsupported
        }

        var publicKey = SSHKeyReader(data: publicBlob)
        let keyType = try publicKey.readString()

        if keyType == "ssh-rsa" {
            return try parseRSA(publicBlob: publicBlob, privateBlob: privateBlob)
        }

        if keyType.hasPrefix("ecdsa-sha2-") {
            let curve = try publicKey.readString()
            let publicBytes = try publicKey.readStringData()
            guard publicKey.isAtEnd else { throw OpenSSHKeyError.invalidFormat }
            return try parseECDSA(
                keyType: keyType,
                curve: curve,
                publicBytes: publicBytes,
                privateBlob: privateBlob
            )
        }

        guard keyType == "ssh-ed25519" else { throw OpenSSHKeyError.unsupportedKeyType }
        let publicBytes = try publicKey.readStringData()
        guard publicBytes.count == 32, publicKey.isAtEnd else { throw OpenSSHKeyError.invalidFormat }

        var privateKey = SSHKeyReader(data: privateBlob)
        let firstCheck = try privateKey.readUInt32()
        guard firstCheck == (try privateKey.readUInt32()) else {
            throw OpenSSHKeyError.invalidCheckints
        }
        guard try privateKey.readString() == "ssh-ed25519" else {
            throw OpenSSHKeyError.unsupportedKeyType
        }
        guard try privateKey.readStringData() == publicBytes else {
            throw OpenSSHKeyError.publicKeyMismatch
        }
        let privateBytes = try privateKey.readStringData()
        guard privateBytes.count == 64,
              privateBytes.suffix(32) == publicBytes else {
            throw OpenSSHKeyError.publicKeyMismatch
        }
        _ = try privateKey.readString() // Comment.
        try privateKey.consumePadding()

        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes.prefix(32))
            guard Data(key.publicKey.rawRepresentation) == publicBytes else {
                throw OpenSSHKeyError.publicKeyMismatch
            }
            return NIOSSHPrivateKey(ed25519Key: key)
        } catch let error as OpenSSHKeyError {
            throw error
        } catch {
            throw OpenSSHKeyError.invalidKeyMaterial
        }
    }

    /// OpenSSH RSA private blob: checkints, "ssh-rsa", n, e, d, iqmp, p, q, comment, padding.
    private static func parseRSA(publicBlob: Data, privateBlob: Data) throws -> NIOSSHPrivateKey {
        var publicKey = SSHKeyReader(data: publicBlob)
        _ = try publicKey.readString()
        let publicE = try publicKey.readStringData()
        let publicN = try publicKey.readStringData()
        guard publicKey.isAtEnd else { throw OpenSSHKeyError.invalidFormat }

        var privateKey = SSHKeyReader(data: privateBlob)
        guard try privateKey.readUInt32() == (try privateKey.readUInt32()) else { throw OpenSSHKeyError.invalidCheckints }
        guard try privateKey.readString() == "ssh-rsa" else { throw OpenSSHKeyError.publicKeyMismatch }
        let n = try privateKey.readStringData()
        let e = try privateKey.readStringData()
        let d = try privateKey.readStringData()
        _ = try privateKey.readStringData() // iqmp; recomputed from p and q.
        let p = try privateKey.readStringData()
        let q = try privateKey.readStringData()
        _ = try privateKey.readString()
        try privateKey.consumePadding()
        guard n == publicN, e == publicE else { throw OpenSSHKeyError.publicKeyMismatch }

        func unsigned(_ value: Data) -> Data { Data(value.drop(while: { $0 == 0 })) }
        do {
            let key = try _RSA.Signing.PrivateKey(n: unsigned(n), e: unsigned(e), d: unsigned(d), p: unsigned(p), q: unsigned(q))
            return NIOSSHPrivateKey(rsaKey: key)
        } catch {
            throw OpenSSHKeyError.invalidKeyMaterial
        }
    }

    private static func parseECDSA(
        keyType: String,
        curve: String,
        publicBytes: Data,
        privateBlob: Data
    ) throws -> NIOSSHPrivateKey {
        let expected: (type: String, curve: String, scalarSize: Int)
        switch keyType {
        case "ecdsa-sha2-nistp256": expected = (keyType, "nistp256", 32)
        case "ecdsa-sha2-nistp384": expected = (keyType, "nistp384", 48)
        case "ecdsa-sha2-nistp521": expected = (keyType, "nistp521", 66)
        default: throw OpenSSHKeyError.unsupportedKeyType
        }
        guard curve == expected.curve else { throw OpenSSHKeyError.invalidFormat }

        var privateKey = SSHKeyReader(data: privateBlob)
        let firstCheck = try privateKey.readUInt32()
        guard firstCheck == (try privateKey.readUInt32()) else { throw OpenSSHKeyError.invalidCheckints }
        guard try privateKey.readString() == expected.type,
              try privateKey.readString() == expected.curve,
              try privateKey.readStringData() == publicBytes else {
            throw OpenSSHKeyError.publicKeyMismatch
        }
        let scalar = try normalizedScalar(try privateKey.readStringData(), size: expected.scalarSize)
        _ = try privateKey.readString()
        try privateKey.consumePadding()

        do {
            switch expected.curve {
            case "nistp256":
                let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
                guard Data(key.publicKey.x963Representation) == publicBytes else {
                    throw OpenSSHKeyError.publicKeyMismatch
                }
                return NIOSSHPrivateKey(p256Key: key)
            case "nistp384":
                let key = try P384.Signing.PrivateKey(rawRepresentation: scalar)
                guard Data(key.publicKey.x963Representation) == publicBytes else {
                    throw OpenSSHKeyError.publicKeyMismatch
                }
                return NIOSSHPrivateKey(p384Key: key)
            case "nistp521":
                let key = try P521.Signing.PrivateKey(rawRepresentation: scalar)
                guard Data(key.publicKey.x963Representation) == publicBytes else {
                    throw OpenSSHKeyError.publicKeyMismatch
                }
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw OpenSSHKeyError.unsupportedKeyType
            }
        } catch let error as OpenSSHKeyError {
            throw error
        } catch {
            throw OpenSSHKeyError.invalidKeyMaterial
        }
    }

    private static func normalizedScalar(_ value: Data, size: Int) throws -> Data {
        var bytes = Array(value)
        while bytes.count > size, bytes.first == 0 {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count <= size else { throw OpenSSHKeyError.invalidKeyMaterial }
        return Data(repeating: 0, count: size - bytes.count) + Data(bytes)
    }
}

private struct SSHKeyReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func consume(_ expected: [UInt8]) throws {
        guard data.count - offset >= expected.count,
              data[offset..<(offset + expected.count)].elementsEqual(expected) else {
            throw OpenSSHKeyError.invalidFormat
        }
        offset += expected.count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw OpenSSHKeyError.invalidFormat
        }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readStringData() throws -> Data {
        let length = Int(try readUInt32())
        guard length <= data.count - offset else {
            throw OpenSSHKeyError.invalidFormat
        }
        defer { offset += length }
        return Data(data[offset..<(offset + length)])
    }

    mutating func readString() throws -> String {
        let bytes = try readStringData()
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw OpenSSHKeyError.invalidFormat
        }
        return value
    }

    mutating func consumePadding() throws {
        var expected: UInt8 = 1
        while !isAtEnd {
            guard data[offset] == expected else {
                throw OpenSSHKeyError.invalidPadding
            }
            offset += 1
            expected &+= 1
        }
    }
}

enum OpenSSHKeyError: LocalizedError, Equatable {
    case invalidEnvelope
    case invalidBase64
    case invalidFormat
    case encryptedKeyUnsupported
    case multipleKeysUnsupported
    case unsupportedKeyType
    case invalidCheckints
    case publicKeyMismatch
    case invalidPadding
    case invalidKeyMaterial

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Paste a complete -----BEGIN OPENSSH PRIVATE KEY----- key."
        case .invalidBase64, .invalidFormat, .invalidPadding, .invalidKeyMaterial, .invalidCheckints:
            return "The OpenSSH private key is invalid."
        case .encryptedKeyUnsupported:
            return "Passphrase-protected keys aren't supported; Keychain protects the key instead. Remove the passphrase with: ssh-keygen -p -N \"\" -f <key>"
        case .multipleKeysUnsupported:
            return "OpenSSH key files containing multiple keys are not supported."
        case .unsupportedKeyType:
            return "Use an OpenSSH Ed25519, ECDSA, or RSA (2048-bit or larger) private key."
        case .publicKeyMismatch:
            return "The OpenSSH private key does not match its public key."
        }
    }
}

final class SSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private let key: NIOSSHPrivateKey?
    private var offeredKey = false
    private var offeredPassword = false

    init(username: String, password: String, key: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !offeredKey, let key, availableMethods.contains(.publicKey) {
            offeredKey = true
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: key))
                )
            )
            return
        }
        if !offeredPassword, !password.isEmpty, availableMethods.contains(.password) {
            offeredPassword = true
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )
            return
        }
        nextChallengePromise.succeed(nil)
    }
}
