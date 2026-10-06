import Foundation
import Testing
@testable import WaveContainer

/// Truncations and bit flips of valid headers. Each case must end in a typed `WaveError` or a
/// valid parse; a crash fails the whole run, and every loop in the parser is bounded by the
/// file size or a sanity limit, so a hang cannot occur.
@Suite("Fuzzing")
struct FuzzTests {
    static func seeds() throws -> [(String, [UInt8])] {
        let entry = try #require(try Fixtures.manifest().first)
        let corpus = try WaveFile.read(from: try Fixtures.corpusURL(entry))
        let bext = try #require(corpus.bext).serialized()
        let ixml = try #require(corpus.ixml).rawBytes
        let audio = (0 ..< 600).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let riff = WaveBuilder.riff([
            WaveBuilder.chunk("bext", bext), WaveBuilder.chunk("JUNK", [UInt8](repeating: 0, count: 28)),
            WaveBuilder.chunk("fmt ", WaveBuilder.fmtExtensible(subFormat: 3)),
            WaveBuilder.chunk("data", audio), WaveBuilder.chunk("iXML", ixml),
        ])
        let rf64 = WaveBuilder.smallDS64File(magic: "RF64", audio: audio, extra: [WaveBuilder.chunk("iXML", ixml)])
        let bw64 = WaveBuilder.smallDS64File(magic: "BW64", audio: audio, extra: [WaveBuilder.chunk("bext", bext)])
        return [("riff", riff), ("rf64", rf64), ("bw64", bw64), ("ds64-table", DS64TableTests.tableFile())]
    }

    enum Outcome { case parsed, typedError }

    static func exercise(_ image: [UInt8]) -> Outcome? {
        let file: WaveFile
        do {
            file = try WaveFile.parse(bytes: image)
        } catch is WaveError {
            return .typedError
        } catch {
            return nil
        }
        // Everything a reader does next must also end in a value or a typed error.
        do {
            _ = try file.flattenedMetadata()
        } catch is WaveError {
        } catch {
            return nil
        }
        do {
            _ = try file.bext?.serialized()
        } catch is WaveError {
        } catch {
            return nil
        }
        _ = file.bext?.specificationIssues
        _ = file.durationSeconds
        return .parsed
    }

    @Test("Thousands of truncations and bit flips end in a typed error or a valid parse")
    func truncationsAndBitFlips() throws {
        var rng = SplitMix64(state: 0x5354_454D_4B49_54)
        var parsed = 0
        var typed = 0
        var untyped = 0
        for (name, seed) in try Self.seeds() {
            #expect(Self.exercise(seed) == .parsed, "seed \(name) must parse")
            // Every truncation length of the first 1200 bytes, then random ones.
            for length in 0 ..< min(seed.count, 1200) {
                switch Self.exercise(Array(seed[0 ..< length])) {
                case .parsed: parsed += 1
                case .typedError: typed += 1
                case nil: untyped += 1
                }
            }
            for _ in 0 ..< 1000 {
                var image = seed
                let flips = 1 + rng.below(4)
                for _ in 0 ..< flips {
                    // Most flips land in the header area, where sizes and ids live.
                    let span = rng.below(4) == 0 ? image.count : min(image.count, 700)
                    let index = rng.below(span)
                    image[index] ^= UInt8(1) << UInt8(rng.below(8))
                }
                if rng.below(3) == 0 {
                    image = Array(image[0 ..< rng.below(image.count + 1)])
                }
                switch Self.exercise(image) {
                case .parsed: parsed += 1
                case .typedError: typed += 1
                case nil: untyped += 1
                }
            }
        }
        #expect(untyped == 0)
        #expect(parsed + typed > 5000)
        print("FUZZ cases=\(parsed + typed + untyped) parsed=\(parsed) typed_errors=\(typed) untyped=\(untyped)")
    }

