import Foundation

/// Random access to the bytes of a file or of an in-memory buffer.
/// Every read returns exactly the requested count or throws.
protocol ByteReader {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

/// Reads an in-memory buffer. Used by the fuzz tests and by `WaveFile.parse(bytes:)`.
struct MemoryReader: ByteReader {
    let bytes: [UInt8]
    var size: UInt64 { UInt64(bytes.count) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw WaveError.io("negative read count") }
        guard offset <= size, UInt64(count) <= size - offset else {
            throw WaveError.unexpectedEndOfFile(offset: offset, needed: UInt64(max(count, 0)))
        }
        let start = Int(offset)
        return Array(bytes[start ..< start + count])
    }
}

/// Reads a file through a `FileHandle`, with seeks. Never maps or loads the whole file.
final class FileReader: ByteReader {
    let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
        } catch let error as WaveError {
            throw error
        } catch {
            throw WaveError.io(error.localizedDescription)
        }
    }

    deinit {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw WaveError.io("negative read count") }
        guard offset <= size, UInt64(count) <= size - offset else {
            throw WaveError.unexpectedEndOfFile(offset: offset, needed: UInt64(max(count, 0)))
        }
        if count == 0 { return [] }
        let data: Data?
        do {
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: count)
        } catch {
            throw WaveError.io(error.localizedDescription)
        }
        guard let data, data.count == count else {
            throw WaveError.unexpectedEndOfFile(offset: offset, needed: UInt64(count))
        }
        return [UInt8](data)
    }
}

/// Little-endian decoding with bounds checks on every access.
enum LE {
    static func u16(_ b: [UInt8], _ o: Int) throws -> UInt16 {
        guard o >= 0, o <= b.count - 2 else { throw WaveError.unexpectedEndOfFile(offset: UInt64(max(o, 0)), needed: 2) }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func i16(_ b: [UInt8], _ o: Int) throws -> Int16 {
        Int16(bitPattern: try u16(b, o))
    }

    static func u32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
        guard o >= 0, o <= b.count - 4 else { throw WaveError.unexpectedEndOfFile(offset: UInt64(max(o, 0)), needed: 4) }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// A 64-bit value stored as a low 32-bit word followed by a high 32-bit word.
    static func u64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
        let low = try u32(b, o)
        let high = try u32(b, o + 4)
        return UInt64(low) | UInt64(high) << 32
    }

    static func put16(_ v: UInt16, into b: inout [UInt8]) {
        b.append(UInt8(truncatingIfNeeded: v))
        b.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    static func put32(_ v: UInt32, into b: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            b.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
        }
    }

    static func put64(_ v: UInt64, into b: inout [UInt8]) {
        put32(UInt32(truncatingIfNeeded: v), into: &b)
        put32(UInt32(truncatingIfNeeded: v >> 32), into: &b)
    }

    static func bytes32(_ v: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        put32(v, into: &out)
        return out
    }

    static func bytes64(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        put64(v, into: &out)
        return out
    }
}

/// ISO 8859-1 text helpers. Every byte maps to one character, so decoding never fails
/// and re-encoding a decoded value reproduces the original bytes.
enum Latin1 {
    static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    static func encode(_ text: String, field: String) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { throw WaveError.notLatin1(field: field) }
            out.append(UInt8(scalar.value))
        }
        return out
    }

    /// The bytes with trailing NUL bytes removed.
    static func trimTrailingNULs(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var end = bytes.endIndex
        while end > bytes.startIndex, bytes[end - 1] == 0 {
            end -= 1
        }
        return bytes[bytes.startIndex ..< end]
    }

    /// A chunk id made safe for messages: non printable bytes become `?`.
    static func printable(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20 ... 0x7E).contains($0) ? Character(Unicode.Scalar($0)) : "?" })
    }
}

/// Lowercase hexadecimal.
enum Hex {
    static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }

    static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30 ... 0x39: return c - 0x30
        case 0x61 ... 0x66: return c - 0x61 + 10
        case 0x41 ... 0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}
