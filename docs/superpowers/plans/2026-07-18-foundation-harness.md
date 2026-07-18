# Foundation And Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a reproducible native Apple project whose blank Metal canvas renders through the real app metallib both onscreen and offscreen, with pure tests, scripted pixel assertions, benchmark JSON, and a repeatable macOS/iPadOS build gate.

**Architecture:** A Swift package owns the platform-free modules, shared CPU/MSL ABI, and Metal implementation. XcodeGen generates a two-target macOS/iPadOS app project from checked-in YAML; the generated `.xcodeproj` is disposable. The macOS app doubles as the GPU harness executable so offscreen verification exercises the exact metallib shipped by the app rather than a test-only shader path.

**Tech Stack:** Swift 6, Swift Testing, Metal, MetalKit, SwiftUI, CoreGraphics, ImageIO, UniformTypeIdentifiers, XcodeGen 2.46.0 or newer, Xcode command-line tools.

## Global Constraints

- Native Swift 6, Metal, and SwiftUI only; no third-party runtime dependency.
- Minimum macOS 14 and iPadOS 17.
- macOS is the interactive validation target; the iPadOS target must compile continuously even though device-only behavior is deferred until hardware is available.
- `PatternEngine` imports Foundation and simd only; it must not import Metal, SwiftUI, AppKit, or UIKit.
- `EditorCore` exposes no SwiftUI, AppKit, or UIKit types.
- `MetalRenderer` depends only on `PatternEngine` and `CShaderTypes`.
- `PatternFile` depends only on `PatternEngine`.
- Circular target dependencies are forbidden.
- CPU/MSL layouts are shared through `CShaderTypes` and guarded by pure layout tests plus a runtime precondition.
- Canonical, live, selection, and drawable color textures use `.bgra8Unorm` premultiplied storage; shape and grain coverage textures use `.r8Unorm`.
- Metal unavailable produces an explicit unsupported-device state; no fallback renderer is allowed.
- `swift test` validates CPU contracts only and must never be described as shader validation.
- GPU assertions execute the built macOS app against its real default metallib and exit nonzero on mismatch.
- Every harness family includes a negative control that proves its assertion can fail.
- Fixed harness scenes record hardware, OS, build, CPU span, GPU span, frame count, and peak resident memory in JSON.
- Generated `App/PatternSpike.xcodeproj/` and `.build/` artifacts are not committed.
- This plan implements Slice 0 only. Drawing, tiling, document pixels, layers, persistence, and production UI controls remain in later accepted slices.

---

## File Map

```text
.gitignore
Package.swift
App/
  project.yml
  PatternSpike/
    PatternSpikeApp.swift
    ContentView.swift
    Canvas/MetalCanvas.swift
    Harness/HarnessLaunch.swift
    Assets.xcassets/Contents.json
    Assets.xcassets/AccentColor.colorset/Contents.json
    Harness/Scenes/blank-canvas.json
    Harness/Scenes/blank-canvas-negative-control.json
Sources/
  PatternEngine/PatternEngineInfo.swift
  EditorCore/EditorCoreInfo.swift
  CShaderTypes/CShaderTypes.c
  CShaderTypes/include/ShaderTypes.h
  MetalRenderer/ShaderABI.swift
  MetalRenderer/MetalRendererError.swift
  MetalRenderer/BlankCanvasContract.swift
  MetalRenderer/BlankRenderer.swift
  MetalRenderer/BenchmarkRecord.swift
  MetalRenderer/Capture/HarnessScene.swift
  MetalRenderer/Capture/HarnessRunner.swift
  MetalRenderer/Capture/PNGWriter.swift
  MetalRenderer/Shaders.metal
  PatternFile/PatternFileInfo.swift
Tests/
  PatternEngineTests/PatternEngineInfoTests.swift
  EditorCoreTests/EditorCoreInfoTests.swift
  MetalRendererTests/ShaderABILayoutTests.swift
  MetalRendererTests/BlankCanvasContractTests.swift
  MetalRendererTests/HarnessSceneTests.swift
  MetalRendererTests/BenchmarkRecordTests.swift
  PatternFileTests/PatternFileInfoTests.swift
scripts/
  bootstrap.sh
  verify-slice0.sh
docs/superpowers/milestones/00-foundation-harness.md
```

Responsibility boundaries:

- `*Info.swift` files make the initial module graph testable without inventing domain behavior.
- `ShaderTypes.h` is the only shared CPU/MSL layout and append-only wire-value source.
- `ShaderABI.swift` validates the imported C layout before any pipeline is made.
- `BlankRenderer.swift` owns Metal pipeline creation, onscreen drawing, offscreen drawing, and GPU timing.
- `HarnessScene.swift` owns the versioned, CPU-testable scene schema.
- `PNGWriter.swift` owns cold-path texture readback and image encoding.
- `HarnessRunner.swift` owns one deterministic scene execution and its output artifacts.
- `HarnessLaunch.swift` owns command-line parsing and process exit behavior; no harness policy belongs in SwiftUI views.
- `project.yml` is the Xcode project source of truth.
- `verify-slice0.sh` is the single automated Slice 0 gate.

---

### Task 1: Restore The Platform-Free Package Graph

**Files:**
- Create: `Package.swift`
- Create: `Sources/PatternEngine/PatternEngineInfo.swift`
- Create: `Sources/EditorCore/EditorCoreInfo.swift`
- Create: `Sources/PatternFile/PatternFileInfo.swift`
- Create: `Tests/PatternEngineTests/PatternEngineInfoTests.swift`
- Create: `Tests/EditorCoreTests/EditorCoreInfoTests.swift`
- Create: `Tests/PatternFileTests/PatternFileInfoTests.swift`

**Interfaces:**
- Consumes: Swift 6 package manager and the target dependency graph in the approved design.
- Produces: `PatternEngineInfo.moduleName`, `EditorCoreInfo.moduleName`, and `PatternFileInfo.moduleName`; package products named `PatternEngine`, `EditorCore`, and `PatternFile`.

