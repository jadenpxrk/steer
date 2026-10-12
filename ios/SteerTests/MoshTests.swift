import Foundation
import Testing
@testable import Steer

struct MoshTests {
    @Test func acknowledgedInputIsTrimmedWithoutResettingAbsoluteCounts() {
        var history = MoshInputHistory()
        history.append(.resize(cols: 80, rows: 24))
        history.append(.keys([0x61]))
        history.append(.keys([0x62]))
        let remaining = MoshProtocol.encodeUserMessage([.keys([0x62])][...])
        history.acknowledge(through: 2)
        #expect(history.base == 2)
        #expect(history.count == 3)
        #expect(MoshProtocol.encodeUserMessage(history.events[...]) == remaining)
        history.acknowledge(through: 1)
        history.acknowledge(through: 4)
        #expect(history.base == 2)
        history.acknowledge(through: 3)
        #expect(history.events.isEmpty)
        history.append(.keys([0x63]))
        #expect(history.count == 4)
        for _ in 0..<1000 {
            history.acknowledge(through: history.count)
            history.append(.keys([0x64]))
        }
        #expect(history.events.count == 1)
        #expect(history.count == 1004)
    }

    private static func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let start = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    /// Generated with Python cryptography's AESOCB3, key 000102…0f.
    private static let vectors: [(String, String, String)] = [
        ("000000000000000000000000", "", "a5a7ac886f721925ed1b023829a078f9"),
        ("000000008000000000000001", "01", "dc20c80d273e1ba56578cc4ba50752d01b"),
        ("000000000000000000000002", "020910171e252c333a41484f565d64", "03cb699a1f3a242b02bae1b0346a45854c6b9d64dab30e1dd77a2b981955be"),
        ("000000008000000000000003", "030a11181f262d343b424950575e656c", "123c54e2353baa6ba3daad23d97ee48c1c7f7ea5ad9c4ba73c7001131a6490c5"),
        ("000000000000000000000004", "040b121920272e353c434a51585f666d74", "f391ff774a46226fa5b362a6c069ca15dc03517f9f2faae0a7d1ef238b59237fbb"),
        ("000000008000000000000005", "050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7", "f30f51921787a868d97581380a83579fcbd9d470fa743d1b0cf829ec7ecd2c77cb4298573750f9b989849057921ebc"),
        ("000000000000000000000006", "060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8df", "f55a23f09fdcca8cc4478a89748e9f98236d269140d437c550d0bab53fcd2dbb6bda183ce28790af540e92ea8460997d"),
        ("000000008000000000000007", "070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7", "e552d93ba4c4af1a6a6d094feef3c9a3bca73f377a118592547c19feb21b8130f466a2a16a02e701fcada4d3bd05659fd6"),
        ("000000000000000000000008", "080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bd", "6cff86a953b943236f9a0c70c6921fe459a50707e19884b0e1cd91a78f88d98fe8ab7d7f1c4475a94e8947c21e854918814f06bce3b8580ada3f599dacad9d831a9f2b73636604db8e4b28307eab44f5332eae8bcf01db5cc70773ce519b41b6e21b4caeb1df26619f9949a6b9d1ac1cc882db90"),
    ]

    @Test func ocbMatchesReferenceVectors() throws {
        let ocb = try #require(AESOCB(key: Array(0..<16)))
        for (nonce, plaintext, sealed) in Self.vectors {
            #expect(ocb.seal(Self.hex(plaintext), nonce: Self.hex(nonce)) == Self.hex(sealed))
            #expect(ocb.open(Self.hex(sealed), nonce: Self.hex(nonce)) == Self.hex(plaintext))
        }
    }

    @Test func ocbRejectsTamperedCiphertext() throws {
        let ocb = try #require(AESOCB(key: Array(0..<16)))
        var sealed = ocb.seal(Array("hello mosh".utf8), nonce: [UInt8](repeating: 0, count: 12))
        sealed[3] ^= 1
        #expect(ocb.open(sealed, nonce: [UInt8](repeating: 0, count: 12)) == nil)
    }
}

