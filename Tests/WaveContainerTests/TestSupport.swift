import Foundation
import Testing
@testable import WaveContainer

/// Locations of the committed fixtures.
enum Fixtures {
    static func root() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    struct Entry: Sendable {
        let file: String
        let sha256: String
        let golden: String
        let goldenSHA256: String
    }

    static func manifest() throws -> [Entry] {
        let data = try Data(contentsOf: try root().appendingPathComponent("manifest.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        let top = try #require(object as? [String: Any])
        let files = try #require(top["files"] as? [[String: Any]])
        return try files.map { item in
            Entry(
                file: try #require(item["file"] as? String),
                sha256: try #require(item["sha256"] as? String),
                golden: try #require(item["golden"] as? String),
                goldenSHA256: try #require(item["golden_sha256"] as? String)
            )
        }
    }

    static func golden(_ entry: Entry) throws -> [String: String] {
        let data = try Data(contentsOf: try root().appendingPathComponent(entry.golden))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    static func corpusURL(_ entry: Entry) throws -> URL {
        try root().appendingPathComponent(entry.file)
    }
}

/// A temporary directory removed when the value is released.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stemkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func copy(_ source: URL, as name: String? = nil) throws -> URL {
        let target = url.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    func write(_ bytes: [UInt8], as name: String) throws -> URL {
        let target = url.appendingPathComponent(name)
        try Data(bytes).write(to: target)
        return target
    }
}

func bytes(of url: URL) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: url))
}

/// Byte offsets where two buffers differ (the shorter length is compared, plus any length difference).
func differingOffsets(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
    var out: [Int] = []
    for i in 0 ..< min(a.count, b.count) where a[i] != b[i] {
        out.append(i)
    }
    if a.count != b.count {
        out.append(min(a.count, b.count))
    }
    return out
}

func scalarsEqual(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

/// Builds small WAVE images in memory for the synthetic tests.
enum WaveBuilder {
    static func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        var out = Array(id.utf8)
        out += LE.bytes32(UInt32(payload.count))
        out += payload
        if payload.count % 2 == 1 { out.append(0) }
        return out
    }

    static func fmt(tag: UInt16 = 1, channels: UInt16 = 1, rate: UInt32 = 48_000, bits: UInt16 = 24) -> [UInt8] {
        let align = channels * ((bits + 7) / 8)
        var p: [UInt8] = []
        LE.put16(tag, into: &p)
        LE.put16(channels, into: &p)
        LE.put32(rate, into: &p)
        LE.put32(rate * UInt32(align), into: &p)
        LE.put16(align, into: &p)
        LE.put16(bits, into: &p)
        return p
    }

    /// `WAVE_FORMAT_EXTENSIBLE` with the given sub-format tag in the GUID's first two bytes.
    static func fmtExtensible(subFormat: UInt16, channels: UInt16 = 2, rate: UInt32 = 48_000, bits: UInt16 = 32) -> [UInt8] {
        var p = fmt(tag: 0xFFFE, channels: channels, rate: rate, bits: bits)
        LE.put16(22, into: &p)  // cbSize
        LE.put16(bits, into: &p)  // valid bits
        LE.put32(0x3, into: &p)  // channel mask: front left, front right
        LE.put16(subFormat, into: &p)
        p += [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
        return p
    }

    static func riff(_ chunks: [[UInt8]]) -> [UInt8] {
        let body = chunks.flatMap { $0 }
        return Array("RIFF".utf8) + LE.bytes32(UInt32(4 + body.count)) + Array("WAVE".utf8) + body
    }

    /// An RF64 or BW64 header with a ds64 chunk. `riffSize` and `dataSize` go into ds64.
    static func ds64Header(magic: String, riffSize: UInt64, dataSize: UInt64, sampleCount: UInt64 = 0,
                           table: [(String, UInt64)] = []) -> [UInt8] {
        var ds: [UInt8] = []
        LE.put64(riffSize, into: &ds)
        LE.put64(dataSize, into: &ds)
        LE.put64(sampleCount, into: &ds)
        LE.put32(UInt32(table.count), into: &ds)
        for (id, size) in table {
            ds += Array(id.utf8)
            LE.put64(size, into: &ds)
        }
        return Array(magic.utf8) + LE.bytes32(0xFFFF_FFFF) + Array("WAVE".utf8) + chunk("ds64", ds)
    }

    /// A complete small RF64/BW64 image whose data chunk uses the 0xFFFFFFFF size marker.
    static func smallDS64File(magic: String, audio: [UInt8], extra: [[UInt8]] = []) -> [UInt8] {
        let fmtChunk = chunk("fmt ", fmt())
        var dataChunk = Array("data".utf8) + LE.bytes32(0xFFFF_FFFF) + audio
        if audio.count % 2 == 1 { dataChunk.append(0) }
        let rest = fmtChunk + dataChunk + extra.flatMap { $0 }
        let headerLength = 12 + 8 + 28
        let total = UInt64(headerLength + rest.count)
        return ds64Header(magic: magic, riffSize: total - 8, dataSize: UInt64(audio.count)) + rest
    }

    static func bextPayload(description: String = "synthetic", history: String = "A=PCM,F=48000,W=24,M=mono\r\n") throws -> [UInt8] {
        var bext = Bext()
        bext.description = description
        bext.originator = "stemkit tests"
        bext.codingHistory = history
        return try bext.serialized()
    }
}

/// Deterministic pseudo random numbers (SplitMix64), so fuzz failures reproduce.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }
}
