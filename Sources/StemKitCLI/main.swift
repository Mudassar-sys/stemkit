import Foundation
import WaveContainer

/// `stemkit inspect <file> --json`, `stemkit set <file> <field> <value>`, `stemkit verify <a> <b>`.
/// Exit codes: 0 success (or same audio), 1 different audio, 2 usage or file error.

let usage = """
    usage:
      stemkit inspect <file> [--json]
      stemkit set <file> <field> <value>
          fields: bext.<name> (\(BextField.allCases.map(\.rawValue).joined(separator: ", ")))
                  ixml (value is the XML text, or @path to read it from a file)
      stemkit verify <a> <b>
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func printJSON(_ object: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("error: cannot encode JSON: \(error.localizedDescription)")
    }
}

func inspect(_ path: String, json: Bool) throws {
    let url = URL(fileURLWithPath: path)
    let file = try WaveFile.read(from: url)
    let format = file.format
    let dataHash = try AudioIntegrity.dataChunkSHA256(of: url, file: file)
    // A malformed iXML must not hide the rest of the report.
    var metadata: [String: String] = [:]
    var metadataError: String?
    do {
        metadata = try file.flattenedMetadata()
    } catch {
        metadataError = "\(error)"
        if let bext = file.bext { metadata = WaveFile.flatten(bext) }
        metadata["riff.other_chunks"] = file.otherChunkIDs.joined(separator: ",")
    }
    var info: [String: Any] = [
        "file": url.lastPathComponent,
        "container": file.container.rawValue,
        "file_size": file.fileSize,
        "chunks": file.chunks.map { chunk -> [String: Any] in
            ["id": chunk.id, "offset": chunk.headerOffset, "size": chunk.size, "pad_byte": chunk.hasPadByte]
        },
        "format": [
            "format_tag": Int(format.formatTag),
            "effective_format_tag": Int(format.effectiveFormatTag),
            "encoding": format.encoding.description,
            "supported": format.isSupportedEncoding,
            "channels": Int(format.channels),
            "sample_rate": Int(format.sampleRate),
            "bits_per_sample": Int(format.bitsPerSample),
            "block_align": Int(format.blockAlign),
        ] as [String: Any],
        "data_size": file.dataChunk.size,
        "data_sha256": dataHash,
        "metadata": metadata,
    ]
    if let metadataError {
        info["metadata_error"] = metadataError
    }
    if let duration = file.durationSeconds {
        info["duration_seconds"] = duration
    }
    if let ds64 = file.ds64 {
        info["ds64"] = [
            "riff_size": ds64.riffSize, "data_size": ds64.dataSize, "sample_count": ds64.sampleCount,
            "table": ds64.table.map { ["id": $0.id, "size": $0.size] },
        ] as [String: Any]
    }
    if let bext = file.bext {
        info["bext_issues"] = bext.specificationIssues
    }
    if json {
        printJSON(info)
    } else {
        print("\(url.lastPathComponent): \(file.container.rawValue), \(format.encoding), \(format.channels) ch, \(format.sampleRate) Hz")
        for chunk in file.chunks {
            print("  \(chunk.id)  offset \(chunk.headerOffset)  size \(chunk.size)")
        }
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            print("  \(key) = \(value)")
        }
    }
}

func set(_ path: String, field: String, value: String) throws {
    let url = URL(fileURLWithPath: path)
    let file = try WaveFile.read(from: url)
    var changes = MetadataChanges()
    if field == "ixml" {
        let text: String
        if value.hasPrefix("@") {
            let source = URL(fileURLWithPath: String(value.dropFirst()))
            // Read at most the limit plus one byte, so a device or pipe cannot exhaust memory.
            let limit = Int(WaveLimits.maxMetadataChunkBytes)
            guard let handle = try? FileHandle(forReadingFrom: source),
                  let data = try? handle.read(upToCount: limit + 1) else {
                throw WaveError.io("cannot read \(source.path)")
            }
            try? handle.close()
            guard data.count <= limit else {
                throw WaveError.sizeLimitExceeded("\(source.lastPathComponent) is larger than \(limit) bytes")
            }
            guard let loaded = String(data: data, encoding: .utf8) else {
                throw WaveError.io("cannot read \(source.path) as UTF-8")
            }
            text = loaded
        } else {
            text = value
        }
        let ixml = IXML(xmlText: text)
        _ = try ixml.flattened()  // refuse malformed XML before touching the file
        changes.ixml = ixml
    } else if field.hasPrefix("bext.") {
        guard let name = BextField(rawValue: String(field.dropFirst(5))) else {
            throw WaveError.unknownField(field)
        }
        var bext = file.bext ?? Bext()
        try name.set(value, in: &bext)
        changes.bext = bext
    } else {
        throw WaveError.unknownField(field)
    }
    let report = try MetadataWriter.apply(changes, to: url)
    printJSON([
        "file": url.lastPathComponent,
        "field": field,
        "write_path": report.path.rawValue,
        "data_sha256_before": report.audioSHA256Before ?? "",
        "data_sha256_after": report.audioSHA256After ?? "",
        "audio_unchanged": report.audioUnchanged,
    ])
}

func verify(_ a: String, _ b: String) throws -> Bool {
    let same = try AudioIntegrity.haveSameAudio(URL(fileURLWithPath: a), URL(fileURLWithPath: b))
    print(same ? "same audio" : "different audio")
    return same
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first ?? "" {
    case "inspect" where arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--json"):
        try inspect(arguments[1], json: arguments.count == 3)
    case "set" where arguments.count == 4:
        try set(arguments[1], field: arguments[2], value: arguments[3])
    case "verify" where arguments.count == 3:
        let same = try verify(arguments[1], arguments[2])
        exit(same ? 0 : 1)
    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
