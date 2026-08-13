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
        .library(
            name: "MetalRendererDiagnostics",
            targets: ["MetalRendererDiagnostics"]
        ),
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
            name: "ProfessionalBrushEvidenceGate",
            targets: ["ProfessionalBrushEvidenceGate"]
        ),
        .executable(
            name: "BrushCorrectiveEvidenceGate",
            targets: ["BrushCorrectiveEvidenceGate"]
        ),
        .executable(
            name: "BrushInputAllocationProbeHarness",
            targets: ["BrushInputAllocationProbeHarness"]
        ),
        .executable(
            name: "StageDAcceptanceProbe",
            targets: ["StageDAcceptanceProbe"]
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
            dependencies: [
                "PatternEngine", "EditorCore", "CShaderTypes", "BrushFormat",
            ],
            exclude: ["Shaders.metal"]
        ),
        .target(
            name: "MetalRendererDiagnostics",
            dependencies: [
                "MetalRenderer",
                "PatternEngine",
                "BrushFormat",
                "CShaderTypes",
                "ProfessionalBrushEvidenceValidation",
            ]
        ),
        .target(
            name: "PatternFile",
            dependencies: ["PatternEngine", "SafeArchive"]
        ),
        .target(name: "SafeArchive"),
        .target(
            name: "BrushFormat",
            dependencies: ["PatternEngine", "SafeArchive"],
            exclude: [
                "Resources/Professional/TechnicalInk/Sources",
                "Resources/Professional/TechnicalInk/technical-ink-tip.png",
                "Resources/Professional/TechnicalInk/PROVENANCE.md",
                "Resources/Professional/Graphite/Sources",
                "Resources/Professional/Graphite/graphite-tip.png",
                "Resources/Professional/Graphite/graphite-paper-grain.png",
                "Resources/Professional/Graphite/PROVENANCE.md",
                "Resources/Professional/Charcoal/Sources",
                "Resources/Professional/Charcoal/charcoal-tip.png",
                "Resources/Professional/Charcoal/charcoal-fine-grain.png",
                "Resources/Professional/Charcoal/charcoal-coarse-grain.png",
                "Resources/Professional/Charcoal/PROVENANCE.md",
                "Resources/Professional/Chisel/Sources",
                "Resources/Professional/Chisel/chisel-tip.png",
                "Resources/Professional/Chisel/PROVENANCE.md",
            ],
            resources: [
                .copy("Resources/Professional/TechnicalInk/technical-ink-tip.r8"),
                .copy("Resources/Professional/Graphite/graphite-tip.r8"),
                .copy("Resources/Professional/Graphite/graphite-paper-grain.r8"),
                .copy("Resources/Professional/Charcoal/charcoal-tip.r8"),
                .copy("Resources/Professional/Charcoal/charcoal-fine-grain.r8"),
                .copy("Resources/Professional/Charcoal/charcoal-coarse-grain.r8"),
                .copy("Resources/Professional/Chisel/chisel-tip.r8"),
            ]
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
            name: "BrushCharacterizationTool",
            dependencies: [
                "PatternEngine", "EditorCore", "BrushFormat",
                "MetalRenderer",
            ]
        ),
        .executableTarget(
            name: "ProfessionalBrushEvidenceGate",
            dependencies: ["ProfessionalBrushEvidenceValidation"]
        ),
        .executableTarget(
            name: "BrushCorrectiveEvidenceGate",
            dependencies: ["MetalRendererDiagnostics"]
        ),
        .executableTarget(
            name: "BrushFoundationEvidenceGate",
            dependencies: ["MetalRendererDiagnostics"]
        ),
        .target(
            name: "BrushDepositionEvidenceValidation"
        ),
        .target(
            name: "ProfessionalBrushEvidenceValidation",
            dependencies: [
                "BrushFormat",
                "CShaderTypes",
                "PatternEngine",
            ]
        ),
        .executableTarget(
            name: "BrushDepositionEvidenceGate",
            dependencies: ["BrushDepositionEvidenceValidation"]
        ),
        .executableTarget(
            name: "BrushInputAllocationProbeHarness",
            dependencies: ["BrushFormat", "MetalRenderer", "PatternEngine"]
        ),
        .executableTarget(
            name: "StageDAcceptanceProbe",
            dependencies: ["MetalRenderer"]
        ),
        .testTarget(
            name: "PatternEngineTests",
            dependencies: ["PatternEngine"]
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["BrushFormat", "EditorCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MetalRendererTests",
            dependencies: [
                "MetalRenderer",
                "MetalRendererDiagnostics",
                "CShaderTypes",
                "EditorCore",
                "BrushFormat",
                "BrushDepositionEvidenceValidation",
                "ProfessionalBrushEvidenceValidation",
            ]
        ),
        .testTarget(
            name: "MetalRendererDiagnosticsTests",
            dependencies: [
                "MetalRenderer",
                "MetalRendererDiagnostics",
                "PatternEngine",
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
                "ProfessionalBrushEvidenceValidation",
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
                "PatternSpike/Acceptance/InteractiveBrushAcceptanceConfiguration.swift",
                "PatternSpike/Acceptance/InteractiveBrushTraceLogger.swift",
                "PatternSpike/Canvas/InteractiveMetalView.swift",
                "PatternSpike/Canvas/MetalCanvas.swift",
                "PatternSpike/Commands/EditorFocusedCommands.swift",
                "PatternSpike/ContentView.swift",
                "PatternSpike/Harness/StageDAppRouteEvidence.swift",
                "PatternSpike/Debug/DebugPerformanceHUD.swift",
                "PatternSpike/Debug/DebugPerformanceMonitor.swift",
                "PatternSpike/Panels/EditorTopBar.swift",
                "PatternSpike/Panels/LayerPanel.swift",
                "PatternSpike/Panels/TilingInspector.swift",
                "PatternSpike/Panels/ToolRail.swift",
                "PatternSpike/Persistence/EditorBrushSelectionStore.swift",
                "PatternSpike/Persistence/PatternProjectBridge.swift",
                "PatternSpike/Persistence/PatternProjectFileDocument.swift",
                "Tests/ContentViewLifecycleTests.swift",
                "Tests/BrushCursorIntegrationTests.swift",
                "Tests/BrushLabSessionTests.swift",
                "Tests/DebugPerformanceMonitorTests.swift",
                "Tests/EditorTopBarColorBoundaryTests.swift",
                "Tests/EditorSessionControllerTests.swift",
                "Tests/PatternProjectBridgeTests.swift",
                "Tests/InteractiveBrushTraceLoggerTests.swift",
            ]
        ),
    ]
)
