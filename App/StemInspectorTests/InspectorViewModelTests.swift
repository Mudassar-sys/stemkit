import Foundation
import StemInspectorCore
import Testing
import WaveContainer

/// An in-memory file service: no disk, adjustable failures and delays, and a record of how
/// many operations ran at once.
actor FakeFiles: StemFileService {
    var snapshots: [URL: StemSnapshot] = [:]
    var failingLoads: Set<String> = []
    var changeAudioOnSave = false
    let delay: Duration
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var saved: [URL: Bext] = [:]
    private(set) var renamed: [String] = []
    var unwritableFolders: Set<String> = []
    private(set) var granted: [URL] = []

    func setUnwritable(_ folders: Set<String>) { unwritableFolders = folders }

    init(count: Int, delay: Duration = .zero) {
        self.delay = delay
        for i in 1 ... count {
            let url = URL(fileURLWithPath: "/stems/take\(i < 10 ? "0" : "")\(i).wav")
            var bext = Bext()
            bext.description = "Take \(i)"
            bext.originator = "Desk A"
            snapshots[url] = StemSnapshot(
                url: url, container: "RIFF", channels: 2, sampleRate: 48_000, bitDepth: 24, encoding: "PCM 24-bit",
                durationSeconds: 10, bext: bext, hasIXML: i % 2 == 0, audioSHA256: "hash-\(i)")
        }
    }

    var urls: [URL] { snapshots.keys.sorted { $0.path < $1.path } }

    func setFailingLoads(_ names: Set<String>) { failingLoads = names }
    func setChangeAudioOnSave(_ value: Bool) { changeAudioOnSave = value }

    private func work() async throws {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
    }

    func expand(_ urls: [URL]) async throws -> [URL] {
        urls.sorted { $0.path < $1.path }
    }

    func load(_ url: URL) async throws -> StemSnapshot {
        try await work()
        if failingLoads.contains(url.lastPathComponent) { throw WaveError.notRIFF(found: "JUNK") }
        guard let snapshot = snapshots[url] else { throw WaveError.io("no such file") }
        return snapshot
    }

    func save(_ bext: Bext, to url: URL) async throws -> WriteReport {
        try await work()
        guard let old = snapshots[url] else { throw WaveError.io("no such file") }
        saved[url] = bext
        let after = changeAudioOnSave ? old.audioSHA256 + "-changed" : old.audioSHA256
        snapshots[url] = StemSnapshot(
            url: url, container: old.container, channels: old.channels, sampleRate: old.sampleRate,
            bitDepth: old.bitDepth, encoding: old.encoding, durationSeconds: old.durationSeconds, bext: bext,
            hasIXML: old.hasIXML, audioSHA256: after)
        return WriteReport(path: .inPlace, audioSHA256Before: old.audioSHA256, audioSHA256After: after)
    }

    func canWrite(in folder: URL) async -> Bool {
        !unwritableFolders.contains(folder.path)
    }

    func grantAccess(_ urls: [URL]) async {
        granted.append(contentsOf: urls)
        for url in urls { unwritableFolders.remove(url.path) }
    }

    func rename(_ url: URL, to fileName: String) async throws -> URL {
        try await work()
        renamed.append(fileName)
        return url.deletingLastPathComponent().appendingPathComponent(fileName)
    }
}

/// Answers folder access requests without a panel and records them.
@MainActor
final class StubFolderAccess: FolderAccessRequester {
    var answer: URL?
    private(set) var asked: [URL] = []

    init(answer: URL?) {
        self.answer = answer
    }

    func requestAccess(to folder: URL) async -> URL? {
        asked.append(folder)
        return answer
    }
}

@MainActor
@Suite("Inspector view model")
struct InspectorViewModelTests {
    @Test("Loading fills the table and records each failure on its own row")
    func loadAndPerFileErrors() async {
        let files = FakeFiles(count: 5)
        await files.setFailingLoads(["take03.wav"])
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        #expect(model.rows.count == 5)
        #expect(model.rows.filter { $0.snapshot != nil }.count == 4)
        let failed = model.rows.filter { $0.error != nil }
        #expect(failed.map(\.name) == ["take03.wav"])
        #expect(model.statusMessage.contains("Loaded 4 of 5"))
        #expect(model.statusMessage.contains("1 failed"))
        #expect(model.rows[0].draft.description == "Take 1")
        #expect(model.progress == nil)

        // Dropping the same files again retries the failed one and skips the loaded ones.
        let retriedID = model.rows[2].id
        await files.setFailingLoads([])
        await model.addAndWait(await files.urls)
        #expect(model.rows.count == 5)
        #expect(model.rows.allSatisfy { $0.snapshot != nil && $0.error == nil })
        #expect(model.statusMessage.contains("Loaded 1 of 1"))
        // The retried row keeps its place and identity.
        #expect(model.rows[2].name == "take03.wav")
        #expect(model.rows[2].id == retriedID)
    }

