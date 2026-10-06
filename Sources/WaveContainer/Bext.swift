import Foundation

/// The broadcast audio extension chunk, EBU Tech 3285 version 2.
///
/// Text fields are decoded as ISO 8859-1 with trailing NUL bytes removed, exactly as the
/// Python reference does, so a decoded value re-encodes to the original bytes. The number
/// of NUL bytes that followed the coding history is kept in `codingHistoryPadding` so an
/// edit to one field does not change any other byte of the chunk.
public struct Bext: Sendable, Equatable {
    /// `Description`, at most 256 bytes.
    public var description: String
    /// `Originator`, at most 32 bytes.
    public var originator: String
    /// `OriginatorReference`, at most 32 bytes.
    public var originatorReference: String
    /// `OriginationDate`, at most 10 bytes (`yyyy-mm-dd`).
    public var originationDate: String
    /// `OriginationTime`, at most 8 bytes (`hh-mm-ss`).
    public var originationTime: String
    /// `TimeReferenceLow` and `TimeReferenceHigh`: the first sample count since midnight.
    public var timeReference: UInt64
    /// `Version`: 0, 1 or 2 in Tech 3285 v2.
    public var version: UInt16
    /// `UMID`, 64 bytes.
    public var umid: [UInt8]
    /// `LoudnessValue`, LUFS times 100, or `Bext.loudnessNotUsed`.
    public var loudnessValue: Int16
    /// `LoudnessRange`, LU times 100, or `Bext.loudnessNotUsed`.
    public var loudnessRange: Int16
    /// `MaxTruePeakLevel`, dBTP times 100, or `Bext.loudnessNotUsed`.
    public var maxTruePeakLevel: Int16
    /// `MaxMomentaryLoudness`, LUFS times 100, or `Bext.loudnessNotUsed`.
    public var maxMomentaryLoudness: Int16
    /// `MaxShortTermLoudness`, LUFS times 100, or `Bext.loudnessNotUsed`.
    public var maxShortTermLoudness: Int16
    /// `Reserved`, 180 bytes, zero for versions 1 and 2.
    public var reserved: [UInt8]
    /// `CodingHistory`, variable length, without trailing NUL bytes.
    public var codingHistory: String
    /// Count of NUL bytes that followed the coding history in the file.
    public var codingHistoryPadding: Int

    /// Size of the fixed part that precedes `CodingHistory`.
    public static let fixedSize = 602
    /// The value Tech 3285 v2 section 2.4 assigns to a loudness field that is not used.
    public static let loudnessNotUsed: Int16 = 0x7FFF

    /// Field widths in bytes, in file order.
    static let textWidths: [(name: String, width: Int)] = [
        ("Description", 256), ("Originator", 32), ("OriginatorReference", 32),
        ("OriginationDate", 10), ("OriginationTime", 8),
    ]

    /// An empty version 2 chunk with every loudness field marked as not used.
    public init() {
        description = ""
        originator = ""
        originatorReference = ""
        originationDate = ""
        originationTime = ""
        timeReference = 0
        version = 2
        umid = [UInt8](repeating: 0, count: 64)
        loudnessValue = Bext.loudnessNotUsed
        loudnessRange = Bext.loudnessNotUsed
        maxTruePeakLevel = Bext.loudnessNotUsed
        maxMomentaryLoudness = Bext.loudnessNotUsed
        maxShortTermLoudness = Bext.loudnessNotUsed
        reserved = [UInt8](repeating: 0, count: 180)
        codingHistory = ""
        codingHistoryPadding = 0
    }

    /// Parses a `bext` payload.
    public init(parsing data: [UInt8]) throws {
        guard data.count >= Bext.fixedSize else {
            throw WaveError.invalidBext("payload is \(data.count) bytes, the fixed part is \(Bext.fixedSize)")
        }
        func text(_ start: Int, _ width: Int) -> String {
            Latin1.decode(Latin1.trimTrailingNULs(data[start ..< start + width]))
        }
        description = text(0, 256)
        originator = text(256, 32)
        originatorReference = text(288, 32)
        originationDate = text(320, 10)
        originationTime = text(330, 8)
        let low = try LE.u32(data, 338)
        let high = try LE.u32(data, 342)
        timeReference = UInt64(low) | UInt64(high) << 32
        version = try LE.u16(data, 346)
        umid = Array(data[348 ..< 412])
        loudnessValue = try LE.i16(data, 412)
        loudnessRange = try LE.i16(data, 414)
        maxTruePeakLevel = try LE.i16(data, 416)
        maxMomentaryLoudness = try LE.i16(data, 418)
        maxShortTermLoudness = try LE.i16(data, 420)
        reserved = Array(data[422 ..< 602])
        let history = data[Bext.fixedSize ..< data.count]
        let trimmed = Latin1.trimTrailingNULs(history)
        codingHistory = Latin1.decode(trimmed)
        codingHistoryPadding = history.count - trimmed.count
    }

