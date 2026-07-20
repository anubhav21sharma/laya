# Transactions, Region Undo, Color, And Eraser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Slice 3: one total editor transaction lifecycle, bounded
region-based undo/redo, colored hard-round drawing, live/committed
destination-out erasing, undoable tiling and top-left crop/fill resize, and
minimal native controls.

**Architecture:** PatternEngine supplies platform-free pixel regions, colors,
render styles, and opaque raster revision references. EditorCore owns the total
transaction reducer, semantic key map, observable editor state, and linear
history. MetalRenderer owns GPU revision payloads and tokenized atomic raster
operations. A thin app controller applies reducer effects in order and
finalizes history only after renderer success.

**Tech Stack:** Swift 6, Swift Testing, Observation, SwiftUI, Metal,
MetalKit, shared C/MSL ABI, XcodeGen, Bash, JSON harness scenes.

## Global Constraints

- Governing spec:
  `docs/superpowers/specs/2026-07-20-transactions-region-undo-color-eraser-design.md`.
- Master precedence:
  `docs/superpowers/specs/2026-07-18-pattern-product-rebuild-design.md`.
- Work directly on `main`; user explicitly rejected a worktree for this
  project.
- Minimum macOS 14 and iPadOS 17; both targets must build after every task.
- PatternEngine imports Foundation and simd only.
- EditorCore contains no Metal, SwiftUI, AppKit, UIKit, `KeyPress`, or
  `NSEvent` types.
- MetalRenderer depends only on PatternEngine and CShaderTypes.
- PatternApp is the only layer importing EditorCore and MetalRenderer
  together.
- Canonical/live textures remain `.bgra8Unorm` premultiplied storage.
- Tile dimensions remain independently bounded to `64...4096`.
- Hard-round diameter is
  `2...min(2000, 8 * min(tileWidth, tileHeight))`; radius is diameter/2.
- History is limited to 100 commands and 200 MiB retained raster payload.
- Tiling changes never mutate canonical bytes.
- Resize preserves the top-left intersection exactly; no sampling or scaling.
- Eraser strength is fixed at `1.0` and never reads mouse pressure.
- Every new GPU harness family runs its named negative control first.
- Existing Slice 0–2 performance thresholds remain unchanged.
- Slice 2 start-gate override permits work; it does not mark Slice 2 accepted.
- Preserve unrelated user changes in the worktree.
- Complete one task, run its focused tests, obtain a fresh review, then commit.

---

## File Map

### PatternEngine

- Create `Sources/PatternEngine/PixelRegion.swift`
  - `PixelRect`, deterministic `PixelRegionSet`, clipping and merge behavior.
- Create `Sources/PatternEngine/InkColor.swift`
  - finite straight-sRGB RGBA value.
- Create `Sources/PatternEngine/RasterRevisionReference.swift`
  - opaque stored revision identity and Metal-free payload descriptor.
- Create `Sources/PatternEngine/StrokeRenderStyle.swift`
  - draw/erase composite mode and captured color/diameter.
- Modify `Sources/PatternEngine/Geometry.swift`
  - make `PixelSize` hashable; add no policy.
- Modify `Sources/PatternEngine/TilingProjection.swift`
  - conservative canonical dirty rectangle for a projected fragment.

### EditorCore

- Create `Sources/EditorCore/Configuration/EditorConfiguration.swift`
  - brush/tile ranges and stepping.
- Create `Sources/EditorCore/Commands/EditorCommand.swift`
  - semantic command, key, modifier, and key-phase values.
- Create `Sources/EditorCore/Commands/EditorKeymap.swift`
  - platform-independent key resolution.
- Create `Sources/EditorCore/History/DocumentHistory.swift`
  - typed commands, two-phase navigation, pruning and revision release.
- Create `Sources/EditorCore/Transactions/EditorTransaction.swift`
  - total state/event reducer and ordered effects.
- Modify `Sources/EditorCore/Model/EditorModel.swift`
  - observable committed configuration and derived availability.

### CShaderTypes And MetalRenderer

- Modify `Sources/CShaderTypes/include/ShaderTypes.h`
  - color in projected instances; composite mode in frame uniforms.
- Modify `Sources/MetalRenderer/ShaderABI.swift`
  - exact new layout checks.
- Modify `Sources/MetalRenderer/ProjectedStampInstance.swift`
  - copy straight RGBA.
- Modify `Sources/MetalRenderer/Shaders.metal`
  - color stamping and shared draw/erase composite helper.
- Modify `Sources/MetalRenderer/GridPipelineLibrary.swift`
  - retain straight-source stamp and replacement commit behavior.
- Create `Sources/MetalRenderer/Raster/RasterRevisionStore.swift`
  - aligned GPU region capture/restore and revision lifetime.
- Create `Sources/MetalRenderer/Raster/RendererRasterOperation.swift`
  - tokenized receipts and completion values.
- Modify `Sources/MetalRenderer/CanonicalRaster.swift`
  - reusable clear/copy resource construction and generation acceptance.
- Modify `Sources/MetalRenderer/LiveStroke.swift`
  - retain dirty regions independently from released instances.
- Modify `Sources/MetalRenderer/GridRenderer.swift`
  - transaction-controlled execution, history captures, clear/restore/resize,
    color, eraser, grid visibility.
- Modify `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`
  - generic operation outcomes.
- Modify `Sources/MetalRenderer/MetalRendererError.swift`
  - typed revision, token, restore, resize and busy failures.
- Delete `Sources/MetalRenderer/GridStrokeLifecycle.swift`
  - reducer replaces policy owner after migration.

### App

- Create `App/PatternSpike/EditorSessionController.swift`
  - reducer/history/renderer orchestration.
- Create `App/PatternSpike/Commands/EditorFocusedCommands.swift`
  - focused menu command bridge.
- Create `App/PatternSpike/Panels/ToolRail.swift`
  - Draw and Erase controls.
- Create `App/PatternSpike/Panels/EditorTopBar.swift`
  - diameter, color, undo, redo, clear.
- Create `App/PatternSpike/Panels/TilingInspector.swift`
  - tiling, grid, width/height draft and Apply.
- Modify `App/PatternSpike/ContentView.swift`
  - compose controller and minimal shell.
- Modify `App/PatternSpike/PatternSpikeApp.swift`
  - focused macOS menu commands.
- Modify `App/PatternSpike/Canvas/MetalCanvas.swift`
  - receive controller and keep renderer as delegate.
- Modify `App/PatternSpike/Canvas/InteractiveMetalView.swift`
  - pointer/gesture adapter only; remove key ownership.

### Tests, Harness, And Gate

- Create `Tests/PatternEngineTests/PixelRegionTests.swift`.
- Create `Tests/PatternEngineTests/InkColorTests.swift`.
- Create `Tests/EditorCoreTests/EditorConfigurationTests.swift`.
- Create `Tests/EditorCoreTests/DocumentHistoryTests.swift`.
- Create `Tests/EditorCoreTests/EditorKeymapTests.swift`.
- Create `Tests/EditorCoreTests/EditorTransactionTests.swift`.
- Create `Tests/MetalRendererTests/RasterRevisionStoreTests.swift`.
- Create `Tests/MetalRendererTests/RendererTransactionTests.swift`.
- Create `Tests/MetalRendererTests/RendererRasterOperationTests.swift`.
- Create `Tests/MetalRendererTests/RendererResizeTests.swift`.
- Modify `Tests/MetalRendererTests/ShaderABILayoutTests.swift`.
- Modify `Tests/MetalRendererTests/ProjectedStampInstanceTests.swift`.
- Delete `Tests/MetalRendererTests/GridStrokeLifecycleTests.swift` after
  equivalent reducer/executor coverage exists.
