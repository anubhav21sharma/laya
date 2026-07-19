# Measured Grid Drawing Kernel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blank Slice 0 canvas with a measured macOS drawing loop whose hard-round mouse strokes repeat immediately across a 256 x 256 grid, cancel without touching canonical pixels, and commit without preview drift or stroke-length-dependent frame work.

**Architecture:** `PatternEngine` owns typed coordinates, pure viewport math, normalized samples, centripetal Catmull-Rom interpolation, grid projection, and the Metal-free raster contract. `MetalRenderer` owns the renderer-local viewport, canonical/front/scratch/live textures, append-only live-stroke identity, bounded triple-buffered GPU uploads, display/stamp/commit pipelines, and the real-metallib harness. The app target translates AppKit events into engine values and semantic navigation commands; it contains no geometry, brush, grid, or shader policy.

**Tech Stack:** Swift 6, Swift Testing, Foundation, simd, Metal, MetalKit, AppKit, SwiftUI, C/MSL shared ABI, CoreGraphics, ImageIO, XcodeGen 2.46.0 or newer, Xcode command-line tools.

## Global Constraints

- Native Swift 6, Metal, and SwiftUI only; no third-party runtime dependency.
- Minimum macOS 14 and iPadOS 17.
- macOS is the interactive target; the iPadOS target remains continuously buildable without claiming Pencil or device behavior.
- `PatternEngine` imports Foundation and simd only; it must not import Metal, MetalKit, SwiftUI, AppKit, or UIKit.
- `MetalRenderer` depends only on `PatternEngine` and `CShaderTypes`.
- World coordinates use pixels and increase rightward and downward.
- The initial canonical raster is exactly 256 x 256 `.bgra8Unorm`, transparent, and centered in the initial drawable.
- Default zoom is `1.0`; zoom clamps to `0.25...8.0` and stays cursor anchored.
- Mouse pressure defaults to `0.5`; Slice 1 records it but does not map it to brush attributes.
- The only brush is opaque black, diameter `20`, radius `10`, with spacing `max(1, min(8, radius * 0.25))`, initially `2.5` world pixels.
- Interpolation is fixed-spacing centripetal Catmull-Rom with the current point duplicated as the trailing control; every emitted dab is final immediately.
- Grid folding uses positive modulo into half-open `[0, width)` and `[0, height)` coordinates.
- The active stroke never mutates canonical pixels.
- Live display and commit use identical premultiplied source-over math.
- Straight-alpha hard-round stamping uses `srcRGB = .sourceAlpha`, `dstRGB = .oneMinusSourceAlpha`, `srcA = .one`, and `dstA = .oneMinusSourceAlpha`.
- The drawable clears to the accepted Precision Light neutral BGRA `(241, 244, 242, 255)`; paper is never baked into canonical, live, or tiling output.
- The live texture is persistent during a stroke and stamps only the new monotonic dab suffix.
- Pointer-up performs no synchronous GPU wait. A successful scratch commit swaps once; cancel or failure swaps never.
- Commit-pending input is rejected, not queued; the interval must stay below one display frame and be imperceptible.
- The input-to-encoding path performs no waits, file I/O, PNG encoding, shader compilation, or unbounded allocation.
- Instance uploads use three preallocated buffers. More than one buffer capacity is encoded in ordered bounded chunks.
- `MTKView` timed redraw is used before any custom display scheduler.
- `swift test` validates CPU contracts only and never claims shader validation.
- GPU verification executes the built macOS app against its real default metallib.
- Every harness family has a deliberate negative control that exits nonzero before its positive scene is accepted.
- Generated `App/PatternSpike.xcodeproj/` and `.build/` artifacts remain uncommitted.
- No half-drop, brick, mirror, rotational tiling, configurable brushes, pressure response, Pencil input, undo, layers, persistence, export, or production toolbar enters Slice 1.

---

## File Map

```text
Sources/
  PatternEngine/
    Geometry.swift
    StrokeSample.swift
    ViewportTransform.swift
    CentripetalCatmullRomStrokeInterpolator.swift
    GridProjection.swift
    RasterSurface.swift
  CShaderTypes/include/ShaderTypes.h
  MetalRenderer/
    ShaderABI.swift
    MetalRendererError.swift
    GridCanvasContract.swift
    LiveStroke.swift
    DabInstanceBufferPool.swift
    CanonicalRaster.swift
    PersistentLiveTile.swift
    GridPipelineLibrary.swift
    GridStrokeLifecycle.swift
    GridRenderer.swift
    GridRenderCompletionMailbox.swift
    BenchmarkRecord.swift
    Capture/HarnessScene.swift
    Capture/HarnessRunner.swift
    Shaders.metal
App/
  project.yml
  PatternSpike/
    Canvas/InteractiveMetalView.swift
    Canvas/MetalCanvas.swift
    ContentView.swift
    Harness/Scenes/
      grid-interior{,-negative-control}.json
      grid-boundary{,-negative-control}.json
      preview-commit{,-negative-control}.json
      cancel-preserves-canonical{,-negative-control}.json
      five-hundred-dabs{,-negative-control}.json
      long-stroke{,-negative-control}.json
Tests/
  PatternEngineTests/
    ViewportTransformTests.swift
    CentripetalCatmullRomStrokeInterpolatorTests.swift
    GridProjectionTests.swift
    RasterSurfaceTests.swift
  MetalRendererTests/
    ShaderABILayoutTests.swift
    LiveStrokeTests.swift
    GridStrokeLifecycleTests.swift
    GridCanvasContractTests.swift
    HarnessSceneTests.swift
    BenchmarkRecordTests.swift
scripts/
  verify-slice1.sh
docs/superpowers/milestones/
  01-measured-grid-drawing-kernel.md
```

Responsibility boundaries:

- `Geometry.swift` defines platform-free screen, world, canonical, size, and pixel-size values. No layer may pass raw AppKit coordinates past the app boundary.
- `StrokeSample.swift` defines the normalized pointer vocabulary shared by the app and renderer.
- `ViewportTransform.swift` is immutable pure math. Mutable viewport ownership remains inside `GridRenderer`.
- `CentripetalCatmullRomStrokeInterpolator.swift` owns no-lookahead segment closure, arc-length carry, initial/final endpoint rules, and no GPU types.
- `GridProjection.swift` owns positive modulo and every translated hard-round placement intersecting the tile.
- `RasterSurface.swift` is the single Metal-free pixel-size/revision interface.
- `ShaderTypes.h` remains the only CPU/MSL ABI source. Existing constants retain their values.
- `LiveStroke.swift` owns absolute dab identity, baked high-water, fixed pending capacity, and safe prefix compaction.
- `DabInstanceBufferPool.swift` owns exactly three `MTLBuffer` slots and nonblocking lease reuse.
- `CanonicalRaster.swift` owns front/scratch identity and successful-only swapping.
- `PersistentLiveTile.swift` owns the transparent stroke texture and dirty/visible state.
- `GridPipelineLibrary.swift` creates the stamp, grid-display, and commit pipelines from the app metallib.
- `GridRenderer.swift` is the sole interactive state machine and `MTKViewDelegate`.
- `InteractiveMetalView.swift` translates AppKit events only; it does not interpolate, fold, place, or blend.
- `HarnessScene.swift` owns a versioned, CPU-validated description of fixed GPU programs and assertions.
- `HarnessRunner.swift` executes both retained Slice 0 blank scenes and new Slice 1 scenes through the real app metallib.
- `verify-slice1.sh` is the single automated Slice 1 gate.

---

### Task 1: Typed Input And Pure Viewport Math

**Files:**
- Create: `Sources/PatternEngine/Geometry.swift`
- Create: `Sources/PatternEngine/StrokeSample.swift`
- Create: `Sources/PatternEngine/ViewportTransform.swift`
- Create: `Tests/PatternEngineTests/ViewportTransformTests.swift`

**Interfaces:**
- Consumes: Swift `Float` and `SIMD2<Float>` only.
- Produces: `ScreenPoint`, `WorldPoint`, `CanonicalPoint`, `PatternSize`, `PixelSize`, `StrokePhase`, `StrokeSource`, `StrokeSample`, and immutable `ViewportTransform`.

- [ ] **Step 1: Write failing viewport and normalized-sample tests**

Create `Tests/PatternEngineTests/ViewportTransformTests.swift`:

```swift
import PatternEngine
import simd
import Testing

private func close(
    _ actual: WorldPoint,
    _ expected: WorldPoint,
    tolerance: Float = 0.0001
) -> Bool {
    abs(actual.x - expected.x) <= tolerance
        && abs(actual.y - expected.y) <= tolerance
}

@Test
func viewportRoundTripsAcrossPanAndZoom() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 2
    )
    let world = WorldPoint(x: -42.5, y: 301.25)

    #expect(close(viewport.screenToWorld(viewport.worldToScreen(world)), world))
}

@Test
func panningMovesWorldCenterOppositeTheScreenDelta() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 2
    )

    let panned = viewport.panned(byScreenDelta: SIMD2<Float>(20, -10))

    #expect(close(panned.worldCenter, WorldPoint(x: 118, y: 133)))
}

@Test
func cursorAnchoredZoomPreservesTheAnchorAndClamps() {
    let viewport = ViewportTransform(
        drawableSize: PatternSize(width: 800, height: 600),
        worldCenter: WorldPoint(x: 128, y: 128),
        zoom: 1
    )
    let anchor = ScreenPoint(x: 73, y: 511)
    let before = viewport.screenToWorld(anchor)
    let zoomed = viewport.zoomed(by: 100, anchorScreen: anchor)

    #expect(zoomed.zoom == 8)
    #expect(close(zoomed.screenToWorld(anchor), before))
    #expect(viewport.zoomed(by: 0.0001, anchorScreen: anchor).zoom == 0.25)
}

@Test
func normalizedMouseSampleCarriesRecoveredNeutralPressure() {
    let sample = StrokeSample.mouse(
        position: ScreenPoint(x: 10, y: 20),
        timestamp: 3,
        phase: .began
    )

    #expect(sample.pressure == 0.5)
    #expect(sample.source == .mouse)
}
```

- [ ] **Step 2: Run the focused tests and confirm missing-type failure**

Run:

```bash
swift test --filter ViewportTransformTests
```

Expected: FAIL at compile time because the geometry, sample, and viewport types do not exist.

- [ ] **Step 3: Add focused geometry and sample values**

Create `Sources/PatternEngine/Geometry.swift`:

```swift
import Foundation
import simd

public struct ScreenPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public var simd: SIMD2<Float> { SIMD2(x, y) }
}

public struct WorldPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public init(_ value: SIMD2<Float>) {
        self.init(x: value.x, y: value.y)
    }

    public var simd: SIMD2<Float> { SIMD2(x, y) }
}

public struct CanonicalPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct PatternSize: Equatable, Sendable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }

    public var simd: SIMD2<Float> { SIMD2(width, height) }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}
```

Create `Sources/PatternEngine/StrokeSample.swift`:

```swift
import Foundation

public enum StrokePhase: UInt8, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}

public enum StrokeSource: UInt8, Equatable, Sendable {
    case mouse
    case tablet
    case pencil
}

public struct StrokeSample: Equatable, Sendable {
    public let position: ScreenPoint
    public let pressure: Float
    public let timestamp: TimeInterval
    public let phase: StrokePhase
    public let source: StrokeSource

    public init(
        position: ScreenPoint,
        pressure: Float,
        timestamp: TimeInterval,
        phase: StrokePhase,
        source: StrokeSource
    ) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
        self.phase = phase
        self.source = source
    }

    public static func mouse(
        position: ScreenPoint,
        timestamp: TimeInterval,
        phase: StrokePhase
    ) -> StrokeSample {
        StrokeSample(
            position: position,
            pressure: 0.5,
            timestamp: timestamp,
            phase: phase,
            source: .mouse
        )
    }
}
```

- [ ] **Step 4: Add immutable viewport math**

Create `Sources/PatternEngine/ViewportTransform.swift`:

