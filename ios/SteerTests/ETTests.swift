import CryptoKit
import Foundation
import Testing
@testable import Steer

struct ETTests {
    private static func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let start = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private static let key = Array("abcdefghijklmnopqrstuvwxyz012345".utf8)

    @Test func poly1305MatchesRFC8439() {
        let key = Self.hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        let tag = SecretBox.poly1305(Array("Cryptographic Forum Research Group".utf8), key: key)
        #expect(tag == Self.hex("a8061dc1305136c6c22b8baf0c0127a9"))
    }

    // Vectors from libsodium's crypto_secretbox_easy with ET's nonces (first packet in each direction).
    @Test func cipherMatchesLibsodium() throws {
        let box = try #require(SecretBox(key: Self.key))
        var client = ETCipher(box: box, direction: 0)
        #expect(client.seal([]) == Self.hex("3d4df56db6a527980d3aa6f36428ecca"))
        client = ETCipher(box: box, direction: 0)
        let sealed = client.seal(Array("hello et".utf8))
        #expect(sealed == Self.hex("9a988522d1a1fb7b83515e5a78391ac57ca76d24bc0d34fa"))

        var server = ETCipher(box: box, direction: 0)
        #expect(server.open(sealed) == Array("hello et".utf8))
        var tampered = sealed
        tampered[20] ^= 1
        server = ETCipher(box: box, direction: 0)
        #expect(server.open(tampered) == nil)
    }

    @Test func nonceCarriesAcrossBytesOverManyPackets() throws {
        var cipher = ETCipher(box: try #require(SecretBox(key: Self.key)), direction: 1)
        let message = Array((0..<512).map { UInt8($0 & 0xFF) }) + Array("tail".utf8)
        for _ in 0..<299 { _ = cipher.seal([]) }
        let sealed = cipher.seal(message)
        #expect(SHA256.hash(data: Data(sealed)).map { String(format: "%02x", $0) }.joined()
            == "2331ae8f154384e53a0403ef1640b6d227dd6fdbbfe5b1c38abbd48216bed778")
    }

    @Test func failedDecryptionDoesNotConsumeTheNonce() throws {
        let box = try #require(SecretBox(key: Self.key))
        var receiver = ETCipher(box: box, direction: 0)
        let genuine = Self.hex("9a988522d1a1fb7b83515e5a78391ac57ca76d24bc0d34fa")
        var tampered = genuine
        tampered[20] ^= 1
        #expect(receiver.open(tampered) == nil)
        #expect(receiver.open(genuine) == Array("hello et".utf8))
        var sender = ETCipher(box: box, direction: 0)
        _ = sender.seal(Array("hello et".utf8))
        #expect(receiver.open(sender.seal(Array("next".utf8))) == Array("next".utf8))
    }

    @Test func parsesEtterminalOutput() {
        let id = "abcdEFGH12345678", passkey = String(repeating: "k", count: 32)
        let parsed = ETConnect.parse("Last login: today\nIDPASSKEY:\(id)/\(passkey)\n")
        #expect(parsed?.id == id)
        #expect(parsed?.passkey == passkey)
        #expect(ETConnect.parse("IDPASSKEY:short/key") == nil)
        #expect(ETConnect.terminalCommand(tag: "t4g").contains("echo 'XXX"))
        #expect(ETConnect.terminalCommand(tag: "t4g").contains("STEER_ET_SESSION=t4g etterminal"))
    }

    @Test func handshakeLengthIsLittleEndian() {
        #expect(ETProtocol.handshake([7, 8]) == [2, 0, 0, 0, 0, 0, 0, 0, 7, 8])
    }
}
