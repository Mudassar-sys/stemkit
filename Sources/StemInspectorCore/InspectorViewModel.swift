import Foundation
import Observation
import WaveContainer

/// State and actions of the Stem Inspector window.
///
/// Batches (load, save, rename) run in a task group with at most `maxConcurrent` files in
/// flight, report progress after each file, and stop scheduling new files when cancelled.
/// Each file operation runs in its own task that cancellation does not reach, so a file
/// already being written finishes its write and no file is left half written. Every failure
/// is stored on its row; nothing is swallowed. Files dropped while a batch runs are queued.
@MainActor
@Observable
public final class InspectorViewModel {
    /// Table rows, in load order.
    public private(set) var rows: [StemRow] = []
    /// Selected row ids.
    public var selection: Set<StemRow.ID> = []
    /// The inspector's editable fields. `applyDraftToSelection` copies the fields the user
    /// changed (and only those) to every selected row.
    public var inspectorDraft = BextDraft()
    /// The inspector's values when they were last loaded or applied; edits are measured against it.
    public private(set) var inspectorBaseline = BextDraft()
    /// Naming template text.
    public var template = "{project}_{index}_{description}"
    /// Value of the `{project}` token.
    public var project = "Project"
    /// Progress of the running batch, nil when idle.
    public private(set) var progress: BatchProgress?
    /// A one line summary of the last batch.
    public private(set) var statusMessage = "Drop WAV files or folders here"
    /// Items dropped while a batch was running; they load when it ends.
    public private(set) var queuedURLs: [URL] = []
    /// Most files processed at once.
    public let maxConcurrent: Int

    private let service: any StemFileService
    private let folderAccess: (any FolderAccessRequester)?
    private var currentTask: Task<Void, Never>?
    /// Batches running through the `...AndWait` entry points (at most one).
    private var activeBatches = 0