```swift
import Foundation

public struct ViewportTransform: Equatable, Sendable {
    public let drawableSize: PatternSize
    public let worldCenter: WorldPoint
    public let zoom: Float

    public init(
        drawableSize: PatternSize,
        worldCenter: WorldPoint,
        zoom: Float
    ) {
        precondition(zoom > 0)
        self.drawableSize = drawableSize
        self.worldCenter = worldCenter
        self.zoom = zoom
    }

    public func worldToScreen(_ point: WorldPoint) -> ScreenPoint {
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        let screen = (point.simd - worldCenter.simd) * zoom + center
        return ScreenPoint(x: screen.x, y: screen.y)
    }

    public func screenToWorld(_ point: ScreenPoint) -> WorldPoint {
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        return WorldPoint((point.simd - center) / zoom + worldCenter.simd)
    }

    public func panned(byScreenDelta delta: SIMD2<Float>) -> ViewportTransform {
        ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(worldCenter.simd - delta / zoom),
            zoom: zoom
        )
    }

    public func zoomed(
        by factor: Float,
        anchorScreen: ScreenPoint
    ) -> ViewportTransform {
        let anchorWorld = screenToWorld(anchorScreen)
        let clamped = min(8, max(0.25, zoom * factor))
        let center = SIMD2(drawableSize.width * 0.5, drawableSize.height * 0.5)
        let adjustedCenter = anchorWorld.simd - (anchorScreen.simd - center) / clamped
        return ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(adjustedCenter),
            zoom: clamped
        )
    }

    public func resized(to size: PatternSize) -> ViewportTransform {
        ViewportTransform(
            drawableSize: size,
            worldCenter: worldCenter,
            zoom: zoom
        )
    }
}
```

- [ ] **Step 5: Run the focused and full CPU suites**

Run:

```bash
swift test --filter ViewportTransformTests
swift test
```

Expected: the four new tests pass; the full suite passes with 15 tests and zero failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/PatternEngine Tests/PatternEngineTests/ViewportTransformTests.swift
git commit -m "feat: add normalized input and viewport math"
```

---

### Task 2: Final-On-Emission Catmull-Rom Interpolation

**Files:**
- Create: `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift`
- Create: `Tests/PatternEngineTests/CentripetalCatmullRomStrokeInterpolatorTests.swift`

**Interfaces:**
- Consumes: `WorldPoint`.
- Produces: `CentripetalCatmullRomStrokeInterpolator.init(radius:)`, `begin(at:emit:)`, `append(_:emit:)`, `finish(at:emit:)`, and `cancel()`. Emission uses a throwing closure so the renderer can write directly into bounded storage without allocating a stroke-sized array.

- [ ] **Step 1: Write failing endpoint, spacing, carry, curve, and cancel tests**

Create `Tests/PatternEngineTests/CentripetalCatmullRomStrokeInterpolatorTests.swift`:

```swift
import PatternEngine
import simd
import Testing

private func distance(_ lhs: WorldPoint, _ rhs: WorldPoint) -> Float {
    simd_distance(lhs.simd, rhs.simd)
}

@Test
func clickEmitsExactlyOneDab() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 4, y: 9)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: 4, y: 9)) { emitted.append($0) }

    #expect(emitted == [WorldPoint(x: 4, y: 9)])
}

@Test
func straightMotionUsesRecoveredSpacingAndExactFinalEndpoint() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 5, y: 0)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: 6, y: 0)) { emitted.append($0) }

    #expect(emitted == [
        WorldPoint(x: 0, y: 0),
        WorldPoint(x: 2.5, y: 0),
        WorldPoint(x: 5, y: 0),
        WorldPoint(x: 6, y: 0),
    ])
}

@Test
func spacingCarryCrossesInputSegments() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 1, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 3, y: 0)) { emitted.append($0) }

    #expect(emitted.count == 2)
    #expect(abs(emitted[1].x - 2.5) < 0.01)
}

@Test
func curvedMotionStaysAtFixedArcLengthWithinTolerance() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: 0, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 8, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: 8, y: 8)) { emitted.append($0) }

    for pair in zip(emitted, emitted.dropFirst()) {
        #expect(abs(distance(pair.0, pair.1) - 2.5) < 0.08)
    }
}

@Test
func cancelResetsIdentityAndCarry() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: -8, y: 0)) { emitted.append($0) }
    try interpolator.append(WorldPoint(x: -6, y: 0)) { emitted.append($0) }
    interpolator.cancel()
    try interpolator.begin(at: WorldPoint(x: 40, y: 20)) { emitted.append($0) }

    #expect(emitted.last == WorldPoint(x: 40, y: 20))
}
```

- [ ] **Step 2: Run the focused tests and confirm missing-interpolator failure**

Run:

```bash
swift test --filter CatmullRomStrokeInterpolatorTests
```

Expected: FAIL at compile time because `CentripetalCatmullRomStrokeInterpolator` does not exist.

- [ ] **Step 3: Add the streaming interpolator**

Create `Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift` with this state and public API:

```swift
import Foundation
import simd

public struct CentripetalCatmullRomStrokeInterpolator: Sendable {
    public let spacing: Float

    private var beforePrevious: WorldPoint?
    private var previous: WorldPoint?
    private var lastEmitted: WorldPoint?
    private var distanceUntilNext: Float

    public init(radius: Float) {
        precondition(radius > 0)
        spacing = max(1, min(8, radius * 0.25))
        distanceUntilNext = spacing
    }

    public mutating func begin(
        at point: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        beforePrevious = point
        previous = point
        lastEmitted = point
        distanceUntilNext = spacing
        try emit(point)
    }

    public mutating func append(
        _ current: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        guard let p1 = previous, let p0 = beforePrevious else {
            return try begin(at: current, emit: emit)
        }
        let estimate = max(
            simd_distance(p0.simd, p1.simd) + simd_distance(p1.simd, current.simd),
            spacing
        )
        let subdivisions = max(1, Int(ceil(estimate / min(0.5, spacing * 0.2))))
        var lineStart = p1

        for step in 1...subdivisions {
            let u = Float(step) / Float(subdivisions)
            let lineEnd = Self.sample(
                p0: p0,
                p1: p1,
                p2: current,
                p3: current,
                u: u
            )
            try consumeLine(from: &lineStart, to: lineEnd, emit: emit)
            lineStart = lineEnd
        }

        beforePrevious = p1
        previous = current
    }

    public mutating func finish(
        at finalPoint: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        if previous != finalPoint {
            try append(finalPoint, emit: emit)
        }
        if lastEmitted != finalPoint {
            try emit(finalPoint)
            lastEmitted = finalPoint
        }
        beforePrevious = nil
        previous = nil
        distanceUntilNext = spacing
    }

    public mutating func cancel() {
        beforePrevious = nil
        previous = nil
        lastEmitted = nil
        distanceUntilNext = spacing
    }

    private mutating func consumeLine(
        from start: inout WorldPoint,
        to end: WorldPoint,
        emit: (WorldPoint) throws -> Void
    ) rethrows {
        var cursor = start.simd
        let terminal = end.simd
        var remainingLength = simd_distance(cursor, terminal)

        while remainingLength >= distanceUntilNext && remainingLength > 0 {
            let direction = (terminal - cursor) / remainingLength
            cursor += direction * distanceUntilNext
            let point = WorldPoint(cursor)
            try emit(point)
            lastEmitted = point
            remainingLength = simd_distance(cursor, terminal)
            distanceUntilNext = spacing
        }

        distanceUntilNext -= remainingLength
        start = WorldPoint(terminal)
    }

    private static func sample(
        p0: WorldPoint,
        p1: WorldPoint,
        p2: WorldPoint,
        p3: WorldPoint,
        u: Float
    ) -> WorldPoint {
        let incoming = p1.simd - p0.simd
        let outgoing = p2.simd - p1.simd
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        if abs(cross) < 0.0001 {
            return WorldPoint(p1.simd + outgoing * u)
        }
        let epsilon: Float = 0.0001
        let dt0 = max(epsilon, sqrt(simd_distance(p0.simd, p1.simd)))
        let dt1 = max(epsilon, sqrt(simd_distance(p1.simd, p2.simd)))
        let dt2 = max(epsilon, sqrt(simd_distance(p2.simd, p3.simd)))
        var m1 = (p1.simd - p0.simd) / dt0
            - (p2.simd - p0.simd) / (dt0 + dt1)
            + (p2.simd - p1.simd) / dt1
        var m2 = (p2.simd - p1.simd) / dt1
            - (p3.simd - p1.simd) / (dt1 + dt2)
            + (p3.simd - p2.simd) / dt2
        m1 *= dt1
        m2 *= dt1
        let u2 = u * u
        let u3 = u2 * u
        return WorldPoint(
            (2 * u3 - 3 * u2 + 1) * p1.simd
                + (u3 - 2 * u2 + u) * m1
                + (-2 * u3 + 3 * u2) * p2.simd
                + (u3 - u2) * m2
        )
    }
}
```

- [ ] **Step 4: Run focused tests, then add a negative-world regression**

Run:

```bash
swift test --filter CatmullRomStrokeInterpolatorTests
```

Expected: PASS, five tests, zero failures.

Add this test to the same file:

```swift
@Test
func negativeWorldMotionDoesNotChangeSpacing() throws {
    var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    var emitted: [WorldPoint] = []
    try interpolator.begin(at: WorldPoint(x: -8, y: -4)) { emitted.append($0) }
    try interpolator.finish(at: WorldPoint(x: -3, y: -4)) { emitted.append($0) }

    #expect(emitted == [
        WorldPoint(x: -8, y: -4),
        WorldPoint(x: -5.5, y: -4),
        WorldPoint(x: -3, y: -4),
    ])
}
```

- [ ] **Step 5: Run the full CPU suite**

Run:

```bash
swift test
```

Expected: all existing and six interpolator tests pass with zero failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift Tests/PatternEngineTests/CentripetalCatmullRomStrokeInterpolatorTests.swift
git commit -m "feat: add final Catmull-Rom dab stream"
```

---

### Task 3: Grid Projection And Metal-Free Raster Contract

**Files:**
- Create: `Sources/PatternEngine/GridProjection.swift`
- Create: `Sources/PatternEngine/RasterSurface.swift`
- Create: `Tests/PatternEngineTests/GridProjectionTests.swift`
- Create: `Tests/PatternEngineTests/RasterSurfaceTests.swift`

**Interfaces:**
- Consumes: `WorldPoint`, `CanonicalPoint`, `PatternSize`, and `PixelSize`.
- Produces: `CanonicalDabPlacement`, `GridProjection.fold(_:tileSize:)`, `GridProjection.placements(center:radius:tileSize:)`, `RasterRevision`, and `RasterSurface`.

- [ ] **Step 1: Write failing fold, boundary, corner, and raster tests**

Create `Tests/PatternEngineTests/GridProjectionTests.swift`:

```swift
import PatternEngine
import Testing

@Test
func gridFoldUsesPositiveHalfOpenModulo() {
    let cases = [
        (WorldPoint(x: 0, y: 0), CanonicalPoint(x: 0, y: 0)),
        (WorldPoint(x: 256, y: 256), CanonicalPoint(x: 0, y: 0)),
        (WorldPoint(x: -1, y: -257), CanonicalPoint(x: 255, y: 255)),
        (WorldPoint(x: 513, y: 510), CanonicalPoint(x: 1, y: 254)),
    ]
    for (world, expected) in cases {
        #expect(
            GridProjection.fold(
                world,
                tileSize: PatternSize(width: 256, height: 256)
            ) == expected
        )
    }
}

@Test
func interiorDabHasOnePlacement() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 100, y: 100),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(placements == [
        CanonicalDabPlacement(center: CanonicalPoint(x: 100, y: 100), radius: 10),
    ])
}

@Test
func leftEdgeDabWrapsToTheRightEdge() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: 3, y: 100),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 3, y: 100),
        CanonicalPoint(x: 259, y: 100),
    ]))
}

@Test
func cornerDabProducesFourTranslatedPlacements() {
    let placements = GridProjection.placements(
        center: WorldPoint(x: -2, y: -2),
        radius: 10,
        tileSize: PatternSize(width: 256, height: 256)
    )

    #expect(Set(placements.map(\.center)) == Set([
        CanonicalPoint(x: 254, y: 254),
        CanonicalPoint(x: -2, y: 254),
        CanonicalPoint(x: 254, y: -2),
        CanonicalPoint(x: -2, y: -2),
    ]))
}
```

Create `Tests/PatternEngineTests/RasterSurfaceTests.swift`:

```swift
import PatternEngine
import Testing

private struct TestSurface: RasterSurface {
    let pixelSize: PixelSize
    let revision: RasterRevision
}

@Test
func rasterSurfaceExposesNoMetalType() {
    let surface = TestSurface(
        pixelSize: PixelSize(width: 256, height: 256),
        revision: RasterRevision(rawValue: 7)
    )

    #expect(surface.pixelSize == PixelSize(width: 256, height: 256))
    #expect(surface.revision == RasterRevision(rawValue: 7))
}
```

- [ ] **Step 2: Run focused tests and confirm missing-contract failure**

Run:

```bash
swift test --filter GridProjectionTests
swift test --filter RasterSurfaceTests
```

Expected: both commands fail at compile time because their production types are missing.