- [ ] **Step 1: Write the package manifest and failing smoke tests**

Create `Package.swift`:

```swift
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
```

Create `Tests/PatternEngineTests/PatternEngineInfoTests.swift`:

```swift
import PatternEngine
import Testing

@Test
func patternEngineModuleIdentityIsStable() {
    #expect(PatternEngineInfo.moduleName == "PatternEngine")
}
```

Create `Tests/EditorCoreTests/EditorCoreInfoTests.swift`:

```swift
import EditorCore
import Testing

@Test
func editorCoreModuleIdentityIsStable() {
    #expect(EditorCoreInfo.moduleName == "EditorCore")
}
```

Create `Tests/PatternFileTests/PatternFileInfoTests.swift`:

```swift
import PatternFile
import Testing

@Test
func patternFileModuleIdentityIsStable() {
    #expect(PatternFileInfo.moduleName == "PatternFile")
}
```

- [ ] **Step 2: Run the tests and verify the missing implementations fail**

Run:

```bash
swift test
```

Expected: FAIL because the three target source directories do not yet contain the referenced module-info types.

- [ ] **Step 3: Add the minimal module implementations**

Create `Sources/PatternEngine/PatternEngineInfo.swift`:

```swift
public enum PatternEngineInfo {
    public static let moduleName = "PatternEngine"
}
```

Create `Sources/EditorCore/EditorCoreInfo.swift`:

```swift
public enum EditorCoreInfo {
    public static let moduleName = "EditorCore"
}
```

Create `Sources/PatternFile/PatternFileInfo.swift`:

```swift
public enum PatternFileInfo {
    public static let moduleName = "PatternFile"
}
```

- [ ] **Step 4: Run the pure tests**

Run:

```bash
swift test
```

Expected: PASS, 3 tests run, 0 failures.

- [ ] **Step 5: Audit the dependency graph**

Run:

```bash
swift package describe
```

Expected: `EditorCore` and `PatternFile` each depend on `PatternEngine`; `PatternEngine` has no package target dependency.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PatternEngine Sources/EditorCore Sources/PatternFile Tests/PatternEngineTests Tests/EditorCoreTests Tests/PatternFileTests
git commit -m "build: restore core package graph"
```

---

### Task 2: Establish The Shared CPU/MSL ABI

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CShaderTypes/CShaderTypes.c`
- Create: `Sources/CShaderTypes/include/ShaderTypes.h`
- Create: `Sources/MetalRenderer/ShaderABI.swift`
- Create: `Sources/MetalRenderer/Shaders.metal`
- Create: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`

**Interfaces:**
- Consumes: the `PatternEngine` product from Task 1.
- Produces: C-imported `PatternFrameUniforms`; append-only constants `PatternTilingWireGrid` through `PatternTilingWireRotational`; `ShaderABI.isValid` and `ShaderABI.preconditionValid()`.

- [ ] **Step 1: Add the Metal targets and failing ABI test**

Replace `Package.swift` with:

```swift
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
    ]
)
```

Create `Tests/MetalRendererTests/ShaderABILayoutTests.swift`:

```swift
import CShaderTypes
import MetalRenderer
import Testing

@Test
func frameUniformLayoutMatchesTheMetalContract() {
    #expect(MemoryLayout<PatternFrameUniforms>.size == 16)
    #expect(MemoryLayout<PatternFrameUniforms>.stride == 16)
    #expect(MemoryLayout<PatternFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0)
    #expect(MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8)
    #expect(ShaderABI.isValid)
}

@Test
func tilingWireValuesAreAppendOnly() {
    #expect(PatternTilingWireGrid == 0)
    #expect(PatternTilingWireHalfDrop == 1)
    #expect(PatternTilingWireBrick == 2)
    #expect(PatternTilingWireMirrorX == 3)
    #expect(PatternTilingWireMirrorY == 4)
    #expect(PatternTilingWireMirrorXY == 5)
    #expect(PatternTilingWireRotational == 6)
}
```

- [ ] **Step 2: Run the ABI tests and verify they fail**

Run:

```bash
swift test
```

Expected: FAIL because `CShaderTypes`, `ShaderABI`, and the shared layouts do not exist yet.

- [ ] **Step 3: Add the shared C/MSL header**

Create `Sources/CShaderTypes/include/ShaderTypes.h`:

```c
#ifndef PATTERN_SHADER_TYPES_H
#define PATTERN_SHADER_TYPES_H

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
typedef uint PatternUInt32;
typedef float2 PatternFloat2;
#define PATTERN_WIRE_CONSTANT constant
#else
#include <stdint.h>
#include <simd/simd.h>
typedef uint32_t PatternUInt32;
typedef vector_float2 PatternFloat2;
#define PATTERN_WIRE_CONSTANT static const
#endif

typedef struct PatternFrameUniforms {
    PatternFloat2 drawableSize;
    PatternFloat2 inverseDrawableSize;
} PatternFrameUniforms;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexFrameUniforms = 0;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireGrid = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireHalfDrop = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireBrick = 2;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorX = 3;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorY = 4;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireMirrorXY = 5;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTilingWireRotational = 6;

#undef PATTERN_WIRE_CONSTANT

#endif
```

Create `Sources/CShaderTypes/CShaderTypes.c`:

```c
#include "ShaderTypes.h"
```

- [ ] **Step 4: Add the Swift runtime layout guard**

Create `Sources/MetalRenderer/ShaderABI.swift`:

```swift
import CShaderTypes

public enum ShaderABI {
    public static var isValid: Bool {
        MemoryLayout<PatternFrameUniforms>.size == 16
            && MemoryLayout<PatternFrameUniforms>.stride == 16
            && MemoryLayout<PatternFrameUniforms>.alignment == 8
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0
            && MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8
    }

    public static func preconditionValid(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(isValid, "CPU/MSL frame uniform layout mismatch", file: file, line: line)
    }
}
```

- [ ] **Step 5: Add the app metallib source**

Create `Sources/MetalRenderer/Shaders.metal`:

```metal
#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct PatternVertexOut {
    float4 position [[position]];
};

