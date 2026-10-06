import Foundation

/// Every failure the container code can report. Malformed input always ends in
/// one of these cases; the library never traps on file-derived data.
public enum WaveError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file ended before `needed` bytes could be read at `offset`.
    case unexpectedEndOfFile(offset: UInt64, needed: UInt64)
    /// The first four bytes are not `RIFF`, `RF64` or `BW64`.
    case notRIFF(found: String)
    /// The form type after the size field is not `WAVE`.
    case notWAVE(found: String)
    /// An RF64 or BW64 file whose first chunk is not `ds64`.
    case missingDS64
    /// A `ds64` chunk that is too small or whose table does not fit.
    case invalidDS64(String)
    /// A chunk whose declared size runs past the end of the file.
    case chunkTruncated(id: String, offset: UInt64, declaredSize: UInt64, available: UInt64)
    /// More chunks than the sanity limit allows.
    case tooManyChunks(limit: Int)
    /// A metadata chunk larger than the sanity limit for loading into memory.
    case chunkTooLargeToLoad(id: String, size: UInt64, limit: UInt64)
    /// A required chunk (`fmt ` or `data`) is absent.
    case missingChunk(String)
    /// A write was asked to replace a chunk that occurs more than once.
    case duplicateChunk(String)
    /// The `fmt ` chunk is too short or carries impossible values.
    case invalidFormat(String)
    /// The `bext` chunk is shorter than its 602 byte fixed part.
    case invalidBext(String)
    /// A text field does not fit its fixed width.
    case fieldTooLong(field: String, maxBytes: Int, actualBytes: Int)
    /// A text field contains a character that ISO 8859-1 cannot encode.
    case notLatin1(field: String)
    /// A value that cannot be stored in the named field.
    case invalidValue(field: String, value: String, reason: String)
    /// A field name the command line tool does not know.
    case unknownField(String)
    /// The iXML payload is not valid UTF-8.
    case invalidUTF8(String)
    /// The iXML payload is not well formed XML.
    case malformedXML(String)
    /// A size or count beyond a documented sanity limit.
    case sizeLimitExceeded(String)
    /// A planned in-place write overlaps the audio payload. Never executed.
    case writeWouldTouchAudio
    /// The audio payload hash differs before and after a write.
    case integrityCheckFailed(before: String, after: String)
    /// An operating system error, with its description.
    case io(String)

    /// A readable explanation of the error.
    public var description: String {
        switch self {
        case let .unexpectedEndOfFile(offset, needed):
            return "unexpected end of file: needed \(needed) bytes at offset \(offset)"
        case let .notRIFF(found):
            return "not a RIFF, RF64 or BW64 file (found \(found))"
        case let .notWAVE(found):
            return "form type is not WAVE (found \(found))"
        case .missingDS64:
            return "RF64/BW64 file without a ds64 chunk directly after the header"
        case let .invalidDS64(reason):
            return "invalid ds64 chunk: \(reason)"
        case let .chunkTruncated(id, offset, declaredSize, available):
            return "chunk '\(id)' at offset \(offset) declares \(declaredSize) bytes but only \(available) remain"
        case let .tooManyChunks(limit):
            return "more than \(limit) chunks"
        case let .chunkTooLargeToLoad(id, size, limit):
            return "chunk '\(id)' is \(size) bytes, above the \(limit) byte limit for metadata"
        case let .missingChunk(id):
            return "required chunk '\(id)' is missing"
        case let .duplicateChunk(id):
            return "chunk '\(id)' occurs more than once, refusing to guess which one to replace"
        case let .invalidFormat(reason):
            return "invalid fmt chunk: \(reason)"
        case let .invalidBext(reason):
            return "invalid bext chunk: \(reason)"
        case let .fieldTooLong(field, maxBytes, actualBytes):
            return "\(field) is \(actualBytes) bytes, the field holds \(maxBytes)"
        case let .notLatin1(field):
            return "\(field) contains characters outside ISO 8859-1"
        case let .invalidValue(field, value, reason):
            return "invalid value '\(value)' for \(field): \(reason)"
        case let .unknownField(name):
            return "unknown field '\(name)'"
        case let .invalidUTF8(context):
            return "invalid UTF-8 in \(context)"
        case let .malformedXML(reason):
            return "malformed iXML: \(reason)"
        case let .sizeLimitExceeded(reason):
            return "size limit exceeded: \(reason)"
        case .writeWouldTouchAudio:
            return "refused: the planned write overlaps the audio payload"
        case let .integrityCheckFailed(before, after):
            return "audio payload hash changed: \(before) became \(after)"
        case let .io(reason):
            return "I/O error: \(reason)"
        }
    }
}

/// Sanity limits applied to sizes declared inside files before any allocation.
public enum WaveLimits {
    /// Largest metadata chunk (`fmt `, `bext`, `iXML`, `ds64`) loaded into memory: 16 MiB.
    public static let maxMetadataChunkBytes: UInt64 = 16 * 1024 * 1024
    /// Most chunks walked in one file.
    public static let maxChunkCount = 10_000
    /// Most entries accepted in a `ds64` chunk size table.
    public static let maxDS64TableEntries: UInt32 = 1_024
    /// Deepest iXML element nesting accepted when flattening.
    public static let maxXMLDepth = 64
    /// Most iXML elements accepted when flattening.
    public static let maxXMLElements = 100_000
    /// Most bytes of keys and values a flattened iXML document may produce: 64 MiB.
    public static let maxFlattenedXMLBytes = 64 * 1024 * 1024
    /// Block size used when streaming bytes between files: 1 MiB.
    public static let copyBlockBytes = 1024 * 1024
}
