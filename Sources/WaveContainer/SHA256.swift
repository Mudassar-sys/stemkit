import Foundation

/// SHA-256 as specified in NIST FIPS 180-4, written against Foundation only so the
/// container target has no other dependency. Checked in the tests against the FIPS 180-4
/// example messages and against the Python `hashlib` digests in the fixture manifest.
public struct SHA256Hasher: Sendable {
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0
    private var schedule = [UInt32](repeating: 0, count: 64)

    private static let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// A fresh hasher.
    public init() {}

    /// Adds bytes to the message.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(buffer: $0) }
    }

    /// Adds bytes to the message.
    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update(buffer: $0) }
    }

    private mutating func update(buffer: UnsafeRawBufferPointer) {
        byteCount &+= UInt64(buffer.count)
        var index = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, buffer.count)
            pending.append(contentsOf: buffer[0 ..< take])
            index = take
            if pending.count == 64 {
                let block = pending
                block.withUnsafeBytes { compress($0) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        while buffer.count - index >= 64 {
            compress(UnsafeRawBufferPointer(rebasing: buffer[index ..< index + 64]))
            index += 64
        }
        if index < buffer.count {
            pending.append(contentsOf: buffer[index ..< buffer.count])
        }
    }

    /// Finishes the message and returns the 32 byte digest.
    public mutating func finalize() -> [UInt8] {
        let bitLength = byteCount &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        pending.removeAll()
        var offset = 0
        while offset < tail.count {
            let block = Array(tail[offset ..< offset + 64])
            block.withUnsafeBytes { compress($0) }
            offset += 64
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    /// Finishes the message and returns the digest as lowercase hex.
    public mutating func finalizeHex() -> String {
        Hex.encode(finalize())
    }

    /// The digest of a complete message, as lowercase hex.
    public static func hex(_ bytes: [UInt8]) -> String {
        var hasher = SHA256Hasher()
        hasher.update(bytes)
        return hasher.finalizeHex()
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private mutating func compress(_ block: UnsafeRawBufferPointer) {
        schedule.withUnsafeMutableBufferPointer { w in
            for t in 0 ..< 16 {
                let b = 4 * t
                w[t] = UInt32(block[b]) << 24 | UInt32(block[b + 1]) << 16 | UInt32(block[b + 2]) << 8 | UInt32(block[b + 3])
            }
            for t in 16 ..< 64 {
                let s0 = SHA256Hasher.rotr(w[t - 15], 7) ^ SHA256Hasher.rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = SHA256Hasher.rotr(w[t - 2], 17) ^ SHA256Hasher.rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        schedule.withUnsafeBufferPointer { w in
            SHA256Hasher.k.withUnsafeBufferPointer { k in
                for t in 0 ..< 64 {
                    let s1 = SHA256Hasher.rotr(e, 6) ^ SHA256Hasher.rotr(e, 11) ^ SHA256Hasher.rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ k[t] &+ w[t]
                    let s0 = SHA256Hasher.rotr(a, 2) ^ SHA256Hasher.rotr(a, 13) ^ SHA256Hasher.rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    h = g
                    g = f
                    f = e
                    e = d &+ t1
                    d = c
                    c = b
                    b = a
                    a = t1 &+ t2
                }
            }
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }
}

/// The audio payload integrity check: SHA-256 of the `data` chunk payload, streamed in
/// 1 MiB blocks. The pad byte is not part of the payload and is not hashed.
public enum AudioIntegrity {
    /// SHA-256 of the `data` chunk payload of the file at `url`, as lowercase hex.
    public static func dataChunkSHA256(of url: URL) throws -> String {
        let file = try WaveFile.read(from: url)
        return try dataChunkSHA256(of: url, file: file)
    }

    /// SHA-256 of the `data` chunk payload, using an already parsed chunk table.
    public static func dataChunkSHA256(of url: URL, file: WaveFile) throws -> String {
        try sha256(of: url, offset: file.dataChunk.payloadOffset, length: file.dataChunk.size)
    }

    /// SHA-256 of a byte range of a file, streamed.
    public static func sha256(of url: URL, offset: UInt64, length: UInt64) throws -> String {
        let reader = try FileReader(url: url)
        guard offset <= reader.size, length <= reader.size - offset else {
            throw WaveError.unexpectedEndOfFile(offset: offset, needed: length)
        }
        var hasher = SHA256Hasher()
        var position = offset
        var remaining = length
        do {
            try reader.handle.seek(toOffset: position)
            while remaining > 0 {
                let count = Int(min(UInt64(WaveLimits.copyBlockBytes), remaining))
                guard let block = try reader.handle.read(upToCount: count), block.count == count else {
                    throw WaveError.unexpectedEndOfFile(offset: position, needed: UInt64(count))
                }
                hasher.update(block)
                position += UInt64(count)
                remaining -= UInt64(count)
            }
        } catch let error as WaveError {
            throw error
        } catch {
            throw WaveError.io(error.localizedDescription)
        }
        return hasher.finalizeHex()
    }

    /// SHA-256 of a whole file, streamed.
    public static func fileSHA256(of url: URL) throws -> String {
        let size = try FileReader(url: url).size
        return try sha256(of: url, offset: 0, length: size)
    }

    /// True when both files carry the same audio: identical sample format fields (including the
    /// extensible channel mask, valid bits and sub-format) and an identical `data` payload hash.
    /// Metadata chunks are ignored.
    public static func haveSameAudio(_ a: URL, _ b: URL) throws -> Bool {
        let fa = try WaveFile.read(from: a)
        let fb = try WaveFile.read(from: b)
        let formatA = (fa.format.effectiveFormatTag, fa.format.channels, fa.format.sampleRate, fa.format.bitsPerSample, fa.format.blockAlign)
        let formatB = (fb.format.effectiveFormatTag, fb.format.channels, fb.format.sampleRate, fb.format.bitsPerSample, fb.format.blockAlign)
        guard formatA == formatB, fa.format.extensible == fb.format.extensible,
              fa.dataChunk.size == fb.dataChunk.size else { return false }
        return try dataChunkSHA256(of: a, file: fa) == dataChunkSHA256(of: b, file: fb)
    }
}