vertex PatternVertexOut patternBlankVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    PatternVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    return output;
}

fragment float4 patternBlankFragment(PatternVertexOut input [[stage_in]]) {
    return float4(242.0 / 255.0, 244.0 / 255.0, 241.0 / 255.0, 1.0);
}
```

- [ ] **Step 6: Run all pure tests**

Run:

```bash
swift test
```

Expected: PASS, 5 tests run, 0 failures. This confirms CPU layout and wire constants only; it does not compile or validate the Metal shader.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CShaderTypes Sources/MetalRenderer/ShaderABI.swift Sources/MetalRenderer/Shaders.metal Tests/MetalRendererTests/ShaderABILayoutTests.swift
git commit -m "feat: establish shared shader ABI"
```

---

### Task 3: Build The Blank Metal Renderer

**Files:**
- Create: `Sources/MetalRenderer/MetalRendererError.swift`
- Create: `Sources/MetalRenderer/BlankCanvasContract.swift`
- Create: `Sources/MetalRenderer/BlankRenderer.swift`
- Create: `Tests/MetalRendererTests/BlankCanvasContractTests.swift`

**Interfaces:**
- Consumes: `ShaderABI.preconditionValid()` and metallib functions `patternBlankVertex` and `patternBlankFragment`.
- Produces: `BlankCanvasContract.canvasBGRA`, `BlankCanvasContract.matches(actual:expected:tolerance:)`, `GPUFrameMetrics`, `RenderedFrame`, and `@MainActor BlankRenderer`.

- [ ] **Step 1: Write the failing blank-canvas contract tests**

Create `Tests/MetalRendererTests/BlankCanvasContractTests.swift`:

```swift
import MetalRenderer
import Testing

@Test
func blankCanvasUsesThePrecisionLightNeutral() {
    #expect(BlankCanvasContract.canvasBGRA == SIMD4<UInt8>(241, 244, 242, 255))
}

@Test
func pixelComparisonHonorsTheEightBitTolerance() {
    #expect(
        BlankCanvasContract.matches(
            actual: SIMD4<UInt8>(240, 245, 242, 255),
            expected: BlankCanvasContract.canvasBGRA,
            tolerance: 1
        )
    )
    #expect(
        !BlankCanvasContract.matches(
            actual: SIMD4<UInt8>(239, 245, 242, 255),
            expected: BlankCanvasContract.canvasBGRA,
            tolerance: 1
        )
    )
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
swift test
```

Expected: FAIL because `BlankCanvasContract` does not exist.

- [ ] **Step 3: Add the pixel contract**

Create `Sources/MetalRenderer/BlankCanvasContract.swift`:

```swift
public enum BlankCanvasContract {
    public static let canvasBGRA = SIMD4<UInt8>(241, 244, 242, 255)

    public static func matches(
        actual: SIMD4<UInt8>,
        expected: SIMD4<UInt8>,
        tolerance: UInt8
    ) -> Bool {
        let maximumDelta = Int(tolerance)
        return abs(Int(actual.x) - Int(expected.x)) <= maximumDelta
            && abs(Int(actual.y) - Int(expected.y)) <= maximumDelta
            && abs(Int(actual.z) - Int(expected.z)) <= maximumDelta
            && abs(Int(actual.w) - Int(expected.w)) <= maximumDelta
    }
}
```

- [ ] **Step 4: Add typed renderer failures**

Create `Sources/MetalRenderer/MetalRendererError.swift`:

```swift
import Foundation

public enum MetalRendererError: Error, Equatable, LocalizedError {
    case commandQueueUnavailable
    case defaultLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case textureAllocationFailed
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            "Metal command queue creation failed."
        case .defaultLibraryUnavailable:
            "The app Metal library is unavailable."
        case let .shaderFunctionUnavailable(name):
            "Metal shader function '\(name)' is unavailable."
        case let .pipelineCreationFailed(message):
            "Metal pipeline creation failed: \(message)"
        case .textureAllocationFailed:
            "Metal render texture allocation failed."
        case .commandBufferUnavailable:
            "Metal command buffer creation failed."
        case .renderEncoderUnavailable:
            "Metal render encoder creation failed."
        case let .commandFailed(message):
            "Metal command execution failed: \(message)"
        }
    }
}
```

- [ ] **Step 5: Add the onscreen/offscreen renderer**

Create `Sources/MetalRenderer/BlankRenderer.swift`:

```swift
import Foundation
import Metal
import MetalKit

public struct GPUFrameMetrics: Codable, Equatable, Sendable {
    public let cpuEncodeMilliseconds: Double
    public let gpuMilliseconds: Double

    public init(
        cpuEncodeMilliseconds: Double,
        gpuMilliseconds: Double
    ) {
        self.cpuEncodeMilliseconds = cpuEncodeMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
    }
}

@MainActor
public struct RenderedFrame {
    public let texture: any MTLTexture
    public let metrics: GPUFrameMetrics
}

@MainActor
public final class BlankRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public private(set) var lastError: MetalRendererError?

    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState

    public convenience init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(device: device, library: library)
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws {
        ShaderABI.preconditionValid()

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        guard let vertexFunction = library.makeFunction(name: "patternBlankVertex") else {
            throw MetalRendererError.shaderFunctionUnavailable("patternBlankVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "patternBlankFragment") else {
            throw MetalRendererError.shaderFunctionUnavailable("patternBlankFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Blank Canvas Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }

        self.device = device
        self.commandQueue = commandQueue
        super.init()
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            lastError = .commandBufferUnavailable
            view.isPaused = true
            return
        }

        do {
            try encode(into: drawable.texture, commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch let error as MetalRendererError {
            lastError = error
            view.isPaused = true
        } catch {
            lastError = .commandFailed(error.localizedDescription)
            view.isPaused = true
        }
    }

    public func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {}

    public func renderOffscreen(
        width: Int,
        height: Int
    ) throws -> RenderedFrame {
        precondition((1...4096).contains(width), "Offscreen width is outside 1...4096")
        precondition((1...4096).contains(height), "Offscreen height is outside 1...4096")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let encodeStart = CFAbsoluteTimeGetCurrent()
        try encode(into: texture, commandBuffer: commandBuffer)
        let cpuMilliseconds = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1_000

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            throw MetalRendererError.commandFailed(
                commandBuffer.error?.localizedDescription ?? "unknown command-buffer error"
            )
        }

        let gpuMilliseconds = max(
            0,
            (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
        )
        return RenderedFrame(
            texture: texture,
            metrics: GPUFrameMetrics(
                cpuEncodeMilliseconds: cpuMilliseconds,
                gpuMilliseconds: gpuMilliseconds
            )
        )
    }

    private func encode(
        into texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }

        encoder.label = "Blank Canvas Pass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
```

