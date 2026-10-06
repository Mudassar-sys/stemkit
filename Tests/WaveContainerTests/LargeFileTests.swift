import Foundation
import Testing
@testable import WaveContainer

/// RF64 and BW64 files whose data chunk is larger than 4 GiB. The audio region is a hole in
/// a sparse file, so nothing close to 4 GiB is written to disk.
@Suite("Files above 4 GiB (sparse)")
struct LargeFileTests {
    static let dataSize: UInt64 = (1 << 32) + 2048

    /// Writes header, a hole for the audio and an iXML chunk after it. Returns the iXML text.
    static func makeSparseFile(magic: String, at url: URL) throws -> String {
        let bext = WaveBuilder.chunk("bext", try WaveBuilder.bextPayload(description: "large file"))
        let fmt = WaveBuilder.chunk("fmt ", WaveBuilder.fmt(channels: 2, rate: 96_000, bits: 24))
        let xml = "<BWFXML><IXML_VERSION>3.01</IXML_VERSION><NOTE>after a 4 GiB data chunk</NOTE></BWFXML>"
        let ixml = WaveBuilder.chunk("iXML", IXML(xmlText: xml).rawBytes)
        let headerLength = UInt64(12 + 8 + 28 + bext.count + fmt.count + 8)
        let total = headerLength + dataSize + UInt64(ixml.count)
        let header = WaveBuilder.ds64Header(magic: magic, riffSize: total - 8, dataSize: dataSize, sampleCount: dataSize / 6)
            + bext + fmt + Array("data".utf8) + LE.bytes32(0xFFFF_FFFF)
        #expect(UInt64(header.count) == headerLength)

        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        try handle.seek(toOffset: headerLength + dataSize)
        try handle.write(contentsOf: ixml)
        try handle.synchronize()
        return xml
    }

    @Test("RF64 and BW64 with a 64-bit data size parse, and in-place writes keep the audio hash", arguments: ["RF64", "BW64"])
    func sparseAbove4GiB(magic: String) throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("\(magic).wav")
        let xml = try Self.makeSparseFile(magic: magic, at: url)

        let file = try WaveFile.read(from: url)
        #expect(file.container.rawValue == magic)
        #expect(file.dataChunk.size == Self.dataSize)
        #expect(file.dataChunk.sizeField == 0xFFFF_FFFF)
        #expect(file.fileSize > 1 << 32)
        #expect(file.declaredOuterSize == file.fileSize - 8)
        #expect(file.chunks.map(\.id) == ["ds64", "bext", "fmt ", "data", "iXML"])
        let ixmlChunk = try #require(file.chunks.last)
        #expect(ixmlChunk.headerOffset > 1 << 32)
        #expect(file.ixml?.text == xml)
        #expect(file.durationSeconds == Double(Self.dataSize / 6) / 96_000)

        // The disk holds far less than the logical size: the audio region is a hole.
        let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        print("SPARSE \(magic) logical_bytes=\(file.fileSize) allocated_bytes=\(allocated)")
        #expect(UInt64(allocated) < 64 * 1024 * 1024)

        let publicBefore = try AudioIntegrity.dataChunkSHA256(of: url)
        // bext before the data chunk, same size: in place.
        var bext = try #require(file.bext)
        bext.description = "large file, edited"
        let first = try MetadataWriter.apply(MetadataChanges(bext: bext), to: url)
        #expect(first.path == .inPlace)
        #expect(first.audioUnchanged)
        let before = try #require(first.audioSHA256Before)
        #expect(before == publicBefore)
        // iXML after the data chunk, beyond 4 GiB, same padded size: in place. Its integrity
        // check is the explicit hash below, compared with the hash taken before the first write.
        let edited = xml.replacingOccurrences(of: "after a 4 GiB data chunk", with: "AFTER A 4 GIB DATA CHUNK")
        let second = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: edited)), to: url, options: WriteOptions(verifyAudioIntegrity: false))
        #expect(second.path == .inPlace)
        let after = try AudioIntegrity.dataChunkSHA256(of: url)
        #expect(before == after)

        let reread = try WaveFile.read(from: url)
        #expect(reread.bext?.description == "large file, edited")
        #expect(reread.ixml?.text == edited)
        #expect(reread.fileSize == file.fileSize)
        print("SPARSE \(magic) data_sha256=\(after)")
    }
}
