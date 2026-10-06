import StemInspectorCore
import StemInspectorUI
import SwiftUI

/// Stem Inspector: inspect and edit broadcast WAV metadata without touching the audio.
/// All logic lives in the StemInspectorCore and StemInspectorUI package targets; this target
/// only wires the real file worker into the window.
@main
struct StemInspectorApp: App {
    @State private var model = InspectorViewModel(service: FileWorker(), folderAccess: FolderAccessPanel())

    var body: some Scene {
        WindowGroup("Stem Inspector") {
            StemInspectorView(model: model)
        }
        .defaultSize(width: 1280, height: 720)
    }
}
