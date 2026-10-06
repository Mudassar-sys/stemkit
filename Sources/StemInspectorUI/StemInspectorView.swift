import StemInspectorCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: the file table, the bext inspector, the naming panel and a status bar.
public struct StemInspectorView: View {
    @Bindable var model: InspectorViewModel
    @State private var importing = false

    /// Creates the view over a view model.
    public init(model: InspectorViewModel) {
        self.model = model
    }

    /// WAVE files under every extension the file worker reads, and folders.
    static let importTypes: [UTType] = [.wav, .folder] + ["wave", "bwf", "rf64"].compactMap { UTType(filenameExtension: $0) }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                StemTable(model: model)
                Divider()
                NamingPanel(model: model)
                Divider()
                StatusBar(model: model)
            }
            Divider()
            BextInspector(model: model)
                .frame(width: 300)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    importing = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                Button {
                    model.saveChanges()
                } label: {
                    Label("Save Changes", systemImage: "square.and.arrow.down")
                }
                .disabled(model.dirtyCount == 0 || model.isBusy)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                model.add(urls)
            }
        }
        .onChange(of: model.selection) {
            model.loadDraftFromSelection()
        }
        .frame(minWidth: 1100, minHeight: 560)
    }
}

/// The file table.
struct StemTable: View {
    @Bindable var model: InspectorViewModel

    var body: some View {
        Table(model.rows, selection: $model.selection) {
            Group {
                TableColumn("Name") { (row: StemRow) in
                    Text(row.name).lineLimit(1)
                }
                .width(min: 130, ideal: 170)
                TableColumn("Audio") { (row: StemRow) in
                    IntegrityBadgeView(row: row)
                }
                .width(min: 110, ideal: 135)
                TableColumn("Container") { (row: StemRow) in Text(row.containerText) }
                    .width(62)
                TableColumn("Ch") { (row: StemRow) in Text(row.channelsText) }
                    .width(26)
                TableColumn("Rate") { (row: StemRow) in Text(row.sampleRateText) }
                    .width(50)
                TableColumn("Bits") { (row: StemRow) in Text(row.bitDepthText) }
                    .width(30)
            }
            Group {
                TableColumn("Duration") { (row: StemRow) in Text(row.durationText) }
                    .width(62)
                TableColumn("Description") { (row: StemRow) in
                    Text(row.draft.description).lineLimit(1)
                }
                .width(min: 110, ideal: 150)
                TableColumn("Originator") { (row: StemRow) in Text(row.draft.originator).lineLimit(1) }
                    .width(min: 80, ideal: 110)
                TableColumn("Time ref") { (row: StemRow) in Text(row.timeReferenceText) }
                    .width(80)
                TableColumn("iXML") { (row: StemRow) in Text(row.ixmlText) }
                    .width(34)
            }
        }
    }
}

/// The per-file proof: verified, failed, unsaved, or the row's error.
struct IntegrityBadgeView: View {
    let row: StemRow

    var body: some View {
        if let error = row.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(error)
        } else if row.isDirty {
            Text("Unsaved edits").foregroundStyle(.secondary)
        } else {
            switch row.badge {
            case let .verified(sha256, path):
                Label("Audio unchanged", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Payload SHA-256 \(sha256), equal at load and after the \(path.rawValue) save")
            case let .failed(reason):
                Label("Check failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help(reason)
            case .notSaved:
                Text(row.snapshot == nil ? "Loading" : "Not saved")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Edits bext text fields for the selection and shows the selected file's payload hash.
struct BextInspector: View {
    @Bindable var model: InspectorViewModel

    private func field(_ title: String, _ text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    var body: some View {
        let selected = model.rows.first { model.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Broadcast extension (bext)").font(.headline)
            field("Description", $model.inspectorDraft.description)
            field("Originator", $model.inspectorDraft.originator)
            field("Originator reference", $model.inspectorDraft.originatorReference)
            HStack(spacing: 8) {
                field("Origination date", $model.inspectorDraft.originationDate, prompt: "yyyy-mm-dd")
                field("Origination time", $model.inspectorDraft.originationTime, prompt: "hh:mm:ss")
            }
            field("Time reference (samples)", $model.inspectorDraft.timeReference)
            HStack {
                Button("Apply to \(model.selection.count) selected") {
                    model.applyDraftToSelection()
                }
                .disabled(model.selection.isEmpty || model.isBusy)
                Button("Revert") {
                    model.discardInspectorEdits()
                }
                .disabled(model.inspectorDraft == model.inspectorBaseline)
                Spacer()
            }
            Text("Only the fields you change are applied. \(model.dirtyCount) file(s) have unsaved edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Audio payload").font(.headline)
            if let selected, let snapshot = selected.snapshot {
                Text("\(snapshot.encoding), \(snapshot.channels) ch, \(snapshot.sampleRate) Hz")
                    .font(.callout)
                Text("SHA-256 at load")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(snapshot.audioSHA256)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                IntegrityBadgeView(row: selected)
            } else {
                Text("Select a file").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The naming template and its preview.
struct NamingPanel: View {
    @Bindable var model: InspectorViewModel

    var body: some View {
        let preview = model.namingPreview
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Naming template").font(.headline)
                TextField("Project", text: $model.project)
                TextField("Template", text: $model.template)
                Text("Tokens: {project} {index} {description} {originator} {name}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Apply Names") {
                    model.applyNaming()
                }
                .disabled(model.rows.isEmpty || model.isBusy || preview.contains { $0.problem != nil })
            }
            .frame(width: 300)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview.prefix(8)) { item in
                        HStack(spacing: 6) {
                            Text(item.oldName).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            if let problem = item.problem {
                                Text(problem).foregroundStyle(.red)
                            } else {
                                Text(item.newName ?? "")
                            }
                        }
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    }
                    if preview.count > 8 {
                        Text("and \(preview.count - 8) more").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(height: 150)
    }
}

/// Progress, cancellation and the last batch summary.
struct StatusBar: View {
    @Bindable var model: InspectorViewModel

    var body: some View {
        HStack(spacing: 12) {
            if let progress = model.progress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 200)
                Text("\(progress.label) \(progress.completed) of \(progress.total)")
                Button("Cancel") {
                    model.cancel()
                }
            } else {
                Text(model.statusMessage).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.rows.count) files").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