    /// Creates a view model over a file service. `folderAccess` is asked for write access to
    /// a folder before a save or rename that needs it; without it, missing access is reported.
    public init(service: any StemFileService, folderAccess: (any FolderAccessRequester)? = nil, maxConcurrent: Int = 4) {
        self.service = service
        self.folderAccess = folderAccess
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// True while a batch runs.
    public var isBusy: Bool { currentTask != nil || activeBatches > 0 || progress != nil }

    /// Claims the single batch slot; false (with a status message) when a batch already runs.
    private func beginBatch() -> Bool {
        guard activeBatches == 0 else {
            statusMessage = "Busy: wait for the current batch or cancel it"
            return false
        }
        activeBatches += 1
        return true
    }

    /// Releases the batch slot and starts any drops queued while it was held.
    private func endBatch() {
        activeBatches -= 1
        if activeBatches == 0, currentTask == nil, !queuedURLs.isEmpty {
            let urls = queuedURLs
            queuedURLs = []
            add(urls)
        }
    }

    /// Rows whose draft has not been saved.
    public var dirtyCount: Int { rows.filter(\.isDirty).count }

    // MARK: - Actions that start a batch

    /// Loads files and folders in the background. While another batch runs, the items are
    /// queued and load as soon as it ends.
    public func add(_ urls: [URL]) {
        if currentTask != nil || activeBatches > 0 {
            queuedURLs.append(contentsOf: urls)
            return
        }
        start {
            if self.activeBatches > 0 {
                self.queuedURLs.append(contentsOf: urls)  // drained when the current batch ends
            } else {
                await self.addAndWait(urls)
            }
        }
    }

    /// Saves every row with unsaved edits in the background.
    public func saveChanges() {
        start { await self.saveChangesAndWait() }
    }

    /// Renames every loaded row to its template name in the background.
    public func applyNaming() {
        start { await self.applyNamingAndWait() }
    }

    /// Stops scheduling new files in the running batch and drops any queued items.
    public func cancel() {
        queuedURLs.removeAll()
        currentTask?.cancel()
    }

    /// Waits for the running batch and any queued loads.
    public func waitForCurrentBatch() async {
        while let task = currentTask {
            await task.value
        }
    }

    private func start(_ work: @escaping @MainActor @Sendable () async -> Void) {
        guard currentTask == nil else {
            statusMessage = "Busy: wait for the current batch or cancel it"
            return
        }
        currentTask = Task { @MainActor in
            await work()
            self.currentTask = nil
            if !self.queuedURLs.isEmpty {
                let urls = self.queuedURLs
                self.queuedURLs = []
                self.add(urls)
            }
        }
    }

    // MARK: - Batches

    /// Loads files and folders; returns when done. Items already loaded are skipped; rows
    /// for items that failed to load (or were never loaded) are loaded again in place.
    public func addAndWait(_ urls: [URL]) async {
        guard beginBatch() else { return }
        defer { endBatch() }
        let files: [URL]
        do {
            files = try await service.expand(urls)
        } catch {
            statusMessage = "Could not read the dropped items: \(Self.message(error))"
            return
        }
        var seen: Set<URL> = []
        let unique = files.filter { seen.insert($0.standardizedFileURL).inserted }
        var existing: [URL: Int] = [:]
        for (index, row) in rows.enumerated() {
            existing[row.url.standardizedFileURL] = existing[row.url.standardizedFileURL] ?? index
        }
        var jobs: [(StemRow.ID, URL)] = []
        var retried: [Int] = []
        var newRows: [StemRow] = []
        for url in unique {
            if let index = existing[url.standardizedFileURL] {
                guard rows[index].snapshot == nil else { continue }  // already loaded
                retried.append(index)  // retried in place: same row, same position
                jobs.append((rows[index].id, rows[index].url))
            } else {
                let row = StemRow(url: url)
                newRows.append(row)
                jobs.append((row.id, url))
            }
        }
        guard rows.count + newRows.count <= FileWorker.maxFiles else {
            statusMessage = "Not added: the table holds at most \(FileWorker.maxFiles) files"
            return
        }
        for index in retried {
            rows[index].error = nil
        }
        rows.append(contentsOf: newRows)
        let added = Set(newRows.map(\.id))
        let service = self.service
        let outcome = await runBatch(label: "Loading", inputs: jobs) { job in
            try await service.load(job.1)
        } apply: { job, result in
            guard let index = self.rows.firstIndex(where: { $0.id == job.0 }) else { return }
            switch result {
            case let .success(snapshot):
                self.rows[index].snapshot = snapshot
                self.rows[index].draft = BextDraft(snapshot.bext)
                self.rows[index].error = nil
            case let .failure(error):
                self.rows[index].error = Self.message(error)
            }
        }
        // New rows that never started are removed, so dropping the items again loads them;
        // retried rows that never started keep their place and say so.
        let notStarted = Set(outcome.notStarted.map { $0.0 })
        rows.removeAll { notStarted.contains($0.id) && added.contains($0.id) }
        selection = selection.filter { id in rows.contains { $0.id == id } }
        for index in rows.indices where notStarted.contains(rows[index].id) {
            rows[index].error = "Not loaded: cancelled"
        }
        statusMessage = "Loaded \(outcome.succeeded) of \(jobs.count) files" + outcome.suffix
        // Anything typed into the inspector while the batch ran is kept (see loadDraftFromSelection).
        loadDraftFromSelection()
    }

    /// Asks for write access to each folder that lacks it; returns the folders still without.
    func foldersWithoutAccess(for urls: [URL]) async -> Set<URL> {
        var missing: Set<URL> = []
        for folder in Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL }) {
            if await service.canWrite(in: folder) { continue }
            if let folderAccess, let granted = await folderAccess.requestAccess(to: folder) {
                await service.grantAccess([granted])
                if await service.canWrite(in: folder) { continue }
            }
            missing.insert(folder)
        }
        return missing
    }

    /// Saves every row with unsaved edits; returns when done.
    public func saveChangesAndWait() async {
        guard beginBatch() else { return }
        defer { endBatch() }
        var jobs: [(StemRow.ID, URL, Bext)] = []
        var invalid = 0
        for index in rows.indices where rows[index].isDirty {
            guard let snapshot = rows[index].snapshot else { continue }
            do {
                jobs.append((rows[index].id, rows[index].url, try rows[index].draft.applied(to: snapshot.bext)))
            } catch {
                setOtherError(Self.message(error), at: index)
                invalid += 1
            }
        }
        // A save may need a rewrite next to the file, so ask for folder access first. Files in
        // folders without access are still tried: an in-place write needs only the file.
        let missing = await foldersWithoutAccess(for: jobs.map { $0.1 })
        let service = self.service
        var outcome = await runBatch(label: "Saving", inputs: jobs) { job in
            let report = try await service.save(job.2, to: job.1)
            // The save and the reload are reported separately: a failed reload must not hide
            // a write that happened.
            do {
                return (report, Result<StemSnapshot, any Error>.success(try await service.load(job.1)))
            } catch {
                return (report, Result<StemSnapshot, any Error>.failure(error))
            }
        } apply: { job, result in
            guard let index = self.rows.firstIndex(where: { $0.id == job.0 }) else { return }
            switch result {
            case let .success((report, reload)):
                let loadedHash = self.rows[index].snapshot?.audioSHA256
                self.rows[index].isDirty = false
                self.setOtherError(nil, at: index)
                switch reload {
                case let .success(reloaded):
                    self.rows[index].badge = Self.badge(report: report, loadedHash: loadedHash, reloadedHash: reloaded.audioSHA256)
                    self.rows[index].snapshot = reloaded
                    self.rows[index].draft = BextDraft(reloaded.bext)
                case let .failure(error):
                    self.rows[index].badge = Self.badge(report: report, loadedHash: loadedHash, reloadedHash: report.audioSHA256After ?? "")
                    // The file holds the bext that was written; record it so later edits build on it.
                    if let old = self.rows[index].snapshot {
                        self.rows[index].snapshot = StemSnapshot(
                            url: old.url, container: old.container, channels: old.channels, sampleRate: old.sampleRate,
                            bitDepth: old.bitDepth, encoding: old.encoding, durationSeconds: old.durationSeconds,
                            bext: job.2, hasIXML: old.hasIXML, audioSHA256: old.audioSHA256)
                    }
                    self.rows[index].draft = BextDraft(job.2)
                    self.setOtherError("Saved, but reading the file back failed: " + Self.message(error), at: index)
                }
            case let .failure(error):
                var text = Self.message(error)
                let folder = job.1.deletingLastPathComponent().standardizedFileURL
                // The folder hint is added only for file system errors, the kind a missing
                // folder grant causes, not for format errors in the file itself.
                if missing.contains(folder), let waveError = error as? WaveError, case .io = waveError {
                    text = FileWorkerError.noFolderAccess(folder.lastPathComponent).description + " (" + text + ")"
                }
                self.rows[index].badge = .failed(text)
                self.setOtherError(text, at: index)
            }
        }
        outcome.failed += invalid
        statusMessage = "Saved \(outcome.succeeded) of \(jobs.count + invalid) files" + outcome.suffix
    }

    /// Renames loaded rows to their template names; returns when done.
    public func applyNamingAndWait() async {
        guard beginBatch() else { return }
        defer { endBatch() }
        var planned: [(StemRow.ID, URL, String)] = []
        for item in namingPreview {
            guard let index = rows.firstIndex(where: { $0.id == item.id }) else { continue }
            if let problem = item.problem {
                setRenameError(problem, at: index)
            } else if let name = item.newName, name != item.oldName {
                planned.append((item.id, rows[index].url, name))
            } else {
                setRenameError(nil, at: index)  // already has its template name
            }
        }
        // A rename changes the folder, so it needs folder access; rows without it are skipped.
        let missing = await foldersWithoutAccess(for: planned.map { $0.1 })
        var jobs: [(StemRow.ID, URL, String)] = []
        for job in planned {
            let folder = job.1.deletingLastPathComponent().standardizedFileURL
            if missing.contains(folder), let index = rows.firstIndex(where: { $0.id == job.0 }) {
                setRenameError(FileWorkerError.noFolderAccess(folder.lastPathComponent).description, at: index)
            } else {
                jobs.append(job)
            }
        }
        let service = self.service
        let outcome = await runBatch(label: "Renaming", inputs: jobs) { job in
            try await service.rename(job.1, to: job.2)
        } apply: { job, result in
            guard let index = self.rows.firstIndex(where: { $0.id == job.0 }) else { return }
            switch result {
            case let .success(url):
                self.rows[index].url = url
                self.setRenameError(nil, at: index)
            case let .failure(error):
                self.setRenameError(Self.message(error), at: index)
            }
        }
        statusMessage = "Renamed \(outcome.succeeded) of \(jobs.count) files" + outcome.suffix
    }

    static let renamePrefix = "Rename: "

    /// Splits a row's error into its load or save part and its rename part.
    func errorParts(at index: Int) -> (other: String?, rename: String?) {
        let current = rows[index].error ?? ""
        if current.isEmpty { return (nil, nil) }
        if current.hasPrefix(Self.renamePrefix) { return (nil, String(current.dropFirst(Self.renamePrefix.count))) }
        if let range = current.range(of: "; " + Self.renamePrefix) {
            return (String(current[..<range.lowerBound]), String(current[range.upperBound...]))
        }
        return (current, nil)
    }

    /// Joins the two parts back into the row's error.
    func setErrorParts(other: String?, rename: String?, at index: Int) {
        let renameText = rename.map { Self.renamePrefix + $0 }
        switch (other, renameText) {
        case (nil, nil): rows[index].error = nil
        case let (nil, rename?): rows[index].error = rename
        case let (other?, nil): rows[index].error = other
        case let (other?, rename?): rows[index].error = other + "; " + rename
        }
    }

    /// Sets or clears the load or save part of a row's error and keeps the rename part.
    func setOtherError(_ message: String?, at index: Int) {
        setErrorParts(other: message, rename: errorParts(at: index).rename, at: index)
    }

    /// Sets or clears the rename part of a row's error and keeps any other error (a load or
    /// save failure) in front of it.
    func setRenameError(_ message: String?, at index: Int) {
        setErrorParts(other: errorParts(at: index).other, rename: message, at: index)
    }

    struct Outcome<Input> {
        var succeeded = 0
        var failed = 0
        var notStarted: [Input] = []
        var suffix: String {
            var parts: [String] = []
            if failed > 0 { parts.append("\(failed) failed") }
            if !notStarted.isEmpty { parts.append("\(notStarted.count) not started (cancelled)") }
            return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
        }
    }

    /// Runs `operation` for every input with at most `maxConcurrent` in flight and applies
    /// each result on the main actor as it arrives. Each operation runs in an unstructured
    /// task, so cancelling the batch never interrupts a file operation that has started.
    private func runBatch<Input: Sendable, Output: Sendable>(
        label: String,
        inputs: [Input],
        operation: @escaping @Sendable (Input) async throws -> Output,
        apply: (Input, Result<Output, any Error>) -> Void
    ) async -> Outcome<Input> {
        var outcome = Outcome<Input>()
        guard !inputs.isEmpty else { return outcome }
        progress = BatchProgress(label: label, completed: 0, total: inputs.count)
        await withTaskGroup(of: (Int, Result<Output, any Error>).self) { group in
            var next = 0
            func schedule() {
                let index = next
                let input = inputs[index]
                next += 1
                group.addTask {
                    let work = Task { try await operation(input) }
                    do {
                        return (index, .success(try await work.value))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            while next < inputs.count, next < maxConcurrent {
                if Task.isCancelled {
                    outcome.notStarted = Array(inputs[next...])
                    next = inputs.count
                    break
                }
                schedule()
            }
            while let (index, result) = await group.next() {
                apply(inputs[index], result)
                if case .success = result { outcome.succeeded += 1 } else { outcome.failed += 1 }
                progress?.completed += 1
                if next < inputs.count {
                    if Task.isCancelled {
                        outcome.notStarted = Array(inputs[next...])
                        next = inputs.count
                    } else {
                        schedule()
                    }
                }
            }
        }
        progress = nil
        return outcome
    }

    // MARK: - Editing and naming

    /// Loads the first selected row (in table order) into the inspector. Fields edited but not
    /// yet applied are carried over onto the newly loaded values; every other field shows the
    /// new row's value, and edits are then measured against the new row.
    public func loadDraftFromSelection() {
        guard let row = rows.first(where: { selection.contains($0.id) }) else { return }
        let edited = Self.draftFields.filter { inspectorDraft[keyPath: $0] != inspectorBaseline[keyPath: $0] }
        var draft = row.draft
        for field in edited {
            draft[keyPath: field] = inspectorDraft[keyPath: field]
        }
        inspectorBaseline = row.draft
        inspectorDraft = draft
    }

    /// Throws away inspector edits that have not been applied.
    public func discardInspectorEdits() {
        inspectorDraft = inspectorBaseline
    }

    /// The draft fields, for comparing and copying field by field.
    static var draftFields: [WritableKeyPath<BextDraft, String>] {
        [\.description, \.originator, \.originatorReference, \.originationDate, \.originationTime, \.timeReference]
    }

    /// Copies the fields edited in the inspector to every selected row and marks changed rows
    /// unsaved. Fields the user did not touch keep each row's own value, so changing the
    /// originator of ten files does not overwrite their ten descriptions.
    public func applyDraftToSelection() {
        // A running save replaces each row's draft when it finishes; edits are applied when idle.
        guard !isBusy else {
            statusMessage = "Busy: apply the edit when the current batch has finished"
            return
        }
        let edited = Self.draftFields.filter { inspectorDraft[keyPath: $0] != inspectorBaseline[keyPath: $0] }
        guard !edited.isEmpty else { return }
        for index in rows.indices where selection.contains(rows[index].id) && rows[index].snapshot != nil {
            var draft = rows[index].draft
            for field in edited {
                draft[keyPath: field] = inspectorDraft[keyPath: field]
            }
            if draft != rows[index].draft {
                rows[index].draft = draft
                rows[index].isDirty = draft != BextDraft(rows[index].snapshot?.bext)
                setOtherError(nil, at: index)  // an earlier validation or save error no longer applies
            }
        }
        inspectorBaseline = inspectorDraft
    }

    /// New names for every loaded row, with problems (template errors, duplicates, clashes).
    /// Rows that are not loaded are not renamed and do not appear.
    public var namingPreview: [NamingPreviewItem] {
        let templateValue = NamingTemplate(template)
        let loaded = rows.filter { $0.snapshot != nil }
        var items: [NamingPreviewItem] = []
        for (offset, row) in loaded.enumerated() {
            let context = NamingTemplate.Context(
                project: project, index: offset + 1, total: loaded.count,
                description: row.draft.description, originator: row.draft.originator, originalName: row.name)
            do {
                let newName = try templateValue.render(context)
                items.append(NamingPreviewItem(id: row.id, oldName: row.name, newName: newName, problem: nil))
            } catch {
                items.append(NamingPreviewItem(id: row.id, oldName: row.name, newName: nil, problem: Self.message(error)))
            }
        }
        // Names clash only within one folder.
        func key(_ url: URL, _ name: String) -> String {
            url.deletingLastPathComponent().standardizedFileURL.path + "/" + name.lowercased()
        }
        var counts: [String: Int] = [:]
        for (offset, item) in items.enumerated() {
            if let name = item.newName { counts[key(loaded[offset].url, name), default: 0] += 1 }
        }
        let currentNames = Set(rows.map { key($0.url, $0.name) })
        for (offset, item) in items.enumerated() {
            guard let name = item.newName else { continue }
            let sameFile = name.lowercased() == item.oldName.lowercased()
            if (counts[key(loaded[offset].url, name)] ?? 0) > 1 {
                items[offset].problem = "duplicate name \(name)"
            } else if !sameFile, currentNames.contains(key(loaded[offset].url, name)) {
                items[offset].problem = "\(name) is the current name of another file"
            }
        }
        return items
    }

    // MARK: - Helpers

    static func badge(report: WriteReport, loadedHash: String?, reloadedHash: String) -> IntegrityBadge {
        guard let after = report.audioSHA256After, let before = report.audioSHA256Before else {
            return .failed("integrity hashes were not taken")
        }
        guard before == after else {
            return .failed("audio hash changed during the write: \(before.prefix(12)) became \(after.prefix(12))")
        }
        guard after == reloadedHash else {
            return .failed("audio hash on reload \(reloadedHash.prefix(12)) differs from \(after.prefix(12))")
        }
        guard let loadedHash, loadedHash == after else {
            return .failed("audio hash differs from the hash taken at load time")
        }
        return .verified(sha256: after, path: report.path)
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case let error as WaveError: return error.description
        case let error as FileWorkerError: return error.description
        case let error as NamingError: return error.description
        default: return error.localizedDescription
        }
    }
}
