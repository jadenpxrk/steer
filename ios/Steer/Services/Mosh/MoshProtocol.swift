import Foundation

/// Mosh wire formats (protocol version 2): protobuf messages, zlib framing, fragments, and packets.
enum MoshProtocol {
    static let version: UInt64 = 2
    /// Keeps each encrypted datagram within a 1280-byte path MTU (mosh's IPv4/IPv6 default).
    static let fragmentPayloadLimit = 1280 - 48 - 8 - 4 - 16 - 10

    struct Instruction: Equatable {
        var oldNum: UInt64 = 0
        var newNum: UInt64 = 0
        var ackNum: UInt64 = 0
        var throwawayNum: UInt64 = 0
        var diff: [UInt8] = []
        var protocolVersion: UInt64 = MoshProtocol.version
    }

    enum UserEvent: Equatable {
        case keys([UInt8])
        case resize(cols: Int, rows: Int)
    }

    enum HostEvent: Equatable {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
        case echoAck(UInt64)
    }

    // MARK: Protobuf (only the fields Mosh uses)

    static func encode(_ instruction: Instruction) -> [UInt8] {
        var out = Protobuf.Writer()
        out.varint(1, instruction.protocolVersion)
        out.varint(2, instruction.oldNum)
        out.varint(3, instruction.newNum)
        out.varint(4, instruction.ackNum)
        out.varint(5, instruction.throwawayNum)
        out.bytes(6, instruction.diff)
        return out.bytes
    }

    static func decodeInstruction(_ bytes: [UInt8]) -> Instruction? {
        var result = Instruction(protocolVersion: 0)
        let ok = Protobuf.fields(bytes) { field, value in
            switch (field, value) {
            case (1, .varint(let v)): result.protocolVersion = v
            case (2, .varint(let v)): result.oldNum = v
            case (3, .varint(let v)): result.newNum = v
            case (4, .varint(let v)): result.ackNum = v
            case (5, .varint(let v)): result.throwawayNum = v
            case (6, .bytes(let v)): result.diff = v
            default: break
            }
        }
        return ok ? result : nil
    }

    /// ClientBuffers.UserMessage; consecutive keystrokes share one instruction like mosh's UserStream.
    static func encodeUserMessage(_ events: ArraySlice<UserEvent>) -> [UInt8] {
        guard !events.isEmpty else { return [] }
        var instructions: [[UInt8]] = []
        var pendingKeys: [UInt8] = []
        func flushKeys() {
            guard !pendingKeys.isEmpty else { return }
            var keystroke = Protobuf.Writer()
            keystroke.bytes(4, pendingKeys)
            var instruction = Protobuf.Writer()
            instruction.bytes(2, keystroke.bytes)
            instructions.append(instruction.bytes)
            pendingKeys = []
        }
        for event in events {
            switch event {
            case .keys(let keys):
                pendingKeys += keys
            case .resize(let cols, let rows):
                flushKeys()
                var resize = Protobuf.Writer()
                resize.varint(5, UInt64(cols))
                resize.varint(6, UInt64(rows))
                var instruction = Protobuf.Writer()
                instruction.bytes(3, resize.bytes)
                instructions.append(instruction.bytes)
            }
        }
        flushKeys()
        var message = Protobuf.Writer()
        for instruction in instructions { message.bytes(1, instruction) }
        return message.bytes
    }

    /// HostBuffers.HostMessage.
    static func decodeHostMessage(_ bytes: [UInt8]) -> [HostEvent]? {
        var events: [HostEvent] = []
        var valid = true
        let outer = Protobuf.fields(bytes) { field, value in
            guard field == 1, case .bytes(let instruction) = value else { return }
            valid = Protobuf.fields(instruction) { field, value in
                guard case .bytes(let body) = value else { return }
                switch field {
                case 2:
                    _ = Protobuf.fields(body) { f, v in
                        if f == 4, case .bytes(let hoststring) = v { events.append(.bytes(hoststring)) }
                    }
                case 3:
                    var cols = 0, rows = 0
                    _ = Protobuf.fields(body) { f, v in
                        if case .varint(let n) = v { if f == 5 { cols = Int(n) } else if f == 6 { rows = Int(n) } }
                    }
                    events.append(.resize(cols: cols, rows: rows))
                case 7:
                    _ = Protobuf.fields(body) { f, v in
                        if f == 8, case .varint(let n) = v { events.append(.echoAck(n)) }
                    }
                default:
                    break
                }
            } && valid
        }
        return outer && valid ? events : nil
    }