- [ ] **Step 6: Run the pure tests**

Run:

```bash
swift test
```

Expected: PASS, 7 tests run, 0 failures. No `BlankRenderer` initializer is invoked by these tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/MetalRenderer/MetalRendererError.swift Sources/MetalRenderer/BlankCanvasContract.swift Sources/MetalRenderer/BlankRenderer.swift Tests/MetalRendererTests/BlankCanvasContractTests.swift
git commit -m "feat: add blank Metal renderer"
```

---

### Task 4: Add Scripted Capture And Benchmark Contracts

**Files:**
- Create: `Sources/MetalRenderer/BenchmarkRecord.swift`
- Create: `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Create: `Sources/MetalRenderer/Capture/PNGWriter.swift`
- Create: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Create: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Create: `Tests/MetalRendererTests/BenchmarkRecordTests.swift`

**Interfaces:**
- Consumes: `BlankRenderer.renderOffscreen(width:height:)`, `BlankCanvasContract.matches(actual:expected:tolerance:)`, and `.bgra8Unorm` textures.
- Produces: versioned `HarnessScene.decode(_:)`; `BenchmarkRecord`; `PNGWriter.write(texture:to:)`; `HarnessRunner.run(scene:outputDirectory:build:)`; deterministic `.screen.png` and `.benchmark.json` artifacts.

- [ ] **Step 1: Write failing scene-schema tests**

Create `Tests/MetalRendererTests/HarnessSceneTests.swift`:

```swift
import Foundation
import MetalRenderer
import Testing

@Test
func harnessSceneDecodesAndValidates() throws {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "blank-canvas",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 32,
              "y": 32,
              "expectedBGRA": [241, 244, 242, 255],
              "tolerance": 1
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.name == "blank-canvas")
    #expect(scene.width == 64)
    #expect(scene.height == 64)
    #expect(scene.checks.count == 1)
    #expect(scene.checks[0].expectedBGRA == [241, 244, 242, 255])
}

@Test
func harnessSceneRejectsAnUnknownSchema() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "future-scene",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 0,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.unsupportedSchema(2)) {
        try HarnessScene.decode(data)
    }
}

@Test
func harnessSceneRejectsAnOutOfBoundsPixelCheck() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "name": "bad-coordinate",
          "width": 64,
          "height": 64,
          "checks": [
            {
              "x": 64,
              "y": 0,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 0
            }
          ]
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.invalidCheckCoordinate(x: 64, y: 0)) {
        try HarnessScene.decode(data)
    }
}
```

- [ ] **Step 2: Write the failing benchmark round-trip test**

Create `Tests/MetalRendererTests/BenchmarkRecordTests.swift`:

```swift
import Foundation
import MetalRenderer
import Testing

@Test
func benchmarkRecordRoundTripsWithoutLosingMetrics() throws {
    let record = BenchmarkRecord(
        schemaVersion: 1,
        timestampUTC: "2026-07-18T12:00:00Z",
        sceneName: "blank-canvas",
        hardware: BenchmarkHardware(
            gpuName: "Test GPU",
            logicalProcessorCount: 8,
            physicalMemoryBytes: 16_000_000_000
        ),
        operatingSystem: "macOS Test",
        build: BenchmarkBuild(
            configuration: "Debug",
            gitCommit: "0123456789abcdef"
        ),
        frameCount: 1,
        cpuEncodeMilliseconds: [0.25],
        gpuMilliseconds: [0.50],
        peakResidentBytes: 42_000_000
    )

    let data = try BenchmarkRecord.encode(record)
    let decoded = try JSONDecoder().decode(BenchmarkRecord.self, from: data)

    #expect(decoded == record)
}
```

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
swift test
```

Expected: FAIL because the scene and benchmark types do not exist.

- [ ] **Step 4: Implement the versioned scene schema**

Create `Sources/MetalRenderer/Capture/HarnessScene.swift`:

```swift
import Foundation

public struct HarnessPixelCheck: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let expectedBGRA: [UInt8]
    public let tolerance: UInt8
}

public struct HarnessScene: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let checks: [HarnessPixelCheck]

    public static func decode(_ data: Data) throws -> HarnessScene {
        let scene = try JSONDecoder().decode(HarnessScene.self, from: data)
        try scene.validate()
        return scene
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw HarnessSceneError.unsupportedSchema(schemaVersion)
        }
        guard !name.isEmpty else {
            throw HarnessSceneError.emptyName
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw HarnessSceneError.invalidDimensions(width: width, height: height)
        }
        guard !checks.isEmpty else {
            throw HarnessSceneError.missingPixelChecks
        }

        for check in checks {
            guard (0..<width).contains(check.x), (0..<height).contains(check.y) else {
                throw HarnessSceneError.invalidCheckCoordinate(x: check.x, y: check.y)
            }
            guard check.expectedBGRA.count == 4 else {
                throw HarnessSceneError.invalidExpectedPixelCount(
                    check.expectedBGRA.count
                )
            }
        }
    }
}