- Modify `Sources/MetalRenderer/Capture/HarnessScene.swift`.
- Create `Sources/MetalRenderer/Capture/SliceThreeHarnessRunner.swift`.
- Modify `Sources/MetalRenderer/Capture/HarnessRunner.swift` only to route
  Slice 3 programs.
- Add twelve schema-4 scene JSON files under
  `App/PatternSpike/Harness/Scenes/`.
- Create `scripts/verify-slice3.sh`.
- Create
  `docs/superpowers/milestones/03-transactions-region-undo-color-eraser.md`.

---

### Task 1: Pixel Regions, Ink Color, And Dirty Bounds

**Files:**
- Create: `Sources/PatternEngine/PixelRegion.swift`
- Create: `Sources/PatternEngine/InkColor.swift`
- Create: `Sources/PatternEngine/RasterRevisionReference.swift`
- Create: `Sources/PatternEngine/StrokeRenderStyle.swift`
- Modify: `Sources/PatternEngine/Geometry.swift`
- Modify: `Sources/PatternEngine/TilingProjection.swift`
- Create: `Tests/PatternEngineTests/PixelRegionTests.swift`
- Create: `Tests/PatternEngineTests/InkColorTests.swift`
- Modify: `Tests/PatternEngineTests/TilingProjectionTests.swift`

**Interfaces:**
- Produces:
  - `PixelRect(minX:minY:maxX:maxY:)`
  - `PixelRegionSet(_:clippedTo:)`
  - `InkColor(red:green:blue:alpha:)`
  - `StoredRasterRevisionID`
  - `RasterRevisionReference`
  - `StrokeCompositeMode`
  - `StrokeRenderStyle`
  - `TilingProjection.dirtyPixelRect(for:radius:)`
- Consumes: existing `PixelSize`, `CellFragment`, `Affine2D`.

- [ ] **Step 1: Write failing region and color tests**

```swift
import PatternEngine
import Testing

@Test
func regionSetMergesTouchingButKeepsSeparatedSeamEdges() {
    let size = PixelSize(width: 256, height: 192)
    let regions = PixelRegionSet(
        [
            PixelRect(minX: -2, minY: 8, maxX: 4, maxY: 20)!,
            PixelRect(minX: 4, minY: 8, maxX: 10, maxY: 20)!,
            PixelRect(minX: 250, minY: 8, maxX: 260, maxY: 20)!,
        ],
        clippedTo: size
    )

    #expect(regions.rectangles == [
        PixelRect(minX: 0, minY: 8, maxX: 10, maxY: 20)!,
        PixelRect(minX: 250, minY: 8, maxX: 256, maxY: 20)!,
    ])
}

@Test
func inkColorRejectsNonfiniteAndOutOfRangeComponents() {
    #expect(InkColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8) != nil)
    #expect(InkColor(red: -.infinity, green: 0, blue: 0, alpha: 1) == nil)
    #expect(InkColor(red: 1.01, green: 0, blue: 0, alpha: 1) == nil)
}
```

Add dirty-bound tests using a manual fragment centered at `(4, 96)` with
radius `10`; the returned rectangle must include the one-pixel shader
expansion and clip to the canonical tile.

- [ ] **Step 2: Run tests and confirm missing-type failures**

Run:

```bash
swift test --filter 'PixelRegionTests|InkColorTests|dirtyPixelRect'
```

Expected: compilation fails because the new values do not exist.

- [ ] **Step 3: Implement pixel rectangles and deterministic region sets**

```swift
public struct PixelRect: Hashable, Sendable {
    public let minX: Int
    public let minY: Int
    public let maxX: Int
    public let maxY: Int

    public init?(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        guard maxX > minX, maxY > minY else { return nil }
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Int { maxX - minX }
    public var height: Int { maxY - minY }

    public func clipped(to size: PixelSize) -> PixelRect? {
        PixelRect(
            minX: max(0, minX),
            minY: max(0, minY),
            maxX: min(size.width, maxX),
            maxY: min(size.height, maxY)
        )
    }

    public func touchesOrOverlaps(_ other: PixelRect) -> Bool {
        minX <= other.maxX && other.minX <= maxX
            && minY <= other.maxY && other.minY <= maxY
    }

    public func union(_ other: PixelRect) -> PixelRect {
        PixelRect(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )!
    }
}

public struct PixelRegionSet: Equatable, Sendable {
    public let rectangles: [PixelRect]

    public init(_ candidates: [PixelRect], clippedTo size: PixelSize) {
        var pending = candidates.compactMap { $0.clipped(to: size) }
        pending.sort(by: PixelRegionSet.precedes)
        var merged: [PixelRect] = []

        while let first = pending.first {
            pending.removeFirst()
            var current = first
            var didMerge = true
            while didMerge {
                didMerge = false
                for index in pending.indices.reversed()
                where current.touchesOrOverlaps(pending[index]) {
                    current = current.union(pending.remove(at: index))
                    didMerge = true
                }
            }
            merged.append(current)
        }
        rectangles = merged.sorted(by: PixelRegionSet.precedes)
    }

    private static func precedes(_ lhs: PixelRect, _ rhs: PixelRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.maxY != rhs.maxY { return lhs.maxY < rhs.maxY }
        return lhs.maxX < rhs.maxX
    }
}
```

- [ ] **Step 4: Implement color, render style, and revision references**

```swift
public struct InkColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public let alpha: Float

    public init?(red: Float, green: Float, blue: Float, alpha: Float) {
        let values = [red, green, blue, alpha]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return nil }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = InkColor(
        red: 0, green: 0, blue: 0, alpha: 1
    )!

    public var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }
}

public enum StrokeCompositeMode: UInt32, Equatable, Sendable {
    case draw = 0
    case erase = 1
}

public struct StrokeRenderStyle: Equatable, Sendable {
    public let color: InkColor
    public let diameter: Float
    public let compositeMode: StrokeCompositeMode
    public let eraserStrength: Float

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float
    ) {
        precondition(diameter.isFinite && diameter > 0)
        precondition(
            eraserStrength.isFinite && (0...1).contains(eraserStrength)
        )
        self.color = color
        self.diameter = diameter
        self.compositeMode = compositeMode
        self.eraserStrength = eraserStrength
    }
}

public struct StoredRasterRevisionID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct RasterRevisionReference: Equatable, Sendable {
    public let id: StoredRasterRevisionID
    public let pixelSize: PixelSize
    public let regions: PixelRegionSet
    public let retainedBytes: Int

    public init(
        id: StoredRasterRevisionID,
        pixelSize: PixelSize,
        regions: PixelRegionSet,
        retainedBytes: Int
    ) {
        precondition(retainedBytes >= 0)
        self.id = id
        self.pixelSize = pixelSize
        self.regions = regions
        self.retainedBytes = retainedBytes
    }
}
```

Add `Hashable` to `PixelSize`.

- [ ] **Step 5: Implement conservative projected dirty bounds**

Use shader-equivalent local expansion:

```swift
public static func dirtyPixelRect(
    for fragment: CellFragment,
    radius: Float
) -> PixelRect {
    precondition(radius.isFinite && radius >= 1)
    let expansion = 1 + 1 / radius
    let corners = [
        SIMD2(-expansion, -expansion),
        SIMD2(expansion, -expansion),
        SIMD2(-expansion, expansion),
        SIMD2(expansion, expansion),
    ].map(fragment.canonicalFromBrush.applying)
    return PixelRect(
        minX: Int(floor(corners.map(\.x).min()!)),
        minY: Int(floor(corners.map(\.y).min()!)),
        maxX: Int(ceil(corners.map(\.x).max()!)),
        maxY: Int(ceil(corners.map(\.y).max()!))
    )!
}
```

This may include unchanged pixels; it may never exclude a shader-touched
pixel.

- [ ] **Step 6: Run focused and full pure tests**

