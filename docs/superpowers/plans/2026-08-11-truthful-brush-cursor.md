# Truthful Brush Cursor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the nominal circular macOS brush cursor with a stable, allocation-free-per-hover evaluation of the active compiled tip, including neutral dynamics, aspect, authored shape transforms, sensor orientation, reflection, zoom, backing scale, and conservative scatter.

**Architecture:** `PatternEngine` owns a renderer-free `BrushCursorDescriptor` evaluator. It evaluates the existing compiled `BrushProgram` through `BrushDynamicsEngine`, composes Task 15's cached tip profile with the evaluated affine frame, and returns core layers plus a stable envelope. `MetalRenderer.CompiledBrush` precomputes the profile once at compilation, while the macOS canvas supplies normalized hover input and draws the descriptor without reading texture bytes.

**Tech Stack:** Swift 6, Swift Testing, PatternEngine affine geometry, AppKit/MetalKit, existing MetalRenderer compiled-tip metadata.

## Global Constraints

- Continue in the shared dirty `main` checkout; preserve every unrelated change.
- Do not stage, commit, push, or create a pull request.
- Circular analytic tips remain analytic; asset cursors consume Task 15 metadata only and never texture bytes.
- The pointer-move descriptor path must not allocate transformed point arrays.
- Missing hover pressure remains absent so each compiled sensor term uses its declared missing-input value.
- Core/support agreement must reach IoU >= 0.85 and maximum edge error <= 1.5 logical pixels in controlled single-dab cases.

---

### Task 1: Pure evaluated cursor geometry

**Files:**

- Create: `Sources/PatternEngine/BrushCursorDescriptor.swift`
- Create: `Tests/PatternEngineTests/BrushCursorDescriptorTests.swift`

**Interfaces:**

- Consumes: `BrushProgram`, `BrushDynamicsEngine.evaluate`, `Affine2D`, `BrushTipAssetSupport.contour`, and `BrushShapeCombinationMode`.
- Produces: `BrushCursorTipProfile`, `BrushCursorInput`, `BrushCursorLayerDescriptor`, and `BrushCursorDescriptor.evaluate(program:profile:input:)`.

- [x] **Step 1: Write the failing transform tests**

Add tests that construct current-schema fixture programs and assert:

```swift
let descriptor = try BrushCursorDescriptor.evaluate(
    program: program,
    profile: .init(primary: .analyticEllipse),
    input: BrushCursorInput(
        nominalDiameter: 40,
        pressure: nil,
        altitude: nil,
        azimuth: nil,
        roll: nil,
        tangentialPressure: nil,
        direction: 0,
        deformation: .identity,
        viewportScale: 2,
        backingScale: 2
    )
)
#expect(descriptor.coreBounds.width == 40)
#expect(descriptor.coreBounds.height == 40)
```

Cover circle, ellipse/aspect, chisel rectangle, authored rotation, dynamic rotation, reflection, zoom, backing scale, and absent pressure. Assert asset contours share their cached array storage semantically by verifying the descriptor retains the exact untransformed contour and only changes its affine frame.

- [x] **Step 2: Run the pure tests and verify RED**

Run:

```bash
swift test --filter BrushCursorDescriptorTests
```

Expected: compilation fails because the cursor descriptor types do not exist.

- [x] **Step 3: Implement the minimal descriptor domain**

Define a cached profile and a value-only evaluated layer:

```swift
public enum BrushCursorTipShape: Equatable, Sendable {
    case analyticEllipse
    case analyticRectangle
    case contour([SIMD2<Float>])
}

public struct BrushCursorTipProfile: Equatable, Sendable {
    public let primary: BrushCursorTipShape
    public let secondary: BrushCursorTipShape?
}

public struct BrushCursorLayerDescriptor: Equatable, Sendable {
    public let shape: BrushCursorTipShape
    public let normalizedTipToLogical: Affine2D
}
```

`BrushCursorInput` carries optional sensors, direction, deformation, viewport scale, and backing scale. Its initializer rejects nonfinite/nonpositive scale and diameter with a typed `BrushCursorDescriptorError`.