public enum HarnessSceneError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyName
    case invalidDimensions(width: Int, height: Int)
    case missingPixelChecks
    case invalidCheckCoordinate(x: Int, y: Int)
    case invalidExpectedPixelCount(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported harness scene schema \(version)."
        case .emptyName:
            "Harness scene name is empty."
        case let .invalidDimensions(width, height):
            "Harness dimensions \(width)x\(height) are outside 1...4096."
        case .missingPixelChecks:
            "Harness scene has no pixel checks."
        case let .invalidCheckCoordinate(x, y):
            "Harness check coordinate (\(x), \(y)) is outside the scene."
        case let .invalidExpectedPixelCount(count):
            "Expected BGRA pixel has \(count) components instead of 4."
        }
    }
}
```

- [ ] **Step 5: Implement the benchmark schema**

Create `Sources/MetalRenderer/BenchmarkRecord.swift`:

```swift
import Foundation

public struct BenchmarkHardware: Codable, Equatable, Sendable {
    public let gpuName: String
    public let logicalProcessorCount: Int
    public let physicalMemoryBytes: UInt64

    public init(
        gpuName: String,
        logicalProcessorCount: Int,
        physicalMemoryBytes: UInt64
    ) {
        self.gpuName = gpuName
        self.logicalProcessorCount = logicalProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public struct BenchmarkBuild: Codable, Equatable, Sendable {
    public let configuration: String
    public let gitCommit: String

    public init(configuration: String, gitCommit: String) {
        self.configuration = configuration
        self.gitCommit = gitCommit
    }
}

public struct BenchmarkRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestampUTC: String
    public let sceneName: String
    public let hardware: BenchmarkHardware
    public let operatingSystem: String
    public let build: BenchmarkBuild
    public let frameCount: Int
    public let cpuEncodeMilliseconds: [Double]
    public let gpuMilliseconds: [Double]
    public let peakResidentBytes: UInt64

    public init(
        schemaVersion: Int,
        timestampUTC: String,
        sceneName: String,
        hardware: BenchmarkHardware,
        operatingSystem: String,
        build: BenchmarkBuild,
        frameCount: Int,
        cpuEncodeMilliseconds: [Double],
        gpuMilliseconds: [Double],
        peakResidentBytes: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.timestampUTC = timestampUTC
        self.sceneName = sceneName
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.build = build
        self.frameCount = frameCount
        self.cpuEncodeMilliseconds = cpuEncodeMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.peakResidentBytes = peakResidentBytes
    }

    public static func encode(_ record: BenchmarkRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }
}
```

- [ ] **Step 6: Implement cold-path PNG capture**

Create `Sources/MetalRenderer/Capture/PNGWriter.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum PNGWriter {
    @MainActor
    public static func pixel(
        in texture: any MTLTexture,
        x: Int,
        y: Int
    ) -> SIMD4<UInt8> {
        precondition(texture.pixelFormat == .bgra8Unorm)
        precondition((0..<texture.width).contains(x))
        precondition((0..<texture.height).contains(y))

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 4,
                from: MTLRegionMake2D(x, y, 1, 1),
                mipmapLevel: 0
            )
        }
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }

    @MainActor
    public static func write(
        texture: any MTLTexture,
        to url: URL
    ) throws {
        guard texture.pixelFormat == .bgra8Unorm else {
            throw PNGWriterError.unsupportedPixelFormat(texture.pixelFormat.rawValue)
        }

        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * texture.height
        )
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw PNGWriterError.dataProviderCreationFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PNGWriterError.imageCreationFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PNGWriterError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGWriterError.finalizeFailed
        }
    }
}

public enum PNGWriterError: Error, Equatable, LocalizedError {
    case unsupportedPixelFormat(UInt)
    case dataProviderCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPixelFormat(rawValue):
            "Unsupported capture pixel format \(rawValue)."
        case .dataProviderCreationFailed:
            "PNG data provider creation failed."
        case .imageCreationFailed:
            "PNG image creation failed."
        case .destinationCreationFailed:
            "PNG destination creation failed."
        case .finalizeFailed:
            "PNG encoding failed."
        }
    }
}
```

- [ ] **Step 7: Implement deterministic scene execution**

Create `Sources/MetalRenderer/Capture/HarnessRunner.swift`:

```swift
import Darwin
import Foundation
import Metal

public struct HarnessRunResult: Equatable, Sendable {
    public let imageURL: URL
    public let benchmarkURL: URL
    public let benchmark: BenchmarkRecord
}

public enum HarnessRunError: Error, Equatable, LocalizedError {
    case processMetricsUnavailable
    case pixelMismatch(
        x: Int,
        y: Int,
        expected: [UInt8],
        actual: [UInt8],
        tolerance: UInt8
    )

    public var errorDescription: String? {
        switch self {
        case .processMetricsUnavailable:
            "Peak resident-memory measurement is unavailable."
        case let .pixelMismatch(x, y, expected, actual, tolerance):
            "Pixel mismatch at (\(x), \(y)): expected \(expected), actual \(actual), tolerance \(tolerance)."
        }
    }
}

@MainActor
public final class HarnessRunner {
    private let renderer: BlankRenderer

    public init(device: any MTLDevice) throws {
        renderer = try BlankRenderer(device: device)
    }

    public func run(
        scene: HarnessScene,
        outputDirectory: URL,
        build: BenchmarkBuild
    ) throws -> HarnessRunResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let frame = try renderer.renderOffscreen(
            width: scene.width,
            height: scene.height
        )
        let imageURL = outputDirectory
            .appendingPathComponent("\(scene.name).screen.png")

        try PNGWriter.write(texture: frame.texture, to: imageURL)