```bash
swift test --filter 'PixelRegionTests|InkColorTests|TilingProjectionTests'
swift test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PatternEngine Tests/PatternEngineTests
git commit -m "feat(engine): add raster region values"
```

---

### Task 2: Typed Bounded Document History

**Files:**
- Create: `Sources/EditorCore/History/DocumentHistory.swift`
- Create: `Tests/EditorCoreTests/DocumentHistoryTests.swift`

**Interfaces:**
- Consumes: `RasterRevisionReference`, `TilingKind`, `PixelSize`.
- Produces:
  - `RasterEditKind`
  - `RasterHistoryCommand`
  - `TileResizeHistoryCommand`
  - `DocumentHistoryCommand`
  - `HistoryNavigation`
  - `DocumentHistory.beginUndo()`
  - `DocumentHistory.beginRedo()`
  - `DocumentHistory.finishNavigation(token:succeeded:)`
  - `DocumentHistory.validateNewCommand(retainedBytes:)`
  - `DocumentHistory.appendSuccessful(_:)`

- [ ] **Step 1: Write failing history tests**

Cover:

```swift
@Test
func navigationMovesCursorOnlyAfterSuccess() throws {
    var history = DocumentHistory()
    let command = makeRasterCommand(bytes: 64)
    try history.validateNewCommand(retainedBytes: command.retainedBytes)
    _ = history.appendSuccessful(command)

    let undo = try #require(history.beginUndo())
    #expect(history.canUndo)
    try history.finishNavigation(token: undo.token, succeeded: false)
    #expect(history.canUndo)

    let retry = try #require(history.beginUndo())
    try history.finishNavigation(token: retry.token, succeeded: true)
    #expect(!history.canUndo)
    #expect(history.canRedo)
}

@Test
func appendClearsRedoAndPrunesBothBounds() throws {
    var history = DocumentHistory(maximumCommands: 3, maximumBytes: 100)
    for index in 0..<4 {
        let command = makeRasterCommand(seed: UInt64(index), bytes: 40)
        try history.validateNewCommand(retainedBytes: command.retainedBytes)
        _ = history.appendSuccessful(
            command
        )
    }
    #expect(history.commandCount == 2)
    #expect(history.retainedRasterBytes == 80)
}

private func makeRasterCommand(
    seed: UInt64 = 1,
    bytes: Int
) -> DocumentHistoryCommand {
    precondition(bytes.isMultiple(of: 2))
    let size = PixelSize(width: 64, height: 64)
    let regions = PixelRegionSet(
        [PixelRect(minX: 0, minY: 0, maxX: 1, maxY: 1)!],
        clippedTo: size
    )
    let before = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: seed * 2),
        pixelSize: size,
        regions: regions,
        retainedBytes: bytes / 2
    )
    let after = RasterRevisionReference(
        id: StoredRasterRevisionID(rawValue: seed * 2 + 1),
        pixelSize: size,
        regions: regions,
        retainedBytes: bytes / 2
    )
    return .raster(
        RasterHistoryCommand(kind: .draw, before: before, after: after)
    )
}
```

Also test metadata costs zero, stale navigation tokens fail, and returned
released revision IDs include redo plus pruned commands without duplicates.

- [ ] **Step 2: Run and confirm missing-type failure**

```bash
swift test --filter DocumentHistoryTests
```

- [ ] **Step 3: Implement typed commands**

```swift
public enum RasterEditKind: UInt8, Equatable, Sendable {
    case draw
    case erase
    case clear
}

public struct RasterHistoryCommand: Equatable, Sendable {
    public let kind: RasterEditKind
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        kind: RasterEditKind,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        precondition(before.pixelSize == after.pixelSize)
        precondition(before.regions == after.regions)
        self.kind = kind
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        before.retainedBytes + after.retainedBytes
    }
}

public struct MetadataChange<Value: Equatable & Sendable>:
    Equatable, Sendable
{
    public let before: Value
    public let after: Value

    public init(before: Value, after: Value) {
        self.before = before
        self.after = after
    }
}

public struct TileResizeHistoryCommand: Equatable, Sendable {
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        self.before = before
        self.after = after
    }

    public var retainedBytes: Int {
        before.retainedBytes + after.retainedBytes
    }
}

public enum DocumentHistoryCommand: Equatable, Sendable {
    case raster(RasterHistoryCommand)
    case tiling(MetadataChange<TilingKind>)
    case tileResize(TileResizeHistoryCommand)

    public var retainedBytes: Int {
        switch self {
        case let .raster(command):
            command.retainedBytes
        case .tiling:
            0
        case let .tileResize(command):
            command.retainedBytes
        }
    }

    public var revisionIDs: Set<StoredRasterRevisionID> {
        switch self {
        case let .raster(command):
            [command.before.id, command.after.id]
        case .tiling:
            []
        case let .tileResize(command):
            [command.before.id, command.after.id]
        }
    }
}
```

- [ ] **Step 4: Implement two-phase cursor navigation**

`beginUndo` selects `commands[cursor - 1]`; `beginRedo` selects
`commands[cursor]`. Neither moves `cursor`. Only a matching successful finish
moves it by one. While navigation is pending, begin/append operations throw
`DocumentHistoryError.navigationPending`.

```swift
public struct HistoryNavigation: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case undo, redo }
    public let token: UInt64
    public let direction: Direction
    public let command: DocumentHistoryCommand
}
```

- [ ] **Step 5: Implement append, redo removal, pruning, and releases**

`validateNewCommand(retainedBytes:)` rejects negative values and a single
command above `maximumBytes` before renderer allocation/submission.

After that preflight, `appendSuccessful` is nonthrowing and:

1. preconditions no navigation is pending and command cost is within the cap;
2. snapshots the old referenced-ID set;
3. removes `commands[cursor...]`;
4. appends the new command and sets cursor to end;
5. removes index zero until both limits hold, decrementing cursor;
6. returns `oldIDs - newIDs` for renderer release.

Use defaults:

```swift
maximumCommands: Int = 100
maximumBytes: Int = 200 * 1_024 * 1_024
```

- [ ] **Step 6: Run focused/full tests**

```bash
swift test --filter DocumentHistoryTests
swift test
```

- [ ] **Step 7: Commit**

```bash
git add Sources/EditorCore/History Tests/EditorCoreTests/DocumentHistoryTests.swift
git commit -m "feat(editor): add bounded document history"
```

---

### Task 3: Total Transaction Reducer, Configuration, And Key Map

**Files:**
- Create: `Sources/EditorCore/Configuration/EditorConfiguration.swift`
- Create: `Sources/EditorCore/Commands/EditorCommand.swift`
- Create: `Sources/EditorCore/Commands/EditorKeymap.swift`
- Create: `Sources/EditorCore/Transactions/EditorTransaction.swift`
- Modify: `Sources/EditorCore/Model/EditorModel.swift`
- Create: `Tests/EditorCoreTests/EditorConfigurationTests.swift`
- Create: `Tests/EditorCoreTests/EditorKeymapTests.swift`
- Create: `Tests/EditorCoreTests/EditorTransactionTests.swift`
- Modify: `Tests/EditorCoreTests/EditorModelTests.swift`

**Interfaces:**
- Produces:
  - `EditorTool`, `StrokeTool`, `EditorShortcut`
  - `EditorKey`, `EditorKeyModifiers`, `EditorKeyPhase`
  - `EditorConfiguration`
  - `EditorTransactionState/Event/Effect`
  - `EditorTransaction.apply(_:)`
  - expanded `EditorModel`
- Consumes: PatternEngine values and `DocumentHistory` availability.

- [ ] **Step 1: Write failing configuration and key-map tests**

Assert:

- diameter default `20`;
- geometric steps round and clamp to tile-dependent max;
- tile steps change width and height by 32 independently;
- `B/E/0/+/=/-/</>/G/1...7/Escape/Space` map exactly;
- `Command-Z` and `Command-Shift-Z` map exactly;
- `S/T/Return` return nil in Slice 3;
- alphabetic matching is case-insensitive.

