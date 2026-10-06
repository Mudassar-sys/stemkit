import Foundation
import WaveContainer

/// Errors from the file worker that are not container errors.
public enum FileWorkerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The rename target already exists.
    case destinationExists(String)
    /// The new name is not a plain file name.
    case invalidFileName(String)
    /// More files than the batch limit.
    case tooManyFiles(Int)
    /// The app may not write in the file's folder (the sandbox grants access per item).
    case noFolderAccess(String)
    /// A file system operation failed.
    case fileSystem(String)

    /// A readable explanation of the error.
    public var description: String {
        switch self {
        case let .destinationExists(name): return "\(name) already exists"
        case let .invalidFileName(name): return "'\(name)' is not a valid file name"
        case let .tooManyFiles(limit): return "more than \(limit) files"
        case let .noFolderAccess(folder): return "no write access to the folder \(folder); add the folder instead of single files"
        case let .fileSystem(reason): return reason
        }
    }
}

/// Does all disk work for the app. Being an actor, it serialises its own state (the set of
/// security-scoped URLs); the file operations themselves run on whichever task calls them,
/// so the view model's task group can run several at once.
public actor FileWorker: StemFileService {
    /// Most files accepted from one drop or import.
    public static let maxFiles = 10_000
    private var scopedURLs: [URL] = []

    /// Creates a worker.
    public init() {}

    /// Keeps sandbox access to user-selected items for the life of the worker.
    public func beginAccess(_ urls: [URL]) {
        for url in urls where !scopedURLs.contains(url) && url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
    }

    /// Ends sandbox access to every item opened with `beginAccess`.
    public func endAccess() {
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
    }

    public func grantAccess(_ urls: [URL]) async {
        beginAccess(urls)
    }

    public func expand(_ urls: [URL]) async throws -> [URL] {
        beginAccess(urls)
        var files: [URL] = []
        let manager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let enumerator = manager.enumerator(
                    at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                while let item = enumerator.nextObject() as? URL {
                    let regular = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    if regular, FileWorker.isWave(item) {
                        files.append(item)
                    }
                    if files.count > FileWorker.maxFiles { throw FileWorkerError.tooManyFiles(FileWorker.maxFiles) }
                }
            } else {
                files.append(url)
            }
        }
        if files.count > FileWorker.maxFiles { throw FileWorkerError.tooManyFiles(FileWorker.maxFiles) }
        // A folder and a file inside it, or overlapping folders, must not give two rows for one file.
        var seen: Set<String> = []
        files = files.filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated static func isWave(_ url: URL) -> Bool {
        ["wav", "wave", "bwf", "rf64"].contains(url.pathExtension.lowercased())
    }

    /// Probes whether a file can be created in `folder` by creating and removing an empty
    /// hidden file. Under the App Sandbox this is the reliable test of folder access.
    public nonisolated func canWrite(in folder: URL) async -> Bool {
        let probe = folder.appendingPathComponent(".stemkit-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    public nonisolated func load(_ url: URL) async throws -> StemSnapshot {
        let file = try WaveFile.read(from: url)
        let hash = try AudioIntegrity.dataChunkSHA256(of: url, file: file)
        return StemSnapshot(
            url: url,
            container: file.container.rawValue,
            channels: Int(file.format.channels),
            sampleRate: Int(file.format.sampleRate),
            bitDepth: Int(file.format.bitsPerSample),
            encoding: file.format.encoding.description,
            durationSeconds: file.durationSeconds,
            bext: file.bext,
            hasIXML: file.ixml != nil,
            audioSHA256: hash
        )
    }

    public nonisolated func save(_ bext: Bext, to url: URL) async throws -> WriteReport {
        try MetadataWriter.apply(MetadataChanges(bext: bext), to: url)
    }

    public nonisolated func rename(_ url: URL, to fileName: String) async throws -> URL {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains(":"), fileName != ".", fileName != ".." else {
            throw FileWorkerError.invalidFileName(fileName)
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(fileName)
        if target.standardizedFileURL == url.standardizedFileURL { return url }
        let manager = FileManager.default
        do {
            if target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased() {
                // A change of letter case only. On a case-insensitive volume the target "exists"
                // because it is the same file; on a case-sensitive one it may be another file.
                if manager.fileExists(atPath: target.path), !FileWorker.sameFile(url, target) {
                    throw FileWorkerError.destinationExists(fileName)
                }
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".stemkit-rename-\(UUID().uuidString)")
                try manager.moveItem(at: url, to: temporary)
                do {
                    try manager.moveItem(at: temporary, to: target)
                } catch {
                    try? manager.moveItem(at: temporary, to: url)  // put the file back under its old name
                    throw error
                }
                return target
            }
            guard !manager.fileExists(atPath: target.path) else {
                throw FileWorkerError.destinationExists(fileName)
            }
            try manager.moveItem(at: url, to: target)
            return target
        } catch let error as FileWorkerError {
            throw error
        } catch {
            throw FileWorkerError.fileSystem(error.localizedDescription)
        }
    }

    /// True when both URLs name the same file system object.
    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return idA.isEqual(idB)
    }
}