        for check in scene.checks {
            let actual = PNGWriter.pixel(
                in: frame.texture,
                x: check.x,
                y: check.y
            )
            let expected = SIMD4(
                check.expectedBGRA[0],
                check.expectedBGRA[1],
                check.expectedBGRA[2],
                check.expectedBGRA[3]
            )
            guard BlankCanvasContract.matches(
                actual: actual,
                expected: expected,
                tolerance: check.tolerance
            ) else {
                throw HarnessRunError.pixelMismatch(
                    x: check.x,
                    y: check.y,
                    expected: check.expectedBGRA,
                    actual: [actual.x, actual.y, actual.z, actual.w],
                    tolerance: check.tolerance
                )
            }
        }

        let processInfo = ProcessInfo.processInfo
        let record = BenchmarkRecord(
            schemaVersion: 1,
            timestampUTC: ISO8601DateFormatter().string(from: Date()),
            sceneName: scene.name,
            hardware: BenchmarkHardware(
                gpuName: renderer.device.name,
                logicalProcessorCount: processInfo.activeProcessorCount,
                physicalMemoryBytes: processInfo.physicalMemory
            ),
            operatingSystem: processInfo.operatingSystemVersionString,
            build: build,
            frameCount: 1,
            cpuEncodeMilliseconds: [frame.metrics.cpuEncodeMilliseconds],
            gpuMilliseconds: [frame.metrics.gpuMilliseconds],
            peakResidentBytes: try Self.peakResidentBytes()
        )
        let benchmarkURL = outputDirectory
            .appendingPathComponent("\(scene.name).benchmark.json")
        try BenchmarkRecord.encode(record).write(
            to: benchmarkURL,
            options: .atomic
        )

        return HarnessRunResult(
            imageURL: imageURL,
            benchmarkURL: benchmarkURL,
            benchmark: record
        )
    }

    private static func peakResidentBytes() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw HarnessRunError.processMetricsUnavailable
        }
        return UInt64(usage.ru_maxrss)
    }
}
```

- [ ] **Step 8: Run all pure tests**

Run:

```bash
swift test
```

Expected: PASS, 11 tests run, 0 failures. The scene parser and benchmark schema are verified; GPU rendering is still unclaimed.

- [ ] **Step 9: Commit**

```bash
git add Sources/MetalRenderer/BenchmarkRecord.swift Sources/MetalRenderer/Capture Tests/MetalRendererTests/HarnessSceneTests.swift Tests/MetalRendererTests/BenchmarkRecordTests.swift
git commit -m "feat: add render harness contracts"
```

---

### Task 5: Generate The macOS And iPadOS App Targets

**Files:**
- Modify: `.gitignore`
- Create: `App/project.yml`
- Create: `App/PatternSpike/PatternSpikeApp.swift`
- Create: `App/PatternSpike/ContentView.swift`
- Create: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Create: `App/PatternSpike/Harness/HarnessLaunch.swift`
- Create: `App/PatternSpike/Assets.xcassets/Contents.json`
- Create: `App/PatternSpike/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `scripts/bootstrap.sh`

**Interfaces:**
- Consumes: the local `MetalRenderer` package product and the shader header/source from Tasks 2-4.
- Produces: generated `App/PatternSpike.xcodeproj`; schemes `PatternSpikeMac` and `PatternSpikePad`; an onscreen `MTKView`; CLI contract `--harness-scene`, `--output-directory`, `--git-commit`, and `--configuration`.

- [ ] **Step 1: Verify the development-only project generator**

Run on the Mac:

```bash
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
xcodegen version
```

Expected: `Version: 2.46.0` or a newer stable version. XcodeGen is a build-time tool and is not linked into the app.

- [ ] **Step 2: Add the generated-project ignore rule**

Append to `.gitignore`:

```gitignore
App/PatternSpike.xcodeproj/
```

- [ ] **Step 3: Add the XcodeGen project contract**

Create `App/project.yml`:

```yaml
name: PatternSpike

options:
  minimumXcodeGenVersion: 2.46.0
  createIntermediateGroups: true

packages:
  PatternModules:
    path: ..

settings:
  base:
    SWIFT_VERSION: 6.0
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: true
    HEADER_SEARCH_PATHS: "$(SRCROOT)/../Sources/CShaderTypes/include"
    MTL_HEADER_SEARCH_PATHS: "$(SRCROOT)/../Sources/CShaderTypes/include"

targets:
  PatternSpikeMac:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: PatternSpike
      - path: ../Sources/MetalRenderer/Shaders.metal
        buildPhase: sources
    dependencies:
      - package: PatternModules
        product: MetalRenderer
    settings:
      base:
        PRODUCT_NAME: PatternSpike
        PRODUCT_BUNDLE_IDENTIFIER: com.anubhav.patternspike
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_CFBundleDisplayName: Pattern
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: 0.1.0

  PatternSpikePad:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: PatternSpike
      - path: ../Sources/MetalRenderer/Shaders.metal
        buildPhase: sources
    dependencies:
      - package: PatternModules
        product: MetalRenderer
    settings:
      base:
        PRODUCT_NAME: PatternSpikePad
        PRODUCT_BUNDLE_IDENTIFIER: com.anubhav.patternspike.pad
        GENERATE_INFOPLIST_FILE: true
        INFOPLIST_KEY_CFBundleDisplayName: Pattern
        INFOPLIST_KEY_UILaunchScreen_Generation: true
        TARGETED_DEVICE_FAMILY: 2
        CURRENT_PROJECT_VERSION: 1
        MARKETING_VERSION: 0.1.0

schemes:
  PatternSpikeMac:
    build:
      targets:
        PatternSpikeMac: all
    run:
      config: Debug

  PatternSpikePad:
    build:
      targets:
        PatternSpikePad: all
    run:
      config: Debug
```

Create `scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' "xcodegen is required. Install XcodeGen 2.46.0 or newer."
  exit 1
fi

printf 'Using %s\n' "$(xcodegen version)"
cd "$repo_root/App"
xcodegen generate --spec project.yml
```

Make it executable:

```bash
chmod +x scripts/bootstrap.sh
```

- [ ] **Step 4: Verify generation rejects the missing app sources**

Run:

```bash
./scripts/bootstrap.sh
```