- [ ] **Step 2: Write failing reducer tests**

Required exact sequences:

```swift
@Test
func undoDuringCollectingCancelsBeforeCommand() {
    var transaction = collectingDrawTransaction()
    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected collecting drawing transaction")
        return
    }

    let effects = transaction.apply(.command(.undo))

    #expect(effects.count == 2)
    guard
        case let .cancelStroke(cancelledToken) = effects[0],
        case let .performCommand(_, command) = effects[1]
    else {
        Issue.record("Expected cancelStroke then performCommand")
        return
    }
    #expect(cancelledToken == drawing.token)
    #expect(command == .undo)
    #expect(transaction.pendingOperation != nil)
}

@Test
func pointerEndStaysDrawingUntilMatchingCompletion() {
    var transaction = collectingDrawTransaction()
    _ = transaction.apply(.pointerEnded(sample(.ended)))
    guard case let .drawing(drawing) = transaction.state else {
        Issue.record("Expected drawing state")
        return
    }
    #expect(drawing.phase == .commitPending)
    #expect(transaction.isBusy)
}
```

Enumerate representative values for every state and every event case. Applying
each pair must return without trapping. Add explicit assertions for the
recovered transform interruption order:

```text
cancelTransform, clearSelectionOverlay, performCommand
```

- [ ] **Step 3: Implement configuration**

```swift
public enum EditorConfiguration {
    public static let defaultBrushDiameter: Float = 20
    public static let minimumBrushDiameter: Float = 2
    public static let maximumBrushDiameter: Float = 2_000

    public static func brushMaximum(for size: PixelSize) -> Float {
        min(maximumBrushDiameter, 8 * Float(min(size.width, size.height)))
    }

    public static func stepBrush(
        _ value: Float,
        larger: Bool,
        pixelSize: PixelSize
    ) -> Float {
        let proposed = (larger ? value * 1.25 : value / 1.25).rounded()
        return min(
            brushMaximum(for: pixelSize),
            max(minimumBrushDiameter, proposed)
        )
    }

    public static func stepTile(
        _ size: PixelSize,
        larger: Bool
    ) -> PixelSize {
        let delta = larger ? 32 : -32
        return PixelSize(
            width: min(4_096, max(64, size.width + delta)),
            height: min(4_096, max(64, size.height + delta))
        )
    }
}
```

- [ ] **Step 4: Implement platform-free key resolution**

Normalize alphabetic characters to lowercase. Modifier routing runs before
plain routing. Space down/up produces `.spaceChanged(Bool)`; repeat produces
no second transition.

```swift
public enum EditorShortcut: Equatable, Sendable {
    case selectTool(EditorTool)
    case clear
    case undo
    case redo
    case stepBrush(larger: Bool)
    case stepTile(larger: Bool)
    case toggleGrid
    case selectTiling(index1: Int)
    case cancel
    case spaceChanged(Bool)
}
```

- [ ] **Step 5: Implement total reducer values**

Use the approved top-level state:

```swift
public enum EditorTool: UInt8, Equatable, Sendable {
    case draw
    case erase
    case select
    case transform
}

public enum StrokeTool: UInt8, Equatable, Sendable {
    case draw
    case erase
}

public enum EditorCommand: UInt8, Equatable, Sendable {
    case undo
    case redo
    case clear
}

public struct EditorTransactionToken:
    RawRepresentable, Hashable, Sendable
{
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct SelectionRegion: Equatable, Sendable {
    public let rawOrigin: CanonicalPoint
    public let folded: PixelRect

    public init(rawOrigin: CanonicalPoint, folded: PixelRect) {
        self.rawOrigin = rawOrigin
        self.folded = folded
    }
}

public enum EditorTransactionState: Equatable, Sendable {
    case idle
    case drawing(DrawingTransaction)
    case selectingDraft(SelectionRegion?)
    case selectionReady(SelectionRegion)
    case transforming(SelectionRegion)
}

public enum EditorTransactionEvent: Equatable, Sendable {
    case pointerBegan(
        StrokeSample,
        tool: StrokeTool,
        style: StrokeRenderStyle
    )
    case pointerMoved(StrokeSample)
    case pointerEnded(StrokeSample)
    case pointerCancelled
    case toolIntent(EditorTool)
    case colorIntent(InkColor)
    case brushDiameterIntent(Float)
    case gridVisibilityIntent(Bool)
    case command(EditorCommand)
    case tilingIntent(TilingKind)
    case tileSizeIntent(PixelSize)
    case selectionChanged(SelectionRegion?)
    case selectionEnded
    case operationCompleted(EditorTransactionToken, succeeded: Bool)
}

public enum EditorTransactionEffect: Equatable, Sendable {
    case beginStroke(
        EditorTransactionToken,
        StrokeSample,
        StrokeTool,
        StrokeRenderStyle
    )
    case appendStroke(EditorTransactionToken, StrokeSample)
    case requestStrokeCommit(EditorTransactionToken, StrokeSample)
    case cancelStroke(EditorTransactionToken)
    case updateTool(EditorTool)
    case updateColor(InkColor)
    case updateBrushDiameter(Float)
    case updateGridVisibility(Bool)
    case performCommand(EditorTransactionToken, EditorCommand)
    case applyTiling(EditorTransactionToken, TilingKind)
    case applyTileSize(EditorTransactionToken, PixelSize)
    case clearSelectionOverlay
    case beginTransform(SelectionRegion)
    case cancelTransform
    case busy
    case reportOperationFailure
}
```

Use this exact mutation interface:

```swift
public mutating func apply(
    _ event: EditorTransactionEvent
) -> [EditorTransactionEffect]
```

Reducer test helpers use only public values:

```swift
private func sample(_ phase: StrokePhase) -> StrokeSample {
    .mouse(
        position: ScreenPoint(x: 32, y: 48),
        timestamp: 1,
        phase: phase
    )
}

private func collectingDrawTransaction() -> EditorTransaction {
    var transaction = EditorTransaction()
    let style = StrokeRenderStyle(
        color: .black,
        diameter: 20,
        compositeMode: .draw,
        eraserStrength: 1
    )
    _ = transaction.apply(
        .pointerBegan(sample(.began), tool: .draw, style: style)
    )
    return transaction
}
```

`EditorTransaction` stores `nextToken`, `state`, and optional
`pendingOperation`. `apply` must:

- route pointer samples only to matching drawing tokens;
- retain `drawing` state whose phase is `commitPending` until matching
  completion;
- cancel collecting strokes before tool/color/diameter/command/config intent;
- allow grid visibility to update only when not busy;
- reject stale completion tokens without changing state;
- define selection transitions exactly as approved;
- return `.busy` for conflicting submitted work;
- never call renderer or mutate history directly.

- [ ] **Step 6: Expand observable model**

Model committed read state:

```swift
public private(set) var tool: EditorTool = .draw
public private(set) var inkColor: InkColor = .black
public private(set) var brushDiameter: Float = 20
public private(set) var eraserStrength: Float = 1
public private(set) var showGrid = false
public private(set) var tiling: TilingKind = .grid
public private(set) var pixelSize = PixelSize(width: 256, height: 256)
public private(set) var canUndo = false
public private(set) var canRedo = false
public private(set) var isBusy = false
```

Expose these methods for the app controller:

```swift
confirmTool(_:)
confirmInkColor(_:)
confirmBrushDiameter(_:)
confirmGridVisibility(_:)
confirmTiling(_:)
confirmPixelSize(_:)
confirmHistoryAvailability(canUndo:canRedo:)
confirmBusy(_:)
```

Every view calls controller intent methods, never these confirmation methods.

- [ ] **Step 7: Run tests and builds**

