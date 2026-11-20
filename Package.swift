// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADFKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ADFKit", targets: ["ADFModel", "ADFPreparation", "ADFRendering", "ADFConfluence"]),
        .library(name: "ADFYouTube", targets: ["ADFYouTube"]),
        .library(name: "ADFBeam", targets: ["ADFBeam"]),
        .executable(name: "ADFSearchBench", targets: ["ADFSearchBench"]),
        .library(name: "ADFAtlassianAuth", targets: ["ADFAtlassianAuth"]),
        .library(name: "ADFResolvers", targets: ["ADFResolvers"]),
        .library(name: "ADFAtlassianMedia", targets: ["ADFAtlassianMedia"]),
        .executable(name: "adf-auth", targets: ["ADFAuthCLI"]),
    ],
    targets: [
        .target(name: "ADFModel"),
        .target(name: "ADFBeam"),
        .testTarget(name: "ADFBeamTests", dependencies: ["ADFBeam"]),
        .target(name: "ADFPreparation", dependencies: ["ADFModel"]),
        .target(name: "ADFRendering", dependencies: ["ADFModel", "ADFPreparation"]),
        .target(name: "ADFYouTube", dependencies: ["ADFModel", "ADFPreparation", "ADFRendering"]),
        .testTarget(name: "ADFYouTubeTests", dependencies: ["ADFYouTube", "ADFModel", "ADFPreparation"]),
        .target(name: "ADFConfluence", dependencies: ["ADFModel"]),
        .executableTarget(name: "ADFSearchBench", dependencies: ["ADFModel", "ADFPreparation"]),
        .testTarget(name: "ADFModelTests", dependencies: ["ADFModel"]),
        .testTarget(name: "ADFPreparationTests", dependencies: ["ADFPreparation", "ADFModel"]),
        .testTarget(name: "ADFRenderingTests", dependencies: ["ADFRendering", "ADFPreparation", "ADFModel"]),
        .testTarget(name: "ADFConfluenceTests", dependencies: ["ADFConfluence", "ADFModel"]),
        .target(name: "ADFAtlassianAuth"),
        .executableTarget(name: "ADFAuthCLI", dependencies: ["ADFAtlassianAuth"]),
        .testTarget(name: "ADFAtlassianAuthTests", dependencies: ["ADFAtlassianAuth"]),
        .target(name: "ADFResolvers", dependencies: ["ADFRendering"]),
        .testTarget(name: "ADFResolversTests", dependencies: ["ADFResolvers"]),
        // The only module that joins Atlassian credentials to ADF media. The
        // renderer and resolvers never import ADFAtlassianAuth; they take the
        // fetcher's `mediaFetch` closure instead.
        .target(name: "ADFAtlassianMedia", dependencies: ["ADFAtlassianAuth", "ADFModel"]),
        .testTarget(name: "ADFAtlassianMediaTests", dependencies: ["ADFAtlassianMedia", "ADFAtlassianAuth", "ADFModel"]),
    ]
)
