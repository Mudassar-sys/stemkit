import AppKit
import StemInspectorCore

/// Asks for write access to a folder with an open panel pointed at it. In the App Sandbox an
/// open panel extends the app's sandbox to the folder the user selects.
@MainActor
public struct FolderAccessPanel: FolderAccessRequester {
    /// Creates the requester.
    public init() {}

    public func requestAccess(to folder: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Stem Inspector needs write access to \"\(folder.lastPathComponent)\" to rewrite or rename files in it."
        panel.prompt = "Allow"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