```bash
swift test --filter 'EditorConfigurationTests|EditorKeymapTests|EditorTransactionTests|EditorModelTests'
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

- [ ] **Step 8: Commit**

```bash
git add Sources/EditorCore Tests/EditorCoreTests
git commit -m "feat(editor): add transaction reducer"
```

---

### Task 4: Color ABI And Shared Composite Math

**Files:**
- Modify: `Sources/CShaderTypes/include/ShaderTypes.h`
- Modify: `Sources/MetalRenderer/ShaderABI.swift`
- Modify: `Sources/MetalRenderer/ProjectedStampInstance.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Tests/MetalRendererTests/ShaderABILayoutTests.swift`
- Modify: `Tests/MetalRendererTests/ProjectedStampInstanceTests.swift`
- Modify: `Tests/MetalRendererTests/TranslationTilingShaderTests.swift`
- Modify: `Tests/MetalRendererTests/ReflectedRotationalShaderTests.swift`

**Interfaces:**
- Consumes: `InkColor`, `StrokeCompositeMode`.
- Produces:
  - 112-byte `PatternProjectedStampInstance`
  - 56-byte `PatternGridFrameUniforms`
  - shared `patternCompositeLive` MSL function.

- [ ] **Step 1: Change ABI tests first**

Assert exact layouts:

```text
PatternGridFrameUniforms:
  size/stride/alignment = 56/56/8
  compositeMode@48, padding@52

PatternProjectedStampInstance:
  size/stride/alignment = 112/112/16
  color@32
  clip0@48, clip1@64, clip2@80, clip3@96
```

Projected instance tests must verify the supplied RGBA survives exactly.

- [ ] **Step 2: Run and observe failures**

```bash
swift test --filter 'ShaderABILayoutTests|ProjectedStampInstanceTests'
```

- [ ] **Step 3: Append shared C/MSL fields**

Add `PatternFloat4` beside `PatternFloat2` in both compilation branches:

```c
#ifdef __METAL_VERSION__
typedef float4 PatternFloat4;
#else
typedef vector_float4 PatternFloat4;
#endif

typedef struct PatternGridFrameUniforms {
    PatternFloat2 drawableSize;
    PatternFloat2 worldCenter;
    PatternFloat2 tileSize;
    float zoom;
    float gridLineWidth;
    PatternUInt32 showGridLines;
    PatternUInt32 liveVisible;
    PatternUInt32 tilingKind;
    PatternUInt32 diagnosticMode;
    PatternUInt32 compositeMode;
    PatternUInt32 padding;
} PatternGridFrameUniforms;

typedef struct PatternProjectedStampInstance {
    PatternFloat2 canonicalXAxis;
    PatternFloat2 canonicalYAxis;
    PatternFloat2 canonicalTranslation;
    float radius;
    PatternUInt32 clipCount;
    PatternFloat4 color;
    PatternClipHalfPlane clip0;
    PatternClipHalfPlane clip1;
    PatternClipHalfPlane clip2;
    PatternClipHalfPlane clip3;
} PatternProjectedStampInstance;

PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireDraw = 0;
PATTERN_WIRE_CONSTANT PatternUInt32 PatternCompositeWireErase = 1;
```

- [ ] **Step 4: Update Swift packing and ABI preconditions**

`PatternProjectedStampInstance.init` gains:

```swift
color: InkColor = .black
```

and initializes `color: color.simd`. Update every ABI check to the exact
offsets above.

- [ ] **Step 5: Update MSL once for both display and commit**

Projected vertex output gains `float4 color [[flat]]`.

```metal
fragment float4 patternHardRoundStampFragment(
    PatternProjectedStampOut input [[stage_in]]
) {
    if (!patternProjectedStampInsideClip(input)) {
        discard_fragment();
    }
    const float2 offsetPixels = input.brushLocal * input.radius;
    const float coverage = clamp(
        input.radius + 0.5 - length(offsetPixels), 0.0, 1.0
    );
    return float4(input.color.rgb, input.color.a * coverage);
}

static float4 patternCompositeLive(
    float4 live,
    float4 canonical,
    uint compositeMode
) {
    if (compositeMode == PatternCompositeWireErase) {
        return canonical * (1.0 - live.a);
    }
    return patternSourceOver(live, canonical);
}
```

Call `patternCompositeLive` from both `patternGridFragment` and
`patternCommitFragment`. No duplicated erase equation is allowed.

- [ ] **Step 6: Keep existing renderer behavior black/draw by default**

Until Task 6 supplies a captured style, pass `.black` into projected
instances and `PatternCompositeWireDraw` into frame uniforms. Existing Slice
0–2 pixels must remain unchanged.

- [ ] **Step 7: Run ABI, shader-source, full tests, and both builds**

```bash
swift test --filter 'ShaderABILayoutTests|ProjectedStampInstanceTests|TranslationTilingShaderTests|ReflectedRotationalShaderTests'
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

- [ ] **Step 8: Commit**

```bash
git add Sources/CShaderTypes Sources/MetalRenderer Tests/MetalRendererTests
git commit -m "feat(renderer): add color composite ABI"
```

---

### Task 5: GPU Raster Revision Store

**Files:**
- Create: `Sources/MetalRenderer/Raster/RasterRevisionStore.swift`
- Create: `Tests/MetalRendererTests/RasterRevisionStoreTests.swift`
- Modify: `Sources/MetalRenderer/MetalRendererError.swift`

**Interfaces:**
- Produces:
  - `PendingRasterRevisionPair`
  - `RasterRevisionStore.allocatePair(
      beforePixelSize:beforeRegions:afterPixelSize:afterRegions:)`
  - `encodeCapture(_:from:on:)`
  - `encodeRestore(_:into:on:)`
  - `publish(_:)`, `discard(_:)`, `release(_:)`
- Consumes: `RasterRevisionReference`, `PixelRegionSet`, Metal blits.

- [ ] **Step 1: Write failing real-Metal store tests**

Create a 64×64 shared BGRA texture with deterministic bytes. Capture two
separated rectangles, overwrite the whole texture, restore, and assert:

- bytes inside both regions equal original;
- bytes between regions remain overwritten;
- retained byte count equals aligned storage;
- discard removes provisional IDs;
- release removes published IDs;
- wrong texture dimensions throw before encoding.

Skip only when `MTLCreateSystemDefaultDevice()` returns nil; do not skip for
timing or assertion failures.

- [ ] **Step 2: Run and confirm missing store**

```bash
swift test --filter RasterRevisionStoreTests
```

- [ ] **Step 3: Implement aligned packed payloads**

Use:

```swift
let alignment = device.minimumTextureBufferAlignment(for: .bgra8Unorm)
let bytesPerRow = align(rect.width * 4, to: alignment)
```

Pack every region into one `.storageModePrivate` buffer per revision. Each
slice records region, buffer offset, bytes-per-row, and bytes-per-image.
Allocate before inserting into the store. IDs increase monotonically and never
reuse after discard.

- [ ] **Step 4: Implement capture and restore encoders**

Capture uses texture-to-buffer `MTLBlitCommandEncoder.copy`. Restore uses the
symmetric buffer-to-texture copy. Validate:

- reference exists;
- texture pixel format is `.bgra8Unorm`;
- texture dimensions equal reference dimensions;
- every region lies inside the texture.

One blit encoder handles all regions, then ends exactly once.

- [ ] **Step 5: Implement provisional/published lifetime**

Allocated references begin provisional. `publish(pair)` marks both published.
`discard(pair)` may remove only provisional IDs. `release(ids)` removes
published IDs not held by an in-flight operation. Programmer misuse
preconditions; missing external history payload restore throws
`.missingRasterRevision`.

- [ ] **Step 6: Run focused/full tests**

```bash
swift test --filter RasterRevisionStoreTests
swift test
```

