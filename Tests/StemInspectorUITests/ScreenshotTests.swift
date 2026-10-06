import AppKit
import Foundation
import StemInspectorCore
import StemInspectorUI
import SwiftUI
import Testing
import WaveContainer

/// Renders the app's main view (`StemInspectorView`), driven by the real file worker over real
/// WAV files, in light and dark appearance, and writes PNG files to `STEMKIT_SCREENSHOT_DIR`
/// (or a temporary folder). The view is hosted in a borderless window, so the window's title
/// bar and toolbar are not in the image. CI uploads the files as an artifact, and the files in
/// docs/screenshots/ are copies of that artifact.
@MainActor
@Suite("Screenshots")
struct ScreenshotTests {
    struct RenderError: Error, CustomStringConvertible {
        let description: String
    }

    static func makeStems(in folder: URL) throws {
        func wave(channels: UInt16, rate: UInt32, bits: UInt16, tag: UInt16, frames: Int) -> [UInt8] {
            func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
            func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
            let align = channels * (bits / 8)
            let size = frames * Int(align)
            let fmt = le16(tag) + le16(channels) + le32(rate) + le32(rate * UInt32(align)) + le16(align) + le16(bits)
            let body = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(UInt32(size))
                + [UInt8](repeating: 0, count: size)
            return Array("RIFF".utf8) + le32(UInt32(body.count)) + body
        }
        let stems: [(String, UInt16, UInt32, UInt16, UInt16, Double, String)] = [
            ("dialogue_boom.wav", 1, 48_000, 24, 1, 2.0, "Dialogue, boom"),
            ("dialogue_lav.wav", 1, 48_000, 24, 1, 2.0, "Dialogue, lavalier"),
            ("music_stereo.wav", 2, 48_000, 24, 1, 1.5, "Score cue 3M2"),
            ("effects_stereo.wav", 2, 96_000, 32, 3, 1.0, "Effects, doors"),
            ("ambience_51.wav", 6, 48_000, 24, 1, 0.5, "Ambience, street"),
            ("foley.wav", 2, 44_100, 16, 1, 1.0, "Foley, footsteps"),
        ]
        for (index, stem) in stems.enumerated() {
            let url = folder.appendingPathComponent(stem.0)
            try Data(wave(channels: stem.1, rate: stem.2, bits: stem.3, tag: stem.4, frames: Int(Double(stem.2) * stem.5))).write(to: url)
            var bext = Bext()
            bext.description = stem.6
            bext.originator = "Stage B"
            bext.originationDate = "2026-10-06"
            bext.originationTime = "10:00:00"
            bext.timeReference = UInt64(index) * 172_800_000
            _ = try MetadataWriter.apply(MetadataChanges(bext: bext), to: url)
            if index % 2 == 0 {
                let xml = "<BWFXML><IXML_VERSION>3.01</IXML_VERSION><PROJECT>Feature Mix</PROJECT></BWFXML>"
                _ = try MetadataWriter.apply(MetadataChanges(ixml: IXML(xmlText: xml)), to: url)
            }
        }
    }

    static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name) throws -> Data {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        // Borderless, so the window is not shrunk to fit the runner's small screen.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.setFrame(CGRect(origin: .zero, size: size), display: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0 ..< 10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard hosting.bounds.size == size else {
            throw RenderError(description: "rendered at \(hosting.bounds.size), expected \(size)")
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw RenderError(description: "no bitmap representation")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError(description: "PNG encoding failed")
        }
        // A blank or single colour image means nothing was drawn.
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255), b = UInt32(c.blueComponent * 255)
                    colours.insert(r << 16 | g << 8 | b)
                }
            }
        }
        guard colours.count > 20 else {
            throw RenderError(description: "image has only \(colours.count) colours")
        }
        return png
    }

    @Test("Main window, light and dark, from real files")
    func lightAndDark() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Feature Mix stems \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.makeStems(in: folder)

        let model = InspectorViewModel(service: FileWorker())
        await model.addAndWait([folder])
        #expect(model.rows.count == 6)
        // Edit and save two files so their integrity badges are real.
        model.selection = Set(model.rows.prefix(2).map(\.id))
        model.loadDraftFromSelection()
        model.inspectorDraft.originator = "Stage B, reel 2"
        model.applyDraftToSelection()
        await model.saveChangesAndWait()
        #expect(model.rows.prefix(2).allSatisfy { if case .verified = $0.badge { return true } else { return false } })
        // Only the edited field changed: each file keeps its own description.
        #expect(model.rows.map(\.draft.description) == [
            "Ambience, street", "Dialogue, boom", "Dialogue, lavalier", "Effects, doors", "Foley, footsteps", "Score cue 3M2",
        ])
        #expect(model.rows.prefix(2).allSatisfy { $0.draft.originator == "Stage B, reel 2" })
        model.project = "Feature Mix"
        model.template = "{project}_{index}_{description}"
        model.selection = [model.rows[0].id]
        model.loadDraftFromSelection()

        let output: URL
        if let dir = ProcessInfo.processInfo.environment["STEMKIT_SCREENSHOT_DIR"], !dir.isEmpty {
            output = URL(fileURLWithPath: dir)
        } else {
            output = FileManager.default.temporaryDirectory.appendingPathComponent("stemkit-screenshots")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var digests: [String] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let png = try Self.render(StemInspectorView(model: model), size: CGSize(width: 1440, height: 810), appearance: appearance)
            let url = output.appendingPathComponent("stem-inspector-\(name).png")
            try png.write(to: url)
            let digest = try AudioIntegrity.fileSHA256(of: url)
            digests.append(digest)
            let pixels = NSBitmapImageRep(data: png).map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "unknown"
            print("SCREENSHOT file=\(url.lastPathComponent) pixels=\(pixels) bytes=\(png.count) sha256=\(digest)")
        }
        #expect(digests[0] != digests[1])
    }
}
