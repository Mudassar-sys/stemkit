import Foundation

extension WaveFile {
    /// Every `bext` and `iXML` field as a string, keyed exactly like the Python reference's
    /// `flatten_metadata`: `bext.<field>` (bytes as lowercase hex, integers in decimal),
    /// `ixml.<path>`, and `riff.other_chunks`.
    public func flattenedMetadata() throws -> [String: String] {
        var flat: [String: String] = [:]
        if let bext {
            flat.merge(Self.flatten(bext)) { _, new in new }
        }
        if let ixml {
            for (key, value) in try ixml.flattened() {
                flat["ixml.\(key)"] = value
            }
        }
        flat["riff.other_chunks"] = otherChunkIDs.joined(separator: ",")
        return flat
    }

    /// The `bext.*` keys for one chunk.
    public static func flatten(_ bext: Bext) -> [String: String] {
        [
            "bext.description": bext.description,
            "bext.originator": bext.originator,
            "bext.originator_reference": bext.originatorReference,
            "bext.origination_date": bext.originationDate,
            "bext.origination_time": bext.originationTime,
            "bext.time_reference": String(bext.timeReference),
            "bext.version": String(bext.version),
            "bext.umid": Hex.encode(bext.umid),
            "bext.loudness_value": String(bext.loudnessValue),
            "bext.loudness_range": String(bext.loudnessRange),
            "bext.max_true_peak_level": String(bext.maxTruePeakLevel),
            "bext.max_momentary_loudness": String(bext.maxMomentaryLoudness),
            "bext.max_short_term_loudness": String(bext.maxShortTermLoudness),
            "bext.reserved": Hex.encode(bext.reserved),
            "bext.coding_history": bext.codingHistory,
        ]
    }
}

/// Field names accepted by `BextField.set` and the `stemkit set` command.
public enum BextField: String, CaseIterable, Sendable {
    /// `Description`.
    case description
    /// `Originator`.
    case originator
    /// `OriginatorReference`.
    case originatorReference = "originator_reference"
    /// `OriginationDate`.
    case originationDate = "origination_date"
    /// `OriginationTime`.
    case originationTime = "origination_time"
    /// `TimeReference`, a sample count.
    case timeReference = "time_reference"
    /// `Version`.
    case version
    /// `UMID`, 128 hex digits.
    case umid
    /// `LoudnessValue`, in LUFS.
    case loudnessValue = "loudness_value"
    /// `LoudnessRange`, in LU.
    case loudnessRange = "loudness_range"
    /// `MaxTruePeakLevel`, in dBTP.
    case maxTruePeakLevel = "max_true_peak_level"
    /// `MaxMomentaryLoudness`, in LUFS.
    case maxMomentaryLoudness = "max_momentary_loudness"
    /// `MaxShortTermLoudness`, in LUFS.
    case maxShortTermLoudness = "max_short_term_loudness"
    /// `CodingHistory`.
    case codingHistory = "coding_history"

    /// Applies a textual value to `bext`. Loudness values are given in LUFS, LU or dBTP
    /// (for example `-23.05`) and stored with the Tech 3285 v2 rounding rule; `none`
    /// stores 0x7FFF. The UMID is 128 hex digits.
    public func set(_ value: String, in bext: inout Bext) throws {
        switch self {
        case .description: bext.description = value
        case .originator: bext.originator = value
        case .originatorReference: bext.originatorReference = value
        case .originationDate: bext.originationDate = value
        case .originationTime: bext.originationTime = value
        case .codingHistory:
            // Reuse NUL padding a writer reserved after the history, so the chunk keeps its
            // size (and can be written in place) when the history grows into that space.
            let oldBytes = bext.codingHistory.unicodeScalars.count + bext.codingHistoryPadding
            bext.codingHistory = value
            bext.codingHistoryPadding = max(0, oldBytes - value.unicodeScalars.count)
        case .timeReference:
            guard let number = UInt64(value) else {
                throw WaveError.invalidValue(field: rawValue, value: value, reason: "expected a sample count")
            }
            bext.timeReference = number
        case .version:
            guard let number = UInt16(value), number <= 2 else {
                throw WaveError.invalidValue(field: rawValue, value: value, reason: "expected 0, 1 or 2")
            }
            if number == 0, bext.umid.contains(where: { $0 != 0 }) {
                throw WaveError.invalidValue(field: rawValue, value: value, reason: "the UMID is reserved in Version 0; clear it first")
            }
            if number < 2, bext.version >= 2 {
                // Going down: the loudness bytes become reserved zeros, so every field must be
                // marked "not used" first (a stored 0.00 is a real measurement in Version 2).
                if LoudnessField.allCases.contains(where: { bext.loudness($0) != Bext.loudnessNotUsed }) {
                    throw WaveError.invalidValue(
                        field: rawValue, value: value, reason: "clear the loudness fields (set them to none) first")
                }
                bext.loudnessValue = 0
                bext.loudnessRange = 0
                bext.maxTruePeakLevel = 0
                bext.maxMomentaryLoudness = 0
                bext.maxShortTermLoudness = 0
            }
            if number == 2, bext.version < 2 {
                // Going up: the reserved zeros become loudness fields, marked "not used".
                bext.loudnessValue = Bext.loudnessNotUsed
                bext.loudnessRange = Bext.loudnessNotUsed
                bext.maxTruePeakLevel = Bext.loudnessNotUsed
                bext.maxMomentaryLoudness = Bext.loudnessNotUsed
                bext.maxShortTermLoudness = Bext.loudnessNotUsed
            }
            bext.version = number
        case .umid:
            guard let bytes = Hex.decode(value), bytes.count == 64 else {
                throw WaveError.invalidValue(field: rawValue, value: value, reason: "expected 128 hex digits")
            }
            bext.umid = bytes
            if bext.version == 0, bytes.contains(where: { $0 != 0 }) {
                bext.version = 1  // the UMID exists from Version 1 on
            }
        case .loudnessValue, .loudnessRange, .maxTruePeakLevel, .maxMomentaryLoudness, .maxShortTermLoudness:
            guard let field = LoudnessField(rawValue: rawValue) else {
                throw WaveError.unknownField(rawValue)
            }
            if value.lowercased() == "none" {
                try bext.setLoudness(field, to: nil)
            } else {
                guard let decimal = LoudnessCoding.parseDecimal(value) else {
                    throw WaveError.invalidValue(field: rawValue, value: value, reason: "expected a decimal number or none")
                }
                try bext.setLoudness(field, to: decimal)
            }
        }
        // Validate widths and encoding now, so a bad value fails before any file is touched.
        _ = try bext.serialized()
    }
}
