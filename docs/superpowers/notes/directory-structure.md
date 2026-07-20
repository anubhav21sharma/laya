.
├── App
│   ├── PatternSpike
│   │   ├── Assets.xcassets
│   │   │   ├── AccentColor.colorset
│   │   │   │   └── Contents.json
│   │   │   ├── AppIcon.appiconset
│   │   │   │   └── Contents.json
│   │   │   ├── Contents.json
│   │   │   ├── grain-paper.imageset
│   │   │   │   ├── Contents.json
│   │   │   │   └── grain-paper.png
│   │   │   └── tip.imageset
│   │   │       ├── Contents.json
│   │   │       └── tip.png
│   │   ├── BrushEditorPanel.swift
│   │   ├── CanvasRepresentable.swift
│   │   ├── ContentView.swift
│   │   ├── HarnessLaunch.swift
│   │   ├── InputAdapter.swift
│   │   ├── PatternCanvasView.swift
│   │   ├── PatternSpikeApp.swift
│   │   └── RenderHarness.swift
│   ├── PatternSpike.xcodeproj
│   │   ├── project.pbxproj
│   │   ├── project.xcworkspace
│   │   │   ├── contents.xcworkspacedata
│   │   │   ├── xcshareddata
│   │   │   │   ├── swiftpm
│   │   │   │   │   └── configuration
│   │   │   │   └── WorkspaceSettings.xcsettings
│   │   │   └── xcuserdata
│   │   │       └── anubshar.xcuserdatatad
│   │   │           ├── UserInterfaceState.xcuserstate
│   │   │           └── WorkspaceSettings.xcsettings
│   │   └── xcuserdata
│   │       └── anubshar.xcuserdatatad
│   │           ├── xcdebugger
│   │           │   └── Breakpoints_v2.xcbkptlist
│   │           └── xcschemes
│   │               └── xcschememanagement.plist
├── buildServer.json
├── docs
│   ├── archive
│   │   └── README.md
│   └── superpowers
│       ├── 00-apple-native-pivot-design.md
│       ├── 03-live-drawing-design.md
│       ├── 04-multi-tiling-design.md
│       ├── 05-input-architecture-design.md
│       ├── 06-offscreen-render-harness.md
│       ├── 07-drawing-tools-roadmap.md
│       ├── 08-colored-brush-design.md
│       ├── 09-eraser-design.md
│       ├── 10-undo-redo-design.md
│       ├── 11-selection-transform-design.md
│       ├── 12-raster-brush-design.md
│       ├── 13-png-brush-quality-design.md
│       ├── 14-edit-transaction-module-design.md
│       ├── 15-professional-brush-engine.md
│       ├── 16-reference-sheet.md
│       ├── archive/legacy-backlog-2026-07-13.md
│       ├── notes
│       │   ├── 2026-06-22-live-tile-perf-promotion-undo.md
│       │   └── 2026-06-23-halfdrop-edge-dab-clipping.md
│       ├── phase0-gate-results.md
│       └── phase0-simulator-grid-tiling.png
├── Package.swift
├── README.md
├── scripts
│   └── start.sh
├── Sources
│   ├── CShaderTypes
│   │   ├── CShaderTypes.c
│   │   └── include
│   │       └── ShaderTypes.h
│   ├── EditorCore
│   │   ├── BrushPreset.swift
│   │   ├── Comparable+Clamped.swift
│   │   ├── EditorConfig.swift
│   │   ├── EditorKeymap.swift
│   │   ├── EditorModel.swift
│   │   ├── EditorTransaction.swift
│   │   ├── SelectionRect.swift
│   │   ├── Stabilizer.swift
│   │   └── TilingChoice.swift
│   ├── MetalRenderer
│   │   ├── BrushTextureResolver.swift
│   │   ├── BrushTextures.swift
│   │   ├── CanonicalRaster.swift
│   │   ├── DabInstance.swift
│   │   ├── LiveTile.swift
│   │   ├── MetalRenderer.swift
│   │   ├── RenderCapture.swift
│   │   ├── SelectionLayer.swift
│   │   ├── Shaders.metal
│   │   ├── SpikeRenderer.swift
│   │   ├── TileTexture.swift
│   │   └── UndoHistory.swift
│   └── PatternEngine
│       ├── Affine.swift
│       ├── BrushDynamics.swift
│       ├── BrushParams.swift
│       ├── CanonicalHit.swift
│       ├── DabSpec.swift
│       ├── Geometry.swift
│       ├── GridStrategy.swift
│       ├── HalfDropStrategy.swift
│       ├── LatticeOffsets.swift
│       ├── MirrorStrategy.swift
│       ├── PatternEngine.swift
│       ├── RotationalStrategy.swift
│       ├── ScriptedScene.swift
│       ├── StrokeInterpolator.swift
│       ├── StrokeSample.swift
│       ├── StrokeSession.swift
│       ├── TilingStrategy.swift
│       └── WrappedPlacement.swift
└── Tests
├── EditorCoreTests
│   ├── BrushEditorTests.swift
│   ├── BrushPresetTests.swift
│   ├── EditorCoreTests.swift
│   ├── EditorTransactionTests.swift
│   └── StabilizerTests.swift
├── MetalRendererTests
│   ├── BrushTexturesTests.swift
│   └── LayoutTests.swift
└── PatternEngineTests
├── AffineTests.swift
├── BrickTests.swift
├── BrushDynamicsFlowTests.swift
├── BrushDynamicsTests.swift
├── CanonicalToWorldTests.swift
├── ColoredBrushTests.swift
├── DabSpecTests.swift
├── EdgeDabParityTests.swift
├── EraserTests.swift
├── FoldParityRegressionTests.swift
├── GeometryTests.swift
├── GridStrategyTests.swift
├── HalfDropTests.swift
├── LargeBrushWrapTests.swift
├── MirrorRotationalWrapTests.swift
├── MirrorTests.swift
├── PatternEngineTests.swift
├── RotationalTests.swift
├── StrokeInterpolatorPressureTests.swift
├── StrokeInterpolatorTests.swift
├── StrokeSampleTests.swift
├── StrokeSessionTests.swift
├── TilingFoldParityTests.swift
├── WrapCommitTests.swift
└── WrapPlacementTests.swift
