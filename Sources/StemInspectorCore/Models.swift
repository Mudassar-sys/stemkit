import Foundation
import WaveContainer

/// What the app knows about one file after loading it.
public struct StemSnapshot: Sendable, Equatable {
    /// File location.
    public let url: URL
    /// `RIFF`, `RF64` or `BW64`.
    public let container: String
    /// Channel count from `fmt `.
    public let channels: Int
    /// Sample rate in Hz.
    public let sampleRate: Int
    /// Bits per sample.
    public let bitDepth: Int
    /// Readable sample encoding, for example "PCM 24-bit".
    public let encoding: String
    /// Duration in seconds, when it can be derived.
    public let durationSeconds: Double?
    /// The `bext` chunk, if present.
    public let bext: Bext?
    /// True when an `iXML` chunk is present.
    public let hasIXML: Bool
    /// SHA-256 of the audio payload when the file was loaded.
    public let audioSHA256: String

    /// Creates a snapshot. Used by the file worker and by test doubles.
    public init(url: URL, container: String, channels: Int, sampleRate: Int, bitDepth: Int, encoding: String,
                durationSeconds: Double?, bext: Bext?, hasIXML: Bool, audioSHA256: String) {
        self.url = url
        self.container = container
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.encoding = encoding
        self.durationSeconds = durationSeconds
        self.bext = bext
        self.hasIXML = hasIXML
        self.audioSHA256 = audioSHA256
    }
}

/// The editable `bext` text fields.
public struct BextDraft: Sendable, Equatable {
    /// bext `Description`.
    public var description = ""
    /// bext `Originator`.
    public var originator = ""
    /// bext `OriginatorReference`.
    public var originatorReference = ""
    /// bext `OriginationDate`.
    public var originationDate = ""
    /// bext `OriginationTime`.
    public var originationTime = ""
    /// bext `TimeReference` as decimal text (a sample count).
    public var timeReference = ""

    /// An empty draft.
    public init() {}

    /// The draft for an existing chunk (or an empty one).
    public init(_ bext: Bext?) {
        guard let bext else { return }
        description = bext.description
        originator = bext.originator
        originatorReference = bext.originatorReference
        originationDate = bext.originationDate
        originationTime = bext.originationTime
        timeReference = String(bext.timeReference)
    }

    /// Applies the draft to `base` (or to a new version 2 chunk). Throws on values that do not fit.
    public func applied(to base: Bext?) throws -> Bext {
        var bext = base ?? Bext()
        try BextField.description.set(description, in: &bext)
        try BextField.originator.set(originator, in: &bext)
        try BextField.originatorReference.set(originatorReference, in: &bext)
        try BextField.originationDate.set(originationDate, in: &bext)
        try BextField.originationTime.set(originationTime, in: &bext)
        try BextField.timeReference.set(timeReference.isEmpty ? "0" : timeReference, in: &bext)
        return bext
    }
}

/// The per-file proof shown after a save.
public enum IntegrityBadge: Sendable, Equatable {
    /// Nothing written yet.
    case notSaved
    /// Saved; the payload hash after the save equals the hash taken when the file was loaded.
    case verified(sha256: String, path: WritePath)
    /// Saved, but the hashes differ or could not be compared.
    case failed(String)
}

/// One row of the table.
public struct StemRow: Identifiable, Sendable, Equatable {
    /// A stable identity for the row, independent of renames.
    public let id: UUID
    /// Current location (changes after a rename).
    public var url: URL
    /// Loaded state; nil while loading or after a load error.
    public var snapshot: StemSnapshot?
    /// Edited `bext` text, saved on request.
    public var draft: BextDraft
    /// Integrity proof of the last save.
    public var badge: IntegrityBadge = .notSaved
    /// The last error for this file, shown in the table.
    public var error: String?
    /// True when the draft differs from the file.
    public var isDirty = false

    /// Creates a row for a file that is about to load.
    public init(url: URL) {
        id = UUID()
        self.url = url
        draft = BextDraft()
    }

    /// The file name shown in the table.
    public var name: String { url.lastPathComponent }
    /// Container column text.
    public var containerText: String { snapshot?.container ?? "" }
    /// Channels column text.
    public var channelsText: String { snapshot.map { String($0.channels) } ?? "" }
    /// Sample rate column text.
    public var sampleRateText: String { snapshot.map { "\($0.sampleRate)" } ?? "" }
    /// Bit depth column text.
    public var bitDepthText: String { snapshot.map { String($0.bitDepth) } ?? "" }
    /// Duration column text, in seconds with three decimals.
    public var durationText: String {
        guard let seconds = snapshot?.durationSeconds else { return "" }
        return String(format: "%.3f s", seconds)
    }
    /// Time reference column text.
    public var timeReferenceText: String { draft.timeReference }
    /// iXML column text.
    public var ixmlText: String { snapshot.map { $0.hasIXML ? "Yes" : "No" } ?? "" }
}

/// Progress of the running batch.
public struct BatchProgress: Sendable, Equatable {
    /// What the batch does, for example "Saving".
    public var label: String
    /// Files finished (successfully or not).
    public var completed: Int
    /// Files in the batch.
    public var total: Int
}

/// The file operations the view model needs. `FileWorker` implements them on disk; tests
/// use an in-memory double.
public protocol StemFileService: Sendable {
    /// Expands folders into the WAVE files they contain, sorted by path. Files pass through.
    func expand(_ urls: [URL]) async throws -> [URL]
    /// Parses a file and hashes its audio payload.
    func load(_ url: URL) async throws -> StemSnapshot
    /// Writes `bext` and returns the write report with the before and after hashes.
    func save(_ bext: Bext, to url: URL) async throws -> WriteReport
    /// Renames a file within its folder and returns the new location.
    func rename(_ url: URL, to fileName: String) async throws -> URL
    /// True when files can be created in `folder` (rewrites and renames need this).
    func canWrite(in folder: URL) async -> Bool
    /// Keeps sandbox access to items the user granted, such as a folder chosen in an open panel.
    func grantAccess(_ urls: [URL]) async
}

/// Asks the user for write access to a folder. The app shows an open panel pointed at the
/// folder, which extends the sandbox to what the user selects; tests use a stub.
@MainActor
public protocol FolderAccessRequester {
    /// Returns the folder the user granted, or nil when they declined.
    func requestAccess(to folder: URL) async -> URL?
}
