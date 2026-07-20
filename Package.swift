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
        .library(name: "CShaderTypes", targets: ["CShaderTypes"]),
        .library(name: "MetalRenderer", targets: ["MetalRenderer"]),
        .library(name: "PatternFile", targets: ["PatternFile"]),
    ],
    targets: [
        .target(name: "PatternEngine"),
        .target(
            name: "EditorCore",
            dependencies: ["PatternEngine"]
        ),
        .target(
            name: "CShaderTypes",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MetalRenderer",
            dependencies: ["PatternEngine", "CShaderTypes"],
            exclude: ["Shaders.metal"]
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
            name: "MetalRendererTests",
            dependencies: ["MetalRenderer", "CShaderTypes"]
        ),
        .testTarget(
            name: "PatternFileTests",
            dependencies: ["PatternFile"]
        ),
        .testTarget(
            name: "EditorSessionControllerTests",
            dependencies: [
                "EditorCore",
                "MetalRenderer",
                "PatternEngine",
            ],
            path: "App",
            exclude: [
                "PatternSpike/Assets.xcassets",
                "PatternSpike/Canvas",
                "PatternSpike/Commands",
                "PatternSpike/ContentView.swift",
                "PatternSpike/Harness",
                "PatternSpike/Panels",
                "PatternSpike/PatternSpikeApp.swift",
                "project.yml",
            ],
            sources: [
                "PatternSpike/EditorSessionController.swift",
                "Tests/EditorSessionControllerTests.swift",
            ]
        ),
    ]
)