- [ ] **Step 3: Add exact grid folding and placement enumeration**

Create `Sources/PatternEngine/GridProjection.swift`:

```swift
import Foundation

public struct CanonicalDabPlacement: Equatable, Sendable {
    public let center: CanonicalPoint
    public let radius: Float

    public init(center: CanonicalPoint, radius: Float) {
        self.center = center
        self.radius = radius
    }
}

public enum GridProjection {
    public static func fold(
        _ point: WorldPoint,
        tileSize: PatternSize
    ) -> CanonicalPoint {
        CanonicalPoint(
            x: point.x - floor(point.x / tileSize.width) * tileSize.width,
            y: point.y - floor(point.y / tileSize.height) * tileSize.height
        )
    }

    public static func placements(
        center: WorldPoint,
        radius: Float,
        tileSize: PatternSize
    ) -> [CanonicalDabPlacement] {
        precondition(radius > 0)
        let folded = fold(center, tileSize: tileSize)
        let xOffsets = intersectingOffsets(
            center: folded.x,
            radius: radius,
            extent: tileSize.width
        )
        let yOffsets = intersectingOffsets(
            center: folded.y,
            radius: radius,
            extent: tileSize.height
        )
        var result: [CanonicalDabPlacement] = []
        result.reserveCapacity(xOffsets.count * yOffsets.count)
        for y in yOffsets {
            for x in xOffsets {
                result.append(
                    CanonicalDabPlacement(
                        center: CanonicalPoint(x: folded.x + x, y: folded.y + y),
                        radius: radius
                    )
                )
            }
        }
        result.sort {
            let lhsDistance = $0.center.x * $0.center.x + $0.center.y * $0.center.y
            let rhsDistance = $1.center.x * $1.center.x + $1.center.y * $1.center.y
            return lhsDistance < rhsDistance
        }
        return result
    }

    private static func intersectingOffsets(
        center: Float,
        radius: Float,
        extent: Float
    ) -> [Float] {
        let minimum = Int(floor((-radius - center) / extent))
        let maximum = Int(ceil((extent + radius - center) / extent))
        return (minimum...maximum).compactMap { lattice in
            let offset = Float(lattice) * extent
            let translated = center + offset
            return translated + radius > 0 && translated - radius < extent
                ? offset
                : nil
        }
    }
}
```

Make `CanonicalPoint` hashable by changing its conformance in `Geometry.swift` to:

```swift
public struct CanonicalPoint: Hashable, Sendable {
```

- [ ] **Step 4: Add the raster revision protocol**

Create `Sources/PatternEngine/RasterSurface.swift`:

```swift
public struct RasterRevision: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public func advanced() -> RasterRevision {
        RasterRevision(rawValue: rawValue &+ 1)
    }
}

public protocol RasterSurface {
    var pixelSize: PixelSize { get }
    var revision: RasterRevision { get }
}
```

- [ ] **Step 5: Run focused tests and the full CPU suite**

Run:

```bash
swift test --filter GridProjectionTests
swift test --filter RasterSurfaceTests
swift test
```

Expected: all fold, placement, raster, and retained Slice 0 tests pass. Exact-boundary placements do not over-emit tangent-only copies.

- [ ] **Step 6: Commit**

```bash
git add Sources/PatternEngine Tests/PatternEngineTests
git commit -m "feat: add grid projection contracts"
```

---

### Task 4: Shared Grid ABI And Bounded Live-Stroke Identity

**Files:**
- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`
- Create: `Sources/MetalRenderer/GridCanvasContract.swift`
- Create: `Sources/MetalRenderer/LiveStroke.swift`
- Modify: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- Create: `Tests/MetalRendererTests/GridCanvasContractTests.swift`
- Create: `Tests/MetalRendererTests/LiveStrokeTests.swift`

**Interfaces:**
- Consumes: existing `PatternFrameUniforms`, buffer index `0`, and tiling wire values `0...6` without modifying them.
- Produces: `PatternGridFrameUniforms`, `PatternDabInstance`, append-only buffer/texture indices, `GridCanvasContract`, `IdentifiedDab`, and fixed-capacity `LiveStroke`.

- [ ] **Step 1: Write failing ABI and live-stroke tests**

Append to `Tests/MetalRendererTests/ShaderABILayoutTests.swift`:

```swift
@Test
func gridUniformAndDabLayoutsMatchTheMetalContract() {
    #expect(MemoryLayout<PatternGridFrameUniforms>.size == 40)
    #expect(MemoryLayout<PatternGridFrameUniforms>.stride == 40)
    #expect(MemoryLayout<PatternGridFrameUniforms>.alignment == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32)
    #expect(MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36)

    #expect(MemoryLayout<PatternDabInstance>.size == 16)
    #expect(MemoryLayout<PatternDabInstance>.stride == 16)
    #expect(MemoryLayout<PatternDabInstance>.alignment == 8)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.center) == 0)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.radius) == 8)
    #expect(MemoryLayout<PatternDabInstance>.offset(of: \.padding) == 12)
    #expect(ShaderABI.isValid)
}

@Test
func gridWireIndicesAppendWithoutRenumberingSliceZero() {
    #expect(PatternBufferIndexFrameUniforms == 0)
    #expect(PatternBufferIndexGridFrameUniforms == 1)
    #expect(PatternBufferIndexDabInstances == 2)
    #expect(PatternTextureIndexCanonical == 0)
    #expect(PatternTextureIndexLive == 1)
}
```

Create `Tests/MetalRendererTests/GridCanvasContractTests.swift`:

```swift
import MetalRenderer
import Testing

@Test
func sliceOneConstantsMatchTheApprovedDesign() {
    #expect(GridCanvasContract.tileSize == 256)
    #expect(GridCanvasContract.brushRadius == 10)
    #expect(GridCanvasContract.dabSpacing == 2.5)
    #expect(GridCanvasContract.zoomRange == 0.25...8)
    #expect(GridCanvasContract.paperBGRA == SIMD4<UInt8>(241, 244, 242, 255))
    #expect(GridCanvasContract.instanceCapacity == 4_096)
    #expect(GridCanvasContract.inFlightBufferCount == 3)
}
```

Create `Tests/MetalRendererTests/LiveStrokeTests.swift`:

```swift
import CShaderTypes
import MetalRenderer
import Testing

private func instance(_ x: Float) -> PatternDabInstance {
    PatternDabInstance(
        center: SIMD2<Float>(x, 0),
        radius: 10,
        padding: 0
    )
}

@Test
func liveStrokeUsesMonotonicIdentityEvenForCoincidentDabs() throws {
    var stroke = LiveStroke(capacity: 8)
    try stroke.append(instance(4))
    try stroke.append(instance(4))

    #expect(stroke.pending.map(\.identity) == [0, 1])
    #expect(stroke.bakedHighWater == 0)
}

@Test
func bakedHighWaterAdvancesAndSafePrefixCompactsWithoutIdentityReset() throws {
    var stroke = LiveStroke(capacity: 8)
    try stroke.append(instance(1))
    try stroke.append(instance(2))
    try stroke.append(instance(3))
    stroke.markEncoded(throughExclusive: 2)
    stroke.releaseEncodedPrefix(throughExclusive: 2)
    try stroke.append(instance(4))

    #expect(stroke.bakedHighWater == 2)
    #expect(stroke.pending.map(\.identity) == [2, 3])
}

@Test
func liveStrokeRejectsGrowthBeyondItsPreallocatedCapacity() throws {
    var stroke = LiveStroke(capacity: 2)
    try stroke.append(instance(1))
    try stroke.append(instance(2))

    #expect(throws: MetalRendererError.pendingDabCapacityExceeded(2)) {
        try stroke.append(instance(3))
    }
}
```

- [ ] **Step 2: Run focused tests and confirm missing ABI/state failures**

Run:

```bash
swift test --filter ShaderABI
swift test --filter LiveStroke
swift test --filter GridCanvasContract
```

Expected: FAIL at compile time because the new C layouts and Swift contracts do not exist.

- [ ] **Step 3: Append new layouts and indices to the shared header**

Add below `PatternFrameUniforms` in `Sources/CShaderTypes/include/ShaderTypes.h`:

```c
typedef struct PatternGridFrameUniforms {
    PatternFloat2 drawableSize;
    PatternFloat2 worldCenter;
    PatternFloat2 tileSize;
    float zoom;
    float gridLineWidth;
    PatternUInt32 showGridLines;
    PatternUInt32 liveVisible;
} PatternGridFrameUniforms;

typedef struct PatternDabInstance {
    PatternFloat2 center;
    float radius;
    float padding;
} PatternDabInstance;
```

Append these constants after `PatternBufferIndexFrameUniforms`:

```c
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexGridFrameUniforms = 1;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternBufferIndexDabInstances = 2;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexCanonical = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternTextureIndexLive = 1;
```

Do not edit `PatternBufferIndexFrameUniforms` or any `PatternTilingWire*` value.

- [ ] **Step 4: Expand the runtime ABI precondition**

Replace `ShaderABI.isValid` in `Sources/MetalRenderer/ShaderABI.swift` with:

```swift
public static var isValid: Bool {
    MemoryLayout<PatternFrameUniforms>.size == 16
        && MemoryLayout<PatternFrameUniforms>.stride == 16
        && MemoryLayout<PatternFrameUniforms>.alignment == 8
        && MemoryLayout<PatternFrameUniforms>.offset(of: \.drawableSize) == 0
        && MemoryLayout<PatternFrameUniforms>.offset(of: \.inverseDrawableSize) == 8
        && MemoryLayout<PatternGridFrameUniforms>.size == 40
        && MemoryLayout<PatternGridFrameUniforms>.stride == 40
        && MemoryLayout<PatternGridFrameUniforms>.alignment == 8
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.drawableSize) == 0
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.worldCenter) == 8
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.tileSize) == 16
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.zoom) == 24
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.gridLineWidth) == 28
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.showGridLines) == 32
        && MemoryLayout<PatternGridFrameUniforms>.offset(of: \.liveVisible) == 36
        && MemoryLayout<PatternDabInstance>.size == 16
        && MemoryLayout<PatternDabInstance>.stride == 16
        && MemoryLayout<PatternDabInstance>.alignment == 8
        && MemoryLayout<PatternDabInstance>.offset(of: \.center) == 0
        && MemoryLayout<PatternDabInstance>.offset(of: \.radius) == 8
        && MemoryLayout<PatternDabInstance>.offset(of: \.padding) == 12
}
```

Change the precondition message to `"CPU/MSL shader layout mismatch"`.

- [ ] **Step 5: Add fixed constants and live-stroke bookkeeping**

Create `Sources/MetalRenderer/GridCanvasContract.swift`:

```swift
public enum GridCanvasContract {
    public static let tileSize: Float = 256
    public static let brushRadius: Float = 10
    public static let dabSpacing: Float = 2.5
    public static let zoomRange: ClosedRange<Float> = 0.25...8
    public static let paperBGRA = SIMD4<UInt8>(241, 244, 242, 255)
    public static let instanceCapacity = 4_096
    public static let pendingCapacity = instanceCapacity * 3
    public static let inFlightBufferCount = 3
}
```

Create `Sources/MetalRenderer/LiveStroke.swift`:

```swift
import CShaderTypes

public struct IdentifiedDab {
    public let identity: UInt64
    public let instance: PatternDabInstance
}

public struct LiveStroke {
    public let capacity: Int
    public private(set) var bakedHighWater: UInt64 = 0
    public private(set) var pending: ContiguousArray<IdentifiedDab> = []
    public var emittedHighWater: UInt64 { nextIdentity }

    private var nextIdentity: UInt64 = 0

    public init(capacity: Int = GridCanvasContract.pendingCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        pending.reserveCapacity(capacity)
    }

    public mutating func append(_ instance: PatternDabInstance) throws {
        guard pending.count < capacity else {
            throw MetalRendererError.pendingDabCapacityExceeded(capacity)
        }
        pending.append(IdentifiedDab(identity: nextIdentity, instance: instance))
        nextIdentity &+= 1
    }

    public mutating func markEncoded(throughExclusive identity: UInt64) {
        precondition(identity >= bakedHighWater && identity <= nextIdentity)
        bakedHighWater = identity
    }

    public mutating func releaseEncodedPrefix(throughExclusive identity: UInt64) {
        precondition(identity <= bakedHighWater)
        let count = pending.prefix { $0.identity < identity }.count
        pending.removeFirst(count)
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        bakedHighWater = 0
        nextIdentity = 0
    }
}
```

Append this error case and message in `MetalRendererError.swift`:

```swift
case pendingDabCapacityExceeded(Int)
```

```swift
case let .pendingDabCapacityExceeded(capacity):
    "Pending dab capacity \(capacity) was exceeded."