- [ ] **Step 7: Commit**

```bash
git add Sources/MetalRenderer/Raster Tests/MetalRendererTests/RasterRevisionStoreTests.swift Sources/MetalRenderer/MetalRendererError.swift
git commit -m "feat(renderer): add raster revision store"
```

---

### Task 6: Transaction-Controlled Colored Draw And Region History

**Files:**
- Create: `Sources/MetalRenderer/Raster/RendererRasterOperation.swift`
- Modify: `Sources/MetalRenderer/LiveStroke.swift`
- Modify: `Sources/MetalRenderer/GridRenderCompletionMailbox.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/CanonicalRaster.swift`
- Delete: `Sources/MetalRenderer/GridStrokeLifecycle.swift`
- Delete: `Tests/MetalRendererTests/GridStrokeLifecycleTests.swift`
- Create: `App/PatternSpike/EditorSessionController.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `Tests/MetalRendererTests/LiveStrokeTests.swift`
- Create: `Tests/MetalRendererTests/RendererTransactionTests.swift`

**Interfaces:**
- Renderer:
  - `beginStroke(token:sample:style:)`
  - `appendStroke(token:sample:)`
  - `requestStrokeCommit(
      token:sample:maximumRetainedBytes:)`
  - `cancelStroke(token:)`
  - `releaseRasterRevisions(_:)`
  - `onOperationCompleted`
- App:
  - `EditorSessionController.handleStrokeSample(_:)`
  - ordered reducer effect execution.

- [ ] **Step 1: Add failing live-stroke dirty-region tests**

Append projected instances whose rectangles touch, then release every encoded
instance. Assert the dirty region accumulator remains and normalizes to the
expected set until `reset()`.

Add renderer token tests proving mismatched append/end/cancel tokens fail,
submitted commit stays pending until completion drain, success returns one
receipt, and failure returns no receipt or canonical swap.

- [ ] **Step 2: Define renderer operation receipts**

```swift
public struct RendererOperationToken:
    RawRepresentable, Hashable, Sendable
{
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct RasterMutationReceipt: Equatable, Sendable {
    public let token: RendererOperationToken
    public let before: RasterRevisionReference
    public let after: RasterRevisionReference

    public init(
        token: RendererOperationToken,
        before: RasterRevisionReference,
        after: RasterRevisionReference
    ) {
        self.token = token
        self.before = before
        self.after = after
    }
}

public enum RendererOperationCompletion: Sendable {
    case rasterSuccess(RasterMutationReceipt)
    case operationSuccess(RendererOperationToken)
    case failure(RendererOperationToken, MetalRendererError)
}
```

Make `MetalRendererError` `Sendable`.

- [ ] **Step 3: Replace policy lifecycle with token validation**

`GridRenderer` stores an internal execution record:

```swift
private struct ActiveStrokeExecution {
    let token: RendererOperationToken
    let style: StrokeRenderStyle
    var commitRequested: Bool
    var pendingRevisions: PendingRasterRevisionPair?
}
```

Public methods validate token and execution shape but never infer tool intent,
cancel policy, command ordering, or history cursor behavior. Remove
`GridStrokeLifecycle` after all call sites migrate.

- [ ] **Step 4: Accumulate style and dirty regions**

At begin:

- create interpolator radius from `style.diameter / 2`;
- reset counters/live stroke;
- capture style.

At every projected fragment:

- pack `style.color` for draw;
- pack `(0,0,0,style.eraserStrength)` for erase;
- call
  `LiveStroke.append(_:dirtyRect:)` with
  `TilingProjection.dirtyPixelRect(for:radius:)`.

Frame uniforms use the captured `style.compositeMode`.

- [ ] **Step 5: Capture before/after around the existing scratch commit**

When all emitted instances are baked and commit is requested:

1. normalize live dirty rectangles;
2. estimate aligned before/after storage and reject above
   `maximumRetainedBytes`;
3. allocate a before/after pair;
4. encode before capture from `canonical.front`;
5. encode existing fullscreen commit into `canonical.scratch`;
6. encode after capture from `canonical.scratch`;
7. include token and provisional pair in completion mailbox.

On successful drain:

- accept scratch;
- publish pair;
- reset live execution;
- invoke `onOperationCompleted(.rasterSuccess(receipt))`.

On failure:

- discard pair;
- retain front;
- reset live execution;
- invoke failure.

- [ ] **Step 6: Add basic app controller**

Controller owns:

```swift
let model: EditorModel
let renderer: GridRenderer
private var transaction = EditorTransaction()
private var history = DocumentHistory()
```

Pointer input builds `StrokeRenderStyle` from committed model values. Reducer
effects call renderer methods in array order. Successful draw/erase receipt is
converted to `RasterHistoryCommand` and appended; released IDs go to
`RasterRevisionStore` through a renderer release API.

Controller converts tokens only by identical raw value:

```swift
RendererOperationToken(rawValue: editorToken.rawValue)
EditorTransactionToken(rawValue: rendererToken.rawValue)
```

Before every new raster mutation, controller passes
`history.maximumBytes` to renderer preflight. History finalization after GPU
success is nonthrowing.

The controller updates model `isBusy/canUndo/canRedo` after every event and
completion.

- [ ] **Step 7: Route native pointer input through controller**

`InteractiveMetalView` receives controller plus renderer. It:

- translates mouse positions to normalized `StrokeSample`;
- calls controller for begin/move/end/cancel;
- calls controller-gated pan/zoom;
- contains no tool/history policy.

`MetalCanvas` passes controller and keeps `renderer` as MTKView delegate.
`ContentView` constructs one controller and retains the existing tiling picker
temporarily.

- [ ] **Step 8: Run tests, Slice 1 functional regression, and builds**

```bash
swift test
PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Expected: existing black/default behavior and all prior functional scenes pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/MetalRenderer App/PatternSpike Tests/MetalRendererTests
git commit -m "feat: route draw through transactions"
```

---

### Task 7: Eraser, Clear, Undo, And Redo

**Files:**
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Raster/RendererRasterOperation.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Create: `App/PatternSpike/Panels/ToolRail.swift`
- Create: `App/PatternSpike/Panels/EditorTopBar.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `Tests/EditorCoreTests/DocumentHistoryTests.swift`
- Modify: `Tests/EditorCoreTests/EditorTransactionTests.swift`
- Create: `Tests/MetalRendererTests/RendererRasterOperationTests.swift`

**Interfaces:**
- Produces:
  - `GridRenderer.requestClear(token:maximumRetainedBytes:)`
  - `GridRenderer.requestRasterRestore(token:revision:)`
  - controller draw/erase/clear/undo/redo intents.

- [ ] **Step 1: Add failing command-order and history tests**

Assert:

- erase receipt is wrapped in `DocumentHistoryCommand.raster`, and its
  `RasterHistoryCommand.kind` equals `.erase`;
- clear during collecting cancels then clears;
- undo selection does not move cursor before renderer success;
- failed restore keeps cursor and availability unchanged;
- new draw after undo clears redo and returns released revision IDs.

- [ ] **Step 2: Implement atomic clear**

Use a full-tile `PixelRegionSet`. Estimate and validate the pair against the
passed history maximum, allocate before/after, capture front, render transparent
scratch, capture scratch, and submit. Success publishes one receipt; failure
preserves front/history.

- [ ] **Step 3: Implement atomic raster restore**

For undo/redo:

1. validate target reference size equals current canonical size;
2. encode full front-to-scratch blit;
3. encode revision regions into scratch;
4. submit;
5. swap on success only.

Restore emits a tokenized success without creating new revision payload.
Use `.operationSuccess(token)`, never `.rasterSuccess`, for restore.

- [ ] **Step 4: Wire two-phase history navigation**

Controller flow:

```text
beginUndo/beginRedo
  raster command -> request before/after restore
  renderer success -> finish navigation(success: true)
  renderer failure -> finish navigation(success: false)
```

Clear success appends `.raster(.clear)`. Draw and erase use the stroke tool
captured in the pending controller operation.

- [ ] **Step 5: Add minimal tool rail/top bar**

Tool rail:

- Draw button, `pencil.tip`;
- Erase button, `eraser`;
- stable ordering and selected state.

Top bar:

- brush diameter display/step controls;
- native `ColorPicker` with opacity;
- undo/redo buttons with derived disabled state;
- clear button.

Color conversion must use sRGB components and reject conversion failure without
changing model color.

- [ ] **Step 6: Verify live/commit eraser manually and with a focused harness probe**

In `RendererRasterOperationTests.swift`, add an internal synchronous renderer
test helper:

1. draw and commit black;
2. begin erase over center;
3. capture live display;
4. commit erase;
5. compare live/committed maximum channel delta `<= 1`;
6. assert canonical center BGRA is transparent.

- [ ] **Step 7: Run tests and both builds**

```bash
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer App/PatternSpike Tests
git commit -m "feat: add eraser and raster undo"
```

---

### Task 8: Undoable Tiling And Top-Left Crop/Fill Resize

**Files:**
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/CanonicalRaster.swift`
- Modify: `Sources/MetalRenderer/PersistentLiveTile.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Create: `App/PatternSpike/Panels/TilingInspector.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Create: `Tests/MetalRendererTests/RendererResizeTests.swift`
- Modify: `Tests/EditorCoreTests/DocumentHistoryTests.swift`

**Interfaces:**
- Produces:
  - `GridRenderer.applyTiling(_:)`
  - `GridRenderer.requestResize(
      token:to:maximumRetainedBytes:)`
  - `GridRenderer.requestResizeRestore(token:revision:)`
  - controller tiling/resize intent and history paths.

- [ ] **Step 1: Add failing resize tests**

Using deterministic canonical pixels:

- 96×80 to 64×72 preserves exact top-left 64×72 and drops right/bottom;
- 64×72 to 96×80 preserves exact top-left and makes new pixels transparent;
- undo/redo restores exact dimensions and bytes;
- allocation-failure injection retains old object identities, size, pixels,
  tiling, viewport center, and history.

- [ ] **Step 2: Make renderer resources replaceable**

Change `pixelSize`, `tileSize`, `canonical`, and `liveTile` from immutable
stored initialization values to state derived from replaceable resource
objects. Keep pipeline/library/queue/pool stable.

Add a focused resource factory so allocation of canonical front/scratch/live
either returns a complete set or throws without changing renderer state.

`CanonicalRaster` gains:

```swift
public init(
    device: any MTLDevice,
    pixelSize: PixelSize,
    initialRevision: RasterRevision = RasterRevision(rawValue: 0)
) throws
```

Replacement resources receive the current public revision; accepting their
scratch advances it once. Resize, resize undo, and resize redo therefore keep
surface generation monotonic across object replacement.

- [ ] **Step 3: Implement new resize commit**

Before submission:

- validate `64...4096`;
- validate aligned old/new full-raster payload cost against history maximum;
- allocate new resource set;
- allocate full-raster old before and new after revisions.

Encode:

1. capture old front;
2. clear new front/scratch/live transparent;
3. blit exact `min(old,new)` top-left rectangle old front to new scratch;
4. capture new scratch;
5. submit.

On success:

- accept new scratch;
- atomically install resource set;
- rebuild tiling strategy with unchanged tiling;
- keep viewport world center and zoom;
- clamp model diameter through controller;
- append tile-resize history.

- [ ] **Step 4: Implement resize undo/redo**

Allocate target-size resources before submission. Restore the full target
revision into target scratch. Install only on success. Move history cursor only
after installation.

- [ ] **Step 5: Implement metadata-only tiling history**

Controller captures before/after `TilingKind`, calls renderer synchronously,
then appends `.tiling` only after acceptance. Undo/redo calls the same renderer
method and moves history cursor only after success. No revision is allocated or
released.

- [ ] **Step 6: Add right inspector**

Inspector contains:

- tiling menu;
- grid toggle;
- independent width and height draft fields;
- Apply button.

Draft values do not mutate model. Apply validates both and sends one resize
intent. On failure, committed values remain; draft resets to committed values
after presenting the typed error.

- [ ] **Step 7: Run focused/full tests and builds**

```bash
swift test --filter 'RendererResizeTests|DocumentHistoryTests'
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

- [ ] **Step 8: Commit**

```bash
git add Sources/MetalRenderer App/PatternSpike Tests
git commit -m "feat: add undoable canvas metadata"
```

---

### Task 9: Unified Keyboard, Menu, Grid, And Final Shell

**Files:**
- Create: `App/PatternSpike/Commands/EditorFocusedCommands.swift`
- Modify: `App/PatternSpike/PatternSpikeApp.swift`
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `App/PatternSpike/Canvas/InteractiveMetalView.swift`
- Modify: `App/PatternSpike/Canvas/MetalCanvas.swift`
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Modify: `Sources/MetalRenderer/GridRenderer.swift`
- Modify: `Sources/MetalRenderer/Shaders.metal`

**Interfaces:**
- Consumes: `EditorKeymap`.
- Produces one keyboard owner and identical toolbar/menu semantic routes.

- [ ] **Step 1: Remove native key ownership**

`InteractiveMetalView`:

- `acceptsFirstResponder == false`;
- no `keyDown`, `keyUp`, or `cancelOperation` override;
- pointer and gesture methods only;
- queries controller `isSpaceDown` on mouse-down to select pan or draw.

- [ ] **Step 2: Add SwiftUI key phases**

Focusable canvas shell handles down/repeat/up. Convert SwiftUI `KeyPress` into
platform-free `EditorKey`, modifiers, and phase, then call `EditorKeymap`.
Controller applies returned shortcut.

Space down/up updates controller transient state. Window/key-focus loss clears
Space and sends pointer cancellation.

- [ ] **Step 3: Wire every documented shortcut**

- `B/E`: tool;
- `0`: clear;
- `+/=/-`: diameter;
- `</>`: both tile dimensions ±32, one resize command;
- `G`: grid;
- `1...7`: tiling;
- `Command-Z/Command-Shift-Z`: history;
- Escape: cancel;
- `S/T/Return`: unconsumed.

While busy, model-derived control state and shortcut handling both reject the
same conflicting intents.

- [ ] **Step 4: Make grid visibility a real display setting**

Store grid visibility in model/controller. Pass it to every interactive
display frame. It changes no canonical pixels and creates no history command.
Harness callers continue supplying their explicit grid flag.

- [ ] **Step 5: Add focused macOS menu commands**

Define `FocusedValueKey` carrying closures for undo, redo, clear, Draw, and
Erase. `PatternSpikeApp.commands` uses those closures and standard shortcuts.
The menu never calls renderer directly.

- [ ] **Step 6: Finalize shell layout**

- left stable tool rail;
- compact top bar;
- right inspector;
- canvas consumes remaining space;
- typed error banner;
- Mac icon controls 30–32 points;
- iPad controls at least 44 points;
- no decorative cards or text-wrapped tool labels.

- [ ] **Step 7: Run logic tests, builds, and manual focus sweep**

```bash
swift test --filter 'EditorKeymapTests|EditorModelTests|EditorTransactionTests'
swift test
(cd App && xcodegen generate)
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac -configuration Debug build
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Manual:

- click every control, then use every shortcut;
- draw after keyboard and toolbar focus changes;
- hold/release Space then pan;
- verify no double command from menu plus `.onKeyPress`.

- [ ] **Step 8: Commit**

```bash
git add App/PatternSpike Sources/MetalRenderer
git commit -m "feat(app): add Slice 3 editor controls"
```

---

### Task 10: Schema-4 Negative-First Harness, Gate, And Milestone

**Files:**
- Modify: `Sources/MetalRenderer/Capture/HarnessScene.swift`
- Create: `Sources/MetalRenderer/Capture/SliceThreeHarnessRunner.swift`
- Modify: `Sources/MetalRenderer/Capture/HarnessRunner.swift`
- Modify: `Sources/MetalRenderer/BenchmarkRecord.swift`
- Modify: `Tests/MetalRendererTests/HarnessSceneTests.swift`
- Modify: `Tests/MetalRendererTests/BenchmarkRecordTests.swift`
- Add:
  - `App/PatternSpike/Harness/Scenes/colored-draw.json`
  - `App/PatternSpike/Harness/Scenes/colored-draw-negative-control.json`
  - `App/PatternSpike/Harness/Scenes/eraser-live-commit.json`
  - `App/PatternSpike/Harness/Scenes/eraser-live-commit-negative-control.json`
  - `App/PatternSpike/Harness/Scenes/region-undo-seam.json`
  - `App/PatternSpike/Harness/Scenes/region-undo-seam-negative-control.json`
  - `App/PatternSpike/Harness/Scenes/clear-undo.json`
  - `App/PatternSpike/Harness/Scenes/clear-undo-negative-control.json`
  - `App/PatternSpike/Harness/Scenes/tiling-undo.json`
  - `App/PatternSpike/Harness/Scenes/tiling-undo-negative-control.json`
  - `App/PatternSpike/Harness/Scenes/resize-crop-fill.json`
  - `App/PatternSpike/Harness/Scenes/resize-crop-fill-negative-control.json`
- Create: `scripts/verify-slice3.sh`
- Create:
  `docs/superpowers/milestones/03-transactions-region-undo-color-eraser.md`

**Interfaces:**
- Produces schema 4 programs, structural metrics, artifacts, benchmark fields,
  one-shot gate.
- Consumes all Slice 3 renderer APIs and prior harness machinery.

- [ ] **Step 1: Add failing schema and benchmark tests**

Schema 4 retains required schema-3 fields and adds program cases:

```swift
case coloredDraw
case eraserLiveCommit
case regionUndoSeam
case clearUndo
case tilingUndo
case resizeCropFill
```

Add structural metrics:

```swift
case historyCommandCount
case historyResidentBytes
case changedRegionCount
case undoCanonicalByteDelta
case redoCanonicalByteDelta
case metadataCanonicalByteDelta
case restoredWidth
case restoredHeight
case previewCommitMaximumDelta
```

Benchmark schema adds:

- `revisionCaptureMilliseconds`;
- `revisionRestoreMilliseconds`;
- `historyResidentBytes`;
- `historyCommandCount`;
- `changedRegionCount`.

All required numeric values must be finite/nonnegative.

- [ ] **Step 2: Implement schema-4 decoding without weakening old schemas**

Schema 1–3 decode and validate byte-for-byte as before. Schema 4 requires
tile width, tile height, tiling, diagnostic mode, program, and at least one
assertion. Only Slice 3 programs are legal in schema 4.

- [ ] **Step 3: Implement focused Slice 3 runner**

Keep the existing 3,460-line runner stable. Route Slice 3 programs to
`SliceThreeHarnessRunner`, which uses public renderer transaction/revision
operations and synchronous harness waits.

Program proofs:

- colored draw: center BGRA matches nonblack RGBA;
- eraser: live/commit maximum delta ≤1 and canonical center transparent;
- region undo seam: changed region count is 2, undo exact pre-edit, redo exact
  post-edit;
- clear undo: clear transparent, undo exact, redo transparent;
- tiling undo: canonical delta always 0, screen returns exactly;
- resize: shrink crop, growth transparent fill, undo/redo exact dimensions and
  intersection bytes.

- [ ] **Step 4: Prove each negative control**

Each negative scene changes only its named expected structural value from `0`
to `1`. Exact stderr form:

```text
HARNESS FAIL Slice 3 scene '<name>-negative-control' metric <metric>: expected equal 1, actual 0.
```

Run each negative before its positive. Capture exact stderr and require exit
status 1. No alternate error is accepted.

- [ ] **Step 5: Write one-shot Slice 3 gate**

`scripts/verify-slice3.sh`:

1. rejects dirty tracked source outside permitted gate/milestone files;
2. runs Slice 0 and Slice 1 functional gates;
3. runs `swift test`;
4. regenerates Xcode project;
5. builds macOS and generic iPadOS Simulator Debug;
6. replays all Slice 2 correctness scenes without changing or claiming
   `verify-slice2.sh` performance acceptance;
7. runs six negative-first Slice 3 pairs in fixed table order;
8. validates artifact families and benchmark JSON;
9. enforces absolute budgets when stable timing is available;
10. prints `SLICE3 GATE PASS` only when every required gate passes.

No retry, warmup filtering, timing skip, or threshold relaxation.

- [ ] **Step 6: Run the complete gate once**

```bash
./scripts/verify-slice3.sh
```

If paravirtual timing prevents performance acceptance, retain exact evidence,
record `Pending Performance And Manual Acceptance`, and do not print or claim
pass. Functional implementation may still be committed.

- [ ] **Step 7: Complete manual Mac checklist**

Launch:

```bash
./scripts/run-macos.sh
```

Record every manual item from the spec, including cursor alignment, tool/color
focus, live erasing, history, tiling bytes, top-left resize, grid, shortcuts,
menu commands, pan, and zoom.

- [ ] **Step 8: Write milestone from evidence**

Milestone must state:

- exact status;
- implementation evidence commit;
- environment identity;
- test/build/harness counts;
- accepted and pending gates;
- benchmark values without synthetic aggregation;
- manual results;
- retained artifact paths;
- deviations: none, or exact approved user overrides.

- [ ] **Step 9: Final review and repository hygiene**

```bash
git diff --check
git status --short
git check-ignore -v .build App/PatternSpike.xcodeproj
rg -n 'TODO|FIXME|TBD' Sources Tests App scripts docs/superpowers/milestones
```

Review against every section and exit criterion in the approved Slice 3 spec.

- [ ] **Step 10: Commit**

```bash
git add Sources/MetalRenderer/Capture Sources/MetalRenderer/BenchmarkRecord.swift Tests/MetalRendererTests App/PatternSpike/Harness/Scenes scripts/verify-slice3.sh docs/superpowers/milestones/03-transactions-region-undo-color-eraser.md
git commit -m "test: add Slice 3 acceptance gate"
```

---

## Slice 3 Exit Checklist

- [ ] One EditorCore reducer owns all edit lifecycle policy.
- [ ] Renderer validates tokens but owns no tool/command transition policy.
- [ ] Pointer-up success creates exactly one command.
- [ ] Pointer cancel and failed GPU operations create none.
- [ ] Draw, erase, and clear undo/redo exact canonical bytes.
- [ ] Region payloads keep separated seam edges separated.
- [ ] History obeys 100-command and 200 MiB bounds.
- [ ] Tiling undo never mutates canonical bytes.
- [ ] Resize is top-left crop/fill, undoable, and never scales.
- [ ] Colored hard-round output reaches real Metal.
- [ ] Eraser live and committed output match within one 8-bit value.
- [ ] Full relevant keymap, menu, and controls share semantic intents.
- [ ] Slice 0–2 functional regressions pass.
- [ ] All Swift tests pass.
- [ ] macOS and generic iPadOS Simulator Debug builds pass.
- [ ] Every Slice 3 negative control fails for its intended exact reason.
- [ ] Every Slice 3 positive scene writes required artifacts and benchmark.
- [ ] Stable real-Metal performance status is recorded honestly.
- [ ] Manual Mac checklist is recorded honestly.
- [ ] Milestone status matches evidence.