    /// The chunk payload. Throws when a text field does not fit its width or is not ISO 8859-1.
    public func serialized() throws -> [UInt8] {
        guard codingHistoryPadding >= 0, UInt64(codingHistoryPadding) <= WaveLimits.maxMetadataChunkBytes else {
            throw WaveError.sizeLimitExceeded("coding history padding of \(codingHistoryPadding) bytes")
        }
        guard UInt64(codingHistory.unicodeScalars.count) <= WaveLimits.maxMetadataChunkBytes else {
            throw WaveError.sizeLimitExceeded("coding history of \(codingHistory.unicodeScalars.count) characters")
        }
        var out: [UInt8] = []
        out.reserveCapacity(Bext.fixedSize + codingHistory.unicodeScalars.count + codingHistoryPadding)
        let values = [description, originator, originatorReference, originationDate, originationTime]
        for (value, spec) in zip(values, Bext.textWidths) {
            let bytes = try Latin1.encode(value, field: spec.name)
            guard bytes.count <= spec.width else {
                throw WaveError.fieldTooLong(field: spec.name, maxBytes: spec.width, actualBytes: bytes.count)
            }
            out.append(contentsOf: bytes)
            out.append(contentsOf: [UInt8](repeating: 0, count: spec.width - bytes.count))
        }
        LE.put32(UInt32(truncatingIfNeeded: timeReference), into: &out)
        LE.put32(UInt32(truncatingIfNeeded: timeReference >> 32), into: &out)
        LE.put16(version, into: &out)
        guard umid.count == 64 else {
            throw WaveError.invalidValue(field: "UMID", value: "\(umid.count) bytes", reason: "must be 64 bytes")
        }
        out.append(contentsOf: umid)
        for value in [loudnessValue, loudnessRange, maxTruePeakLevel, maxMomentaryLoudness, maxShortTermLoudness] {
            LE.put16(UInt16(bitPattern: value), into: &out)
        }
        guard reserved.count == 180 else {
            throw WaveError.invalidValue(field: "Reserved", value: "\(reserved.count) bytes", reason: "must be 180 bytes")
        }
        out.append(contentsOf: reserved)
        out.append(contentsOf: try Latin1.encode(codingHistory, field: "CodingHistory"))
        out.append(contentsOf: [UInt8](repeating: 0, count: codingHistoryPadding))
        guard UInt64(out.count) <= WaveLimits.maxMetadataChunkBytes else {
            throw WaveError.sizeLimitExceeded("bext payload of \(out.count) bytes")
        }
        return out
    }

    /// Reads one loudness field.
    public func loudness(_ field: LoudnessField) -> Int16 {
        switch field {
        case .loudnessValue: return loudnessValue
        case .loudnessRange: return loudnessRange
        case .maxTruePeakLevel: return maxTruePeakLevel
        case .maxMomentaryLoudness: return maxMomentaryLoudness
        case .maxShortTermLoudness: return maxShortTermLoudness
        }
    }

    /// Sets one loudness field from a measurement, applying the Tech 3285 v2 rounding rule.
    /// A `nil` value stores 0x7FFF ("not used"). Storing a measurement raises `version`
    /// to 2, because the loudness fields exist from version 2 on; in Versions 0 and 1 those
    /// ten bytes are reserved zeros, so on that raise the other four fields become 0x7FFF
    /// rather than reading as measurements of 0.00.
    public mutating func setLoudness(_ field: LoudnessField, to value: Decimal?) throws {
        let raw: Int16
        if value == nil, version < 2 {
            return  // Versions 0 and 1 have no loudness fields: the bytes stay reserved zeros.
        }
        if let value {
            raw = try LoudnessCoding.encode(value, field: field)
            if version < 2 {
                loudnessValue = Bext.loudnessNotUsed
                loudnessRange = Bext.loudnessNotUsed
                maxTruePeakLevel = Bext.loudnessNotUsed
                maxMomentaryLoudness = Bext.loudnessNotUsed
                maxShortTermLoudness = Bext.loudnessNotUsed
                version = 2
            }
        } else {
            raw = Bext.loudnessNotUsed
        }
        switch field {
        case .loudnessValue: loudnessValue = raw
        case .loudnessRange: loudnessRange = raw
        case .maxTruePeakLevel: maxTruePeakLevel = raw
        case .maxMomentaryLoudness: maxMomentaryLoudness = raw
        case .maxShortTermLoudness: maxShortTermLoudness = raw
        }
    }