```

- [ ] **Step 6: Run focused tests, full tests, and dependency audit**

Run:

```bash
swift test --filter ShaderABI
swift test --filter LiveStroke
swift test --filter GridCanvasContract
swift test
swift package describe
```

Expected: all tests pass; the package graph is unchanged; `PatternEngine` has no Metal dependency.

- [ ] **Step 7: Commit**

```bash
git add Sources/CShaderTypes Sources/MetalRenderer Tests/MetalRendererTests
git commit -m "feat: define grid ABI and live stroke identity"
```

---

### Task 5: Metal Resources, Pipelines, And Exact Blend Math

**Files:**
- Create: `Sources/MetalRenderer/CanonicalRaster.swift`
- Create: `Sources/MetalRenderer/PersistentLiveTile.swift`
- Create: `Sources/MetalRenderer/DabInstanceBufferPool.swift`
- Create: `Sources/MetalRenderer/GridPipelineLibrary.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`

**Interfaces:**
- Consumes: `PatternGridFrameUniforms`, `PatternDabInstance`, `GridCanvasContract`, an app `MTLLibrary`, and one `MTLDevice`.
- Produces: front/scratch canonical ownership, one persistent live texture, exactly three nonblocking upload buffers, and stamp/display/commit pipeline states. No app integration occurs in this task.

- [ ] **Step 1: Add CPU-testable texture and lease-state assertions**

Add to `Tests/MetalRendererTests/GridCanvasContractTests.swift`:

```swift
@Test
func physicalStrokePayloadHasAClosedUpperBound() {
    let pending = GridCanvasContract.pendingCapacity
    let inFlight = GridCanvasContract.instanceCapacity
        * GridCanvasContract.inFlightBufferCount

    #expect(pending == 12_288)
    #expect(pending + inFlight == 24_576)
}
```

Add to `Tests/MetalRendererTests/LiveStrokeTests.swift`:

```swift
@Test
func resetKeepsCapacityButRestoresPerStrokeIdentity() throws {
    var stroke = LiveStroke(capacity: 4)
    try stroke.append(instance(1))
    stroke.reset()
    try stroke.append(instance(2))

    #expect(stroke.pending.map(\.identity) == [0])
    #expect(stroke.capacity == 4)
}
```

- [ ] **Step 2: Run the new tests before GPU resource work**

Run:

```bash
swift test --filter GridCanvasContract
swift test --filter LiveStroke
```

Expected: PASS. These tests lock the CPU capacity contract before Metal objects are introduced; they do not validate shaders.

- [ ] **Step 3: Add canonical and persistent-live texture owners**

Create `Sources/MetalRenderer/CanonicalRaster.swift`:

```swift
import Metal
import PatternEngine

public final class CanonicalRaster: RasterSurface {
    public let pixelSize: PixelSize
    public private(set) var revision = RasterRevision(rawValue: 0)
    public private(set) var front: any MTLTexture
    public private(set) var scratch: any MTLTexture

    public init(device: any MTLDevice, pixelSize: PixelSize) throws {
        self.pixelSize = pixelSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard
            let front = device.makeTexture(descriptor: descriptor),
            let scratch = device.makeTexture(descriptor: descriptor)
        else {
            throw MetalRendererError.textureAllocationFailed
        }
        front.label = "Canonical Front"
        scratch.label = "Canonical Scratch"
        self.front = front
        self.scratch = scratch
    }

    public func acceptScratchCommit() {
        swap(&front, &scratch)
        revision = revision.advanced()
    }
}
```

Create `Sources/MetalRenderer/PersistentLiveTile.swift`:

```swift
import Metal
import PatternEngine

@MainActor
public final class PersistentLiveTile {
    public let texture: any MTLTexture
    public private(set) var isVisible = false
    public private(set) var isDirty = false

    public init(device: any MTLDevice, pixelSize: PixelSize) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        texture.label = "Persistent Live Stroke"
        self.texture = texture
    }

    public func markStamped() {
        isVisible = true
        isDirty = true
    }

    public func hide() {
        isVisible = false
    }

    public func markCleared() {
        isVisible = false
        isDirty = false
    }
}
```

The renderer must clear front, scratch, and live to transparent with GPU clear passes during initialization or before first sampling. It must never expose uninitialized private texture bytes.

- [ ] **Step 4: Add a nonblocking triple-buffered instance pool**

Create `Sources/MetalRenderer/DabInstanceBufferPool.swift`:

```swift
import CShaderTypes
import Metal

@MainActor
public final class DabInstanceBufferPool {
    public struct Lease {
        public let slot: Int
        public let buffer: any MTLBuffer
        public let capacity: Int
        public let signalValue: UInt64
    }

    private struct Entry {
        let buffer: any MTLBuffer
        var reusableAfterValue: UInt64
    }

    public let event: any MTLSharedEvent
    private var entries: [Entry]
    private var nextSignalValue: UInt64 = 1
    private var searchStart = 0

    public init(
        device: any MTLDevice,
        capacity: Int = GridCanvasContract.instanceCapacity
    ) throws {
        guard let event = device.makeSharedEvent() else {
            throw MetalRendererError.sharedEventUnavailable
        }
        self.event = event
        var entries: [Entry] = []
        entries.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        let length = capacity * MemoryLayout<PatternDabInstance>.stride
        for index in 0..<GridCanvasContract.inFlightBufferCount {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw MetalRendererError.instanceBufferAllocationFailed
            }
            buffer.label = "Dab Instances \(index)"
            entries.append(Entry(buffer: buffer, reusableAfterValue: 0))
        }
        self.entries = entries
    }

    public func acquire() -> Lease? {
        for offset in entries.indices {
            let index = (searchStart + offset) % entries.count
            guard event.signaledValue >= entries[index].reusableAfterValue else {
                continue
            }
            let signal = nextSignalValue
            nextSignalValue &+= 1
            searchStart = (index + 1) % entries.count
            return Lease(
                slot: index,
                buffer: entries[index].buffer,
                capacity: entries[index].buffer.length
                    / MemoryLayout<PatternDabInstance>.stride,
                signalValue: signal
            )
        }
        return nil
    }

    public func write(
        _ instances: ArraySlice<IdentifiedDab>,
        into lease: Lease
    ) {
        precondition(instances.count <= lease.capacity)
        let destination = lease.buffer.contents()
            .bindMemory(to: PatternDabInstance.self, capacity: lease.capacity)
        for (offset, dab) in instances.enumerated() {
            destination[offset] = dab.instance
        }
    }

    public func markSubmitted(_ lease: Lease, on commandBuffer: any MTLCommandBuffer) {
        entries[lease.slot].reusableAfterValue = lease.signalValue
        commandBuffer.encodeSignalEvent(event, value: lease.signalValue)
    }
}
```

Append these error cases and exact messages:

```swift
case sharedEventUnavailable
case instanceBufferAllocationFailed
```

```swift
case .sharedEventUnavailable:
    "Metal shared-event creation failed."
case .instanceBufferAllocationFailed:
    "Metal instance-buffer allocation failed."
```

Acquisition returning `nil` is normal backpressure, not an error and never causes a wait. Pending dabs remain retryable on the next timed frame.

- [ ] **Step 5: Add the three pipeline states with exact blend factors**

Create `Sources/MetalRenderer/GridPipelineLibrary.swift`:

```swift
import Metal

@MainActor
public struct GridPipelineLibrary {
    public let stamp: any MTLRenderPipelineState
    public let display: any MTLRenderPipelineState
    public let commit: any MTLRenderPipelineState

    public init(device: any MTLDevice, library: any MTLLibrary) throws {
        stamp = try Self.makePipeline(
            device: device,
            library: library,
            label: "Hard Round Stamp",
            vertex: "patternDabVertex",
            fragment: "patternDabFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        display = try Self.makePipeline(
            device: device,
            library: library,
            label: "Grid Display",
            vertex: "patternFullscreenVertex",
            fragment: "patternGridFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        commit = try Self.makePipeline(
            device: device,
            library: library,
            label: "Canonical Commit",
            vertex: "patternFullscreenVertex",
            fragment: "patternCommitFragment",
            configure: { $0.isBlendingEnabled = false }
        )
    }

    private static func makePipeline(
        device: any MTLDevice,
        library: any MTLLibrary,
        label: String,
        vertex: String,
        fragment: String,
        configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void
    ) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw MetalRendererError.shaderFunctionUnavailable(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw MetalRendererError.shaderFunctionUnavailable(fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        configure(descriptor.colorAttachments[0])
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 6: Add stamp, display, and commit MSL functions**

Keep `patternBlankVertex` and `patternBlankFragment` unchanged in `Shaders.metal`, then append:

```metal
struct PatternFullscreenOut {
    float4 position [[position]];
    float2 screenPixel;
};

struct PatternDabOut {
    float4 position [[position]];
    float2 offsetPixels;
    float radius;
};

vertex PatternFullscreenOut patternFullscreenVertex(
    uint vertexID [[vertex_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]]
) {
    const float2 clip[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    PatternFullscreenOut output;
    output.position = float4(clip[vertexID], 0.0, 1.0);
    output.screenPixel = float2(
        (clip[vertexID].x + 1.0) * 0.5 * frame.drawableSize.x,
        (1.0 - clip[vertexID].y) * 0.5 * frame.drawableSize.y
    );
    return output;
}

vertex PatternDabOut patternDabVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    const device PatternDabInstance* dabs
        [[buffer(PatternBufferIndexDabInstances)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    const PatternDabInstance dab = dabs[instanceID];
    const float expandedRadius = dab.radius + 1.0;
    const float2 offset = corners[vertexID] * expandedRadius;
    const float2 pixel = dab.center + offset;
    PatternDabOut output;
    output.position = float4(
        pixel.x / frame.tileSize.x * 2.0 - 1.0,
        1.0 - pixel.y / frame.tileSize.y * 2.0,
        0.0,
        1.0
    );
    output.offsetPixels = offset;
    output.radius = dab.radius;
    return output;
}

fragment float4 patternDabFragment(PatternDabOut input [[stage_in]]) {
    const float coverage = clamp(
        input.radius + 0.5 - length(input.offsetPixels),
        0.0,
        1.0
    );
    return float4(0.0, 0.0, 0.0, coverage);
}

static float2 patternPositiveFold(float2 world, float2 tileSize) {
    return world - floor(world / tileSize) * tileSize;
}

static float4 patternSourceOver(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
}

fragment float4 patternGridFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]]
) {
    constexpr sampler tileSampler(coord::normalized, address::repeat, filter::linear);
    const float2 screenCenter = frame.drawableSize * 0.5;
    const float2 world = (input.screenPixel - screenCenter) / frame.zoom
        + frame.worldCenter;
    const float2 canonicalPixel = patternPositiveFold(world, frame.tileSize);
    const float2 uv = canonicalPixel / frame.tileSize;
    const float4 base = canonical.sample(tileSampler, uv);
    const float4 overlay = frame.liveVisible == 0
        ? float4(0.0)
        : live.sample(tileSampler, uv);
    float4 result = patternSourceOver(overlay, base);

    if (frame.showGridLines != 0) {
        const float2 edgeDistance = min(canonicalPixel, frame.tileSize - canonicalPixel)
            * frame.zoom;
        const float coverage = 1.0 - smoothstep(
            frame.gridLineWidth,
            frame.gridLineWidth + 1.0,
            min(edgeDistance.x, edgeDistance.y)
        );
        const float alpha = 0.22 * coverage;
        const float4 grid = float4(float3(0.18, 0.20, 0.19) * alpha, alpha);
        result = patternSourceOver(grid, result);
    }
    return result;
}

fragment float4 patternCommitFragment(
    PatternFullscreenOut input [[stage_in]],
    constant PatternGridFrameUniforms& frame
        [[buffer(PatternBufferIndexGridFrameUniforms)]],
    texture2d<float> canonical [[texture(PatternTextureIndexCanonical)]],
    texture2d<float> live [[texture(PatternTextureIndexLive)]]
) {
    constexpr sampler tileSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    const float2 uv = input.screenPixel / frame.tileSize;
    return patternSourceOver(
        live.sample(tileSampler, uv),
        canonical.sample(tileSampler, uv)
    );
}
```

The commit pass must receive `drawableSize == tileSize` so its fullscreen coordinates are canonical pixels. The display fragment returns tile alpha unchanged; neutral paper comes only from the render-pass clear plus the display pipeline blend.

- [ ] **Step 7: Run CPU tests and both app builds**

Run:

```bash
swift test
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
```

Expected: CPU tests pass; both app builds compile the appended MSL through the real app metallib. No GPU correctness claim is made yet.

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer Tests/MetalRendererTests
git commit -m "feat: add grid Metal pipelines"
```

---

### Task 6: Persistent Live Renderer, Commit, And Cancel

**Files:**
- Create: `Sources/MetalRenderer/GridStrokeLifecycle.swift`
- Create: `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`
- Create: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`
- Create: `Tests/MetalRendererTests/GridStrokeLifecycleTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5 types plus `MTKViewDelegate`.
- Produces: `GridRenderer`, renderer-local `viewport`, normalized `handle(_:)`, idle-only `pan(byScreenDelta:)` and `zoom(by:anchor:)`, async scratch commit, cancel, structural counters, and offscreen capture seams used by Task 8.

- [ ] **Step 1: Write failing lifecycle tests**

Create `Tests/MetalRendererTests/GridStrokeLifecycleTests.swift`:

```swift
import MetalRenderer
import Testing

@Test
func lifecycleSerializesStrokeAndCommit() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.requestCommit()
    let token = try lifecycle.markCommitSubmitted()

    #expect(lifecycle.state == .commitPending(token))
    #expect(throws: MetalRendererError.commitPendingInput) {
        try lifecycle.begin()
    }

    try lifecycle.completeCommit(token: token, succeeded: true)
    #expect(lifecycle.state == .idle)
}

@Test
func failedCommitReturnsToIdleWithoutAcceptingScratch() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.requestCommit()
    let token = try lifecycle.markCommitSubmitted()
    try lifecycle.completeCommit(token: token, succeeded: false)