Expected: FAIL with an XcodeGen validation error because `App/PatternSpike` does not exist.

- [ ] **Step 5: Add the app entry point and explicit unsupported state**

Create `App/PatternSpike/PatternSpikeApp.swift`:

```swift
import SwiftUI

@main
struct PatternSpikeApp: App {
    init() {
        HarnessLaunch.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Create `App/PatternSpike/ContentView.swift`:

```swift
import Metal
import MetalRenderer
import SwiftUI

struct ContentView: View {
    private let state: CanvasState

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable("Pattern requires a Metal-capable Apple device.")
            return
        }

        do {
            state = .ready(try BlankRenderer(device: device))
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            switch state {
            case let .ready(renderer):
                MetalCanvas(renderer: renderer)
            case let .unavailable(message):
                ContentUnavailableView(
                    "Renderer Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum CanvasState {
        case ready(BlankRenderer)
        case unavailable(String)
    }
}
```

- [ ] **Step 6: Add the platform-specific `MTKView` host**

Create `App/PatternSpike/Canvas/MetalCanvas.swift`:

```swift
import MetalKit
import MetalRenderer
import SwiftUI

private func configure(
    _ view: MTKView,
    renderer: BlankRenderer
) {
    view.device = renderer.device
    view.delegate = renderer
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
}

#if os(macOS)
import AppKit

struct MetalCanvas: NSViewRepresentable {
    let renderer: BlankRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
#else
import UIKit

struct MetalCanvas: UIViewRepresentable {
    let renderer: BlankRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
```

- [ ] **Step 7: Add harness command-line launch behavior**

Create `App/PatternSpike/Harness/HarnessLaunch.swift`:

```swift
import Darwin
import Foundation
import Metal
import MetalRenderer

enum HarnessLaunch {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.contains("--harness-scene") else {
            return
        }

        do {
            let scenePath = try value(after: "--harness-scene", in: arguments)
            let outputPath = try value(after: "--output-directory", in: arguments)
            let gitCommit = try value(after: "--git-commit", in: arguments)
            let configuration = try value(after: "--configuration", in: arguments)

            guard let device = MTLCreateSystemDefaultDevice() else {
                throw HarnessLaunchError.metalUnavailable
            }

            let sceneData = try Data(contentsOf: URL(fileURLWithPath: scenePath))
            let scene = try HarnessScene.decode(sceneData)
            let result = try HarnessRunner(device: device).run(
                scene: scene,
                outputDirectory: URL(fileURLWithPath: outputPath),
                build: BenchmarkBuild(
                    configuration: configuration,
                    gitCommit: gitCommit
                )
            )

            print(
                "HARNESS PASS scene=\(scene.name) image=\(result.imageURL.path) benchmark=\(result.benchmarkURL.path)"
            )
            exit(EXIT_SUCCESS)
        } catch {
            let message = "HARNESS FAIL \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func value(
        after flag: String,
        in arguments: [String]
    ) throws -> String {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            throw HarnessLaunchError.missingArgument(flag)
        }
        return arguments[index + 1]
    }
}

enum HarnessLaunchError: Error, LocalizedError {
    case missingArgument(String)
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case let .missingArgument(flag):
            "Missing required harness argument \(flag)."
        case .metalUnavailable:
            "Metal is unavailable."
        }
    }
}
```

- [ ] **Step 8: Add the minimal asset catalog**

Create `App/PatternSpike/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Create `App/PatternSpike/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.376",
          "green" : "0.467",
          "red" : "0.098"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 9: Generate and build both platforms**

Run:

```bash
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
```

Expected: both commands end with `** BUILD SUCCEEDED **`. The iPadOS command is a compile gate, not a device-behavior claim.

- [ ] **Step 10: Confirm the generated project is ignored**

Run:

```bash
git status --short
```

Expected: `App/PatternSpike.xcodeproj/`, `.build/DerivedData/`, and `.build/DerivedDataPad/` do not appear.

- [ ] **Step 11: Commit**

```bash
git add .gitignore App/project.yml App/PatternSpike scripts/bootstrap.sh
git commit -m "feat: add native Apple app shell"
```

---

### Task 6: Close The Slice 0 Verification Gate

**Files:**
- Create: `App/PatternSpike/Harness/Scenes/blank-canvas.json`
- Create: `App/PatternSpike/Harness/Scenes/blank-canvas-negative-control.json`
- Create: `scripts/verify-slice0.sh`
- Create after the gate passes: `docs/superpowers/milestones/00-foundation-harness.md`

**Interfaces:**
- Consumes: `PatternSpikeMac`, the harness CLI from Task 5, and the deterministic neutral pixel from Task 3.
- Produces: a single `./scripts/verify-slice0.sh` gate; positive PNG/benchmark artifacts under `.build/slice0-artifacts/`; a recorded negative-control failure; a short milestone decision note.

- [ ] **Step 1: Add the positive scripted scene**

Create `App/PatternSpike/Harness/Scenes/blank-canvas.json`:

```json
{
  "schemaVersion": 1,
  "name": "blank-canvas",
  "width": 64,
  "height": 64,
  "checks": [
    {
      "x": 0,
      "y": 0,
      "expectedBGRA": [241, 244, 242, 255],
      "tolerance": 1
    },
    {
      "x": 32,
      "y": 32,
      "expectedBGRA": [241, 244, 242, 255],
      "tolerance": 1
    },
    {
      "x": 63,
      "y": 63,
      "expectedBGRA": [241, 244, 242, 255],
      "tolerance": 1
    }
  ]
}
```

- [ ] **Step 2: Add a deliberate negative control**

Create `App/PatternSpike/Harness/Scenes/blank-canvas-negative-control.json`:

```json
{
  "schemaVersion": 1,
  "name": "blank-canvas-negative-control",
  "width": 64,
  "height": 64,
  "checks": [
    {
      "x": 32,
      "y": 32,
      "expectedBGRA": [0, 0, 0, 255],
      "tolerance": 0
    }
  ]
}
```

- [ ] **Step 3: Add the complete automated gate**

Create `scripts/verify-slice0.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
pad_derived_data="$repo_root/.build/DerivedDataPad"
artifacts="$repo_root/.build/slice0-artifacts"
mac_log="$repo_root/.build/slice0-macos-build.log"
pad_log="$repo_root/.build/slice0-ipados-build.log"
test_log="$repo_root/.build/slice0-swift-test.log"

