import Foundation

/// The outer container of a WAVE file.
public enum ContainerKind: String, Sendable, Equatable {
    /// 32-bit RIFF/WAVE.
    case riff = "RIFF"
    /// EBU Tech 3306 RF64, which defers its sizes to the `ds64` chunk.
    case rf64 = "RF64"
    /// ITU-R BS.2088 BW64, which defers its sizes to the `ds64` chunk.
    case bw64 = "BW64"
}

/// One entry of the chunk table: where a chunk sits and how large it is.
public struct ChunkInfo: Sendable, Equatable {
    /// The four character id, decoded as ISO 8859-1 (for example `"fmt "`).
    public let id: String
    /// Offset of the 8 byte chunk header from the start of the file.
    public let headerOffset: UInt64
    /// Payload size in bytes, without the pad byte. Taken from `ds64` when the
    /// 32-bit size field holds `0xFFFFFFFF` in an RF64 or BW64 file.
    public let size: UInt64
    /// The raw 32-bit size field as stored in the header.
    public let sizeField: UInt32
    /// True when the payload size is odd and the pad byte is present in the file.
    public let hasPadByte: Bool

    /// Offset of the first payload byte.
    public var payloadOffset: UInt64 { headerOffset + 8 }
    /// Offset just past the payload and its pad byte, if any.
    public var paddedEnd: UInt64 { payloadOffset + size + (hasPadByte ? 1 : 0) }
    /// Bytes the chunk occupies in the file, header and pad byte included.
    public var span: UInt64 { paddedEnd - headerOffset }
}

/// One row of the `ds64` chunk size table (BS.2088 `ChunkSize64`).
public struct DS64Entry: Sendable, Equatable {
    /// The id of the chunk whose size does not fit 32 bits.
    public let id: String
    /// Its 64-bit size.
    public let size: UInt64
}

/// The parsed `ds64` chunk (ITU-R BS.2088 `DataSize64Chunk`).
public struct DS64: Sendable, Equatable {
    /// 64-bit size of the outer chunk (`bw64Size`, called `riffSize` in Tech 3306).
    public let riffSize: UInt64
    /// 64-bit size of the `data` chunk.
    public let dataSize: UInt64
    /// The value BS.2088 calls `dummy` and Tech 3306 calls `sampleCount`.
    public let sampleCount: UInt64
    /// The size table for other chunks larger than 4 GiB.
    public let table: [DS64Entry]
}

/// A parsed WAVE file. Holds the chunk table and the small metadata chunks, never the audio.
public struct WaveFile: Sendable, Equatable {
    /// RIFF, RF64 or BW64.
    public let container: ContainerKind
    /// The raw 32-bit size field of the outer chunk.
    public let outerSizeField: UInt32
    /// The outer chunk size in effect (from `ds64` when the field is `0xFFFFFFFF`).
    public let declaredOuterSize: UInt64
    /// Size of the file in bytes.
    public let fileSize: UInt64
    /// Every chunk in file order, including `ds64` and `data`.
    public let chunks: [ChunkInfo]
    /// The `ds64` chunk of an RF64 or BW64 file.
    public let ds64: DS64?
    /// The first `fmt ` chunk, parsed.
    public let format: WaveFormat
    /// The first `data` chunk. Its payload is never loaded.
    public let dataChunk: ChunkInfo
    /// The last `bext` chunk, parsed (the Python reference keeps the last one too).
    public let bext: Bext?
    /// The last `iXML` chunk, with its raw bytes.
    public let ixml: IXML?
    /// Offset where bytes that belong to no chunk begin (equal to `fileSize` when there are none).
    public let trailingBytesOffset: UInt64

    /// Parses the file at `url` using seeks and small reads. The audio payload is not read.
    public static func read(from url: URL) throws -> WaveFile {
        let reader = try FileReader(url: url)
        return try parse(reader: reader)
    }

    /// Parses an in-memory image of a file. Used for fuzzing and tests.
    public static func parse(bytes: [UInt8]) throws -> WaveFile {
        try parse(reader: MemoryReader(bytes: bytes))
    }

