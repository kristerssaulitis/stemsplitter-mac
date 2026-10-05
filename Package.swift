// swift-tools-version: 6.0
import PackageDescription

// Engine libraries; the app target lives in project.yml (xcodegen). Standalone: no
// dependency on ../stemsplitter (see AudioDecoder.swift).
let package = Package(
    name: "StemSplitterMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StemSeparation", targets: ["StemSeparation"]),
        .library(name: "StemAnalysis", targets: ["StemAnalysis"]),
        .library(name: "StemMix", targets: ["StemMix"]),
        // Spotify/YouTube link ingestion: link parsing + spotDL subprocess runner.
        .library(name: "StemLink", targets: ["StemLink"]),
    ],
    targets: [
        .target(name: "StemSeparation"),
        .target(name: "StemAnalysis"),
        .target(name: "StemMix"),
        .target(name: "StemLink"),
        .executableTarget(
            name: "stembench",
            dependencies: ["StemSeparation", "StemAnalysis"],
            path: "bench"
        ),
        .testTarget(name: "StemSeparationTests", dependencies: ["StemSeparation"]),
        .testTarget(name: "StemAnalysisTests", dependencies: ["StemAnalysis"]),
        .testTarget(name: "StemMixTests", dependencies: ["StemMix"]),
        .testTarget(name: "StemLinkTests", dependencies: ["StemLink"]),
    ],
    swiftLanguageModes: [.v5]
)
