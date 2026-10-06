import Foundation
import Testing
@testable import WaveContainer

/// Round trip, single field edits and the two write paths. Every test that writes calls
/// the public integrity check before and after.
@Suite("Metadata writes")
struct WriteTests {
    @Test("Read then write reproduces every corpus file byte for byte, on both paths")
    func byteExactRoundTrip() throws {
        let temp = try TempDirectory()
        for entry in try Fixtures.manifest() {
            let source = try Fixtures.corpusURL(entry)
            let original = try bytes(of: source)
            let parsed = try WaveFile.read(from: source)
            let changes = MetadataChanges(bext: parsed.bext, ixml: parsed.ixml)
            for allowInPlace in [true, false] {
                let copy = try temp.copy(source, as: "\(allowInPlace)-\(source.deletingLastPathComponent().lastPathComponent)-\(source.lastPathComponent)")
                let before = try AudioIntegrity.dataChunkSHA256(of: copy)
                let report = try MetadataWriter.apply(changes, to: copy, options: WriteOptions(allowInPlace: allowInPlace))
                #expect(report.path == (allowInPlace ? .inPlace : .streamingRewrite))
                #expect(try bytes(of: copy) == original, "\(entry.file) allowInPlace=\(allowInPlace)")
                #expect(try AudioIntegrity.dataChunkSHA256(of: copy) == before)
                #expect(report.audioUnchanged)
            }
        }
    }

    struct EditCase: Sendable, CustomStringConvertible {
        let field: String
        let value: String
        let offset: Int
        let width: Int
        var description: String { field }
    }

    @Test("Editing one bext field changes only that field's bytes", arguments: [
        EditCase(field: "description", value: "Edited description", offset: 0, width: 256),
        EditCase(field: "originator", value: "Edited originator", offset: 256, width: 32),
        EditCase(field: "originator_reference", value: "REF-0042", offset: 288, width: 32),
        EditCase(field: "origination_date", value: "2026-01-02", offset: 320, width: 10),
        EditCase(field: "origination_time", value: "12-34-56", offset: 330, width: 8),
        EditCase(field: "time_reference", value: "123456789012", offset: 338, width: 8),
        EditCase(field: "loudness_value", value: "-23.05", offset: 412, width: 2),
        EditCase(field: "max_true_peak_level", value: "-1", offset: 416, width: 2),
        EditCase(field: "loudness_range", value: "7.5", offset: 414, width: 2),
        EditCase(field: "max_momentary_loudness", value: "-12.25", offset: 418, width: 2),
        EditCase(field: "max_short_term_loudness", value: "-15", offset: 420, width: 2),
        EditCase(field: "umid", value: String(repeating: "ab", count: 64), offset: 348, width: 64),
    ])
    func singleFieldEdit(item: EditCase) throws {
        let field = item.field
        let value = item.value
        let offset = item.offset
        let width = item.width
        let temp = try TempDirectory()
        let entry = try #require(try Fixtures.manifest().first)
        let path = try temp.copy(try Fixtures.corpusURL(entry))
        let original = try bytes(of: path)
        let parsed = try WaveFile.read(from: path)
        let bextChunk = try #require(parsed.chunks.first { $0.id == "bext" })
        var bext = try #require(parsed.bext)
        let name = try #require(BextField(rawValue: field))
        try name.set(value, in: &bext)

        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: path)
        let after = try AudioIntegrity.dataChunkSHA256(of: path)
        #expect(report.path == .inPlace)
        #expect(before == after)

