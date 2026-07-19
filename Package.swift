// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pattern",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PatternEngine", targets: ["PatternEngine"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "PatternFile", targets: ["PatternFile"]),
    ],
    targets: [
        .target(name: "PatternEngine"),
        .target(
            name: "EditorCore",
            dependencies: ["PatternEngine"]
        ),
        .target(
            name: "PatternFile",
            dependencies: ["PatternEngine"]
        ),
        .testTarget(
            name: "PatternEngineTests",
            dependencies: ["PatternEngine"]
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"]
        ),
        .testTarget(
            name: "PatternFileTests",
            dependencies: ["PatternFile"]
        ),
    ]
)