    @Test("Mutated files on disk: reads and writes end in a typed error or keep the audio hash")
    func mutatedFilesOnDisk() throws {
        let temp = try TempDirectory()
        var rng = SplitMix64(state: 42)
        var outcomes = [0, 0, 0]
        for (name, seed) in try Self.seeds() {
            for i in 0 ..< 60 {
                var image = seed
                for _ in 0 ..< (1 + rng.below(3)) {
                    let index = rng.below(min(image.count, 400))
                    image[index] ^= UInt8(1) << UInt8(rng.below(8))
                }
                let url = try temp.write(image, as: "\(name)-\(i).wav")
                // The audio hash is taken independently of the writer, before and after.
                let before = try? AudioIntegrity.dataChunkSHA256(of: url)
                do {
                    let file = try WaveFile.read(from: url)
                    var bext = file.bext ?? Bext()
                    bext.description = "fuzz \(i)"
                    let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: url)
                    #expect(report.audioUnchanged)
                    #expect(before != nil)
                    #expect(try AudioIntegrity.dataChunkSHA256(of: url) == before)
                    outcomes[0] += 1
                } catch let error as WaveError {
                    if case .integrityCheckFailed = error { Issue.record("audio changed: \(error)") }
                    // A refused or failed write leaves the file exactly as it was.
                    #expect(try bytes(of: url) == image, "\(name)-\(i): \(error)")
                    outcomes[1] += 1
                } catch {
                    outcomes[2] += 1
                    Issue.record("untyped error: \(error)")
                }
            }
        }
        #expect(outcomes[2] == 0)
        print("FUZZ_DISK written=\(outcomes[0]) typed_errors=\(outcomes[1]) untyped=\(outcomes[2])")
    }
}

@Suite("Tech 3285 v2 loudness rounding")
struct RoundingTests {
    struct Example: Sendable, CustomStringConvertible {
        let text: String
        let expected: Int16
        let hex: UInt16
        var description: String { text }
    }

    @Test("The specification's examples", arguments: [
        Example(text: "-22.644", expected: -2264, hex: 0xF728),
        Example(text: "-22.645", expected: -2265, hex: 0xF727),
        Example(text: "-22.646", expected: -2265, hex: 0xF727),
        Example(text: "12.764", expected: 1276, hex: 0x04FC),
        Example(text: "12.765", expected: 1277, hex: 0x04FD),
        Example(text: "12.766", expected: 1277, hex: 0x04FD),
    ])
    func specExamples(example: Example) throws {
        let value = try #require(LoudnessCoding.parseDecimal(example.text))
        let encoded = try LoudnessCoding.encode(value, field: .loudnessValue)
        #expect(encoded == example.expected)
        #expect(UInt16(bitPattern: encoded) == example.hex)
    }

    @Test("A binary double can miss a decimal tie, which is why the API takes Decimal")
    func doubleTieIsNotExact() throws {
        // The double nearest 1.005 is slightly below it, so 1.005 * 100 lands below the tie.
        let product = 1.005 * 100.0
        print("DOUBLE 1.005*100=\(product)")
        #expect(product < 100.5)
        let value = try #require(LoudnessCoding.parseDecimal("1.005"))
        #expect(try LoudnessCoding.encode(value, field: .loudnessValue) == 101)
    }

    @Test("Zero, not used and ranges")
    func edges() throws {
        #expect(try LoudnessCoding.encode(0, field: .loudnessValue) == 0)
        #expect(try LoudnessCoding.encode(Decimal(string: "-0.004") ?? 1, field: .loudnessValue) == 0)
        #expect(try LoudnessCoding.encode(Decimal(string: "99.99") ?? 0, field: .loudnessRange) == 9999)
        #expect(throws: WaveError.self) { try LoudnessCoding.encode(Decimal(100), field: .loudnessValue) }
        #expect(throws: WaveError.self) { try LoudnessCoding.encode(Decimal(-1), field: .loudnessRange) }
        #expect(LoudnessCoding.decode(Bext.loudnessNotUsed, field: .loudnessValue) == nil)
        #expect(LoudnessCoding.decode(-2265, field: .loudnessValue) == Decimal(string: "-22.65"))
        #expect(LoudnessCoding.decode(-5, field: .loudnessRange) == nil)
        #expect(LoudnessCoding.parseDecimal("1e3") == nil)
        #expect(LoudnessCoding.parseDecimal("12.5x") == nil)
        #expect(LoudnessCoding.parseDecimal("") == nil)
    }
}

