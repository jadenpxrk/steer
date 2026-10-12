import Crypto
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import Steer

struct SSHAgentTests {
    private func frame(_ type: UInt8, _ fields: [[UInt8]], flags: UInt32? = nil) -> [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeInteger(type)
        for field in fields {
            buffer.writeInteger(UInt32(field.count))
            buffer.writeBytes(field)
        }
        if let flags { buffer.writeInteger(flags) }
        return Array(buffer.readableBytesView)
    }

    private func blob(_ key: NIOSSHPrivateKey) -> [UInt8] {
        Array(Data(base64Encoded: String(String(openSSHPublicKey: key.publicKey).split(separator: " ")[1]))!)
    }

    @Test func listsTheHostKey() {
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        var reply = ByteBuffer(bytes: SSHAgent(key: key, comment: "steer").reply(to: [11]))
        #expect(reply.readInteger(as: UInt8.self) == 12)
        #expect(reply.readInteger(as: UInt32.self) == 1)
        let length = reply.readInteger(as: UInt32.self)!
        #expect(reply.readBytes(length: Int(length)) == blob(key))
        #expect(SSHAgent(key: nil, comment: "").reply(to: [11]) == [12, 0, 0, 0, 0])
    }

    @Test func signsOnlyForItsOwnKey() throws {
        let raw = Curve25519.Signing.PrivateKey()
        let key = NIOSSHPrivateKey(ed25519Key: raw)
        let agent = SSHAgent(key: key, comment: "steer")
        let data = Array("session-data".utf8)

        var reply = ByteBuffer(bytes: agent.reply(to: frame(13, [blob(key), data], flags: 0)))
        #expect(reply.readInteger(as: UInt8.self) == 14)
        _ = reply.readInteger(as: UInt32.self)
        let algorithmLength = reply.readInteger(as: UInt32.self)!
        #expect(reply.readString(length: Int(algorithmLength)) == "ssh-ed25519")
        let signatureLength = reply.readInteger(as: UInt32.self)!
        let signature = reply.readBytes(length: Int(signatureLength))!
        #expect(raw.publicKey.isValidSignature(signature, for: data))

        let other = NIOSSHPrivateKey(ed25519Key: .init())
        #expect(agent.reply(to: frame(13, [blob(other), data], flags: 0)) == [5])
        #expect(agent.reply(to: [27]) == [5])
    }

    @Test func rsaRefusesLegacySHA1() throws {
        let key = try OpenSSHPrivateKeyParser.parse(RSAFixture.privateKey)
        let agent = SSHAgent(key: key, comment: "steer")
        #expect(agent.reply(to: frame(13, [blob(key), [1, 2, 3]], flags: 0)) == [5])
        #expect(agent.reply(to: frame(13, [blob(key), [1, 2, 3]], flags: 4)).first == 14)
    }
}