struct MoshProtocolTests {
    @Test func instructionsRoundTripThroughFragments() throws {
        var instruction = MoshProtocol.Instruction(oldNum: 3, newNum: 9, ackNum: 7, throwawayNum: 3)
        instruction.diff = (0..<4000).map { _ in UInt8.random(in: 0...255) }
        let fragments = MoshProtocol.fragments(instruction, id: 42)
        #expect(fragments.count > 1)
        #expect(fragments.last?.final == true)
        var assembly = MoshProtocol.Assembly()
        var result: MoshProtocol.Instruction?
        for fragment in fragments.reversed() {
            result = assembly.add(try #require(MoshProtocol.Fragment(fragment.bytes)))
        }
        #expect(result == instruction)
    }

    @Test func zlibFramingInteroperates() {
        // `python3 -c "import zlib; print(zlib.compress(b'hello hello hello').hex())"`
        let pythonZlib: [UInt8] = [0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x90, 0x00, 0x3a, 0x2e, 0x06, 0x7d]
        #expect(MoshProtocol.uncompress(pythonZlib) == Array("hello hello hello".utf8))
        #expect(MoshProtocol.uncompress(MoshProtocol.compress(Array("round trip".utf8))) == Array("round trip".utf8))
    }

    @Test func userMessageMergesKeystrokesAndKeepsResizes() {
        let encoded = MoshProtocol.encodeUserMessage([.resize(cols: 80, rows: 24), .keys([0x61]), .keys([0x62])][...])
        #expect(encoded == [0x0a, 0x06, 0x1a, 0x04, 0x28, 0x50, 0x30, 0x18, 0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x61, 0x62])
    }

    @Test func decodesHostMessage() {
        // HostMessage { instruction { hostbytes { hoststring: "hi" } } instruction { echoack { 5 } } }
        let bytes: [UInt8] = [0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x68, 0x69, 0x0a, 0x04, 0x3a, 0x02, 0x40, 0x05]
        #expect(MoshProtocol.decodeHostMessage(bytes) == [.bytes(Array("hi".utf8)), .echoAck(5)])
        #expect(MoshProtocol.decodeHostMessage([0x0a, 0x09]) == nil)
    }
}

struct MoshPredictorTests {
    @Test func showsPredictionsOnlyAfterAnEarlierOneIsConfirmed() {
        var predictor = MoshPredictor()
        predictor.typed(Array("l".utf8), cursor: (col: 2, row: 0), cols: 80, eventCount: 1)
        #expect(predictor.visible.isEmpty)
        predictor.confirm(echoedEventCount: 1) { col, row in col == 2 && row == 0 ? "l" : " " }
        predictor.typed(Array("s".utf8), cursor: (col: 3, row: 0), cols: 80, eventCount: 2)
        #expect(predictor.visible == [.init(row: 0, col: 3, character: "s", eventCount: 2)])
        predictor.typed([0x7F], cursor: (col: 3, row: 0), cols: 80, eventCount: 3)
        #expect(predictor.visible.isEmpty)
    }

    @Test func hiddenInputBreaksTheEpoch() {
        var predictor = MoshPredictor()
        predictor.typed(Array("p".utf8), cursor: (col: 10, row: 4), cols: 80, eventCount: 1)
        // A password prompt doesn't echo, so the screen still shows a blank.
        predictor.confirm(echoedEventCount: 1) { _, _ in " " }
        predictor.typed(Array("w".utf8), cursor: (col: 10, row: 4), cols: 80, eventCount: 2)
        #expect(predictor.visible.isEmpty)
        predictor.typed([0x0D], cursor: (col: 10, row: 4), cols: 80, eventCount: 3)
        #expect(predictor.pending.isEmpty)
    }

    @Test func stopsAtTheRightEdge() {
        var predictor = MoshPredictor()
        predictor.typed(Array("abc".utf8), cursor: (col: 78, row: 0), cols: 80, eventCount: 3)
        #expect(predictor.pending.isEmpty)
    }

    @Test func serverCommandHonorsPortRangeAndPath() {
        #expect(MoshConnect.portRange("60001") == "60001")
        #expect(MoshConnect.portRange(" 60000-60010 ") == "60000:60010")
        #expect(MoshConnect.portRange("60010:60000") == nil)
        #expect(MoshConnect.portRange("70000") == nil)
        #expect(MoshConnect.portRange("1;rm") == nil)
        let command = MoshConnect.serverCommand(running: nil, ports: "60000:60010", path: "/opt/my mosh/mosh-server")
        #expect(command.contains("'/opt/my mosh/mosh-server' new -s -c 256 -p 60000:60010 -l LANG=en_US.UTF-8"))
        #expect(!MoshConnect.serverCommand(running: nil, ports: "bad").contains(" -p "))
    }
}