Build an `InterpolatedStrokeSample` whose capabilities contain only sensors actually present. Evaluate one stable core with `BrushDynamicsEngine`, `BrushRandomValues.centered`, ordinal zero, and a fixed nonzero seed. Recover the common evaluated tip frame from the primary authored shape and use it to compose an optional secondary shape frame. Apply deformation and `viewportScale / backingScale` after world evaluation.

Do not map the contour into a new array. Store the cached contour and its affine frame. Compute bounds with scalar loops. Recognize a circle only when the effective ellipse axes are orthogonal and equal within tolerance and there is no secondary shape.

The descriptor exposes:

```swift
public let primary: BrushCursorLayerDescriptor
public let secondary: BrushCursorLayerDescriptor?
public let secondaryCombination: BrushShapeCombinationMode?
public let coreBounds: BrushCursorBounds
public let envelopeBounds: BrushCursorBounds
public let isCircle: Bool
public func containsCore(_ point: SIMD2<Float>) -> Bool
```

`containsCore` inverse-transforms the point and applies the same replace/multiply/minimum/maximum occupancy rule as deposition. `envelopeBounds` expands the core by the maximum authored scatter plus placement jitter in logical pixels; it remains stable across pointer moves.

- [x] **Step 4: Run pure tests and verify GREEN**

Run:

```bash
swift test --filter BrushCursorDescriptorTests
```

Expected: all descriptor tests pass.

---

### Task 2: Precompute the compiled cursor profile

**Files:**

- Modify: `Sources/MetalRenderer/BrushCompiler/CompiledBrush.swift`
- Modify: `Sources/MetalRenderer/BrushCompiler/BrushCompiler.swift`
- Modify: `Tests/MetalRendererTests/BrushCompilerTests.swift`

**Interfaces:**

- Consumes: Task 15 `CompiledBrushTipSupport.source` and `.assetSupport.contour`.
- Produces: immutable `CompiledBrush.cursorTipProfile` and `CompiledBrush.cursorDescriptor(input:)`.

- [x] **Step 1: Write the failing compilation-profile tests**

Compile analytic round, chisel, textured, and dual-shape brushes. Assert the compiled profiles are respectively ellipse, rectangle, cached contour, and two ordered shapes with the definition's secondary combination. Capture compiler diagnostics before and after repeated `cursorDescriptor(input:)` calls and assert package decode, image decode, upload, cache, and activation counters do not change.

- [x] **Step 2: Run the compiler tests and verify RED**

Run:

```bash
swift test --filter 'BrushCompilerTests.*cursor|BrushCursorDescriptorTests'
```

Expected: compilation fails because `cursorTipProfile` is absent.

- [x] **Step 3: Build and retain the profile once**

Map each compiled source without inspecting an `MTLTexture`:

```swift
switch support.source {
case .analyticEllipse: .analyticEllipse
case .analyticRectangle: .analyticRectangle
case .texture: .contour(try require(support.assetSupport).contour)
}
```

Pass the finished profile into `CompiledBrush.init`, store it as a public immutable property, and expose a thin descriptor method delegating to `PatternEngine`. Profile construction remains in the cold compiler path; calls only copy value metadata and retain the existing contour buffer.

- [x] **Step 4: Run the focused compiler and descriptor tests**

Run:

```bash
swift test --filter 'BrushCompilerTests.*cursor|BrushCursorDescriptorTests'
```

Expected: all selected tests pass and compiler counters remain unchanged.

---

### Task 3: Route native hover and canvas updates

**Files:**

- Modify: `App/PatternSpike/Input/BrushInputAdapter.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `Package.swift`
- Create: `App/Tests/BrushCursorIntegrationTests.swift`
- Modify: `App/Tests/EditorSessionControllerTests.swift`

**Interfaces:**

- Consumes: `CompiledBrush.cursorDescriptor(input:)`, `GridRenderer.preparedBrush(for:)`, normalized AppKit hover/tablet input, viewport zoom, and drawable backing scale.
- Produces: immediate descriptor updates on pointer, zoom/layout, active brush, and brush diameter changes.

- [x] **Step 1: Write failing AppKit integration tests**

Add tests for:

```swift
view.updateBrushCursor(diameter: 40)
view.mouseMoved(with: move)
#expect(view.brushCursorDescriptorForTesting?.isCircle == true)