        let edited = try bytes(of: path)
        let start = Int(bextChunk.payloadOffset) + offset
        let changed = differingOffsets(original, edited)
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy { $0 >= start && $0 < start + width }, "changed offsets \(changed)")

        // Every other flattened field is unchanged.
        let old = try parsed.flattenedMetadata()
        let new = try WaveFile.read(from: path).flattenedMetadata()
        for key in old.keys where key != "bext.\(field)" {
            #expect(old[key] == new[key], "\(key)")
        }
    }

    @Test("Loudness edits follow the version rule: a version 1 chunk is raised to 2")
    func loudnessRaisesVersion() throws {
        var bext = Bext()
        bext.version = 1
        try bext.setLoudness(.loudnessValue, to: Decimal(string: "-23.5"))
        #expect(bext.version == 2)
        #expect(bext.loudnessValue == -2350)
        try bext.setLoudness(.loudnessRange, to: nil)
        #expect(bext.loudnessRange == Bext.loudnessNotUsed)
        #expect(bext.specificationIssues.isEmpty)
        bext.version = 1
        #expect(!bext.specificationIssues.isEmpty)
    }

    @Test("A longer iXML at the end of the file takes the streaming path and keeps every other chunk")
    func streamingPathForGrowingIXML() throws {
        let temp = try TempDirectory()
        let entry = try #require(try Fixtures.manifest().first)
        let path = try temp.copy(try Fixtures.corpusURL(entry))
        let original = try bytes(of: path)
        let parsed = try WaveFile.read(from: path)
        let oldText = try #require(parsed.ixml?.text)
        let newText = oldText.replacingOccurrences(of: "</BWFXML>", with: "<USER>streaming path test with a longer document</USER></BWFXML>")
        #expect(newText != oldText)

        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: newText)), to: path)
        let after = try AudioIntegrity.dataChunkSHA256(of: path)
        #expect(report.path == .streamingRewrite)
        #expect(before == after)
        #expect(report.audioUnchanged)

        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == parsed.chunks.map(\.id))
        #expect(written.ixml?.text == newText)
        #expect(try written.ixml?.flattened()["USER"] == "streaming path test with a longer document")
        // Bytes before the iXML chunk are identical apart from the RIFF size field.
        let edited = try bytes(of: path)
        let ixmlOffset = Int(try #require(parsed.chunks.last).headerOffset)
        let changedBefore = differingOffsets(Array(original[0 ..< ixmlOffset]), Array(edited[0 ..< ixmlOffset]))
        #expect(changedBefore.allSatisfy { (4 ..< 8).contains($0) }, "\(changedBefore)")
        #expect(try LE.u32(edited, 4) == UInt32(edited.count - 8))
        // No temporary file is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("A growing bext followed by JUNK is written in place and the JUNK chunk shrinks")
    func inPlaceWithJunkFiller() throws {
        let temp = try TempDirectory()
        let audio = (0 ..< 4800).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let image = WaveBuilder.riff([
            WaveBuilder.chunk("bext", try WaveBuilder.bextPayload()),
            WaveBuilder.chunk("JUNK", [UInt8](repeating: 0, count: 200)),
            WaveBuilder.chunk("fmt ", WaveBuilder.fmt()),
            WaveBuilder.chunk("data", audio),
        ])
        let path = try temp.write(image, as: "junk.wav")
        var bext = try #require(try WaveFile.read(from: path).bext)
        bext.codingHistory += "A=PCM,F=48000,W=24,M=mono,T=edited in place\r\n"

        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: path)
        #expect(report.path == .inPlace)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.fileSize == UInt64(image.count))
        #expect(written.chunks.map(\.id) == ["bext", "JUNK", "fmt ", "data"])
        #expect(written.bext == bext)
        let junk = try #require(written.chunks.first { $0.id == "JUNK" })
        #expect(junk.size < 200)
    }

    @Test("A shrinking bext followed by JUNK is written in place, the JUNK grows and old bytes are zeroed")
    func inPlaceShrinkIntoJunk() throws {
        let temp = try TempDirectory()
        let longHistory = String(repeating: "A=PCM,F=48000,W=24,M=mono,T=a long coding history line\r\n", count: 4)
        let image = WaveBuilder.riff([
            WaveBuilder.chunk("bext", try WaveBuilder.bextPayload(history: longHistory)),
            WaveBuilder.chunk("JUNK", [UInt8](repeating: 0xEE, count: 64)),
            WaveBuilder.chunk("fmt ", WaveBuilder.fmt()),
            WaveBuilder.chunk("data", [UInt8](repeating: 5, count: 960)),
        ])
        let path = try temp.write(image, as: "shrink.wav")
        let parsed = try WaveFile.read(from: path)
        var bext = try #require(parsed.bext)
        bext.codingHistory = "A=PCM\r\n"
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: path)
        #expect(report.path == .inPlace)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.fileSize == UInt64(image.count))
        #expect(written.chunks.map(\.id) == ["bext", "JUNK", "fmt ", "data"])
        #expect(written.bext == bext)
        let junk = try #require(written.chunks.first { $0.id == "JUNK" })
        #expect(junk.size > 64)
        // The bytes that held the old coding history are now zero; the old JUNK payload is untouched.
        let edited = try bytes(of: path)
        let oldBextEnd = Int(try #require(parsed.chunks.first { $0.id == "bext" }).paddedEnd)
        #expect(edited[Int(junk.payloadOffset) ..< oldBextEnd + 8].allSatisfy { $0 == 0 })
        #expect(edited[(oldBextEnd + 8) ..< Int(junk.paddedEnd)].allSatisfy { $0 == 0xEE })
    }

    @Test("A new bext is inserted before fmt through the streaming path")
    func insertBext() throws {
        let temp = try TempDirectory()
        let image = WaveBuilder.riff([
            WaveBuilder.chunk("fmt ", WaveBuilder.fmt(bits: 16)),
            WaveBuilder.chunk("LIST", Array("INFOISFT\u{0}\u{0}\u{0}\u{0}".utf8)),
            WaveBuilder.chunk("data", [UInt8](repeating: 7, count: 1001)),
        ])
        let path = try temp.write(image, as: "nobext.wav")
        var bext = Bext()
        bext.description = "inserted"
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: path)
        #expect(report.path == .streamingRewrite)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == ["bext", "fmt ", "LIST", "data"])
        #expect(written.bext?.description == "inserted")
        #expect(written.dataChunk.hasPadByte)
    }

    @Test("Shrinking by 8 bytes or more is in place with a new JUNK chunk; by less, a streaming rewrite")
    func shrinkPaths() throws {
        let temp = try TempDirectory()
        let entry = try #require(try Fixtures.manifest().first)
        // Shrink by the whole coding history: in place, the freed space becomes JUNK.
        let path = try temp.copy(try Fixtures.corpusURL(entry), as: "big-shrink.wav")
        var bext = try #require(try WaveFile.read(from: path).bext)
        let original = bext.codingHistory
        bext.codingHistory = ""
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(bext: bext), to: path)
        #expect(report.path == .inPlace)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == ["bext", "JUNK", "fmt ", "data", "iXML"])
        #expect(written.bext?.codingHistory == "")
        #expect(written.fileSize == UInt64(try bytes(of: try Fixtures.corpusURL(entry)).count))

        // Shrink by 2 bytes: too small for a chunk header, so the file is rewritten.
        let small = try temp.copy(try Fixtures.corpusURL(entry), as: "small-shrink.wav")
        var bext2 = try #require(try WaveFile.read(from: small).bext)
        bext2.codingHistory = String(original.dropLast(2))
        let before2 = try AudioIntegrity.dataChunkSHA256(of: small)
        let report2 = try MetadataWriter.apply(MetadataChanges(bext: bext2), to: small)
        #expect(report2.path == .streamingRewrite)
        #expect(try AudioIntegrity.dataChunkSHA256(of: small) == before2)
        #expect(try WaveFile.read(from: small).bext?.codingHistory == bext2.codingHistory)
    }

    @Test("Appending iXML after an odd last chunk without its pad byte adds the pad byte first")
    func appendAfterUnpaddedOddChunk() throws {
        let temp = try TempDirectory()
        // The data chunk is 3 bytes and the file ends right after it: no pad byte.
        let image = Array("RIFF".utf8) + LE.bytes32(UInt32(4 + 24 + 11)) + Array("WAVE".utf8)
            + WaveBuilder.chunk("fmt ", WaveBuilder.fmt())
            + Array("data".utf8) + LE.bytes32(3) + [1, 2, 3]
        let path = try temp.write(image, as: "unpadded.wav")
        let parsed = try WaveFile.read(from: path)
        #expect(parsed.dataChunk.hasPadByte == false)
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: "<BWFXML><NOTE>n</NOTE></BWFXML>")), to: path)
        #expect(report.path == .streamingRewrite)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == ["fmt ", "data", "iXML"])
        #expect(written.dataChunk.hasPadByte)
        #expect(try written.ixml?.flattened()["NOTE"] == "n")
        #expect(written.declaredOuterSize == written.fileSize - 8)
    }

    @Test("A Version 1 chunk raised to Version 2 marks the other loudness fields as not used")
    func versionOneToTwo() throws {
        var payload = try WaveBuilder.bextPayload()
        payload[346] = 1  // Version 1: bytes 412 to 421 are reserved zeros
        payload[347] = 0
        for i in 412 ..< 422 { payload[i] = 0 }
        var bext = try Bext(parsing: payload)
        #expect(bext.version == 1)
        #expect(bext.specificationIssues.isEmpty)
        try bext.setLoudness(.loudnessValue, to: Decimal(string: "-23"))
        #expect(bext.version == 2)
        #expect(bext.loudnessValue == -2300)
        #expect([bext.loudnessRange, bext.maxTruePeakLevel, bext.maxMomentaryLoudness, bext.maxShortTermLoudness]
            .allSatisfy { $0 == Bext.loudnessNotUsed })
        #expect(bext.specificationIssues.isEmpty)
        // Back to Version 1 is refused while a measurement is stored, allowed once it is cleared.
        #expect(throws: WaveError.self) { try BextField.version.set("1", in: &bext) }
        try bext.setLoudness(.loudnessValue, to: nil)
        try BextField.version.set("1", in: &bext)
        #expect(bext.version == 1)
        #expect(bext.specificationIssues.isEmpty)
        // Clearing a loudness field in Version 1 leaves the reserved bytes at zero.
        try bext.setLoudness(.loudnessRange, to: nil)
        #expect(bext.loudnessRange == 0)
        #expect(bext.specificationIssues.isEmpty)
        // Raising the version directly marks every loudness field as not used.
        try BextField.version.set("2", in: &bext)
        #expect(LoudnessField.allCases.allSatisfy { bext.loudness($0) == Bext.loudnessNotUsed })
        // Version 0 needs a zero UMID.
        bext.umid = [UInt8](repeating: 1, count: 64)
        #expect(throws: WaveError.self) { try BextField.version.set("0", in: &bext) }
    }

    @Test("Unknown chunks and odd pad bytes survive a streaming rewrite unchanged")
    func unknownChunksAndPadBytes() throws {
        let temp = try TempDirectory()
        // An odd sized unknown chunk with a non-zero pad byte, and trailing bytes after the last chunk.
        var odd = Array("zzzz".utf8) + LE.bytes32(3) + [1, 2, 3]
        odd.append(0xEE)
        var image = WaveBuilder.riff([
            WaveBuilder.chunk("fmt ", WaveBuilder.fmt(bits: 16)),
            odd,
            WaveBuilder.chunk("data", [UInt8](repeating: 3, count: 64)),
        ])
        image += [0xAB, 0xCD]  // bytes past the declared RIFF size
        let path = try temp.write(image, as: "unknown.wav")
        let before = try AudioIntegrity.dataChunkSHA256(of: path)
        let report = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: "<BWFXML><NOTE>x</NOTE></BWFXML>")), to: path)
        #expect(report.path == .streamingRewrite)
        #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
        let edited = try bytes(of: path)
        // Everything up to the end of the data chunk is unchanged apart from the RIFF size.
        let dataEnd = image.count - 2
        #expect(differingOffsets(Array(image[0 ..< dataEnd]), Array(edited[0 ..< dataEnd])).allSatisfy { (4 ..< 8).contains($0) })
        #expect(Array(edited.suffix(2)) == [0xAB, 0xCD])
        let written = try WaveFile.read(from: path)
        #expect(written.chunks.map(\.id) == ["fmt ", "zzzz", "data", "iXML"])
    }

    @Test("RF64 streaming rewrite updates the ds64 size and keeps the data size marker")
    func rf64StreamingRewrite() throws {
        let temp = try TempDirectory()
        for magic in ["RF64", "BW64"] {
            let image = WaveBuilder.smallDS64File(magic: magic, audio: [UInt8](repeating: 9, count: 3000))
            let path = try temp.write(image, as: "\(magic).wav")
            let before = try AudioIntegrity.dataChunkSHA256(of: path)
            let report = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: "<BWFXML><NOTE>large</NOTE></BWFXML>")), to: path)
            #expect(report.path == .streamingRewrite)
            #expect(try AudioIntegrity.dataChunkSHA256(of: path) == before)
            let written = try WaveFile.read(from: path)
            #expect(written.container.rawValue == magic)
            #expect(written.outerSizeField == 0xFFFF_FFFF)
            #expect(written.ds64?.riffSize == written.fileSize - 8)
            #expect(written.dataChunk.sizeField == 0xFFFF_FFFF)
            #expect(written.dataChunk.size == 3000)
            #expect(try written.ixml?.flattened()["NOTE"] == "large")
        }
    }

    @Test("Writes that would replace a duplicated chunk are refused before touching the file")
    func duplicateChunkRefused() throws {
        let temp = try TempDirectory()
        let payload = try WaveBuilder.bextPayload()
        let image = WaveBuilder.riff([
            WaveBuilder.chunk("bext", payload), WaveBuilder.chunk("bext", payload),
            WaveBuilder.chunk("fmt ", WaveBuilder.fmt()), WaveBuilder.chunk("data", [0, 0, 0]),
        ])
        let path = try temp.write(image, as: "dupe.wav")
        #expect(throws: WaveError.duplicateChunk("bext")) {
            try MetadataWriter.apply(MetadataChanges(bext: Bext()), to: path)
        }
        #expect(try bytes(of: path) == image)
    }
}
