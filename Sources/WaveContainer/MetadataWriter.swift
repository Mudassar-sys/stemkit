import Foundation

/// How a metadata write reached the file.
public enum WritePath: String, Sendable, Equatable {
    /// The new chunk fitted the space of the old one (and of a following `JUNK` chunk, if
    /// any). Only metadata bytes were written; the audio was not copied.
    case inPlace = "in-place"
    /// The file was streamed into a temporary file in the same directory, which then
    /// replaced the original with `FileManager.replaceItemAt`.
    case streamingRewrite = "streaming-rewrite"
}

/// Options for `MetadataWriter.apply`.
public struct WriteOptions: Sendable, Equatable {
    /// Use the in-place path when the new chunks fit. When false, always rewrite.
    public var allowInPlace: Bool
    /// Hash the audio payload before and after the write and fail when they differ.
    public var verifyAudioIntegrity: Bool

    /// Creates options. Both default to true.
    public init(allowInPlace: Bool = true, verifyAudioIntegrity: Bool = true) {
        self.allowInPlace = allowInPlace
        self.verifyAudioIntegrity = verifyAudioIntegrity
    }
}

/// The metadata to store. A `nil` member leaves that chunk as it is.
public struct MetadataChanges: Sendable, Equatable {
    /// The new `bext` chunk.
    public var bext: Bext?
    /// The new `iXML` chunk.
    public var ixml: IXML?

    /// Creates a change set.
    public init(bext: Bext? = nil, ixml: IXML? = nil) {
        self.bext = bext
        self.ixml = ixml
    }
}

/// What a write did, with the integrity evidence.
public struct WriteReport: Sendable, Equatable {
    /// The path taken.
    public let path: WritePath
    /// SHA-256 of the audio payload before the write (nil when verification was off).
    public let audioSHA256Before: String?
    /// SHA-256 of the audio payload after the write (nil when verification was off).
    public let audioSHA256After: String?

    /// Creates a report. Public so test doubles of file services can return one.
    public init(path: WritePath, audioSHA256Before: String?, audioSHA256After: String?) {
        self.path = path
        self.audioSHA256Before = audioSHA256Before
        self.audioSHA256After = audioSHA256After
    }

    /// True when both hashes were taken and are equal.
    public var audioUnchanged: Bool {
        guard let audioSHA256Before, let audioSHA256After else { return false }
        return audioSHA256Before == audioSHA256After
    }
}

/// Writes `bext` and `iXML` chunks without altering the audio payload.
///
/// Chunk order, unknown chunks, pad bytes and bytes after the last chunk are preserved.
/// A new `bext` is inserted before `fmt `; a new `iXML` is appended after the last chunk.
/// A chunk that shrinks by 8 bytes or more is written in place and followed by a new `JUNK`
/// chunk covering the rest of its old space; a replaced chunk of odd size gets a zero pad byte.
public enum MetadataWriter {
    /// Ids of filler chunks that may absorb a size change during an in-place write.
    static let fillerIDs: Set<String> = ["JUNK", "PAD ", "FLLR"]

