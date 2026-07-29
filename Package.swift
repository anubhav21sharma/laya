// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pattern",
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
    ],
    products: [
        .library(name: "PatternEngine", targets: ["PatternEngine"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "CShaderTypes", targets: ["CShaderTypes"]),
        .library(name: "MetalRenderer", targets: ["MetalRenderer"]),
        .library(name: "SafeArchive", targets: ["SafeArchive"]),
        .library(name: "BrushFormat", targets: ["BrushFormat"]),
        .library(name: "BrushConverter", targets: ["BrushConverter"]),
        .executable(
            name: "layabrush-convert",
            targets: ["LayabrushConvert"]
        ),
        .executable(
            name: "brush-converter-fuzz",
            targets: ["BrushConverterFuzz"]
        ),
        .executable(
            name: "SliceThreeEvidenceGate",
            targets: ["SliceThreeEvidenceGate"]
        ),
        .executable(
            name: "BrushCharacterizationTool",
            targets: ["BrushCharacterizationTool"]
        ),
        .executable(
            name: "BrushFoundationEvidenceGate",
            targets: ["BrushFoundationEvidenceGate"]
        ),
        .executable(
            name: "BrushDepositionEvidenceGate",
            targets: ["BrushDepositionEvidenceGate"]
        ),
        .executable(
            name: "BrushInputAllocationProbeHarness",
            targets: ["BrushInputAllocationProbeHarness"]
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
            dependencies: ["PatternEngine", "CShaderTypes", "BrushFormat"],
            exclude: ["Shaders.metal"]
        ),
        .target(
            name: "PatternFile",
            dependencies: ["PatternEngine", "SafeArchive"]
        ),
        .target(name: "SafeArchive"),
        .target(
            name: "BrushFormat",
            dependencies: ["PatternEngine", "SafeArchive"]
        ),
        .target(
            name: "BrushConverter",
            dependencies: ["PatternEngine", "BrushFormat", "SafeArchive"]
        ),
        .executableTarget(
            name: "LayabrushConvert",
            dependencies: ["BrushConverter"]
        ),
        .target(
            name: "BrushConverterFuzzSupport",
            dependencies: ["BrushConverter"],
            resources: [.copy("Corpus")]
        ),
        .executableTarget(
            name: "BrushConverterFuzz",
            dependencies: ["BrushConverterFuzzSupport"]
        ),
        .executableTarget(
            name: "SliceThreeEvidenceGate",
            dependencies: ["MetalRenderer"]
        ),
        .executableTarget(
            name: "BrushCharacterizationTool",
            dependencies: ["PatternEngine", "EditorCore", "MetalRenderer"]
        ),
        .executableTarget(
            name: "BrushFoundationEvidenceGate",
            dependencies: ["MetalRenderer"]
        ),
        .executableTarget(
            name: "BrushDepositionEvidenceGate"
        ),
        .executableTarget(
            name: "BrushInputAllocationProbeHarness",
            dependencies: ["BrushFormat", "MetalRenderer", "PatternEngine"]
        ),
        .testTarget(
            name: "PatternEngineTests",
            dependencies: ["PatternEngine"]
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: [
                "MetalRenderer",
                "CShaderTypes",
                "EditorCore",
                "BrushFormat",
                "BrushDepositionEvidenceGate",
            ]
        ),
        .testTarget(
            name: "PatternFileTests",
            dependencies: ["PatternFile"]
        ),
        .testTarget(
            name: "SafeArchiveTests",
            dependencies: ["SafeArchive"]
        ),
        .testTarget(
            name: "BrushFormatTests",
            dependencies: ["BrushFormat", "PatternEngine", "SafeArchive"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BrushConverterTests",
            dependencies: [
                "BrushConverter",
                "BrushConverterFuzzSupport",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BrushConverterIntegrationTests",
            dependencies: [
                "BrushConverter",
                "BrushFormat",
                "MetalRenderer",
            ]
        ),
        .testTarget(
            name: "EditorSessionControllerTests",
            dependencies: [
                "BrushConverter",
                "EditorCore",
                "BrushFormat",
                "MetalRenderer",
                "PatternEngine",
                "PatternFile",
            ],
            path: "App",
            exclude: [
                "PatternSpike/Assets.xcassets",
                "PatternSpike/Harness/HarnessLaunch.swift",
                "PatternSpike/Harness/Baselines",
                "PatternSpike/Harness/Scenes",
                "PatternSpike/PatternSpikeMac-Info.plist",
                "PatternSpike/PatternSpikePad-Info.plist",
                "PatternSpike/PatternSpikeApp.swift",
                "PatternSpike/BrushLab/BrushLabView.swift",
                "UITests",
                "project.yml",
            ],
            sources: [
                "PatternSpike/EditorSessionController.swift",
                "PatternSpike/BrushLab/BrushLabManualCard.swift",
                "PatternSpike/BrushLab/BrushLabSession.swift",
                "PatternSpike/Input/BrushInputAdapter.swift",
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
                "PatternSpike/Persistence/PatternProjectBridge.swift",
                "PatternSpike/Persistence/PatternProjectFileDocument.swift",
                "Tests/ContentViewLifecycleTests.swift",
                "Tests/BrushLabSessionTests.swift",
                "Tests/DebugPerformanceMonitorTests.swift",
                "Tests/EditorSessionControllerTests.swift",
                "Tests/PatternProjectBridgeTests.swift",
                "Tests/SliceThreeHarnessHistoryTests.swift",
            ]
        ),
    ]
)
