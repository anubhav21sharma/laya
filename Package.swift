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
        .executable(
            name: "SliceThreeEvidenceGate",
            targets: ["SliceThreeEvidenceGate"]
        ),
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
        .executableTarget(
            name: "SliceThreeEvidenceGate",
            dependencies: ["MetalRenderer"]
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
                "PatternSpike/Harness/HarnessLaunch.swift",
                "PatternSpike/Harness/Scenes",
                "PatternSpike/PatternSpikeApp.swift",
                "UITests",
                "project.yml",
            ],
            sources: [
                "PatternSpike/EditorSessionController.swift",
                "PatternSpike/Canvas/InteractiveMetalView.swift",
                "PatternSpike/Canvas/MetalCanvas.swift",
                "PatternSpike/Commands/EditorFocusedCommands.swift",
                "PatternSpike/ContentView.swift",
                "PatternSpike/Debug/DebugPerformanceHUD.swift",
                "PatternSpike/Debug/DebugPerformanceMonitor.swift",
                "PatternSpike/Harness/SliceThreeHarnessHistory.swift",
                "PatternSpike/Harness/SliceThreeHarnessRunner.swift",
                "PatternSpike/Panels/EditorTopBar.swift",
                "PatternSpike/Panels/TilingInspector.swift",
                "PatternSpike/Panels/ToolRail.swift",
                "Tests/ContentViewLifecycleTests.swift",
                "Tests/DebugPerformanceMonitorTests.swift",
                "Tests/EditorSessionControllerTests.swift",
                "Tests/SliceThreeHarnessHistoryTests.swift",
            ]
        ),
    ]
)