    /// Applies `changes` to the file at `url`.
    public static func apply(
        _ changes: MetadataChanges, to link: URL, options: WriteOptions = WriteOptions()
    ) throws -> WriteReport {
        // Both paths act on the real file: a symbolic link is resolved first, so the streaming
        // path does not replace the link with a copy.
        let url = link.resolvingSymlinksInPath()
        // Both paths refuse a read-only file (the streaming path would otherwise replace it,
        // since replacing needs only write access to the folder).
        if let writable = try? url.resourceValues(forKeys: [.isWritableKey]).isWritable, !writable {
            throw WaveError.io("\(url.lastPathComponent) is read-only")
        }
        let file = try WaveFile.read(from: url)
        var replacements: [(id: String, payload: [UInt8])] = []
        if let bext = changes.bext {
            replacements.append(("bext", try bext.serialized()))
        }
        if let ixml = changes.ixml {
            guard UInt64(ixml.rawBytes.count) <= WaveLimits.maxMetadataChunkBytes else {
                throw WaveError.sizeLimitExceeded("iXML payload of \(ixml.rawBytes.count) bytes")
            }
            replacements.append(("iXML", ixml.rawBytes))
        }
        for replacement in replacements where file.duplicatedChunkIDs.contains(replacement.id) {
            throw WaveError.duplicateChunk(replacement.id)
        }
        let before = options.verifyAudioIntegrity ? try AudioIntegrity.dataChunkSHA256(of: url, file: file) : nil

        if options.allowInPlace, let plan = try inPlacePlan(file: file, replacements: replacements) {
            try writeInPlace(plan, url: url)
            let after = options.verifyAudioIntegrity ? try AudioIntegrity.dataChunkSHA256(of: url) : nil
            if let before, let after, before != after {
                throw WaveError.integrityCheckFailed(before: before, after: after)
            }
            return WriteReport(path: .inPlace, audioSHA256Before: before, audioSHA256After: after)
        }

        let after = try streamingRewrite(file: file, url: url, replacements: replacements, expectedAudioHash: before)
        return WriteReport(path: .streamingRewrite, audioSHA256Before: before, audioSHA256After: after)
    }

    // MARK: - In place

    struct InPlaceWrite {
        let offset: UInt64
        let bytes: [UInt8]
    }

    /// Returns the writes for the in-place path, or nil when any replacement does not fit.
    static func inPlacePlan(
        file: WaveFile, replacements: [(id: String, payload: [UInt8])]
    ) throws -> [InPlaceWrite]? {
        guard !replacements.isEmpty else { return [] }
        var writes: [InPlaceWrite] = []
        for replacement in replacements {
            guard let index = file.chunks.lastIndex(where: { $0.id == replacement.id }) else { return nil }
            let old = file.chunks[index]
            // An odd chunk at the very end of a file without its pad byte has no spare byte.
            if old.size & 1 == 1, !old.hasPadByte { return nil }
            let newSize = UInt64(replacement.payload.count)
            let newSpan = 8 + newSize + (newSize & 1)
            var bytes = Array(replacement.id.utf8)
            LE.put32(UInt32(newSize), into: &bytes)
            bytes.append(contentsOf: replacement.payload)
            if newSize & 1 == 1 { bytes.append(0) }

            let next: ChunkInfo? = index + 1 < file.chunks.count ? file.chunks[index + 1] : nil
            // A filler whose size comes from the ds64 table (size field 0xFFFFFFFF) is left alone:
            // rewriting it with an explicit size would hand its table entry to the next chunk
            // with the same id.
            let filler: ChunkInfo? = next.flatMap { chunk in
                fillerIDs.contains(chunk.id) && (chunk.hasPadByte || chunk.size & 1 == 0)
                    && chunk.sizeField != 0xFFFF_FFFF ? chunk : nil
            }
            if newSpan == old.span {
                // Exact fit.
            } else if let filler, old.span + filler.span >= newSpan + 8,
                      old.span + filler.span - newSpan - 8 <= UInt64(UInt32.max) - 1 {
                // A filler chunk follows: it grows or shrinks to absorb the difference.
                let fillerSize = old.span + filler.span - newSpan - 8
                bytes.append(contentsOf: Array(filler.id.utf8))
                LE.put32(UInt32(fillerSize), into: &bytes)
                // Zero only the bytes that held the old chunk and now belong to the filler's
                // payload, so old metadata does not linger; the rest of the filler is left as
                // it is. Bounded by the old chunk's size, which is under the metadata limit.
                if old.span > newSpan {
                    bytes.append(contentsOf: [UInt8](repeating: 0, count: Int(old.span - newSpan)))
                }
            } else if newSpan + 8 <= old.span {
                // Smaller by at least a chunk header: the rest of the old space becomes a new
                // JUNK chunk, zero filled (bounded by the old chunk's size).
                let junkSize = old.span - newSpan - 8
                bytes.append(contentsOf: Array("JUNK".utf8))
                LE.put32(UInt32(junkSize), into: &bytes)
                bytes.append(contentsOf: [UInt8](repeating: 0, count: Int(junkSize)))
            } else {
                return nil
            }
            let write = InPlaceWrite(offset: old.headerOffset, bytes: bytes)
            // The audio payload must lie entirely outside the written range.
            let start = write.offset
            let end = write.offset + UInt64(write.bytes.count)
            let audioStart = file.dataChunk.payloadOffset
            let audioEnd = audioStart + file.dataChunk.size
            if start < audioEnd, audioStart < end {
                throw WaveError.writeWouldTouchAudio
            }
            writes.append(write)
        }
        return writes
    }