    static func parse(reader: some ByteReader) throws -> WaveFile {
        let fileSize = reader.size
        guard fileSize >= 12 else { throw WaveError.unexpectedEndOfFile(offset: 0, needed: 12) }
        let head = try reader.read(at: 0, count: 12)
        let magicBytes = Array(head[0 ..< 4])
        let container: ContainerKind
        switch Latin1.decode(magicBytes) {
        case "RIFF": container = .riff
        case "RF64": container = .rf64
        case "BW64": container = .bw64
        default: throw WaveError.notRIFF(found: Latin1.printable(magicBytes))
        }
        let outerSizeField = try LE.u32(head, 4)
        let formBytes = Array(head[8 ..< 12])
        guard Latin1.decode(formBytes) == "WAVE" else {
            throw WaveError.notWAVE(found: Latin1.printable(formBytes))
        }

        var ds64: DS64?
        if container != .riff {
            ds64 = try parseDS64(reader: reader)
        }

        let declaredOuterSize: UInt64
        if container != .riff, outerSizeField == 0xFFFF_FFFF, let ds64 {
            declaredOuterSize = ds64.riffSize
        } else {
            declaredOuterSize = UInt64(outerSizeField)
        }
        // The walk stops at the declared end or the file end, whichever comes first,
        // matching the Python reference (`min(len(raw), 8 + size)`).
        let outerEnd = declaredOuterSize > fileSize - 8 ? fileSize : 8 + declaredOuterSize

        var chunks: [ChunkInfo] = []
        var tableUsed = [Bool](repeating: false, count: ds64?.table.count ?? 0)
        var pos: UInt64 = 12
        while pos <= outerEnd, outerEnd - pos >= 8 {
            guard chunks.count < WaveLimits.maxChunkCount else {
                throw WaveError.tooManyChunks(limit: WaveLimits.maxChunkCount)
            }
            let header = try reader.read(at: pos, count: 8)
            let idBytes = Array(header[0 ..< 4])
            let id = Latin1.decode(idBytes)
            let sizeField = try LE.u32(header, 4)
            var size = UInt64(sizeField)
            if sizeField == 0xFFFF_FFFF, let ds64 {
                if id == "data" {
                    size = ds64.dataSize
                } else if let index = ds64.table.indices.first(where: { !tableUsed[$0] && ds64.table[$0].id == id }) {
                    tableUsed[index] = true
                    size = ds64.table[index].size
                }
            }
            let payload = pos + 8
            let available = fileSize - payload
            guard size <= available else {
                throw WaveError.chunkTruncated(
                    id: Latin1.printable(idBytes), offset: pos, declaredSize: size, available: available)
            }
            let odd = size & 1 == 1
            let hasPad = odd && size < available
            chunks.append(ChunkInfo(id: id, headerOffset: pos, size: size, sizeField: sizeField, hasPadByte: hasPad))
            pos = payload + size + (odd ? 1 : 0)
        }

        guard let fmtInfo = chunks.first(where: { $0.id == "fmt " }) else {
            throw WaveError.missingChunk("fmt ")
        }
        guard let dataChunk = chunks.first(where: { $0.id == "data" }) else {
            throw WaveError.missingChunk("data")
        }
        let format = try WaveFormat(parsing: try loadPayload(fmtInfo, reader: reader))

        var bext: Bext?
        if let info = chunks.last(where: { $0.id == "bext" }) {
            bext = try Bext(parsing: try loadPayload(info, reader: reader))
        }
        var ixml: IXML?
        if let info = chunks.last(where: { $0.id == "iXML" }) {
            ixml = IXML(rawBytes: try loadPayload(info, reader: reader))
        }

        let trailing = chunks.last.map { $0.paddedEnd } ?? 12
        return WaveFile(
            container: container,
            outerSizeField: outerSizeField,
            declaredOuterSize: declaredOuterSize,
            fileSize: fileSize,
            chunks: chunks,
            ds64: ds64,
            format: format,
            dataChunk: dataChunk,
            bext: bext,
            ixml: ixml,
            trailingBytesOffset: min(trailing, fileSize)
        )
    }

    /// Reads the `ds64` chunk, which BS.2088 requires as the first chunk after the header.
    static func parseDS64(reader: some ByteReader) throws -> DS64 {
        let header = try reader.read(at: 12, count: 8)
        guard Latin1.decode(header[0 ..< 4]) == "ds64" else { throw WaveError.missingDS64 }
        let size = UInt64(try LE.u32(header, 4))
        guard size >= 28 else {
            throw WaveError.invalidDS64("size \(size) is below the 28 byte minimum")
        }
        let maxSize = 28 + UInt64(WaveLimits.maxDS64TableEntries) * 12
        guard size <= maxSize else {
            throw WaveError.chunkTooLargeToLoad(id: "ds64", size: size, limit: maxSize)
        }
        let body = try reader.read(at: 20, count: Int(size))
        let riffSize = try LE.u64(body, 0)
        let dataSize = try LE.u64(body, 8)
        let sampleCount = try LE.u64(body, 16)
        let tableLength = try LE.u32(body, 24)
        let capacity = (size - 28) / 12
        guard UInt64(tableLength) <= capacity else {
            throw WaveError.invalidDS64("table length \(tableLength) does not fit in a \(size) byte chunk")
        }
        var table: [DS64Entry] = []
        table.reserveCapacity(Int(tableLength))
        for i in 0 ..< Int(tableLength) {
            let base = 28 + i * 12
            guard base + 12 <= body.count else {
                throw WaveError.invalidDS64("table entry \(i) is truncated")
            }
            let id = Latin1.decode(body[base ..< base + 4])
            table.append(DS64Entry(id: id, size: try LE.u64(body, base + 4)))
        }
        return DS64(riffSize: riffSize, dataSize: dataSize, sampleCount: sampleCount, table: table)
    }

    /// Loads a metadata chunk payload after checking it against the sanity limit.
    static func loadPayload(_ info: ChunkInfo, reader: some ByteReader) throws -> [UInt8] {
        guard info.size <= WaveLimits.maxMetadataChunkBytes else {
            throw WaveError.chunkTooLargeToLoad(id: info.id, size: info.size, limit: WaveLimits.maxMetadataChunkBytes)
        }
        return try reader.read(at: info.payloadOffset, count: Int(info.size))
    }

    /// Ids of chunks other than `bext`, `iXML`, `fmt ` and `data`, in file order.
    /// This is the reference's `riff.other_chunks` list.
    public var otherChunkIDs: [String] {
        chunks.map(\.id).filter { !["bext", "iXML", "fmt ", "data"].contains($0) }
    }

    /// Audio duration in seconds, from the data size, block align and sample rate.
    public var durationSeconds: Double? {
        guard format.blockAlign > 0, format.sampleRate > 0 else { return nil }
        let frames = dataChunk.size / UInt64(format.blockAlign)
        return Double(frames) / Double(format.sampleRate)
    }

    /// Chunks that occur more than once, by id.
    public var duplicatedChunkIDs: Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for chunk in chunks where !seen.insert(chunk.id).inserted {
            dupes.insert(chunk.id)
        }
        return dupes
    }
}
