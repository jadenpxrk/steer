import Crypto
import Foundation

struct GeneratedSSHKey: Equatable, Sendable {
    let privateKey: String
    let publicKey: String
}

enum OpenSSHKeyGenerator {
    static func makeEd25519(comment: String = "steer-pair") throws -> GeneratedSSHKey {
        let key = Curve25519.Signing.PrivateKey()
        let seed = Data(key.rawRepresentation)
        let publicBytes = Data(key.publicKey.rawRepresentation)

        var publicBlob = Data()
        publicBlob.append(sshString("ssh-ed25519"))
        publicBlob.append(sshString(publicBytes))

        let check = UInt32.random(in: UInt32.min...UInt32.max)
        var privateBlob = Data()
        privateBlob.append(uint32(check))
        privateBlob.append(uint32(check))
        privateBlob.append(sshString("ssh-ed25519"))
        privateBlob.append(sshString(publicBytes))
        privateBlob.append(sshString(seed + publicBytes))
        privateBlob.append(sshString(comment))
        var padding: UInt8 = 1
        repeat {
            privateBlob.append(padding)
            padding += 1
        } while !privateBlob.count.isMultiple(of: 8)

        var container = Data("openssh-key-v1\0".utf8)
        container.append(sshString("none"))
        container.append(sshString("none"))
        container.append(sshString(Data()))
        container.append(uint32(1))
        container.append(sshString(publicBlob))
        container.append(sshString(privateBlob))

        let encoded = container.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 70).map { start in
            let lower = encoded.index(encoded.startIndex, offsetBy: start)
            let upper = encoded.index(lower, offsetBy: min(70, encoded.count - start))
            return String(encoded[lower..<upper])
        }
        let privateKey = (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + [
            "-----END OPENSSH PRIVATE KEY-----",
        ]).joined(separator: "\n")
        let publicKey = "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)"
        return GeneratedSSHKey(privateKey: privateKey, publicKey: publicKey)
    }

    private static func sshString(_ value: String) -> Data {
        sshString(Data(value.utf8))
    }

    private static func sshString(_ value: Data) -> Data {
        uint32(UInt32(value.count)) + value
    }

    private static func uint32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