    static func writeInPlace(_ writes: [InPlaceWrite], url: URL) throws {
        guard !writes.isEmpty else { return }
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            for write in writes {
                try handle.seek(toOffset: write.offset)
                try handle.write(contentsOf: write.bytes)
            }
            try handle.synchronize()
        } catch let error as WaveError {
            throw error
        } catch {
            throw WaveError.io(error.localizedDescription)
        }
    }

    // MARK: - Streaming rewrite

    enum Segment {
        case copy(offset: UInt64, length: UInt64)
        case bytes([UInt8])
        /// The `ds64` chunk, written with its outer size updated.
        case ds64(span: UInt64)
    }

    /// Streams the file into a temporary sibling, verifies it, then atomically replaces the
    /// original. Returns the audio hash of the new file when verification is on.
    static func streamingRewrite(
        file: WaveFile, url: URL, replacements: [(id: String, payload: [UInt8])], expectedAudioHash: String?
    ) throws -> String? {
        var newChunks: [String: [UInt8]] = [:]
        for replacement in replacements {
            newChunks[replacement.id] = replacement.payload
        }
        func chunkBytes(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            var bytes = Array(id.utf8)
            LE.put32(UInt32(payload.count), into: &bytes)
            bytes.append(contentsOf: payload)
            if payload.count % 2 == 1 { bytes.append(0) }
            return bytes
        }

        var body: [Segment] = []
        var bextPending = newChunks["bext"] != nil && !file.chunks.contains(where: { $0.id == "bext" })
        let ds64Chunk: ChunkInfo? = file.container != .riff ? file.chunks.first : nil
        for (index, chunk) in file.chunks.enumerated() {
            if bextPending, chunk.id == "fmt ", let payload = newChunks["bext"] {
                body.append(.bytes(chunkBytes("bext", payload)))
                bextPending = false
            }
            if index == 0, ds64Chunk != nil {
                body.append(.ds64(span: chunk.span))
            } else if let payload = newChunks[chunk.id], file.chunks.last(where: { $0.id == chunk.id }) == chunk {
                body.append(.bytes(chunkBytes(chunk.id, payload)))
            } else {
                body.append(.copy(offset: chunk.headerOffset, length: chunk.span))
            }
        }
        if let payload = newChunks["iXML"], !file.chunks.contains(where: { $0.id == "iXML" }) {
            // A last chunk of odd size whose pad byte is missing at the end of the file needs
            // its pad byte before anything can follow it, or the new chunk would be misaligned.
            if let last = file.chunks.last, last.size & 1 == 1, !last.hasPadByte {
                body.append(.bytes([0]))
            }
            body.append(.bytes(chunkBytes("iXML", payload)))
        }
        if file.trailingBytesOffset < file.fileSize {
            body.append(.copy(offset: file.trailingBytesOffset, length: file.fileSize - file.trailingBytesOffset))
        }

        // New length and the size fields that follow from it.
        var newLength: UInt64 = 12
        for segment in body {
            switch segment {
            case let .copy(_, length): newLength += length
            case let .bytes(bytes): newLength += UInt64(bytes.count)
            case let .ds64(span): newLength += span
            }
        }
        // Size fields move by the change in file length. Checked arithmetic: a hostile size
        // near 2^64 becomes a typed error, not an overflow trap.
        func shifted(_ value: UInt64) throws -> UInt64 {
            if newLength >= file.fileSize {
                let (result, overflow) = value.addingReportingOverflow(newLength - file.fileSize)
                guard !overflow else { throw WaveError.sizeLimitExceeded("size field overflows after rewrite") }
                return result
            }
            let (result, overflow) = value.subtractingReportingOverflow(file.fileSize - newLength)
            guard !overflow else { throw WaveError.sizeLimitExceeded("negative size after rewrite") }
            return result
        }

        let reader = try FileReader(url: url)
        var header = try reader.read(at: 0, count: 12)
        var ds64Bytes: [UInt8] = []
        if file.container != .riff, file.outerSizeField == 0xFFFF_FFFF, let ds64Chunk, let ds64 = file.ds64 {
            ds64Bytes = try reader.read(at: ds64Chunk.headerOffset, count: Int(ds64Chunk.span))
            let newOuter = LE.bytes64(try shifted(ds64.riffSize))
            ds64Bytes.replaceSubrange(8 ..< 16, with: newOuter)
        } else {
            let newOuter = try shifted(UInt64(file.outerSizeField))
            guard newOuter <= UInt64(UInt32.max) else {
                throw WaveError.sizeLimitExceeded("the file would pass 4 GiB; conversion to RF64 is not supported")
            }
            header.replaceSubrange(4 ..< 8, with: LE.bytes32(UInt32(newOuter)))
            if let ds64Chunk {
                ds64Bytes = try reader.read(at: ds64Chunk.headerOffset, count: Int(ds64Chunk.span))
            }
        }

        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".stemkit-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WaveError.io("cannot create a temporary file in \(directory.path)")
        }
        do {
            let output = try FileHandle(forWritingTo: tempURL)
            do {
                try output.write(contentsOf: header)
                for segment in body {
                    switch segment {
                    case let .bytes(bytes):
                        try output.write(contentsOf: bytes)
                    case .ds64:
                        try output.write(contentsOf: ds64Bytes)
                    case let .copy(offset, length):
                        try copy(from: reader.handle, offset: offset, length: length, to: output)
                    }
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }

            let written = try WaveFile.read(from: tempURL)
            guard written.dataChunk.size == file.dataChunk.size else {
                throw WaveError.integrityCheckFailed(
                    before: "\(file.dataChunk.size) bytes", after: "\(written.dataChunk.size) bytes")
            }
            var after: String?
            if let expectedAudioHash {
                let hash = try AudioIntegrity.dataChunkSHA256(of: tempURL, file: written)
                guard hash == expectedAudioHash else {
                    throw WaveError.integrityCheckFailed(before: expectedAudioHash, after: hash)
                }
                after = hash
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            return after
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            if let error = error as? WaveError { throw error }
            throw WaveError.io(error.localizedDescription)
        }
    }

    /// Copies `length` bytes starting at `offset` in blocks of `WaveLimits.copyBlockBytes`.
    static func copy(from input: FileHandle, offset: UInt64, length: UInt64, to output: FileHandle) throws {
        try input.seek(toOffset: offset)
        var remaining = length
        var position = offset
        while remaining > 0 {
            let count = Int(min(UInt64(WaveLimits.copyBlockBytes), remaining))
            guard let block = try input.read(upToCount: count), block.count == count else {
                throw WaveError.unexpectedEndOfFile(offset: position, needed: UInt64(count))
            }
            try output.write(contentsOf: block)
            remaining -= UInt64(count)
            position += UInt64(count)
        }
    }
}