    #expect(lifecycle.state == .idle)
}

@Test
func cancelOnlyAppliesToAnActiveStroke() throws {
    var lifecycle = GridStrokeLifecycle()
    try lifecycle.begin()
    try lifecycle.cancelActive()

    #expect(lifecycle.state == .idle)
    #expect(throws: MetalRendererError.invalidStrokeLifecycle) {
        try lifecycle.cancelActive()
    }
}
```

- [ ] **Step 2: Run lifecycle tests and confirm missing-state failure**

Run:

```bash
swift test --filter GridStrokeLifecycle
```

Expected: FAIL at compile time because `GridStrokeLifecycle` does not exist.

- [ ] **Step 3: Implement the pure lifecycle state machine**

Create `Sources/MetalRenderer/GridStrokeLifecycle.swift`:

```swift
public struct GridStrokeLifecycle: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case active
        case commitRequested
        case commitPending(UInt64)
    }

    public private(set) var state: State = .idle
    private var nextCommitToken: UInt64 = 1

    public init() {}

    public mutating func begin() throws {
        guard state == .idle else {
            if state == .commitRequested {
                throw MetalRendererError.commitPendingInput
            }
            if case .commitPending = state {
                throw MetalRendererError.commitPendingInput
            }
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .active
    }

    public mutating func requestCommit() throws {
        guard state == .active else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .commitRequested
    }

    public mutating func markCommitSubmitted() throws -> UInt64 {
        guard state == .commitRequested else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        let token = nextCommitToken
        nextCommitToken &+= 1
        state = .commitPending(token)
        return token
    }

    public mutating func completeCommit(
        token: UInt64,
        succeeded: Bool
    ) throws {
        guard state == .commitPending(token) else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .idle
    }

    public mutating func cancelActive() throws {
        guard state == .active else {
            throw MetalRendererError.invalidStrokeLifecycle
        }
        state = .idle
    }

    public mutating func resetTransiently() {
        state = .idle
    }
}
```

Append these error cases and messages:

```swift
case invalidStrokeLifecycle
case commitPendingInput
case invalidDrawableSize
```

```swift
case .invalidStrokeLifecycle:
    "The requested stroke transition is invalid."
case .commitPendingInput:
    "A canonical commit is still pending."
case .invalidDrawableSize:
    "The drawable size is invalid."
```

- [ ] **Step 4: Add a thread-safe completion mailbox**

Create `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`:

```swift
import Foundation

final class GridRenderCompletionMailbox: @unchecked Sendable {
    struct Outcome: Sendable {
        let commitToken: UInt64?
        let succeeded: Bool
        let errorMessage: String?
    }

    private let lock = NSLock()
    private var outcomes: [Outcome] = []

    func push(_ outcome: Outcome) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }

    @MainActor
    func drain() -> [Outcome] {
        lock.lock()
        let result = outcomes
        outcomes.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }
}
```

The mailbox is the only cross-thread mutable object. Metal completion handlers write outcomes; the main actor drains them at the beginning of each timed frame. Texture identity, lifecycle, viewport, and UI state never mutate on a Metal callback thread.

- [ ] **Step 5: Create `GridRenderer` with exact public state and sample flow**

Create `Sources/MetalRenderer/GridRenderer.swift` with this public shape:

```swift
import CShaderTypes
import Foundation
import Metal
import MetalKit
import PatternEngine

public struct GridStructuralCounters: Equatable, Sendable {
    public var newDabsThisEvent = 0
    public var totalDabsThisStroke = 0
    public var newInstancesThisFrame = 0
    public var totalInstancesThisStroke = 0
    public var renderedFramesThisStroke = 0
}

@MainActor
public final class GridRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    public private(set) var lastError: MetalRendererError?
    public var onError: ((MetalRendererError) -> Void)?
    public private(set) var viewport: ViewportTransform
    public private(set) var counters = GridStructuralCounters()
    public var isIdle: Bool { lifecycle.state == .idle }
    public var hasActiveStroke: Bool { lifecycle.state == .active }

    private let commandQueue: any MTLCommandQueue
    private let pipelines: GridPipelineLibrary
    private let canonical: CanonicalRaster
    private let liveTile: PersistentLiveTile
    private let instancePool: DabInstanceBufferPool
    private let completionMailbox = GridRenderCompletionMailbox()
    private let tileSize = PatternSize(width: 256, height: 256)
    private var lifecycle = GridStrokeLifecycle()
    private var interpolator = CentripetalCatmullRomStrokeInterpolator(radius: 10)
    private var liveStroke = LiveStroke()
    private var completedUploadRanges: [(signal: UInt64, throughExclusive: UInt64)] = []
    private var needsLiveClear = true

    public convenience init(
        device: any MTLDevice,
        drawableSize: PatternSize
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(device: device, library: library, drawableSize: drawableSize)
    }

    public init(
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize
    ) throws {
        ShaderABI.preconditionValid()
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        pipelines = try GridPipelineLibrary(device: device, library: library)
        canonical = try CanonicalRaster(
            device: device,
            pixelSize: PixelSize(width: 256, height: 256)
        )
        liveTile = try PersistentLiveTile(
            device: device,
            pixelSize: PixelSize(width: 256, height: 256)
        )
        instancePool = try DabInstanceBufferPool(device: device)
        viewport = ViewportTransform(
            drawableSize: drawableSize,
            worldCenter: WorldPoint(x: 128, y: 128),
            zoom: 1
        )
        super.init()
        try clearInitialTextures()
    }

    public func handle(_ sample: StrokeSample) {
        do {
            counters.newDabsThisEvent = 0
            switch sample.phase {
            case .began:
                try lifecycle.begin()
                counters = GridStructuralCounters()
                let world = viewport.screenToWorld(sample.position)
                try interpolator.begin(at: world, emit: appendWorldDab)
            case .moved:
                guard lifecycle.state == .active else {
                    throw MetalRendererError.invalidStrokeLifecycle
                }
                let world = viewport.screenToWorld(sample.position)
                try interpolator.append(world, emit: appendWorldDab)
            case .ended:
                guard lifecycle.state == .active else {
                    throw MetalRendererError.invalidStrokeLifecycle
                }
                let world = viewport.screenToWorld(sample.position)
                try interpolator.finish(at: world, emit: appendWorldDab)
                try lifecycle.requestCommit()
            case .cancelled:
                try cancelActiveStroke()
            }
        } catch MetalRendererError.commitPendingInput {
            return
        } catch let error as MetalRendererError {
            failTransiently(error)
        } catch {
            failTransiently(.commandFailed(error.localizedDescription))
        }
    }

    public func cancelActiveStroke() throws {
        try lifecycle.cancelActive()
        interpolator.cancel()
        liveStroke.reset()
        liveTile.hide()
        needsLiveClear = true
    }

    public func pan(byScreenDelta delta: SIMD2<Float>) {
        guard isIdle else { return }
        viewport = viewport.panned(byScreenDelta: delta)
    }

    public func zoom(by factor: Float, anchor: ScreenPoint) {
        guard isIdle else { return }
        viewport = viewport.zoomed(by: factor, anchorScreen: anchor)
    }

    public func resize(to size: PatternSize) {
        viewport = viewport.resized(to: size)
    }

    private func appendWorldDab(_ point: WorldPoint) throws {
        let placements = GridProjection.placements(
            center: point,
            radius: GridCanvasContract.brushRadius,
            tileSize: tileSize
        )
        counters.newDabsThisEvent += 1
        counters.totalDabsThisStroke += 1
        for placement in placements {
            try liveStroke.append(
                PatternDabInstance(
                    center: SIMD2(placement.center.x, placement.center.y),
                    radius: placement.radius,
                    padding: 0
                )
            )
            counters.totalInstancesThisStroke += 1
        }
    }

    private func frameUniforms(
        drawableSize: PatternSize,
        showGridLines: Bool
    ) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: drawableSize.simd,
            worldCenter: viewport.worldCenter.simd,
            tileSize: tileSize.simd,
            zoom: viewport.zoom,
            gridLineWidth: 1,
            showGridLines: showGridLines ? 1 : 0,
            liveVisible: liveTile.isVisible ? 1 : 0
        )
    }
}
```

`clearInitialTextures()` is allowed to commit and wait because it runs once
during cold renderer initialization, before the renderer accepts input:

```swift
private func clearInitialTextures() throws {
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw MetalRendererError.commandBufferUnavailable
    }
    for texture in [canonical.front, canonical.scratch, liveTile.texture] {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.endEncoding()
    }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
        throw MetalRendererError.commandFailed(
            commandBuffer.error?.localizedDescription
                ?? "initial transparent clear failed"
        )
    }
    liveTile.markCleared()
}
```

- [ ] **Step 6: Add exact per-frame encoding and completion order**

Add these methods to `GridRenderer`; keep each encoder focused and make encoder creation failure leave pending state retryable:

```swift
public func draw(in view: MTKView) {
    drainFrameOutcomes()
    drainCompletedUploadRanges()
    guard let drawable = view.currentDrawable else { return }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        report(.commandBufferUnavailable)
        return
    }

    do {
        counters.newInstancesThisFrame = 0
        let encodedClear = needsLiveClear
        if encodedClear {
            try encodeLiveClear(commandBuffer)
        }
        let uploads = try encodePendingLiveDabs(commandBuffer)
        let encodedCommit = lifecycle.state == .commitRequested
        if encodedCommit {
            try encodeCommit(commandBuffer, after: uploads)
        }
        try encodeDisplay(into: drawable.texture, commandBuffer: commandBuffer)
        try finalizeFrameEncoding(
            encodedClear: encodedClear,
            uploads: uploads,
            encodedCommit: encodedCommit,
            commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        counters.renderedFramesThisStroke += lifecycle.state == .idle ? 0 : 1
        commandBuffer.commit()
    } catch let error as MetalRendererError {
        report(error)
    } catch {
        report(.commandFailed(error.localizedDescription))
    }
}

