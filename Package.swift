// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StemKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WaveContainer", targets: ["WaveContainer"]),
        .library(name: "MelFrontEnd", targets: ["MelFrontEnd"]),
        .library(name: "StemInspectorCore", targets: ["StemInspectorCore"]),
        .library(name: "StemInspectorUI", targets: ["StemInspectorUI"]),
        .executable(name: "stemkit", targets: ["StemKitCLI"]),
    ],
    targets: [
        // Foundation only: container parsing, bext, iXML, writes and the integrity hash.
        .target(name: "WaveContainer"),
        // Accelerate: the log-mel front end.
        .target(name: "MelFrontEnd"),
        // View models, the file worker actor and the naming template. No SwiftUI.
        .target(name: "StemInspectorCore", dependencies: ["WaveContainer"]),
        // SwiftUI views shared by the app target and the screenshot test.
        .target(name: "StemInspectorUI", dependencies: ["StemInspectorCore"]),
        .executableTarget(name: "StemKitCLI", dependencies: ["WaveContainer"]),
        .testTarget(
            name: "WaveContainerTests",
            dependencies: ["WaveContainer"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MelFrontEndTests",
            dependencies: ["MelFrontEnd"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "StemInspectorCoreTests", dependencies: ["StemInspectorCore", "WaveContainer"]),
        .testTarget(name: "StemInspectorUITests", dependencies: ["StemInspectorUI", "StemInspectorCore", "WaveContainer"]),
        .testTarget(name: "RepositoryGuardTests"),
    ],
    swiftLanguageModes: [.v6]
)
