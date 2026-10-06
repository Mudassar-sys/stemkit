import Foundation
import Testing
@testable import WaveContainer

/// Parity with the independent Python reference (`evalgate.metadata.flatten_metadata`)
/// for every WAV of the reference corpus. Golden JSON and digests come from
/// `reference/export_metadata_golden.py`.
@Suite("Python reference parity")
struct ParityTests {
    @Test("Every corpus file matches the reference field by field")
    func everyFieldMatchesReference() throws {
        let entries = try Fixtures.manifest()
        #expect(entries.count == 15)
        var comparedFields = 0
        var mismatches: [String] = []
        for entry in entries {
            let url = try Fixtures.corpusURL(entry)
            // The fixture is the file the reference read: our SHA-256 must equal hashlib's.
            #expect(try AudioIntegrity.fileSHA256(of: url) == entry.sha256, "\(entry.file) digest")
            #expect(try AudioIntegrity.fileSHA256(of: try Fixtures.root().appendingPathComponent(entry.golden)) == entry.goldenSHA256,
                    "\(entry.golden) digest")
            let expected = try Fixtures.golden(entry)
            let actual = try WaveFile.read(from: url).flattenedMetadata()
            for key in Set(expected.keys).union(actual.keys).sorted() {
                comparedFields += 1
                let e = expected[key]
                let a = actual[key]
                if let e, let a, scalarsEqual(e, a) { continue }
                mismatches.append("\(entry.file) \(key): expected \(e ?? "<absent>") got \(a ?? "<absent>")")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
        print("PARITY files=\(entries.count) fields_compared=\(comparedFields) mismatches=\(mismatches.count)")
    }

    @Test("Corpus files parse as RIFF, 24-bit PCM mono at 48 kHz, five seconds")
    func corpusFormat() throws {
        for entry in try Fixtures.manifest() {
            let file = try WaveFile.read(from: try Fixtures.corpusURL(entry))
            #expect(file.container == .riff)
            #expect(file.format.encoding == .pcm(bits: 24))
            #expect(file.format.channels == 1)
            #expect(file.format.sampleRate == 48_000)
            #expect(file.durationSeconds == 5.0)
            #expect(file.chunks.map(\.id) == ["bext", "fmt ", "data", "iXML"])
        }
    }
}

@Suite("SHA-256 (FIPS 180-4, NIST example values)")
struct SHA256Tests {
    @Test("NIST example values: the two SHA-256 examples and the additional test data")
    func nistExamples() {
        // SHA256.pdf example values.
        #expect(SHA256Hasher.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Hasher.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // SHA2_Additional.pdf, SHA-256 cases #1, #3, #4, #6 (padding boundaries) and #10.
        #expect(SHA256Hasher.hex([0xBD]) == "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b")
        #expect(SHA256Hasher.hex([UInt8](repeating: 0, count: 55)) == "02779466cdec163811d078815c633f21901413081449002f24aa3e80f0b88ef7")
        #expect(SHA256Hasher.hex([UInt8](repeating: 0, count: 56)) == "d4817aa5497628e7c77e6b606107042bbba3130888c5f47a375e6179be789fbb")
        #expect(SHA256Hasher.hex([UInt8](repeating: 0, count: 64)) == "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b")
        var million = SHA256Hasher()
        let block = [UInt8](repeating: 0, count: 1000)
        for _ in 0 ..< 1000 { million.update(block) }
        #expect(million.finalizeHex() == "d29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025")
    }

    @Test("Incremental updates of any split equal a single update")
    func incrementalEqualsOneShot() {
        var rng = SplitMix64(state: 7)
        let message = (0 ..< 5000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let oneShot = SHA256Hasher.hex(message)
        for _ in 0 ..< 50 {
            var hasher = SHA256Hasher()
            var index = 0
            while index < message.count {
                let n = min(message.count - index, rng.below(130))
                hasher.update(Array(message[index ..< index + n]))
                index += n
            }
            #expect(hasher.finalizeHex() == oneShot)
        }
    }
}