public func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
) {
    guard size.width > 0, size.height > 0 else { return }
    resize(to: PatternSize(width: Float(size.width), height: Float(size.height)))
}
```

Define the transaction value exactly:

```swift
private struct FrameUpload {
    let lease: DabInstanceBufferPool.Lease
    let throughExclusive: UInt64
    let count: Int
}
```

`encodePendingLiveDabs(_:)` returns `[FrameUpload]` and must:

1. Take the suffix whose identities are `>= liveStroke.bakedHighWater`.
2. Acquire up to three available leases without waiting.
3. Split the suffix into ordered chunks of at most `lease.capacity`.
4. Copy each chunk, encode a `.load` stamp pass with six vertices and `instanceCount == chunk.count`, and end the encoder.
5. Return one `FrameUpload` per encoded chunk without yet advancing
   high-water, counters, visibility, or buffer reuse state.

Only after the clear, stamp, commit, and display encoders all succeed,
`finalizeFrameEncoding(encodedClear:uploads:encodedCommit:commandBuffer:)`:

1. Marks the clear complete logically when `encodedClear` is true.
2. Calls `instancePool.markSubmitted` and encodes the shared-event signal for
   every lease.
3. Records `(lease.signalValue, throughExclusive)` in
   `completedUploadRanges`.
4. Advances `liveStroke.markEncoded(throughExclusive:)` in chunk order.
5. Adds only each chunk count to `newInstancesThisFrame` and marks live
   visible/dirty.

This transaction boundary guarantees an encoder-creation failure leaves
counters, pending dabs, high-water, logical clear state, and buffer reuse
unchanged. The uncommitted command buffer is discarded.

`drainCompletedUploadRanges()` reads `instancePool.event.signaledValue`, finds the greatest completed `throughExclusive`, calls `liveStroke.releaseEncodedPrefix(throughExclusive:)`, and removes only the corresponding range records. It never resets absolute identity.

`encodeCommit(_:after:)` must:

1. Refuse submission unless the last planned upload’s exclusive identity (or
   the current baked high-water when there is no upload) equals
   `liveStroke.emittedHighWater`.
2. Render canonical front plus visible live into canonical scratch using `pipelines.commit`, blending disabled, load `.dontCare`, store `.store`, and a 256 x 256 frame uniform.
3. Leave lifecycle and texture identity unchanged until every frame encoder
   succeeds.

When `encodedCommit` is true,
`finalizeFrameEncoding(encodedClear:uploads:encodedCommit:commandBuffer:)`
marks the commit submitted. Whether or not this frame contains a commit,
finalization adds exactly one completion handler; `commitToken` is the new
token for a commit frame and `nil` otherwise:

```swift
let commitToken: UInt64? = encodedCommit
    ? try lifecycle.markCommitSubmitted()
    : nil
commandBuffer.addCompletedHandler { [completionMailbox] buffer in
    completionMailbox.push(
        .init(
            commitToken: commitToken,
            succeeded: buffer.status == .completed,
            errorMessage: buffer.error?.localizedDescription
        )
    )
}
```

`drainFrameOutcomes()` processes every submitted-frame result. A successful
outcome with no token requires no lifecycle mutation. A successful outcome
with a token must match the current commit, then calls
`canonical.acceptScratchCommit()`, hides and resets live state, sets
`needsLiveClear = true`, and completes the lifecycle. Any failed outcome
cancels transient state and records `.commandFailed(...)`; a failed commit
never swaps scratch.

`encodeDisplay(into:commandBuffer:)` clears the drawable to:

```swift
MTLClearColor(
    red: 242.0 / 255.0,
    green: 244.0 / 255.0,
    blue: 241.0 / 255.0,
    alpha: 1
)
```

It binds canonical front at texture `0`, live at texture `1`, the current renderer-local viewport uniform at buffer `1`, and draws the fullscreen triangle with the display pipeline. `showGridLines` defaults to `0`; harness calls may override it per frame.

All error writes go through a private `report(_:)` method that assigns
`lastError` and invokes `onError` on the main actor. Pre-submit command-buffer
or encoder creation failures only report the error;
the frame transaction remains retryable and no pending counters or instances
are consumed. `failTransiently(_:)` is reserved for a submitted GPU failure:
it records `lastError`, calls
`lifecycle.resetTransiently()`, cancels interpolation, hides and resets live
state, clears `completedUploadRanges`, marks live for clear, and never changes
canonical front or its revision. Successful commit, active cancel, and any
failure also clear `completedUploadRanges` before resetting `LiveStroke`, so a
later shared-event signal can never compact a new stroke. Missing drawables
return before consuming pending dabs.

- [ ] **Step 7: Add deterministic offscreen seams without waits on the interactive API**

Add these internal methods for `HarnessRunner`:

```swift
func flushPendingLiveForHarness() throws -> GPUFrameMetrics

func renderOffscreenDisplayForHarness(
    width: Int,
    height: Int,
    showGridLines: Bool
) throws -> RenderedFrame

func finishCommitForHarness() throws -> GPUFrameMetrics

func copyCanonicalForHarness() throws -> any MTLTexture

var harnessCounters: GridStructuralCounters { counters }
var harnessRevision: RasterRevision { canonical.revision }
```

`flushPendingLiveForHarness` uses the same stamp encoder as the interactive
frame but isolates it in one command buffer so its GPU start/end timestamps
measure only dab rendering. `renderOffscreenDisplayForHarness` creates a shared
`.bgra8Unorm` target and isolates the normal display encoder in a second
command buffer. `finishCommitForHarness` isolates the normal commit encoder,
waits, drains the mailbox, and reports the commit GPU span.
`copyCanonicalForHarness` blits front into a shared readback texture. Waiting
is permitted only inside these explicitly cold harness methods. None is called
from `draw(in:)`, input handlers, or app navigation.

- [ ] **Step 8: Run lifecycle tests, full tests, and both builds**

Run:

```bash
swift test --filter GridStrokeLifecycle
swift test
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
```

Expected: lifecycle and retained CPU tests pass; both targets compile. GPU behavior remains unclaimed until Task 8 runs real-metallib scenes.

- [ ] **Step 9: Commit**

```bash
git add Sources/MetalRenderer Tests/MetalRendererTests
git commit -m "feat: add persistent grid renderer lifecycle"
```

---

### Task 7: macOS Input Adapter And Interactive Canvas

**Files:**
- Create: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `App/project.yml`

**Interfaces:**
- Consumes: `GridRenderer.handle(_:)`, `pan(byScreenDelta:)`,
  `zoom(by:anchor:)`, `hasActiveStroke`, `isIdle`, and `resize(to:)`.
- Produces: normalized mouse begin/move/end, idle-only Space-primary pan, cursor-anchored wheel/magnification zoom, Escape/focus-loss cancel, backing-coordinate conversion exactly once, and a compile-safe iPad view.

- [ ] **Step 1: Replace the SwiftUI renderer type and confirm the app fails to compile**

Add direct `PatternEngine` package dependencies beside `MetalRenderer` for
both `PatternSpikeMac` and `PatternSpikePad` in `App/project.yml`:

```yaml
    dependencies:
      - package: PatternModules
        product: PatternEngine
      - package: PatternModules
        product: MetalRenderer