    @Test("Text typed in the inspector survives the end of a batch")
    func inspectorEditsSurviveBatch() async {
        let files = FakeFiles(count: 4)
        let model = InspectorViewModel(service: files)
        let urls = await files.urls
        await model.addAndWait(Array(urls.prefix(2)))
        model.selection = [model.rows[0].id]
        model.loadDraftFromSelection()
        model.inspectorDraft.description = "typed while loading"
        await model.addAndWait(Array(urls.suffix(2)))
        #expect(model.inspectorDraft.description == "typed while loading")
    }

    @Test("A selection change keeps unapplied edits and shows the new row's other fields")
    func selectionRebase() async {
        let files = FakeFiles(count: 2)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.selection = [model.rows[0].id]
        model.loadDraftFromSelection()
        model.inspectorDraft.description = "typed"
        model.selection = [model.rows[1].id]
        model.loadDraftFromSelection()
        #expect(model.inspectorDraft.description == "typed")
        #expect(model.inspectorBaseline.description == "Take 2")
        #expect(model.inspectorDraft.timeReference == model.rows[1].draft.timeReference)
        model.discardInspectorEdits()
        #expect(model.inspectorDraft == model.rows[1].draft)
    }

    @Test("Cancel also drops items queued behind the batch")
    func cancelClearsQueue() async {
        let files = FakeFiles(count: 10, delay: .milliseconds(30))
        let model = InspectorViewModel(service: files, maxConcurrent: 1)
        let urls = await files.urls
        model.add(Array(urls.prefix(6)))
        model.add(Array(urls.suffix(4)))
        #expect(model.queuedURLs.count == 4)
        model.cancel()
        #expect(model.queuedURLs.isEmpty)
        await model.waitForCurrentBatch()
        #expect(!model.rows.contains { urls.suffix(4).contains($0.url) })
    }

    @Test("Without folder access the user is asked; a declined request skips the renames")
    func folderAccess() async {
        let files = FakeFiles(count: 2)
        await files.setUnwritable(["/stems"])
        let declined = StubFolderAccess(answer: nil)
        let model = InspectorViewModel(service: files, folderAccess: declined)
        await model.addAndWait(await files.urls)
        model.template = "{index}"
        await model.applyNamingAndWait()
        #expect(declined.asked.map(\.path) == ["/stems"])
        #expect(await files.renamed.isEmpty)
        #expect(model.rows.allSatisfy { $0.error?.contains("no write access") == true })

        let granted = StubFolderAccess(answer: URL(fileURLWithPath: "/stems"))
        let model2 = InspectorViewModel(service: files, folderAccess: granted)
        await model2.addAndWait(await files.urls)
        model2.template = "{index}"
        await model2.applyNamingAndWait()
        #expect(granted.asked.count == 1)
        #expect(await files.renamed.sorted() == ["01.wav", "02.wav"])
    }

    @Test("A drop that names the same file twice gives one row")
    func duplicateDrop() async {
        let files = FakeFiles(count: 4)
        let model = InspectorViewModel(service: files)
        let urls = await files.urls
        await model.addAndWait(urls + urls)
        #expect(model.rows.count == 4)
        #expect(Set(model.rows.map(\.id)).count == 4)
    }

    @Test("Files dropped while a batch runs are queued and loaded afterwards")
    func queuedDrop() async {
        let files = FakeFiles(count: 12, delay: .milliseconds(20))
        let model = InspectorViewModel(service: files, maxConcurrent: 2)
        let urls = await files.urls
        model.add(Array(urls.prefix(8)))
        model.add(Array(urls.suffix(4)))
        #expect(model.queuedURLs.count == 4)
        await model.waitForCurrentBatch()
        #expect(model.rows.count == 12)
        #expect(model.rows.allSatisfy { $0.snapshot != nil })
        #expect(model.queuedURLs.isEmpty)
    }

    @Test("At most maxConcurrent files are in flight")
    func boundedParallelism() async {
        let files = FakeFiles(count: 12, delay: .milliseconds(30))
        let model = InspectorViewModel(service: files, maxConcurrent: 3)
        await model.addAndWait(await files.urls)
        let peak = await files.maxInFlight
        #expect(peak == 3)
        #expect(model.rows.allSatisfy { $0.snapshot != nil })
    }