    // MARK: zlib (mosh uses zlib compress()/uncompress(): a 2-byte header, raw DEFLATE, then Adler-32)

    static func compress(_ bytes: [UInt8]) -> [UInt8] {
        let deflated = (try? (Data(bytes) as NSData).compressed(using: .zlib)) as Data? ?? Data()
        var adler = adler32(bytes).bigEndian
        return [0x78, 0x9C] + Array(deflated) + withUnsafeBytes(of: &adler) { Array($0) }
    }

    static func uncompress(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 6, bytes[0] & 0x0F == 8 else { return nil }
        let raw = Data(bytes[2..<(bytes.count - 4)])
        guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else { return nil }
        let result = Array(inflated)
        let expected = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return adler32(result) == expected ? result : nil
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: bytes.count, by: 5552) {
            for byte in bytes[chunk..<min(chunk + 5552, bytes.count)] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    // MARK: Fragments: uint64 id, uint16 (final << 15 | number), payload

    struct Fragment: Equatable {
        var id: UInt64
        var number: UInt16
        var final: Bool
        var payload: [UInt8]

        var bytes: [UInt8] {
            var out = [UInt8]()
            out.appendBigEndian(id)
            out.appendBigEndian((final ? 0x8000 : 0) | number)
            return out + payload
        }

        init(id: UInt64, number: UInt16, final: Bool, payload: [UInt8]) {
            self.id = id
            self.number = number
            self.final = final
            self.payload = payload
        }

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= 10 else { return nil }
            id = bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
            let combined = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
            final = combined & 0x8000 != 0
            number = combined & 0x7FFF
            payload = Array(bytes[10...])
        }
    }

    static func fragments(_ instruction: Instruction, id: UInt64) -> [Fragment] {
        let payload = compress(encode(instruction))
        let chunks = stride(from: 0, to: max(payload.count, 1), by: fragmentPayloadLimit).map {
            Array(payload[$0..<min($0 + fragmentPayloadLimit, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            Fragment(id: id, number: UInt16(index), final: index == chunks.count - 1, payload: chunk)
        }
    }

    /// Reassembles one instruction at a time, like mosh's FragmentAssembly.
    struct Assembly {
        private var id: UInt64?
        private var parts: [UInt16: [UInt8]] = [:]
        private var total: Int?

        mutating func add(_ fragment: Fragment) -> Instruction? {
            if fragment.id != id {
                id = fragment.id
                parts = [:]
                total = nil
            }
            parts[fragment.number] = fragment.payload
            if fragment.final { total = Int(fragment.number) + 1 }
            guard let total, parts.count == total else { return nil }
            let payload = (0..<total).flatMap { parts[UInt16($0)] ?? [] }
            parts = [:]
            self.total = nil
            return uncompress(payload).flatMap(decodeInstruction)
        }
    }
}

enum Protobuf {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    struct Writer {
        private(set) var bytes: [UInt8] = []

        mutating func varint(_ field: Int, _ value: UInt64) {
            raw(UInt64(field << 3))
            raw(value)
        }

        mutating func bytes(_ field: Int, _ value: [UInt8]) {
            raw(UInt64(field << 3 | 2))
            raw(UInt64(value.count))
            bytes += value
        }

        private mutating func raw(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                bytes.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            bytes.append(UInt8(value))
        }
    }

    /// Calls `visit` for each varint or length-delimited field; skips fixed-width ones. Returns false on malformed input.
    @discardableResult
    static func fields(_ bytes: [UInt8], _ visit: (Int, Value) -> Void) -> Bool {
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return false }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return false }
                visit(field, .varint(value))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return false }
                visit(field, .bytes(Array(bytes[index..<(index + Int(length))])))
                index += Int(length)
            case 1:
                guard bytes.count - index >= 8 else { return false }
                index += 8
            case 5:
                guard bytes.count - index >= 4 else { return false }
                index += 4
            default:
                return false
            }
        }
        return true
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