    /// Problems a reader should know about. An empty list means the chunk follows Tech 3285 v2.
    public var specificationIssues: [String] {
        var issues: [String] = []
        if version > 2 {
            issues.append("Version \(version) is newer than Tech 3285 v2")
        }
        if reserved.contains(where: { $0 != 0 }) {
            issues.append("Reserved bytes are not zero (Version \(version))")
        }
        if version == 0, umid.contains(where: { $0 != 0 }) {
            issues.append("the UMID bytes are reserved in Version 0 but are not zero")
        }
        if version < 2 {
            // In Versions 0 and 1 the loudness bytes are part of the reserved area.
            if LoudnessField.allCases.contains(where: { loudness($0) != 0 }) {
                issues.append("bytes 412 to 421 are reserved in Version \(version) but are not zero")
            }
            return issues
        }
        for field in LoudnessField.allCases {
            let raw = loudness(field)
            if raw == Bext.loudnessNotUsed { continue }
            if LoudnessCoding.decode(raw, field: field) == nil {
                issues.append("\(field.specName) value \(raw) is outside its valid range")
            }
        }
        return issues
    }
}

/// The five loudness fields of Tech 3285 v2.
public enum LoudnessField: String, CaseIterable, Sendable {
    /// `LoudnessValue`, integrated loudness in LUFS.
    case loudnessValue = "loudness_value"
    /// `LoudnessRange` in LU.
    case loudnessRange = "loudness_range"
    /// `MaxTruePeakLevel` in dBTP.
    case maxTruePeakLevel = "max_true_peak_level"
    /// `MaxMomentaryLoudness` in LUFS.
    case maxMomentaryLoudness = "max_momentary_loudness"
    /// `MaxShortTermLoudness` in LUFS.
    case maxShortTermLoudness = "max_short_term_loudness"

    /// The field name used in Tech 3285.
    public var specName: String {
        switch self {
        case .loudnessValue: return "LoudnessValue"
        case .loudnessRange: return "LoudnessRange"
        case .maxTruePeakLevel: return "MaxTruePeakLevel"
        case .maxMomentaryLoudness: return "MaxMomentaryLoudness"
        case .maxShortTermLoudness: return "MaxShortTermLoudness"
        }
    }

    /// Valid stored range: 0x0000 to 0x270F for LoudnessRange, 0xD8F1 to 0x270F for the others.
    public var validRange: ClosedRange<Int16> {
        self == .loudnessRange ? 0 ... 9999 : -9999 ... 9999
    }
}

/// The loudness encoding of Tech 3285 v2 section 2.4.
public enum LoudnessCoding {
    /// Stored integer for a measured value: the integer part of `x + sgn(x) * 0.5` where
    /// `x` is the value times 100 ("round to nearest, ties away from zero").
    ///
    /// The value is a `Decimal`, so a decimal input such as `1.005` is held exactly and rounds
    /// to 101 by the rule; the nearest binary `Double` to 1.005 lies below it, so 1.005 x 100
    /// computed in `Double` falls below the tie (the tests print it).
    public static func encode(_ value: Decimal, field: LoudnessField) throws -> Int16 {
        guard value.isFinite else {
            throw WaveError.invalidValue(field: field.specName, value: "\(value)", reason: "not a finite number")
        }
        var scaled = value * Decimal(100)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let limit = Decimal(Int(Int16.max))
        guard rounded <= limit, rounded >= -limit else {
            throw WaveError.invalidValue(field: field.specName, value: "\(value)", reason: "outside the 16-bit range")
        }
        let integer = Int16(truncatingIfNeeded: NSDecimalNumber(decimal: rounded).intValue)
        guard field.validRange.contains(integer) else {
            let low = Decimal(Int(field.validRange.lowerBound)) / 100
            let high = Decimal(Int(field.validRange.upperBound)) / 100
            throw WaveError.invalidValue(
                field: field.specName, value: "\(value)", reason: "valid range is \(low) to \(high)")
        }
        return integer
    }

    /// The measured value a stored integer represents, or `nil` when the field is marked
    /// as not used (0x7FFF) or holds a value outside its valid range, which section 2.4
    /// says shall be ignored.
    public static func decode(_ raw: Int16, field: LoudnessField) -> Decimal? {
        guard raw != Bext.loudnessNotUsed, field.validRange.contains(raw) else { return nil }
        return Decimal(Int(raw)) / 100
    }

    /// Parses a decimal string such as `-23.05`. Only plain decimal notation is accepted.
    public static func parseDecimal(_ text: String) -> Decimal? {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        var index = 0
        if scalars[0] == "-" || scalars[0] == "+" { index = 1 }
        var digits = 0
        var dots = 0
        while index < scalars.count {
            let s = scalars[index]
            if s == "." {
                dots += 1
            } else if ("0" ... "9").contains(s) {
                digits += 1
            } else {
                return nil
            }
            index += 1
        }
        guard digits > 0, dots <= 1, digits <= 30 else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}
