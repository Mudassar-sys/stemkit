import Foundation

/// How samples are encoded, derived from the format tag (or the extensible sub-format).
public enum SampleEncoding: Sendable, Equatable, CustomStringConvertible {
    /// Integer PCM (`WAVE_FORMAT_PCM`, tag 1).
    case pcm(bits: Int)
    /// IEEE floating point (`WAVE_FORMAT_IEEE_FLOAT`, tag 3).
    case ieeeFloat(bits: Int)
    /// Any other tag. Parsed and reported, not interpreted.
    case other(tag: UInt16, bits: Int)

    /// A readable name such as "PCM 24-bit".
    public var description: String {
        switch self {
        case let .pcm(bits): return "PCM \(bits)-bit"
        case let .ieeeFloat(bits): return "IEEE float \(bits)-bit"
        case let .other(tag, bits): return "format 0x\(String(tag, radix: 16, uppercase: true)), \(bits)-bit"
        }
    }
}

/// The extra fields of `WAVE_FORMAT_EXTENSIBLE` (tag 0xFFFE).
public struct ExtensibleFormat: Sendable, Equatable {
    /// Valid bits per sample (`wValidBitsPerSample`).
    public let validBitsPerSample: UInt16
    /// Speaker position mask (`dwChannelMask`).
    public let channelMask: UInt32
    /// The 16 byte sub-format GUID, lowercase hex in file byte order.
    public let subFormatGUID: String
}

/// The parsed `fmt ` chunk.
public struct WaveFormat: Sendable, Equatable {
    /// `wFormatTag` as stored.
    public let formatTag: UInt16
    /// `nChannels`.
    public let channels: UInt16
    /// `nSamplesPerSec`.
    public let sampleRate: UInt32
    /// `nAvgBytesPerSec`.
    public let byteRate: UInt32
    /// `nBlockAlign`.
    public let blockAlign: UInt16
    /// `wBitsPerSample`.
    public let bitsPerSample: UInt16
    /// Present when the tag is 0xFFFE and the chunk carries the extension.
    public let extensible: ExtensibleFormat?
    /// The tag that describes the samples: the first two bytes of the sub-format GUID for
    /// extensible files (as the Python reference reads it), otherwise `formatTag`.
    public let effectiveFormatTag: UInt16

    /// `WAVE_FORMAT_PCM`.
    public static let pcmTag: UInt16 = 0x0001
    /// `WAVE_FORMAT_IEEE_FLOAT`.
    public static let ieeeFloatTag: UInt16 = 0x0003
    /// `WAVE_FORMAT_EXTENSIBLE`.
    public static let extensibleTag: UInt16 = 0xFFFE

    /// Parses a `fmt ` payload. Requires the 16 byte common part and plausible values.
    public init(parsing data: [UInt8]) throws {
        guard data.count >= 16 else {
            throw WaveError.invalidFormat("chunk is \(data.count) bytes, at least 16 are required")
        }
        formatTag = try LE.u16(data, 0)
        channels = try LE.u16(data, 2)
        sampleRate = try LE.u32(data, 4)
        byteRate = try LE.u32(data, 8)
        blockAlign = try LE.u16(data, 12)
        bitsPerSample = try LE.u16(data, 14)
        guard channels > 0 else { throw WaveError.invalidFormat("zero channels") }
        guard sampleRate > 0 else { throw WaveError.invalidFormat("zero sample rate") }
        guard blockAlign > 0 else { throw WaveError.invalidFormat("zero block align") }

        var effective = formatTag
        var ext: ExtensibleFormat?
        if formatTag == WaveFormat.extensibleTag {
            if data.count >= 26 {
                effective = try LE.u16(data, 24)
            }
            if data.count >= 40 {
                ext = ExtensibleFormat(
                    validBitsPerSample: try LE.u16(data, 18),
                    channelMask: try LE.u32(data, 20),
                    subFormatGUID: Hex.encode(data[24 ..< 40])
                )
            }
        }
        extensible = ext
        effectiveFormatTag = effective
    }

    /// The sample encoding after resolving `WAVE_FORMAT_EXTENSIBLE`.
    public var encoding: SampleEncoding {
        let bits = Int(bitsPerSample)
        switch effectiveFormatTag {
        case WaveFormat.pcmTag: return .pcm(bits: bits)
        case WaveFormat.ieeeFloatTag: return .ieeeFloat(bits: bits)
        default: return .other(tag: effectiveFormatTag, bits: bits)
        }
    }

    /// True for the encodings this package names as supported: PCM 16, 24 and 32 bit and
    /// IEEE float 32 and 64 bit, plain or extensible.
    public var isSupportedEncoding: Bool {
        switch encoding {
        case let .pcm(bits): return [16, 24, 32].contains(bits)
        case let .ieeeFloat(bits): return [32, 64].contains(bits)
        case .other: return false
        }
    }
}