controller.zoom(by: 2, anchor: .zero)
view.updateBrushCursor(diameter: 40)
#expect(view.brushCursorFrameForTesting.width == 80)
```

Also install a broad chisel compiled brush and assert the cursor frame is anisotropic and rotated; switch brush diameter without another mouse event and assert the frame changes immediately; send a normalized tablet hover with tilt/azimuth and assert the descriptor changes; hide on exit.

- [x] **Step 2: Run the AppKit tests and verify RED**

Run:

```bash
swift test --filter 'BrushCursorIntegrationTests|brushCursorTracksPointerDiameterAndZoom'
```

Expected: tests fail because the view still stores only a nominal diameter.

- [x] **Step 3: Expose normalized hover input without an array**

Add a `BrushInputAdapter.cursorSample(for:position:) -> StrokeSample?` method that reuses `nativeSample` and `normalizedSample` directly. Mouse hover keeps capabilities empty; tablet hover uses the cached proximity capability mask. It must not call `orderedSamples` or allocate a one-element array.

- [x] **Step 4: Draw the evaluated descriptor**

Make `BrushCursorView` store one descriptor. Draw analytic ellipses/rectangles with AppKit primitives and cached asset contours by enumerating points through their affine transform. Draw the stable envelope only when it differs from the core. Preserve the black outer/white inner visibility treatment.

`InteractiveMetalView` retains the latest normalized hover sample and rebuilds its descriptor when any of these changes: pointer sensor values, diameter, viewport zoom, drawable backing scale, layout, or prepared brush identity. The view frame is the descriptor envelope translated to the pointer, with enough stroke inset to avoid clipping. `MetalCanvas` continues invoking the update on every SwiftUI state update, so brush-size changes are immediate.

- [x] **Step 5: Run AppKit integration tests and verify GREEN**

Run:

```bash
swift test --filter 'BrushCursorIntegrationTests|brushCursorTracksPointerDiameterAndZoom'
```

Expected: all selected AppKit tests pass.

---

### Task 4: Independent single-dab agreement and final verification

**Files:**

- Modify: `App/Tests/BrushCursorIntegrationTests.swift`
- Create: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/task-16-truthful-cursor-checkpoint.md`
- Modify: `.superpowers/sdd/2026-08-01-brush-engine-corrective-program/progress.md`

**Interfaces:**

- Consumes: the production descriptor and production single-dab Metal rendering path.
- Produces: independent cursor/raster IoU and edge-distance evidence plus the Task 16 checkpoint.

- [x] **Step 1: Write controlled raster agreement tests**

Render centered single dabs for hard round, ellipse, chisel, rotated chisel, and a deterministic asset tip with zero scatter/jitter. Independently threshold BGRA8 alpha, sample descriptor occupancy at pixel centers, and calculate:

```swift
let iou = Float(intersectionCount) / Float(unionCount)
let maximumEdgeError = maximumNearestOppositeBoundaryDistance(...)
#expect(iou >= 0.85)
#expect(maximumEdgeError <= 1.5)
```

The oracle must not call shader coverage helpers or reuse renderer support calculations. Add negative controls that shrink the descriptor by 20% and prove at least one metric fails.

- [x] **Step 2: Run the prescribed Task 16 gate**

Run:

```bash
swift test --filter 'BrushCursorDescriptorTests|BrushCursorIntegrationTests|BrushCorrectiveFunctionalTests'
```

Expected: new cursor tests pass; the existing corrective functional boundary retains only its scheduled Task 21-23 issues.

- [x] **Step 3: Run adjacent regression, release, and hygiene gates**

Run:

```bash
swift test --filter 'BrushCompilerTests|BrushDynamicsEngineTests|EditorSessionControllerTests'
swift build -c release
git diff --check
rg -n 'texture\.getBytes|CGImageSourceCreate|NSImage\(' Sources/PatternEngine/BrushCursorDescriptor.swift App/PatternSpike/Canvas/InteractiveMetalView.swift
```

Expected: selected regressions and Release build pass; diff check is clean; the cursor path contains no texture decoding/readback.

- [x] **Step 4: Review and document**

Request a code review covering the Task 16 diff. Reproduce every Critical/Important finding with a failing test, fix it, rerun the focused and Release gates, and obtain a clean re-review. Record exact commands/counts, any unchanged scheduled corrective issues, and the no-stage/no-commit/no-push state in the checkpoint and progress ledger.