```

In `ContentView.swift`, replace both `BlankRenderer` references with `GridRenderer` and initialize it with a nonzero startup size:

```swift
state = .ready(
    try GridRenderer(
        device: device,
        drawableSize: PatternSize(width: 1, height: 1)
    )
)
```

Add `import PatternEngine`.

Add runtime error state:

```swift
@State private var runtimeError: String?
```

Attach the renderer callback and a non-destructive overlay to the ready case:

```swift
MetalCanvas(renderer: renderer)
    .onAppear {
        renderer.onError = { runtimeError = $0.localizedDescription }
    }
    .overlay(alignment: .top) {
        if let runtimeError {
            Text(runtimeError)
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }
```

Initialization failure continues to use `ContentUnavailableView`. A runtime
failure keeps the last committed canvas visible beneath the short message.

Run:

```bash
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `MetalCanvas` still consumes `BlankRenderer`.

- [ ] **Step 2: Add the AppKit event adapter**

Create `App/PatternSpike/Canvas/InteractiveMetalView.swift`:

```swift
#if os(macOS)
import AppKit
import MetalKit
import MetalRenderer
import PatternEngine

@MainActor
final class InteractiveMetalView: MTKView {
    private enum DragMode {
        case drawing
        case panning(last: ScreenPoint)
    }

    let gridRenderer: GridRenderer
    private var dragMode: DragMode?
    private var spaceIsDown = false
    private var resignObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(frame: CGRect, renderer: GridRenderer) {
        gridRenderer = renderer
        super.init(frame: frame, device: renderer.device)
    }

    required init(coder: NSCoder) {
        fatalError("InteractiveMetalView requires a GridRenderer")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        guard let window else {
            resignObserver = nil
            screenObserver = nil
            return
        }
        window.makeFirstResponder(self)
        preferredFramesPerSecond = window.screen?.maximumFramesPerSecond ?? 60
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.spaceIsDown = false
                self?.cancelIfActive()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.preferredFramesPerSecond =
                    window?.screen?.maximumFramesPerSecond ?? 60
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = backingPoint(event)
        if spaceIsDown, gridRenderer.isIdle {
            dragMode = .panning(last: point)
        } else {
            dragMode = .drawing
            gridRenderer.handle(
                .mouse(position: point, timestamp: event.timestamp, phase: .began)
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = backingPoint(event)
        switch dragMode {
        case let .panning(last):
            gridRenderer.pan(
                byScreenDelta: SIMD2(point.x - last.x, point.y - last.y)
            )
            dragMode = .panning(last: point)
        case .drawing:
            gridRenderer.handle(
                .mouse(position: point, timestamp: event.timestamp, phase: .moved)
            )
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragMode = nil }
        guard case .drawing = dragMode else { return }
        gridRenderer.handle(
            .mouse(
                position: backingPoint(event),
                timestamp: event.timestamp,
                phase: .ended
            )
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard gridRenderer.isIdle else { return }
        gridRenderer.zoom(
            by: exp(Float(-event.scrollingDeltaY) * 0.01),
            anchor: backingPoint(event)
        )
    }

    override func magnify(with event: NSEvent) {
        guard gridRenderer.isIdle else { return }
        gridRenderer.zoom(
            by: max(0.01, 1 + Float(event.magnification)),
            anchor: backingPoint(event)
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = true
        } else if event.keyCode == 53 {
            cancelIfActive()
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceIsDown = false
        } else {
            super.keyUp(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelIfActive()
    }

    override func resignFirstResponder() -> Bool {
        cancelIfActive()
        return super.resignFirstResponder()
    }

    private func backingPoint(_ event: NSEvent) -> ScreenPoint {
        let local = convert(event.locationInWindow, from: nil)
        let backing = convertToBacking(local)
        return ScreenPoint(x: Float(backing.x), y: Float(backing.y))
    }

    private func cancelIfActive() {
        guard gridRenderer.hasActiveStroke else { return }
        gridRenderer.handle(
            .mouse(
                position: ScreenPoint(x: 0, y: 0),
                timestamp: ProcessInfo.processInfo.systemUptime,
                phase: .cancelled
            )
        )
        dragMode = nil
    }
}
#endif
```

Key code `49` is tracked directly because Space is a key, not an
`NSEvent.ModifierFlags` member. Command, Option, and middle drag are not mapped.

- [ ] **Step 3: Wire the representable and timed Metal view**

Change the shared configure function in `MetalCanvas.swift` to consume `GridRenderer`:

```swift
@MainActor
private func configure(
    _ view: MTKView,
    renderer: GridRenderer
) {
    view.device = renderer.device
    view.delegate = renderer
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(
        red: 242.0 / 255.0,
        green: 244.0 / 255.0,
        blue: 241.0 / 255.0,
        alpha: 1
    )
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
}
```

The shared fallback is 60 fps. On macOS, `InteractiveMetalView` replaces it
with `window.screen.maximumFramesPerSecond` and updates it when the window
moves to another screen.

Replace the macOS representable with:

```swift
struct MetalCanvas: NSViewRepresentable {
    let renderer: GridRenderer

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView(frame: .zero, renderer: renderer)
        configure(view, renderer: renderer)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {}
}
```

Keep the iPadOS representable compile-safe and passive:

```swift
struct MetalCanvas: UIViewRepresentable {
    let renderer: GridRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
```

- [ ] **Step 4: Build both targets and run the first manual interaction smoke**

Run:

```bash
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
open .build/DerivedData/Build/Products/Debug/PatternSpike.app
```

Expected automated result: both builds pass.

Manual smoke:

- Primary drag produces a black hard-round repeated stroke.
- A click produces one dot.
- Space-primary-drag pans only when begun idle.
- Pressing Space during a stroke does not convert the stroke into pan.
- Wheel and magnification keep the cursor’s world point anchored.
- Escape and loss of key focus remove an active stroke.
- Pointer-up causes no visible jump.

- [ ] **Step 5: Run all CPU tests**

Run:

```bash
swift test
```

Expected: all CPU tests pass; this command still makes no shader or AppKit-routing claim.

- [ ] **Step 6: Commit**

```bash
git add App/project.yml App/PatternSpike/Canvas App/PatternSpike/ContentView.swift
git commit -m "feat: connect macOS grid drawing input"
```

---

### Task 8: Real-Metallib Grid Harness And Benchmark Schema

**Files:**
- Modify: `Sources/MetalRenderer/BenchmarkRecord.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Modify: `Tests/MetalRendererTests/BenchmarkRecordTests.swift`
- Modify: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Create: `App/PatternSpike/Harness/Scenes/grid-interior.json`
- Create: `App/PatternSpike/Harness/Scenes/grid-interior-negative-control.json`
- Create: `App/PatternSpike/Harness/Scenes/grid-boundary.json`
- Create: `App/PatternSpike/Harness/Scenes/grid-boundary-negative-control.json`
- Create: `App/PatternSpike/Harness/Scenes/preview-commit.json`
- Create: `App/PatternSpike/Harness/Scenes/preview-commit-negative-control.json`
- Create: `App/PatternSpike/Harness/Scenes/cancel-preserves-canonical.json`
- Create: `App/PatternSpike/Harness/Scenes/cancel-preserves-canonical-negative-control.json`
- Create: `App/PatternSpike/Harness/Scenes/five-hundred-dabs.json`
- Create: `App/PatternSpike/Harness/Scenes/five-hundred-dabs-negative-control.json`
- Create: `App/PatternSpike/Harness/Scenes/long-stroke.json`
- Create: `App/PatternSpike/Harness/Scenes/long-stroke-negative-control.json`

**Interfaces:**
- Consumes: retained schema-1 blank scenes and `GridRenderer` cold harness seams.
- Produces: schema-2 `GridHarnessProgram`, per-channel pixel checks, structural checks, preview/commit and before/after equality checks, expanded benchmark JSON, live/committed/canonical PNGs, and typed nonzero failures.

- [ ] **Step 1: Write failing schema and benchmark tests**

Append to `Tests/MetalRendererTests/HarnessSceneTests.swift`:

```swift
@Test
func gridHarnessSceneDecodesVersionTwoProgramAndAssertions() throws {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "grid-interior",
          "width": 512,
          "height": 512,
          "program": "gridInterior",
          "checks": [
            {
              "channel": "liveScreen",
              "x": 200,
              "y": 256,
              "expectedBGRA": [0, 0, 0, 255],
              "tolerance": 1
            }
          ],
          "structuralChecks": [
            {
              "metric": "restampedInstanceCount",
              "relation": "equal",
              "value": 0
            }
          ]
        }
        """.utf8
    )

    let scene = try HarnessScene.decode(data)

    #expect(scene.program == .gridInterior)
    #expect(scene.checks[0].channel == .liveScreen)
    #expect(scene.structuralChecks.count == 1)
}

@Test
func schemaOneBlankSceneRemainsDecodable() throws {
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
    #expect(scene.program == nil)
    #expect(scene.checks[0].channel == .screen)
}

@Test
func schemaTwoRequiresAGridProgram() {
    let data = Data(
        """
        {
          "schemaVersion": 2,
          "name": "missing-program",
          "width": 512,
          "height": 512,
          "checks": []
        }
        """.utf8
    )

    #expect(throws: HarnessSceneError.missingProgram) {
        try HarnessScene.decode(data)
    }
}
```

Extend `benchmarkRecordRoundTripsWithoutLosingMetrics()` with:

```swift
brushProcessingMilliseconds: [0.4, 0.5],
eventToSubmitMilliseconds: [1.0, 1.1],
dabGPUMilliseconds: [0.8],
gridGPUMilliseconds: [0.6, 0.7],
commitGPUMilliseconds: [0.9],
commitPendingMilliseconds: [3.2],
displayFrameBudgetMilliseconds: 16.667,
newInstanceCounts: [12, 9],
totalStrokeInstanceCounts: [12, 21],
missedFrameCount: 0,
```

- [ ] **Step 2: Run focused tests and confirm schema/initializer failures**

Run:

```bash
swift test --filter HarnessScene
swift test --filter BenchmarkRecord
```

Expected: FAIL because schema 2 and expanded metrics are undefined.

- [ ] **Step 3: Extend the scene vocabulary while preserving schema 1**

Add to `HarnessScene.swift`:

```swift
public enum HarnessPixelChannel: String, Codable, Equatable, Sendable {
    case screen
    case liveScreen
    case committedScreen
    case canonical
}

public enum GridHarnessProgram: String, Codable, Equatable, Sendable {
    case gridInterior
    case gridBoundary
    case previewCommit
    case cancelPreservesCanonical
    case fiveHundredDabs
    case longStroke
}

public enum HarnessStructuralMetric: String, Codable, Equatable, Sendable {
    case emittedDabCount
    case encodedInstanceCount
    case restampedInstanceCount
    case canonicalRevisionDelta
    case previewCommitMaximumDelta
    case canonicalByteDelta
    case missedFrameCount
}

public enum HarnessRelation: String, Codable, Equatable, Sendable {
    case equal
    case lessThanOrEqual
}

public struct HarnessStructuralCheck: Codable, Equatable, Sendable {
    public let metric: HarnessStructuralMetric
    public let relation: HarnessRelation
    public let value: Int
}
```

Add `channel` to `HarnessPixelCheck` and decode it with `.screen` as the schema-1 default:

```swift
public let channel: HarnessPixelChannel

private enum CodingKeys: String, CodingKey {
    case channel, x, y, expectedBGRA, tolerance
}

public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    channel = try values.decodeIfPresent(
        HarnessPixelChannel.self,
        forKey: .channel
    ) ?? .screen
    x = try values.decode(Int.self, forKey: .x)
    y = try values.decode(Int.self, forKey: .y)
    expectedBGRA = try values.decode([UInt8].self, forKey: .expectedBGRA)
    tolerance = try values.decode(UInt8.self, forKey: .tolerance)
}
```

Add these properties to `HarnessScene`:

```swift
public let program: GridHarnessProgram?
public let structuralChecks: [HarnessStructuralCheck]
```

Use an explicit decoder that defaults both to `nil`/`[]` for schema 1. Validation accepts only:

```swift
switch schemaVersion {
case 1:
    guard program == nil else {
        throw HarnessSceneError.programForbiddenForSchemaOne
    }
case 2:
    guard program != nil else {
        throw HarnessSceneError.missingProgram
    }
default:
    throw HarnessSceneError.unsupportedSchema(schemaVersion)
}
```

Schema 1 still requires at least one pixel check. Schema 2 requires at least one pixel or structural check. Validate channel coordinates against scene dimensions and require all structural values to be nonnegative.

Add typed errors and messages:

```swift
case missingProgram
case programForbiddenForSchemaOne
case missingAssertions
case invalidStructuralValue(Int)
```

- [ ] **Step 4: Expand benchmark records without breaking Slice 0 decoding**

Add optional metric fields to `BenchmarkRecord`:

```swift
public let brushProcessingMilliseconds: [Double]?
public let eventToSubmitMilliseconds: [Double]?
public let dabGPUMilliseconds: [Double]?
public let gridGPUMilliseconds: [Double]?
public let commitGPUMilliseconds: [Double]?
public let commitPendingMilliseconds: [Double]?
public let displayFrameBudgetMilliseconds: Double?
public let newInstanceCounts: [Int]?
public let totalStrokeInstanceCounts: [Int]?
public let missedFrameCount: Int?
```

Add matching initializer parameters with `nil` defaults. Keep all existing
fields and coding keys unchanged. Slice 0 records omit the new keys; Slice 1
grid records set all ten metric fields.

Add these computed functions for tested gate math:

```swift
public static func percentile95(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int(ceil(Double(sorted.count) * 0.95)) - 1
    return sorted[max(0, min(index, sorted.count - 1))]
}

public var missedFrameFraction: Double {
    guard frameCount > 0 else { return 0 }
    return Double(missedFrameCount ?? 0) / Double(frameCount)
}
```

Add tests for `percentile95([1, 2, 3, 4, 100]) == 100` and `missedFrameCount = 1`, `frameCount = 200` producing `0.005`.

- [ ] **Step 5: Implement fixed, deterministic grid programs**

Add `import PatternEngine` to `HarnessRunner.swift`.

Change `HarnessRunner` to retain both renderers:

```swift
private let blankRenderer: BlankRenderer
private let gridRenderer: GridRenderer

public init(device: any MTLDevice) throws {
    guard let library = device.makeDefaultLibrary() else {
        throw MetalRendererError.defaultLibraryUnavailable
    }
    blankRenderer = try BlankRenderer(device: device, library: library)
    gridRenderer = try GridRenderer(
        device: device,
        library: library,
        drawableSize: PatternSize(width: 512, height: 512)
    )
}
```

Extend `HarnessRunResult` without breaking `HarnessLaunch`:

```swift
public let artifactURLs: [URL]
```

For schema 1, `artifactURLs == [imageURL, benchmarkURL]`. For schema 2,
`imageURL` is the committed screen when present, otherwise the live screen;
`artifactURLs` contains every emitted live/committed/canonical PNG plus the
benchmark JSON. The existing command-line `HARNESS PASS` prefix and primary
`image=`/`benchmark=` fields remain stable for Slice 0.

Keep the existing schema-1 path byte-for-byte equivalent. For schema 2, dispatch on `scene.program` to exact deterministic programs:

```swift
switch program {
case .gridInterior:
    begin(200, 256)
    move(240, 256)
    captureLive()
    end(240, 256)
    captureCommittedAndCanonical()
case .gridBoundary:
    begin(128, 128)
    move(160, 160)
    captureLive()
    end(160, 160)
    captureCommittedAndCanonical()
case .previewCommit:
    begin(180, 220)
    move(260, 300)
    captureLive()
    end(260, 300)
    captureCommittedAndCanonical()
case .cancelPreservesCanonical:
    begin(180, 180)
    end(220, 180)
    finishCommit()
    captureCanonicalBefore()
    begin(300, 300)
    move(340, 320)
    cancel()
    captureCommittedAndCanonical()
case .fiveHundredDabs:
    injectFiveHundredInteriorDabsIntoOneFrame()
    captureLive()
case .longStroke:
    replayLongZigzagWithOneFramePerSegment()
    captureLive()
    endAtLastZigzagPoint()
    captureCommittedAndCanonical()
}
```

Use timestamps starting at `0` and increasing by `1.0 / 120.0`. `begin`,
`move`, and `end` construct `StrokeSample.mouse`; `cancel` constructs
`.cancelled`. Measure brush CPU time directly around each `handle` call.
Every live capture calls `flushPendingLiveForHarness` followed by
`renderOffscreenDisplayForHarness`; commit programs call
`finishCommitForHarness` and then render the committed display. Record the
isolated GPU spans in `dabGPUMilliseconds`, `gridGPUMilliseconds`, and the
commit metrics.

`injectFiveHundredInteriorDabsIntoOneFrame()` is a harness-only internal seam on `GridRenderer`. It appends exactly 500 hard-round instances with centers on a 20 x 25 lattice inside canonical `[32, 224)`, then renders one live frame. This isolates the exact 500-instance GPU budget; the other five programs prove the real input/interpolation path.

`replayLongZigzagWithOneFramePerSegment()` uses 240 move samples alternating between x `48` and `208`, with y cycling through `48...208`, and records counters after every frame. Calculate:

```swift
restampedInstanceCount += max(
    0,
    counters.newInstancesThisFrame - instancesCreatedSincePreviousFrame
)
```

This must remain zero. Also retain every frame’s `newInstancesThisFrame` and `totalInstancesThisStroke` in benchmark JSON so late-frame work is auditable.

Capture:

- `name.live.screen.png` immediately before end/cancel.
- `name.committed.screen.png` after commit/cancel settles.
- `name.canonical.png` from the shared canonical readback.
- `name.benchmark.json` with CPU brush spans, event-to-submit spans,
  commit-pending spans, display-frame budget, separate dab/display GPU spans,
  frame counts, instance counters, missed frames, hardware, OS, build, and
  peak resident memory.

For preview/commit, compare every BGRA byte and report the maximum absolute channel delta. For cancel, compare canonical-before and canonical-after bytes exactly and record revision delta. These comparisons occur before evaluating JSON-authored checks.

- [ ] **Step 6: Add typed channel and structural assertion failures**

Add to `HarnessRunError`:

```swift
case missingArtifact(HarnessPixelChannel)
case structuralMismatch(
    metric: HarnessStructuralMetric,
    expectedRelation: HarnessRelation,
    expectedValue: Int,
    actualValue: Int
)
```

Evaluate every pixel check against its named texture and every structural check against the measured dictionary. `.equal` uses `actual == value`; `.lessThanOrEqual` uses `actual <= value`. Error text includes scene name, metric/channel, expected relation/value, and actual value so the verification script can require the exact intended failure family.

- [ ] **Step 7: Add the twelve exact scene files**

Every file uses width/height `512`, schema `2`, BGRA byte order, and tolerance `1`. Use this exact positive shape:

```json
{
  "schemaVersion": 2,
  "name": "grid-interior",
  "width": 512,
  "height": 512,
  "program": "gridInterior",
  "checks": [
    {
      "channel": "liveScreen",
      "x": 200,
      "y": 256,
      "expectedBGRA": [0, 0, 0, 255],
      "tolerance": 1
    },
    {
      "channel": "committedScreen",
      "x": 456,
      "y": 256,
      "expectedBGRA": [0, 0, 0, 255],
      "tolerance": 1
    }
  ],
  "structuralChecks": [
    {
      "metric": "restampedInstanceCount",
      "relation": "equal",
      "value": 0
    }
  ]
}
```

Create the remaining files using these exact programs and assertions:

| File stem | Program | Positive assertion | Negative-control change |
|---|---|---|---|
| `grid-interior` | `gridInterior` | live `(200,256)` and committed repeat `(456,256)` are `[0,0,0,255]`; restamped `0` | expect paper at live `(200,256)` |
| `grid-boundary` | `gridBoundary` | live `(128,128)` and `(384,128)` are ink; canonical `(0,0)` is ink | expect paper at canonical `(0,0)` |
| `preview-commit` | `previewCommit` | `previewCommitMaximumDelta <= 1` and canonical revision delta `1` | expect paper at the known live ink probe `(180,220)` |
| `cancel-preserves-canonical` | `cancelPreservesCanonical` | `canonicalByteDelta == 0` and revision delta `0` across cancelled stroke | require revision delta `1` |
| `five-hundred-dabs` | `fiveHundredDabs` | emitted dab count `500`, encoded instance count `500`, restamped `0` | require encoded instance count `499` |
| `long-stroke` | `longStroke` | restamped `0`, missed-frame count `<= 2`, preview/commit delta `<= 1` | require restamped instance count `1` |

Each `*-negative-control.json` differs from its positive partner only by the listed deliberately wrong assertion. Do not add renderer mutation flags or test-only shader branches.

- [ ] **Step 8: Run schema tests, build the app, then prove each negative fails**

Run:

```bash
swift test --filter HarnessScene
swift test --filter BenchmarkRecord
swift test
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -destination 'platform=macOS' -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
```

For each negative scene, run the built app with the existing `--harness-scene`, `--output-directory`, `--git-commit`, and `--configuration` flags.

Expected: all six negative controls exit nonzero with `HARNESS FAIL` naming their intended pixel or structural mismatch.

Then run all six positive scenes.

Expected: all exit zero with `HARNESS PASS`; each emits the relevant PNG set and expanded benchmark JSON.

- [ ] **Step 9: Commit**

```bash
git add Sources/MetalRenderer Tests/MetalRendererTests App/PatternSpike/Harness/Scenes
git commit -m "test: add measured grid render harness"
```

---

### Task 9: Automated Gate, Performance Acceptance, And Milestone

**Files:**
- Create: `scripts/verify-slice1.sh`
- Create after measured acceptance: `docs/superpowers/milestones/01-measured-grid-drawing-kernel.md`

**Interfaces:**
- Consumes: Slice 0 gate, all twelve Slice 1 scenes, built app executable, PNG artifacts, benchmark JSON, repository state, and the manual Mac checklist.
- Produces: one executable `./scripts/verify-slice1.sh`, accepted fixed-scene baseline artifacts under `.build/slice1-artifacts/`, and a milestone evidence note.

- [ ] **Step 1: Write the gate script around exact negative-first ordering**

Create `scripts/verify-slice1.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/slice1-artifacts"
scenes="$repo_root/App/PatternSpike/Harness/Scenes"
binary="$repo_root/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"

cd "$repo_root"
rm -rf "$artifacts"
mkdir -p "$artifacts/negative-control" "$artifacts/positive"

./scripts/verify-slice0.sh

git_commit="$(git rev-parse HEAD)"

negative_scenes=(
  grid-interior-negative-control
  grid-boundary-negative-control
  preview-commit-negative-control
  cancel-preserves-canonical-negative-control
  five-hundred-dabs-negative-control
  long-stroke-negative-control
)

for name in "${negative_scenes[@]}"; do
  output="$artifacts/negative-control/$name"
  mkdir -p "$output"
  if "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$output/stdout.log" \
    2>"$output/stderr.log"
  then
    printf 'Negative control unexpectedly passed: %s\n' "$name"
    exit 1
  fi
  grep -q '^HARNESS FAIL ' "$output/stderr.log"
  printf 'negative-control=%s failed-as-expected\n' "$name"
done

positive_scenes=(
  grid-interior
  grid-boundary
  preview-commit
  cancel-preserves-canonical
  five-hundred-dabs
  long-stroke
)

for name in "${positive_scenes[@]}"; do
  output="$artifacts/positive/$name"
  mkdir -p "$output"
  "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    | tee "$output/stdout.log"
  grep -q "^HARNESS PASS scene=$name " "$output/stdout.log"
  test -s "$output/$name.benchmark.json"
done

test -s "$artifacts/positive/grid-interior/grid-interior.live.screen.png"
test -s "$artifacts/positive/grid-interior/grid-interior.committed.screen.png"
test -s "$artifacts/positive/grid-interior/grid-interior.canonical.png"

if git ls-files --error-unmatch App/PatternSpike.xcodeproj >/dev/null 2>&1; then
  printf '%s\n' "Generated Xcode project is tracked."
  exit 1
fi

if git status --short -- .build App/PatternSpike.xcodeproj | grep -q .; then
  printf '%s\n' "Generated build artifacts escaped ignore rules."
  exit 1
fi

printf '%s\n' "slice0-regression=passed"
printf '%s\n' "swift-tests=passed"
printf '%s\n' "macos-build=passed"
printf '%s\n' "ipados-simulator-build=passed"
printf '%s\n' "grid-negative-controls=passed"
printf '%s\n' "grid-positive-scenes=passed"
printf '%s\n' "SLICE1 AUTOMATED GATE PASS"
```

Make it executable:

```bash
chmod +x scripts/verify-slice1.sh
```

- [ ] **Step 2: Enforce performance budgets from measured scene records**

Before the final success line, add a Swift one-shot check invoked with the six benchmark paths:

```bash
swift - "$artifacts/positive" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let names = [
    "grid-interior",
    "grid-boundary",
    "preview-commit",
    "cancel-preserves-canonical",
    "five-hundred-dabs",
    "long-stroke",
]

func p95(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    return sorted[index]
}

var records: [[String: Any]] = []
for name in names {
    let url = root
        .appendingPathComponent(name)
        .appendingPathComponent("\(name).benchmark.json")
    let data = try Data(contentsOf: url)
    records.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
}

let allBrush = records.flatMap { $0["brushProcessingMilliseconds"] as! [Double] }
let allGrid = records.flatMap { $0["gridGPUMilliseconds"] as! [Double] }
let fiveHundred = records.first { $0["sceneName"] as? String == "five-hundred-dabs" }!
let dab = (fiveHundred["dabGPUMilliseconds"] as! [Double]).max() ?? 0
let long = records.first { $0["sceneName"] as? String == "long-stroke" }!
let frameCount = long["frameCount"] as! Int
let missed = long["missedFrameCount"] as! Int
let newCounts = long["newInstanceCounts"] as! [Int]
let totals = long["totalStrokeInstanceCounts"] as! [Int]
let commitPending = records.flatMap {
    $0["commitPendingMilliseconds"] as! [Double]
}
let frameBudget = records.compactMap {
    $0["displayFrameBudgetMilliseconds"] as? Double
}.min()!

guard p95(allBrush) < 2 else { fatalError("brush p95 budget failed") }
guard p95(allGrid) < 2 else { fatalError("grid p95 budget failed") }
guard dab < 3 else { fatalError("500-dab GPU budget failed") }
guard Double(missed) / Double(frameCount) < 0.01 else {
    fatalError("missed-frame budget failed")
}
guard zip(newCounts, totals).allSatisfy({ $0 <= $1 }) else {
    fatalError("instance counter ordering failed")
}
guard (commitPending.max() ?? 0) < frameBudget else {
    fatalError("commit-pending frame budget failed")
}
SWIFT
```

The fixed long-stroke structural assertion remains the primary no-growth proof. The timing check establishes the accepted Slice 1 baseline; no comparison to an earlier Slice 1 baseline is made.

- [ ] **Step 3: Run the complete automated gate**

Run:

```bash
./scripts/verify-slice1.sh
```

Expected tail:

```text
slice0-regression=passed
swift-tests=passed
macos-build=passed
ipados-simulator-build=passed
grid-negative-controls=passed
grid-positive-scenes=passed
SLICE1 AUTOMATED GATE PASS
```

If a hardware timing budget fails, retain the JSON and investigate the measured stage. Do not weaken a threshold or label the gate accepted without resolving and recording the environment-specific cause.

- [ ] **Step 4: Run the full manual Mac gate**

Launch:

```bash
open .build/DerivedData/Build/Products/Debug/PatternSpike.app
```

Confirm all:

- First dab appears under the cursor.
- A stroke repeats live across visible grid cells.
- Grid-edge and corner strokes have no visible gap.
- Pointer-up causes no visible change.
- Escape discards the active stroke.
- Switching application focus discards the active stroke.
- Space-primary-drag pans from idle.
- Pressing Space mid-stroke does not convert the stroke to pan.
- Wheel and pinch zoom stay cursor anchored and clamp at `0.25...8.0`.
- Long strokes remain responsive.
- Resize preserves rendering and input alignment.
- Rapid pointer-down during the sub-frame commit-pending interval produces no partial second stroke or perceptible stall.

- [ ] **Step 5: Record measured acceptance**

Create `docs/superpowers/milestones/01-measured-grid-drawing-kernel.md` with:

```markdown
# Slice 1: Measured Grid Drawing Kernel

**Status:** Accepted
**Gate:** `./scripts/verify-slice1.sh`

## Result

- Pure viewport, interpolation, grid projection, raster, ABI, lifecycle, and harness contracts passed.
- macOS interaction and generic iPadOS Simulator builds passed.
- The real app metallib passed all six grid scene families.
- Each negative control failed on its intended pixel or structural assertion before its positive partner passed.
- Preview and commit maximum channel delta stayed within one 8-bit value.
- Cancel preserved canonical bytes and revision identity.
- Long-stroke counters recorded zero restamped instances.

## Measured Baseline

- Record the exact artifact-relative benchmark paths.
- Record GPU name, OS version, build configuration, and commit from the JSON.
- Record brush-processing p95, grid-pass p95, 500-dab GPU time, missed-frame fraction, peak resident bytes, and commit-pending maximum.

## Decisions

- Record whether timed `MTKView` met the interaction and frame budgets without a custom display scheduler.
- Record the accepted fixed pending and instance-buffer capacities.
- Record any measured environment limitation and its resolution.

## Manual Gate

- Record acceptance of drawing feel, grid continuity, preview/commit stability, cancel, pan/zoom, long-stroke responsiveness, resize alignment, and commit-pending behavior.

## Retrospective

- Record evidence-backed improvements for Slice 2 planning without expanding Slice 1 scope.
```

Replace every “Record …” instruction with the actual values and observations from the accepted run before committing the milestone. The checked-in note contains no unfilled metric field.

- [ ] **Step 6: Re-run hygiene and commit**

Run:

```bash
git diff --check
if rg -n '^- Record ' docs/superpowers/milestones/01-measured-grid-drawing-kernel.md; then
  exit 1
fi
git status --short
```

Expected: `git diff --check` exits zero; no unfilled “Record” instruction
remains; only the script and completed milestone note are pending.

Commit:

```bash
git add scripts/verify-slice1.sh docs/superpowers/milestones/01-measured-grid-drawing-kernel.md
git commit -m "test: close measured grid kernel gate"
```

---

## Final Acceptance Checklist

- [ ] `swift test` passes all CPU-only contracts.
- [ ] Existing Slice 0 blank positive and negative scenes still pass their gate.
- [ ] macOS app build succeeds through generated `PatternSpikeMac`.
- [ ] generic iPadOS Simulator build succeeds through `PatternSpikePad`.
- [ ] All six Slice 1 negative controls fail on their intended assertion.
- [ ] All six Slice 1 positive scenes pass through the real app metallib.
- [ ] Live, committed, and canonical PNG artifacts exist where required.
- [ ] Preview and commit differ by at most one 8-bit channel value.
- [ ] Cancel leaves canonical bytes and revision unchanged.
- [ ] Long-stroke structural counters show no accumulated restamping.
- [ ] Brush processing p95 is below 2 ms/frame.
- [ ] The 500-new-dab GPU pass is below 3 ms.
- [ ] Grid display p95 is below 2 ms.
- [ ] Missed frames stay below 1 percent.
- [ ] Slice 1 benchmark identity and baseline values are recorded.
- [ ] Manual drawing, grid continuity, commit, cancel, pan/zoom, resize, and feel checks are accepted.
- [ ] Generated project and build artifacts remain ignored.
- [ ] No Slice 2 or later product behavior entered the diff.
