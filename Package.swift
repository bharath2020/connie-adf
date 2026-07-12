// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADFKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ADFKit", targets: ["ADFModel", "ADFPreparation", "ADFRendering"]),
        .library(name: "ADFBeam", targets: ["ADFBeam"]),
    ],
    targets: [
        .target(name: "ADFModel"),
        .target(name: "ADFBeam"),
        .testTarget(name: "ADFBeamTests", dependencies: ["ADFBeam"]),
        .target(name: "ADFPreparation", dependencies: ["ADFModel"]),
        .target(name: "ADFRendering", dependencies: ["ADFModel", "ADFPreparation"]),
        .testTarget(name: "ADFModelTests", dependencies: ["ADFModel"]),
        .testTarget(name: "ADFPreparationTests", dependencies: ["ADFPreparation", "ADFModel"]),
        .testTarget(name: "ADFRenderingTests", dependencies: ["ADFRendering", "ADFPreparation", "ADFModel"]),
    ]
)
