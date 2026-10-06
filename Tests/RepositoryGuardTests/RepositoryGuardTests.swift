import Foundation
import Testing

/// Repository content rules, enforced on every text file in the checkout, this file included:
/// no em dash, no client or person names, no contact details, no statement of how long
/// anything took. The list of names is not in the repository in any form: CI passes it from a
/// repository secret in the environment variable STEMKIT_DENIED_NAMES.
@Suite("Repository guards")
struct RepositoryGuardTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let skippedDirectories: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "xcuserdata", "__pycache__", "artifacts"]
    static let binaryExtensions: Set<String> = ["wav", "f32", "s16", "png", "pdf", "zip", "xcuserstate"]
    /// Files CI writes while the tests run (the test log), which are not repository content.
    static let generatedExtensions: Set<String> = ["log"]

    /// Names that must not appear (client, company and person names): one name of one or two
    /// words per line or per comma, compared in lowercase. A hash of a short name can be
    /// reversed by trying candidates, so the names are kept out of the repository entirely.
    static let deniedNames: Set<String> = parseNames(
        ProcessInfo.processInfo.environment["STEMKIT_DENIED_NAMES"] ?? "")

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func parseNames(_ raw: String) -> Set<String> {
        // `isNewline` also covers a CR LF pair, which Swift treats as one character.
        Set(raw.split { $0.isNewline || $0 == "," }
            .map { words(String($0)).joined(separator: " ") }
            .filter { !$0.isEmpty })
    }

    struct TextFile {
        let path: String
        let text: String
    }

    static func textFiles() throws -> [TextFile] {
        var out: [TextFile] = []
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if binaryExtensions.contains(url.pathExtension.lowercased()) { continue }
            if generatedExtensions.contains(url.pathExtension.lowercased()) { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                Issue.record("not UTF-8 text and not a known binary type: \(url.path)")
                continue
            }
            out.append(TextFile(path: String(url.path.dropFirst(root.path.count)), text: text))
        }
        return out
    }

    static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    @Test("The scan covers the repository")
    func coverage() throws {
        let files = try Self.textFiles()
        #expect(files.count > 30)
        #expect(files.contains { $0.path.hasSuffix("README.md") })
        print("GUARD text_files_scanned=\(files.count)")
    }

    // The checks, shared by the repository scan and by the self-test below.

    static func emDashHit(_ text: String) -> Bool {
        text.contains("\u{2014}")
    }

    /// Positions of denied names in `text`. Only positions are reported, so a failing run never
    /// prints a name from the list.
    static func nameHits(_ text: String, denied: Set<String> = RepositoryGuardTests.deniedNames) -> [String] {
        // The repository's own address contains the hosting account's login; it is the
        // location of this code, not a statement about anyone, so it is removed first.
        let cleaned = text.replacingOccurrences(
            of: #"github\.com/[A-Za-z0-9-]+/stemkit"#, with: " ", options: .regularExpression)
        let words = Self.words(cleaned)
        var hits: [String] = []
        for (i, word) in words.enumerated() {
            if denied.contains(word) { hits.append("word \(i)") }
            if i + 1 < words.count, denied.contains(word + " " + words[i + 1]) {
                hits.append("words \(i) and \(i + 1)")
            }
        }
        return hits
    }

    static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#
    static let phonePattern = #"\+\d{1,3}[ .-]?\(?\d{2,4}\)?[ .-]?\d{3,4}[ .-]?\d{3,4}"#
    static let linkPattern = #"(linkedin\.com/in/|wa\.me/|t\.me/|calendly\.com/|sky[p]e:)"#
    static let durationPatterns = [
        #"\b(took|taking|spent|spending|within|in under|in about|in roughly|in just)\s+(about\s+|around\s+|roughly\s+|nearly\s+|only\s+)?\d+(\.\d+)?\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#,
        #"\b\d+(\.\d+)?[- ](man-)?(hours?|days?|weeks?|months?)\b(?!\s*(old|ago))"#,
        #"\b(same|one|two|three|a single)[- ]day\b"#,
        #"\bovernight\b"#,
    ]

    static func contactHits(_ text: String) throws -> [String] {
        var hits = try matches(emailPattern, in: text).filter { !$0.lowercased().hasSuffix(".invalid") }
        hits += try matches(phonePattern, in: text)
        hits += try matches(linkPattern, in: text)
        return hits
    }

    static func durationHits(_ text: String) throws -> [String] {
        try durationPatterns.flatMap { try matches($0, in: text) }
    }

    @Test("No em dash anywhere")
    func noEmDash() throws {
        let hits = try Self.textFiles().filter { Self.emDashHit($0.text) }.map(\.path)
        #expect(hits.isEmpty, "em dash in \(hits)")
    }

    @Test("No client, company or person names")
    func noNames() throws {
        // Counts only: the names themselves are never printed.
        let count = Self.deniedNames.count
        let longEntries = Self.deniedNames.filter { $0.split(separator: " ").count > 2 }.count
        print("GUARD denied_names=\(count)")
        #expect(count > 0, "STEMKIT_DENIED_NAMES is empty, so the name check cannot run")
        #expect(longEntries == 0, "\(longEntries) entries have more than two words and can never match")
        var hits: [String] = []
        for file in try Self.textFiles() {
            hits += Self.nameHits(file.text).map { "\(file.path): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("No contact details")
    func noContactDetails() throws {
        var hits: [String] = []
        for file in try Self.textFiles() {
            hits += try Self.contactHits(file.text).map { "\(file.path): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("No statement of how long anything took")
    func noDurations() throws {
        var hits: [String] = []
        for file in try Self.textFiles() {
            hits += try Self.durationHits(file.text).map { "\(file.path): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("The guards detect planted samples and pass clean text")
    func guardsDetect() throws {
        // Samples are assembled at run time, so this file itself stays clean.
        #expect(Self.emDashHit("a" + "\u{2014}" + "b"))
        #expect(!Self.emDashHit("a - b"))
        // A test-only list with made-up words, so no real name is planted here. It is parsed the
        // way the secret is: mixed case, spaces, commas and line breaks.
        let planted = Self.parseNames(" Zyxwvut \r\nQoph  Tsade,\n\n")
        #expect(planted == ["zyxwvut", "qoph tsade"])
        #expect(!Self.nameHits("Hello Zyxwvut, thanks", denied: planted).isEmpty)
        #expect(!Self.nameHits("from Qoph Tsade Ltd", denied: planted).isEmpty)
        #expect(Self.nameHits("Qoph alone, and Tsade alone", denied: planted).isEmpty)
        #expect(Self.nameHits("github.com/zyxwvut-sys/stemkit/actions", denied: planted).isEmpty)
        #expect(Self.nameHits("a clean sentence about audio stems", denied: planted).isEmpty)
        #expect(!(try Self.contactHits("write to someone" + "@" + "example.com")).isEmpty)
        #expect(try Self.contactHits("maintainers" + "@" + "stemkit.invalid").isEmpty)
        #expect(!(try Self.contactHits("call " + "+" + "44 20 7946 0000")).isEmpty)
        #expect(!(try Self.contactHits("see linked" + "in.com/in/someone")).isEmpty)
        #expect(!(try Self.durationHits("it took " + "3" + " hours")).isEmpty)
        #expect(!(try Self.durationHits("a two" + "-day job")).isEmpty)
        #expect(try Self.durationHits("a 30 second chunk at 16 kHz").isEmpty)
    }
}
