import Foundation
import StemInspectorCore
import Testing
import WaveContainer

/// Builds real WAVE files on disk for the core and screenshot tests.
enum DiskStems {
    static func wave(channels: UInt16, rate: UInt32, bits: UInt16, tag: UInt16 = 1, seconds: Double) -> [UInt8] {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
        let align = channels * (bits / 8)
        let frames = Int(Double(rate) * seconds)
        let dataSize = frames * Int(align)
        var fmt = le16(tag) + le16(channels) + le32(rate) + le32(rate * UInt32(align)) + le16(align) + le16(bits)
        fmt = Array("fmt ".utf8) + le32(UInt32(fmt.count)) + fmt
        var audio = [UInt8](repeating: 0, count: dataSize)
        for i in 0 ..< dataSize { audio[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        var data = Array("data".utf8) + le32(UInt32(dataSize)) + audio
        if dataSize % 2 == 1 { data.append(0) }
        let body = Array("WAVE".utf8) + fmt + data
        return Array("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    /// Writes a WAV and gives it a bext chunk through the library's own writer.
    static func make(_ folder: URL, name: String, channels: UInt16, rate: UInt32, bits: UInt16, tag: UInt16 = 1,
                     seconds: Double, description: String, originator: String, timeReference: UInt64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(wave(channels: channels, rate: rate, bits: bits, tag: tag, seconds: seconds)).write(to: url)
        var bext = Bext()
        bext.description = description
        bext.originator = originator
        bext.originationDate = "2026-10-06"
        bext.originationTime = "10:00:00"
        bext.timeReference = timeReference
        bext.codingHistory = "A=PCM,F=\(rate),W=\(bits),M=\(channels == 1 ? "mono" : "stereo")\r\n"
        _ = try MetadataWriter.apply(MetadataChanges(bext: bext), to: url)
        return url
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stemkit-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Naming template")
struct NamingTemplateTests {
    func context(_ index: Int, total: Int = 3, description: String = "Lead Vocal", name: String = "take.wav") -> NamingTemplate.Context {
        NamingTemplate.Context(project: "Feature Mix", index: index, total: total, description: description,
                               originator: "Desk A", originalName: name)
    }

    @Test("Tokens render and the extension is kept")
    func tokens() throws {
        #expect(try NamingTemplate("{project}_{index}_{description}").render(context(1)) == "Feature_Mix_01_Lead_Vocal.wav")
        #expect(try NamingTemplate("{name}-{originator}").render(context(2)) == "take-Desk_A.wav")
        #expect(try NamingTemplate("{index}").render(context(7, total: 120)) == "007.wav")
        #expect(try NamingTemplate("{index}").render(context(7, total: 120, name: "noext")) == "007")
    }

    @Test("Values are sanitised for file names")
    func sanitise() throws {
        #expect(try NamingTemplate("{description}").render(context(1, description: "  a/b: c\td  ")) == "ab_c_d.wav")
        #expect(NamingTemplate.sanitise("..hidden") == "hidden")
        #expect(NamingTemplate.sanitise("Dialogue, boom? <take 2>") == "Dialogue_boom_take_2")
    }

    @Test("Errors are typed")
    func errors() {
        #expect(throws: NamingError.unknownToken("take")) { try NamingTemplate("{take}").render(context(1)) }
        #expect(throws: NamingError.unclosedToken) { try NamingTemplate("{project").render(context(1)) }
        #expect(throws: NamingError.emptyName) { try NamingTemplate("{description}").render(context(1, description: "  ")) }
    }
}

@Suite("File worker on disk")
struct FileWorkerTests {
    @Test("Expand, load, save with a verified hash, and rename")
    func roundTrip() async throws {
        let folder = try DiskStems.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try DiskStems.make(folder, name: "b.wav", channels: 2, rate: 48_000, bits: 24, seconds: 0.5,
                               description: "B", originator: "x", timeReference: 1)
        _ = try DiskStems.make(folder, name: "a.wav", channels: 1, rate: 44_100, bits: 16, seconds: 0.25,
                               description: "A", originator: "x", timeReference: 2)
        _ = try DiskStems.make(sub, name: "c.WAV", channels: 2, rate: 96_000, bits: 32, tag: 3, seconds: 0.1,
                               description: "C", originator: "x", timeReference: 3)
        try Data("not audio".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let worker = FileWorker()
        let files = try await worker.expand([folder])
        #expect(files.map(\.lastPathComponent) == ["a.wav", "b.wav", "c.WAV"])

        let snapshot = try await worker.load(files[2])
        #expect(snapshot.encoding == "IEEE float 32-bit")
        #expect(snapshot.channels == 2)
        #expect(snapshot.sampleRate == 96_000)
        #expect(snapshot.bext?.description == "C")

        var bext = try #require(snapshot.bext)
        bext.description = "C edited"
        let report = try await worker.save(bext, to: files[2])
        #expect(report.audioUnchanged)
        #expect(report.audioSHA256After == snapshot.audioSHA256)
        let reloaded = try await worker.load(files[2])
        #expect(reloaded.bext?.description == "C edited")
        #expect(reloaded.audioSHA256 == snapshot.audioSHA256)
        #expect(try AudioIntegrity.dataChunkSHA256(of: files[2]) == snapshot.audioSHA256)
        #expect(await worker.canWrite(in: folder))

        let renamed = try await worker.rename(files[0], to: "renamed.wav")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        await #expect(throws: FileWorkerError.destinationExists("b.wav")) {
            _ = try await worker.rename(renamed, to: "b.wav")
        }
        await #expect(throws: FileWorkerError.invalidFileName("x/y.wav")) {
            _ = try await worker.rename(renamed, to: "x/y.wav")
        }
        // A change of letter case only goes through a temporary name.
        let recased = try await worker.rename(renamed, to: "Renamed.wav")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains("Renamed.wav"))
        #expect(!names.contains { $0.hasPrefix(".stemkit-rename-") })
        #expect(FileManager.default.fileExists(atPath: recased.path))
    }

    @MainActor
    @Test("View model over the real worker: load a folder, edit, save, badge verified")
    func viewModelOnDisk() async throws {
        let folder = try DiskStems.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 1 ... 6 {
            _ = try DiskStems.make(folder, name: "stem\(i).wav", channels: 2, rate: 48_000, bits: 24, seconds: 0.2,
                                   description: "Stem \(i)", originator: "Desk A", timeReference: UInt64(i) * 48_000)
        }
        let model = InspectorViewModel(service: FileWorker(), maxConcurrent: 3)
        await model.addAndWait([folder])
        #expect(model.rows.count == 6)
        #expect(model.rows.allSatisfy { $0.snapshot != nil && $0.error == nil })
        model.selection = Set(model.rows.prefix(2).map(\.id))
        model.loadDraftFromSelection()
        model.inspectorDraft.originator = "Desk B"
        model.applyDraftToSelection()
        await model.saveChangesAndWait()
        for row in model.rows.prefix(2) {
            guard case let .verified(sha256, path) = row.badge else {
                Issue.record("expected verified, got \(row.badge)")
                continue
            }
            #expect(sha256 == row.snapshot?.audioSHA256)
            #expect(path == .inPlace)
            #expect(row.snapshot?.bext?.originator == "Desk B")
        }
        #expect(model.rows.dropFirst(2).allSatisfy { $0.badge == .notSaved })
    }
}