cd "$repo_root"
mkdir -p "$artifacts/positive" "$artifacts/negative-control"

./scripts/bootstrap.sh

swift test >"$test_log"

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$mac_log"

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$pad_derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$pad_log"

binary="$derived_data/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
git_commit="$(git rev-parse HEAD)"

if "$binary" \
  --harness-scene "$repo_root/App/PatternSpike/Harness/Scenes/blank-canvas-negative-control.json" \
  --output-directory "$artifacts/negative-control" \
  --git-commit "$git_commit" \
  --configuration Debug \
  >"$artifacts/negative-control/stdout.log" \
  2>"$artifacts/negative-control/stderr.log"
then
  printf '%s\n' "Negative control unexpectedly passed."
  exit 1
fi

grep -q "HARNESS FAIL" "$artifacts/negative-control/stderr.log"
printf '%s\n' "negative-control=failed-as-expected"

"$binary" \
  --harness-scene "$repo_root/App/PatternSpike/Harness/Scenes/blank-canvas.json" \
  --output-directory "$artifacts/positive" \
  --git-commit "$git_commit" \
  --configuration Debug \
  | tee "$artifacts/positive/stdout.log"

test -s "$artifacts/positive/blank-canvas.screen.png"
test -s "$artifacts/positive/blank-canvas.benchmark.json"
grep -q '"sceneName" : "blank-canvas"' "$artifacts/positive/blank-canvas.benchmark.json"
grep -q '"frameCount" : 1' "$artifacts/positive/blank-canvas.benchmark.json"

printf '%s\n' "swift-tests=passed"
printf '%s\n' "macos-build=passed"
printf '%s\n' "ipados-simulator-build=passed"
printf '%s\n' "offscreen-harness=passed"
printf '%s\n' "SLICE0 AUTOMATED GATE PASS"
```

Make it executable:

```bash
chmod +x scripts/verify-slice0.sh
```

- [ ] **Step 4: Run the automated gate**

Run:

```bash
./scripts/verify-slice0.sh
```

Expected final output:

```text
negative-control=failed-as-expected
HARNESS PASS scene=blank-canvas image=... benchmark=...
swift-tests=passed
macos-build=passed
ipados-simulator-build=passed
offscreen-harness=passed
SLICE0 AUTOMATED GATE PASS
```

Also inspect:

```bash
cat .build/slice0-artifacts/positive/blank-canvas.benchmark.json
```

Expected: schema version 1; the current GPU, processor count, physical memory, OS, Debug build, current Git commit, one CPU timing, one GPU timing, one frame, and nonzero peak resident bytes.

- [ ] **Step 5: Run the manual macOS/VNC gate**

Run:

```bash
open .build/DerivedData/Build/Products/Debug/PatternSpike.app
```

Expected:

- The app opens a resizable macOS window.
- The entire content region is the uniform Precision Light neutral canvas.
- No black frame, transparency, stale edge, or resize artifact appears.
- The process remains responsive while the window is repeatedly resized.
- User confirms the visual result over VNC before Slice 0 is accepted.

- [ ] **Step 6: Record the milestone decision after both gates pass**

Create `docs/superpowers/milestones/00-foundation-harness.md`:

```markdown
# Slice 0: Foundation And Harness

**Status:** Accepted
**Gate:** `./scripts/verify-slice0.sh`

## Result

- Swift package tests passed.
- The macOS app built and rendered the blank canvas onscreen.
- The iPadOS simulator target compiled; no iPad hardware behavior is claimed.
- The real app metallib rendered the scripted scene offscreen.
- The negative-control scene exited nonzero before the positive scene passed.
- PNG and benchmark JSON were emitted under `.build/slice0-artifacts/positive/`.

## Decisions

- `App/project.yml` is the project source of truth; generated Xcode project files remain disposable.
- GPU verification stays in the app executable so tests cannot accidentally use a different metallib.
- Harness scenes use versioned JSON and exact BGRA checks with explicit tolerance.
- Slice 1 may build on `BlankRenderer`; it must replace the blank-pass name when the measured grid drawing pipeline arrives.

## Retrospective

The foundation now distinguishes pure contracts, app builds, real GPU assertions, and manual visual acceptance. No drawing, tiling, or document behavior is inferred from this gate.
```

- [ ] **Step 7: Confirm repository hygiene**

Run:

```bash
git status --short
```

Expected: only the two scene files, verification script, and milestone note are uncommitted. Generated projects, build logs, PNGs, and benchmark JSON do not appear.

- [ ] **Step 8: Commit**

```bash
git add App/PatternSpike/Harness/Scenes scripts/verify-slice0.sh docs/superpowers/milestones/00-foundation-harness.md
git commit -m "test: close foundation harness gate"
```

---

## Slice 0 Exit Checklist

- [ ] `swift test` passes all CPU-only tests.
- [ ] The shared shader layout is checked by tests and a renderer startup precondition.
- [ ] `PatternSpikeMac` builds for macOS 14 or newer.
- [ ] `PatternSpikePad` builds for an iPadOS 17 simulator destination.
- [ ] The generated Xcode project and all build artifacts remain ignored.
- [ ] The app’s real metallib produces the expected offscreen BGRA pixels.
- [ ] The negative-control scene exits nonzero.
- [ ] The positive scene emits a nonempty PNG and complete benchmark JSON.
- [ ] The blank canvas renders uniformly onscreen and remains correct during resize.
- [ ] The user accepts the Mac/VNC visual gate.
- [ ] The milestone note is committed.
- [ ] No Slice 1 drawing or tiling behavior has leaked into this slice.
