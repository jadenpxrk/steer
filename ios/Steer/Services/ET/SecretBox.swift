import Foundation

/// libsodium's `crypto_secretbox` (XSalsa20-Poly1305), which Eternal Terminal uses for every packet.
/// Output is the 16-byte Poly1305 tag followed by the ciphertext.
struct SecretBox {
    private let key: [UInt32]

    init?(key: [UInt8]) {
        guard key.count == 32 else { return nil }
        self.key = Self.words(key)
    }

    func seal(_ plaintext: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var stream = keystream(nonce: nonce, count: 32 + plaintext.count)
        for index in plaintext.indices { stream[32 + index] ^= plaintext[index] }
        let ciphertext = Array(stream[32...])
        return Self.poly1305(ciphertext, key: Array(stream[0..<32])) + ciphertext
    }

    func open(_ sealed: [UInt8], nonce: [UInt8]) -> [UInt8]? {
        guard sealed.count >= 16 else { return nil }
        let ciphertext = Array(sealed[16...])
        var stream = keystream(nonce: nonce, count: 32 + ciphertext.count)
        let tag = Self.poly1305(ciphertext, key: Array(stream[0..<32]))
        guard zip(tag, sealed[0..<16]).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        for index in ciphertext.indices { stream[32 + index] ^= ciphertext[index] }
        return Array(stream[32...])
    }

    private func keystream(nonce: [UInt8], count: Int) -> [UInt8] {
        precondition(nonce.count == 24)
        let nonceWords = Self.words(nonce)
        let subkey = Self.hsalsa(key: key, nonce: Array(nonceWords[0..<4]))
        var output = [UInt8]()
        output.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while output.count < count {
            let block = Self.salsa(Self.input(key: subkey, middle: [
                nonceWords[4], nonceWords[5], UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32)
            ]))
            for word in block { withUnsafeBytes(of: word.littleEndian) { output += $0 } }
            counter += 1
        }
        return Array(output[0..<count])
    }

    // MARK: Salsa20

    private static func input(key: [UInt32], middle: [UInt32]) -> [UInt32] {
        [0x6170_7865, key[0], key[1], key[2], key[3], 0x3320_646E, middle[0], middle[1],
         middle[2], middle[3], 0x7962_2D32, key[4], key[5], key[6], key[7], 0x6B20_6574]
    }

    private static func rounds(_ x: inout [UInt32]) {
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[b] ^= (x[a] &+ x[d]).rotatedLeft(7)
            x[c] ^= (x[b] &+ x[a]).rotatedLeft(9)
            x[d] ^= (x[c] &+ x[b]).rotatedLeft(13)
            x[a] ^= (x[d] &+ x[c]).rotatedLeft(18)
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12); quarter(5, 9, 13, 1); quarter(10, 14, 2, 6); quarter(15, 3, 7, 11)
            quarter(0, 1, 2, 3); quarter(5, 6, 7, 4); quarter(10, 11, 8, 9); quarter(15, 12, 13, 14)
        }
    }

    private static func salsa(_ input: [UInt32]) -> [UInt32] {
        var x = input
        rounds(&x)
        return zip(x, input).map { $0 &+ $1 }
    }

    private static func hsalsa(key: [UInt32], nonce: [UInt32]) -> [UInt32] {
        var x = input(key: key, middle: nonce)
        rounds(&x)
        return [x[0], x[5], x[10], x[15], x[6], x[7], x[8], x[9]]
    }

    private static func words(_ bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { le32(bytes, $0) }
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    // MARK: Poly1305 (26-bit limbs, as in poly1305-donna)

    static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let mask: UInt32 = 0x3FF_FFFF
        let r0 = UInt64(le32(key, 0) & 0x3FF_FFFF), r1 = UInt64((le32(key, 3) >> 2) & 0x3FF_FF03)
        let r2 = UInt64((le32(key, 6) >> 4) & 0x3FF_C0FF), r3 = UInt64((le32(key, 9) >> 6) & 0x3F0_3FFF)
        let r4 = UInt64((le32(key, 12) >> 8) & 0x00F_FFFF)
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5
        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

        var offset = 0
        while offset < message.count {
            var block = Array(message[offset..<min(offset + 16, message.count)])
            let hibit: UInt32 = block.count == 16 ? 1 << 24 : 0
            if block.count < 16 { block += [1] + [UInt8](repeating: 0, count: 15 - block.count) }
            offset += 16
            h0 += le32(block, 0) & mask
            h1 += (le32(block, 3) >> 2) & mask
            h2 += (le32(block, 6) >> 4) & mask
            h3 += (le32(block, 9) >> 6) & mask
            h4 += (le32(block, 12) >> 8) | hibit
            let d0 = UInt64(h0) * r0 + UInt64(h1) * s4 + UInt64(h2) * s3 + UInt64(h3) * s2 + UInt64(h4) * s1
            var d1 = UInt64(h0) * r1 + UInt64(h1) * r0 + UInt64(h2) * s4 + UInt64(h3) * s3 + UInt64(h4) * s2
            var d2 = UInt64(h0) * r2 + UInt64(h1) * r1 + UInt64(h2) * r0 + UInt64(h3) * s4 + UInt64(h4) * s3
            var d3 = UInt64(h0) * r3 + UInt64(h1) * r2 + UInt64(h2) * r1 + UInt64(h3) * r0 + UInt64(h4) * s4
            var d4 = UInt64(h0) * r4 + UInt64(h1) * r3 + UInt64(h2) * r2 + UInt64(h3) * r1 + UInt64(h4) * r0
            h0 = UInt32(d0 & UInt64(mask)); d1 += d0 >> 26
            h1 = UInt32(d1 & UInt64(mask)); d2 += d1 >> 26
            h2 = UInt32(d2 & UInt64(mask)); d3 += d2 >> 26
            h3 = UInt32(d3 & UInt64(mask)); d4 += d3 >> 26
            h4 = UInt32(d4 & UInt64(mask))
            h0 += UInt32(d4 >> 26) * 5
            h1 += h0 >> 26; h0 &= mask
        }

        var c: UInt32
        c = h1 >> 26; h1 &= mask; h2 += c
        c = h2 >> 26; h2 &= mask; h3 += c
        c = h3 >> 26; h3 &= mask; h4 += c
        c = h4 >> 26; h4 &= mask; h0 += c * 5
        c = h0 >> 26; h0 &= mask; h1 += c

        // Subtract p = 2^130 - 5 when h >= p, without branching on secret data.
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        var g4 = h4 &+ c &- (1 << 26)
        var select = (g4 >> 31) &- 1
        g0 &= select; g1 &= select; g2 &= select; g3 &= select; g4 &= select
        select = ~select
        h0 = (h0 & select) | g0; h1 = (h1 & select) | g1; h2 = (h2 & select) | g2
        h3 = (h3 & select) | g3; h4 = (h4 & select) | g4

        let words = [h0 | h1 << 26, h1 >> 6 | h2 << 20, h2 >> 12 | h3 << 14, h3 >> 18 | h4 << 8]
        var carry: UInt64 = 0
        var tag = [UInt8]()
        for index in 0..<4 {
            carry += UInt64(words[index]) + UInt64(le32(key, 16 + 4 * index))
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: carry).littleEndian) { tag += $0 }
            carry >>= 32
        }
        return tag
    }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
}