@Suite("fmt chunk")
struct FormatTests {
    struct FormatCase: Sendable, CustomStringConvertible {
        let tag: UInt16
        let bits: UInt16
        let expected: SampleEncoding
        var description: String { expected.description }
    }

    @Test("PCM 16, 24 and 32 bit and IEEE float 32 and 64 bit", arguments: [
        FormatCase(tag: 1, bits: 16, expected: .pcm(bits: 16)),
        FormatCase(tag: 1, bits: 24, expected: .pcm(bits: 24)),
        FormatCase(tag: 1, bits: 32, expected: .pcm(bits: 32)),
        FormatCase(tag: 3, bits: 32, expected: .ieeeFloat(bits: 32)),
        FormatCase(tag: 3, bits: 64, expected: .ieeeFloat(bits: 64)),
    ])
    func plainFormats(item: FormatCase) throws {
        let format = try WaveFormat(parsing: WaveBuilder.fmt(tag: item.tag, channels: 2, rate: 44_100, bits: item.bits))
        #expect(format.encoding == item.expected)
        #expect(format.isSupportedEncoding)
        #expect(format.blockAlign == 2 * (item.bits / 8))
        #expect(format.extensible == nil)
    }

    @Test("WAVE_FORMAT_EXTENSIBLE resolves the sub-format", arguments: [
        FormatCase(tag: 1, bits: 32, expected: .pcm(bits: 32)),
        FormatCase(tag: 3, bits: 32, expected: .ieeeFloat(bits: 32)),
    ])
    func extensible(item: FormatCase) throws {
        let subFormat = item.tag
        let expected = item.expected
        let format = try WaveFormat(parsing: WaveBuilder.fmtExtensible(subFormat: subFormat))
        #expect(format.formatTag == 0xFFFE)
        #expect(format.encoding == expected)
        #expect(format.extensible?.channelMask == 0x3)
        #expect(format.extensible?.validBitsPerSample == 32)
        #expect(format.extensible?.subFormatGUID.hasPrefix(subFormat == 1 ? "0100" : "0300") == true)
    }

    @Test("Malformed fmt chunks are typed errors")
    func malformed() throws {
        #expect(throws: WaveError.self) { try WaveFormat(parsing: [1, 0, 1, 0]) }
        var zeroChannels = WaveBuilder.fmt()
        zeroChannels[2] = 0
        zeroChannels[3] = 0
        #expect(throws: WaveError.self) { try WaveFormat(parsing: zeroChannels) }
        #expect(try WaveFormat(parsing: WaveBuilder.fmt(tag: 2, bits: 4)).isSupportedEncoding == false)
    }

    @Test("iXML flattening is bounded: too many elements or too much output is a typed error")
    func ixmlBounds() throws {
        let many = "<BWFXML>" + String(repeating: "<A/>", count: WaveLimits.maxXMLElements + 1) + "</BWFXML>"
        #expect(throws: WaveError.self) { try IXML(xmlText: many).flattened() }
        // 2,000 children under a 40,000-character name: about 80 MB of keys, over the budget.
        let longName = String(repeating: "N", count: 40_000)
        let wide = "<BWFXML><\(longName)>" + String(repeating: "<a>x</a>", count: 2_000) + "</\(longName)></BWFXML>"
        #expect(throws: WaveError.self) { try IXML(xmlText: wide).flattened() }
        // A normal document still flattens.
        #expect(try IXML(xmlText: "<BWFXML><NOTE>ok</NOTE></BWFXML>").flattened()["NOTE"] == "ok")
    }

    @Test("Container errors are typed")
    func containerErrors() {
        #expect(throws: WaveError.notRIFF(found: "OggS")) { try WaveFile.parse(bytes: Array("OggS0000WAVE".utf8)) }
        #expect(throws: WaveError.self) { try WaveFile.parse(bytes: Array("RIFF".utf8)) }
        #expect(throws: WaveError.missingDS64) {
            try WaveFile.parse(bytes: Array("RF64".utf8) + LE.bytes32(0xFFFF_FFFF) + Array("WAVE".utf8) + WaveBuilder.chunk("fmt ", WaveBuilder.fmt()))
        }
        #expect(throws: WaveError.missingChunk("data")) {
            try WaveFile.parse(bytes: WaveBuilder.riff([WaveBuilder.chunk("fmt ", WaveBuilder.fmt())]))
        }
    }
}

