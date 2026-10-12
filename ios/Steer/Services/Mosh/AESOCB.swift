import CommonCrypto
import Foundation

/// AES-128-OCB3 (RFC 7253) with a 96-bit nonce, 128-bit tag, and no associated data — the AEAD Mosh uses.
/// Apple's crypto libraries do not provide OCB, so it is built here on single-block AES.
final class AESOCB: @unchecked Sendable {
    private let encryptor: CCCryptorRef
    private let decryptor: CCCryptorRef
    private let lStar: [UInt8]
    private let lDollar: [UInt8]
    private var l: [[UInt8]]

    init?(key: [UInt8]) {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var enc: CCCryptorRef?
        var dec: CCCryptorRef?
        guard CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                              key, key.count, nil, &enc) == kCCSuccess,
              CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                              key, key.count, nil, &dec) == kCCSuccess,
              let enc, let dec else { return nil }
        encryptor = enc
        decryptor = dec
        var zero = [UInt8](repeating: 0, count: 16)
        AESOCB.apply(enc, &zero)
        lStar = zero
        lDollar = AESOCB.double(lStar)
        l = [AESOCB.double(lDollar)]
    }

    deinit {
        CCCryptorRelease(encryptor)
        CCCryptorRelease(decryptor)
    }

    /// Returns ciphertext followed by the 16-byte tag.
    func seal(_ plaintext: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var offset = initialOffset(nonce)
        var checksum = [UInt8](repeating: 0, count: 16)
        var out = [UInt8]()
        out.reserveCapacity(plaintext.count + 16)
        let full = plaintext.count / 16
        for i in 0..<full {
            xor(&offset, lValue(ntz(i + 1)))
            let block = Array(plaintext[(i * 16)..<(i * 16 + 16)])
            xor(&checksum, block)
            var tmp = block
            xor(&tmp, offset)
            AESOCB.apply(encryptor, &tmp)
            xor(&tmp, offset)
            out += tmp
        }
        let rest = Array(plaintext[(full * 16)...])
        if !rest.isEmpty {
            xor(&offset, lStar)
            var pad = offset
            AESOCB.apply(encryptor, &pad)
            out += zip(rest, pad).map { $0 ^ $1 }
            xor(&checksum, padded(rest))
        }
        var tag = checksum
        xor(&tag, offset)
        xor(&tag, lDollar)
        AESOCB.apply(encryptor, &tag)
        return out + tag
    }

    /// Returns the plaintext, or nil when the tag does not verify.
    func open(_ sealed: [UInt8], nonce: [UInt8]) -> [UInt8]? {
        guard sealed.count >= 16 else { return nil }
        let ciphertext = sealed.dropLast(16)
        var offset = initialOffset(nonce)
        var checksum = [UInt8](repeating: 0, count: 16)
        var out = [UInt8]()
        out.reserveCapacity(ciphertext.count)
        let full = ciphertext.count / 16
        let base = ciphertext.startIndex
        for i in 0..<full {
            xor(&offset, lValue(ntz(i + 1)))
            var tmp = Array(ciphertext[(base + i * 16)..<(base + i * 16 + 16)])
            xor(&tmp, offset)
            AESOCB.apply(decryptor, &tmp)
            xor(&tmp, offset)
            xor(&checksum, tmp)
            out += tmp
        }
        let rest = Array(ciphertext[(base + full * 16)...])
        if !rest.isEmpty {
            xor(&offset, lStar)
            var pad = offset
            AESOCB.apply(encryptor, &pad)
            let plain = zip(rest, pad).map { $0 ^ $1 }
            xor(&checksum, padded(plain))
            out += plain
        }
        var tag = checksum
        xor(&tag, offset)
        xor(&tag, lDollar)
        AESOCB.apply(encryptor, &tag)
        // Constant-time comparison.
        let difference = zip(tag, sealed.suffix(16)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        return difference == 0 ? out : nil
    }

    private func initialOffset(_ nonce: [UInt8]) -> [UInt8] {
        precondition(nonce.count == 12)
        // Nonce block for a 128-bit tag: 31 zero bits, a one bit, then the 96-bit nonce.
        var block: [UInt8] = [0, 0, 0, 1] + nonce
        let bottom = Int(block[15] & 0x3F)
        block[15] &= 0xC0
        AESOCB.apply(encryptor, &block)
        let stretch = block + (0..<8).map { block[$0] ^ block[$0 + 1] }
        let byteShift = bottom / 8
        let bitShift = bottom % 8
        return (0..<16).map { i in
            let hi = stretch[i + byteShift] << bitShift
            let lo = bitShift == 0 ? 0 : stretch[i + byteShift + 1] >> (8 - bitShift)
            return hi | lo
        }
    }

    private func lValue(_ index: Int) -> [UInt8] {
        while l.count <= index { l.append(AESOCB.double(l[l.count - 1])) }
        return l[index]
    }

    private func ntz(_ value: Int) -> Int { value.trailingZeroBitCount }

    private func padded(_ bytes: [UInt8]) -> [UInt8] {
        var block = bytes + [0x80]
        block += [UInt8](repeating: 0, count: 16 - block.count)
        return block
    }

    private func xor(_ a: inout [UInt8], _ b: [UInt8]) {
        for i in 0..<16 { a[i] ^= b[i] }
    }

    private static func double(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            out[i] = block[i] << 1 | (i < 15 ? block[i + 1] >> 7 : 0)
        }
        if block[0] & 0x80 != 0 { out[15] ^= 0x87 }
        return out
    }

    private static func apply(_ cryptor: CCCryptorRef, _ block: inout [UInt8]) {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        _ = CCCryptorUpdate(cryptor, block, 16, &out, 16, &moved)
        block = out
    }
}