    @Test("Cancel stops scheduling new files and reports how many did not start")
    func cancellation() async throws {
        let files = FakeFiles(count: 30, delay: .milliseconds(60))
        let model = InspectorViewModel(service: files, maxConcurrent: 2)
        model.add(await files.urls)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.isBusy)
        model.cancel()
        await model.waitForCurrentBatch()
        let loaded = model.rows.filter { $0.snapshot != nil }.count
        #expect(loaded > 0)
        #expect(loaded < 30)
        // Files in flight at the moment of cancel finish; files never started leave no row.
        #expect(model.rows.count == loaded)
        #expect(model.rows.allSatisfy { $0.error == nil })
        #expect(model.statusMessage.contains("not started (cancelled)"))
        #expect(!model.isBusy)
        // Dropping the folder again loads the rest.
        await model.addAndWait(await files.urls)
        #expect(model.rows.count == 30)
        #expect(model.rows.allSatisfy { $0.snapshot != nil })
    }

    @Test("Saving edits shows a verified badge when the audio hash is unchanged")
    func saveVerified() async {
        let files = FakeFiles(count: 3)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.selection = [model.rows[1].id]
        model.loadDraftFromSelection()
        model.inspectorDraft.description = "Lead vocal, take 2"
        model.applyDraftToSelection()
        #expect(model.dirtyCount == 1)
        await model.saveChangesAndWait()
        #expect(model.dirtyCount == 0)
        #expect(model.rows[1].badge == .verified(sha256: "hash-2", path: .inPlace))
        #expect(model.rows[0].badge == .notSaved)
        #expect(await files.saved.values.map(\.description) == ["Lead vocal, take 2"])
    }

    @Test("Editing one field for several selected files changes only that field")
    func multiSelectionAppliesOnlyEditedFields() async {
        let files = FakeFiles(count: 3)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.selection = Set(model.rows.map(\.id))
        model.loadDraftFromSelection()
        #expect(model.inspectorDraft.description == "Take 1")
        model.inspectorDraft.originator = "Desk C"
        model.applyDraftToSelection()
        #expect(model.rows.map(\.draft.originator) == ["Desk C", "Desk C", "Desk C"])
        #expect(model.rows.map(\.draft.description) == ["Take 1", "Take 2", "Take 3"])
        #expect(model.dirtyCount == 3)
        await model.saveChangesAndWait()
        #expect(await files.saved.values.map(\.description).sorted() == ["Take 1", "Take 2", "Take 3"])
    }

    @Test("A changed audio hash after a save is shown as a failed check")
    func saveDetectsChangedAudio() async {
        let files = FakeFiles(count: 1)
        await files.setChangeAudioOnSave(true)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.selection = [model.rows[0].id]
        model.loadDraftFromSelection()
        model.inspectorDraft.originator = "Desk B"
        model.applyDraftToSelection()
        await model.saveChangesAndWait()
        guard case .failed = model.rows[0].badge else {
            Issue.record("expected a failed badge, got \(model.rows[0].badge)")
            return
        }
    }

    @Test("A value that does not fit bext is reported on the row and nothing is written")
    func invalidDraft() async {
        let files = FakeFiles(count: 1)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.selection = [model.rows[0].id]
        model.loadDraftFromSelection()
        model.inspectorDraft.description = String(repeating: "x", count: 300)
        model.applyDraftToSelection()
        await model.saveChangesAndWait()
        #expect(model.rows[0].error?.contains("Description") == true)
        #expect(await files.saved.isEmpty)
    }

    @Test("Naming preview, duplicate detection and apply")
    func naming() async {
        let files = FakeFiles(count: 3)
        let model = InspectorViewModel(service: files)
        await model.addAndWait(await files.urls)
        model.project = "Feature Mix"
        model.template = "{project}_{index}_{description}"
        #expect(model.namingPreview.map(\.newName) == ["Feature_Mix_01_Take_1.wav", "Feature_Mix_02_Take_2.wav", "Feature_Mix_03_Take_3.wav"])
        #expect(model.namingPreview.allSatisfy { $0.problem == nil })

        model.template = "{project}"
        #expect(model.namingPreview.allSatisfy { $0.problem?.contains("duplicate") == true })

        model.template = "{project}_{unknown}"
        #expect(model.namingPreview.allSatisfy { $0.problem == "unknown token {unknown}" })

        model.template = "{index}-{originator}"
        await model.applyNamingAndWait()
        #expect(await files.renamed.sorted() == ["01-Desk_A.wav", "02-Desk_A.wav", "03-Desk_A.wav"])
        #expect(model.rows.map(\.name) == ["01-Desk_A.wav", "02-Desk_A.wav", "03-Desk_A.wav"])
    }
}