@Suite("ds64 chunk size table")
struct DS64TableTests {
    /// An RF64 image whose two JUNK chunks take their sizes from the ds64 table (in order),
    /// with an extra table entry that matches no chunk.
    static func tableFile() -> [UInt8] {
        let junkA = Array("JUNK".utf8) + LE.bytes32(0xFFFF_FFFF) + [UInt8](repeating: 0xAA, count: 10)
        let junkB = Array("JUNK".utf8) + LE.bytes32(0xFFFF_FFFF) + [UInt8](repeating: 0xBB, count: 20)
        let fmt = WaveBuilder.chunk("fmt ", WaveBuilder.fmt())
        let audio = [UInt8](repeating: 1, count: 300)
        let data = Array("data".utf8) + LE.bytes32(0xFFFF_FFFF) + audio
        let rest = junkA + junkB + fmt + data
        let table: [(String, UInt64)] = [("JUNK", 10), ("JUNK", 20), ("axml", 99)]
        let headerLength = 12 + 8 + 28 + 12 * table.count
        let total = UInt64(headerLength + rest.count)
        return WaveBuilder.ds64Header(magic: "RF64", riffSize: total - 8, dataSize: UInt64(audio.count), table: table) + rest
    }

    @Test("0xFFFFFFFF sizes of other chunks come from table entries, in order, once each")
    func tableEntries() throws {
        let file = try WaveFile.parse(bytes: Self.tableFile())
        #expect(file.ds64?.table.map(\.id) == ["JUNK", "JUNK", "axml"])
        #expect(file.chunks.map(\.id) == ["ds64", "JUNK", "JUNK", "fmt ", "data"])
        #expect(file.chunks[1].size == 10)
        #expect(file.chunks[2].size == 20)
        #expect(file.chunks[1].sizeField == 0xFFFF_FFFF)
        #expect(file.dataChunk.size == 300)
        #expect(file.trailingBytesOffset == file.fileSize)
    }

    @Test("A filler sized by the ds64 table is not resized in place; the rewrite keeps the table valid")
    func tableSizedFillerIsNotResized() throws {
        let temp = try TempDirectory()
        let bext = WaveBuilder.chunk("bext", try WaveBuilder.bextPayload())
        let junkA = Array("JUNK".utf8) + LE.bytes32(0xFFFF_FFFF) + [UInt8](repeating: 0, count: 10)
        let junkB = Array("JUNK".utf8) + LE.bytes32(0xFFFF_FFFF) + [UInt8](repeating: 0, count: 20)
        let fmt = WaveBuilder.chunk("fmt ", WaveBuilder.fmt())
        let audio = [UInt8](repeating: 7, count: 240)
        let data = Array("data".utf8) + LE.bytes32(0xFFFF_FFFF) + audio
        let rest = bext + junkA + junkB + fmt + data
        let table: [(String, UInt64)] = [("JUNK", 10), ("JUNK", 20)]
        let total = UInt64(12 + 8 + 28 + 12 * table.count + rest.count)
        let image = WaveBuilder.ds64Header(magic: "BW64", riffSize: total - 8, dataSize: UInt64(audio.count), table: table) + rest
        let path = try temp.write(image, as: "table-filler.wav")
        var edited = try #require(try WaveFile.read(from: path).bext)
        edited.codingHistory += "AB"
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: edited), to: path)
        #expect(report.path == .streamingRewrite)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == ["ds64", "bext", "JUNK", "JUNK", "fmt ", "data"])
        #expect(written.chunks[2].size == 10)
        #expect(written.chunks[3].size == 20)
        #expect(written.bext == edited)
    }

    @Test("A table length that does not fit the chunk is a typed error")
    func tableTooLong() throws {
        var image = Self.tableFile()
        image[12 + 8 + 24] = 200  // tableLength low byte
        #expect(throws: WaveError.self) { try WaveFile.parse(bytes: image) }
    }
}
