import Crypto
import Foundation
import NIOSSH
import Testing
@testable import Steer

struct OpenSSHPrivateKeyParserTests {
    @Test
    func parsesUnencryptedEd25519Key() throws {
        let pem = try makeEd25519PEM(seed: Data((0..<32).map(UInt8.init)))

        _ = try OpenSSHPrivateKeyParser.parse(pem)
    }

    @Test
    func generatedKeyParsesAndMatchesItsPublicKey() throws {
        let generated = try OpenSSHKeyGenerator.makeEd25519(comment: "steer")
        let key = try OpenSSHPrivateKeyParser.parse(generated.privateKey)

        #expect(generated.publicKey == String(openSSHPublicKey: key.publicKey) + " steer")
    }

    @Test
    func parsesOpenSSHRSAKey() throws {
        let key = try OpenSSHPrivateKeyParser.parse(RSAFixture.privateKey)
        #expect(String(openSSHPublicKey: key.publicKey) == RSAFixture.publicKey)
    }

    @Test
    func rejectsEncryptedKeysWithGuidance() {
        #expect(throws: OpenSSHKeyError.encryptedKeyUnsupported) {
            try OpenSSHPrivateKeyParser.parse(Self.encryptedEd25519PEM)
        }
    }

    @Test
    func parsesUnencryptedECDSAP256Key() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))

        _ = try OpenSSHPrivateKeyParser.parse(makeECDSAPEM(key: key))
    }

    @Test
    func parsesUnencryptedECDSAP384Key() throws {
        let key = try P384.Signing.PrivateKey(rawRepresentation: Data((1...48).map(UInt8.init)))

        _ = try OpenSSHPrivateKeyParser.parse(makeECDSAPEM(key: key))
    }

    @Test
    func parsesUnencryptedECDSAP521Key() throws {
        let key = try P521.Signing.PrivateKey(rawRepresentation: Data((1...66).map(UInt8.init)))

        _ = try OpenSSHPrivateKeyParser.parse(makeECDSAPEM(key: key))
    }

    private func makeEd25519PEM(seed: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicBytes = Data(key.publicKey.rawRepresentation)

        var publicBlob = Data()
        publicBlob.append(sshString("ssh-ed25519"))
        publicBlob.append(sshString(publicBytes))

        var privateBlob = Data()
        privateBlob.append(uint32(0x1234_5678))
        privateBlob.append(uint32(0x1234_5678))
        privateBlob.append(sshString("ssh-ed25519"))
        privateBlob.append(sshString(publicBytes))
        privateBlob.append(sshString(seed + publicBytes))
        privateBlob.append(sshString("test"))
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

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(container.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private func makeECDSAPEM(key: P256.Signing.PrivateKey) -> String {
        makeECDSAPEM(
            keyType: "ecdsa-sha2-nistp256",
            curve: "nistp256",
            publicBytes: Data(key.publicKey.x963Representation),
            scalar: Data(key.rawRepresentation)
        )
    }

    private func makeECDSAPEM(key: P384.Signing.PrivateKey) -> String {
        makeECDSAPEM(
            keyType: "ecdsa-sha2-nistp384",
            curve: "nistp384",
            publicBytes: Data(key.publicKey.x963Representation),
            scalar: Data(key.rawRepresentation)
        )
    }

    private func makeECDSAPEM(key: P521.Signing.PrivateKey) -> String {
        makeECDSAPEM(
            keyType: "ecdsa-sha2-nistp521",
            curve: "nistp521",
            publicBytes: Data(key.publicKey.x963Representation),
            scalar: Data(key.rawRepresentation)
        )
    }

    private func makeECDSAPEM(keyType: String, curve: String, publicBytes: Data, scalar: Data) -> String {
        var publicBlob = Data()
        publicBlob.append(sshString(keyType))
        publicBlob.append(sshString(curve))
        publicBlob.append(sshString(publicBytes))

        var privateBlob = Data()
        privateBlob.append(uint32(0x1234_5678))
        privateBlob.append(uint32(0x1234_5678))
        privateBlob.append(sshString(keyType))
        privateBlob.append(sshString(curve))
        privateBlob.append(sshString(publicBytes))
        privateBlob.append(sshString(scalar))
        privateBlob.append(sshString("test"))
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
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(container.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    private func sshString(_ value: String) -> Data {
        sshString(Data(value.utf8))
    }

    private func sshString(_ value: Data) -> Data {
        uint32(UInt32(value.count)) + value
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    // Disposable fixture generated by:
    // ssh-keygen -t ed25519 -N steer-test-passphrase -C steer-disposable-test
    private static let encryptedEd25519PEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAiNCgqGH
        cxZdi/XeaKoWn9AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFeJoYq6POeZcefB
        Eci6L8r6VmasT+ulwC6pzqz4bNdPAAAAoD6NiHPWw2FTekq2QXHBH4hs+98dzBegqg0NMp
        BTSti+O0vlME1VYahPeM75/6wUiwshaiqD40qy85MY/dgfkc5uTRrf0re7KBEWInecYujM
        rUFEloK53yckofy3E2a05nJlda6EQGiFcE959mukZueIhiY5QZu1WFHoZ98QsXma8wdTui
        R2jMG046lFwlI2mHMyFphzEB9UTTzQrmARZjU=
        -----END OPENSSH PRIVATE KEY-----
        """
}
