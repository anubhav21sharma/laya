# Generalized Seam-Correct Tiling Design

**Date:** 2026-07-20
**Status:** Approved
**Slice:** 2
**Parent specification:**
`2026-07-18-pattern-product-rebuild-design.md`

## 1. Purpose

Replace Slice 1's grid-only, round-dab center-fold shortcut with a generalized
projection kernel that remains correct for rectangular tiles, large
footprints, reflections, rotations, and future textured or directional
brushes.

Production rendering uses Metal from the first vertical slice. A slow CPU
oracle exists only to provide an independent pixel-level truth source for pure
tests and the real-metallib harness. It is not a fallback renderer and does
not enter the interactive frame path.

Slice 2 supports:

- grid;
- half-drop;
- brick;
- mirror X;
- mirror Y;
- mirror XY;
- rotational `p2`;
- rectangular canonical tile sizes;
- drawing through any visible repeated cell;
- metadata-only tiling switches that preserve canonical bytes;
- full cell transforms and convex fragment clips;
- CPU-oracle and real-Metal zero-hole/zero-phantom verification.

Slice 2 does not add color, erasing, undo, brush configuration, layers,
selection, persistence, export, Pencil behavior, or production brush assets.

## 2. Governing Decisions

### 2.1 Generalized projection wins

The rebuild does not restore the lost implementation's center-only fold plus
special-case neighbor copies. That approach was exact only for radial stamps
and still required tiling-specific completion rules.

Every emitted stamp is projected as cell fragments:

1. determine conservative world-space footprint bounds;
2. enumerate every tiling cell intersecting those bounds;
3. intersect the footprint with each cell;
4. obtain that cell's complete world-to-canonical isometry;
5. preserve brush-local coordinates;
6. emit a transformed canonical placement plus a convex clip.

Grid and the hard-round Slice 1 brush use the same generalized path as every
other tiling. There is no permanent grid-only production branch.

### 2.2 Metal is present from the first vertical slice

Implementation order is not CPU-renderer-then-GPU-renderer. The first
integrated deliverable is:

```text
grid tiling math
  -> generalized cell fragment
  -> shared CPU/MSL instance
  -> Metal stamp
  -> Metal display
  -> real-metallib grid scene
```

Later tilings extend this already-running Metal path one family at a time.
No alternate CPU rendering backend may silently substitute for Metal.

### 2.3 The CPU oracle is independent

The oracle must not call the production cell enumerator, reuse its clips, or
replay its projected instances. It directly evaluates coverage:

1. sample the source footprint in world space;
2. apply the selected tiling's direct point fold;
3. accumulate expected canonical coverage;
4. derive expected screen pixels from that canonical result.

Production projection and the oracle share only primitive value types and the
`TilingKind` selector. The oracle implements its own direct point-fold switch;
it does not call `TilingStrategy.fold`, fragment enumeration, cell transforms,
or clipping code. Agreement therefore checks the algorithm instead of
repeating it.

### 2.4 Canonical pixels remain authoritative

Tiling is metadata. Switching tiling changes projection and display sampling
only. It never:

- rewrites the canonical raster;
- repairs seams;
- resamples pixels;
- clears raster history;
- retains or replays committed strokes.

Changing back to a prior tiling must reproduce the exact prior rendering from
unchanged canonical bytes.

Existing pixels are not promised seamless under a different tiling than the
one active when they were drawn. The switch is reversible reinterpretation,
not seam repair. New strokes are seam-correct for the tiling active while they
are drawn.

### 2.5 Slice 1 performance acceptance does not gate implementation

Explicit user decision on 2026-07-20 overrides the earlier delivery-sequence
gate: Slice 2 implementation may proceed while
`01-measured-grid-drawing-kernel.md` remains `Pending Performance Acceptance`.
Slice 1's functional tests, real-metallib scenes, builds, and interaction
regressions remain mandatory. Its unstable paravirtual-GPU measurements remain
diagnostic evidence and are not relabeled as accepted.

If a stable accepted Slice 1 baseline becomes available before Slice 2
performance acceptance, Slice 2 performs the planned 15-percent comparison.
Its absence does not block implementation; the Slice 2 milestone records the
missing comparison explicitly while retaining Slice 2's absolute performance
budgets.

## 3. Coordinate And Boundary Rules

- World, screen, canonical, and brush-local coordinates increase rightward and
  downward.
- Canonical storage is the half-open rectangle
  `[0, tileWidth) x [0, tileHeight)`.
- Exact right and bottom boundaries belong to the next cell.
- Positive modulo is used for negative and large world coordinates.
- Tile width and height are independent values from `64...4096`.
- Supported footprint diameter is
  `2...min(2000, 8 * min(tileWidth, tileHeight))`; radius is half the
  diameter. The interactive Slice 2 brush remains fixed at diameter `20`.
- All production geometry uses `Float`; the oracle uses deterministic sample
  coordinates and explicit tolerances.
- Cell indices use signed integers and remain stable for negative coordinates.
- An isometry contains an orthogonal 2x2 basis and a translation. Mixed-axis
  reflection cannot be reduced to one sign bit.
- Brush-local coordinates do not restart at cell boundaries.

## 4. Tiling Definitions

The engine exposes seven user-facing `TilingKind` values whose raw GPU values
are already reserved in `ShaderTypes.h`:

| Tiling | Wire value | Cell mapping |
| --- | ---: | --- |
| grid | 0 | translation |
| half-drop | 1 | translation; odd columns phase Y by half a tile |
| brick | 2 | translation; odd rows phase X by half a tile |
| mirror X | 3 | alternate X reflection |
| mirror Y | 4 | alternate Y reflection |
| mirror XY | 5 | independent alternating X/Y reflection |
| rotational | 6 | translation lattice plus tile-center 180° image |

Raw values are append-only and must never be renumbered.

### 4.1 Grid

Cell `(column, row)` has world origin:

```text
(column * width, row * height)
```

Its world-to-canonical transform is translation by the negative origin.

### 4.2 Half-drop

Columns alternate row phase. For column `c`:

```text
phaseY = parity(c) * height / 2
canonicalX = positiveModulo(worldX, width)
canonicalY = positiveModulo(worldY - phaseY, height)
```

Cell `(column, row)` has origin:

```text
(column * width, row * height + phaseY)
```

This sign matches the recovered correction evidence where
`fold(300, 144)` in a `288 x 288` odd column is `(12, 0)`.

### 4.3 Brick

Brick is the exact transpose of half-drop. For row `r`:

```text
phaseX = parity(r) * width / 2
canonicalX = positiveModulo(worldX - phaseX, width)
canonicalY = positiveModulo(worldY, height)
```

Cell `(column, row)` has origin:

```text
(column * width + phaseX, row * height)
```

### 4.4 Mirror X, Y, And XY

Grid cell indices select independent axis reflections:

```text
mirrorX = kind reflects X && column is odd
mirrorY = kind reflects Y && row is odd
```

An unmirrored axis maps local `u` to `u`; a mirrored axis maps it to
`positiveModulo(extent - u, extent)`. The modulo is load-bearing at the exact
zero/extent boundary. The full cell isometry carries the axis signs and
translation. Fragment and brush-local transforms preserve orientation rather
than folding only the stamp center.

### 4.5 Rotational

The recovered documents pin the `p2` rotation center but do not define a
checkerboard cell formula. Slice 2 therefore models the documented group
directly instead of inventing parity:

```text
translation generators = (width, 0), (0, height)
rotation generator R(x, y) = (width - x, height - y)
```

`R` is the 180-degree isometry around `(width / 2, height / 2)`. Projection
emits the identity and rotated images within the translation lattice and
deduplicates a fixed image when both transforms produce the same fragment.
Display repeats the resulting p2-symmetric canonical tile over the translation
lattice.

Tests verify the rotation generator, its translated centers, fixed points,
deduplication, and fold consistency. They do not assert mirror-style edge
continuity, because `p2` continuity is defined by its rotational centers rather
than reflection seams.

## 5. PatternEngine Architecture

### 5.1 Core values

`PatternEngine` gains focused geometry values:

```swift
public struct CellIndex: Hashable, Sendable {
    public let column: Int
    public let row: Int
}

public struct Affine2D: Equatable, Sendable {
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    public let translation: SIMD2<Float>
}

public struct TilingImage: Equatable, Sendable {
    public let cell: CellIndex
    public let ordinal: UInt8
    public let worldBounds: AxisAlignedRect
    public let worldToCanonical: Affine2D
}

public struct HalfPlane2D: Equatable, Sendable {
    public let normal: SIMD2<Float>
    public let offset: Float
}

public struct ConvexClip: Equatable, Sendable {
    public let halfPlanes: [HalfPlane2D]
}
```

`ConvexClip` accepts no more than four half-planes for Slice 2 cell clips.
Construction validates finite values and normalized, nonzero normals. Invalid
or empty tile geometry fails before projection.

### 5.2 Strategy contract

One `TilingStrategy` value owns the mathematical definition used by
production projection:

```swift
public struct TilingStrategy: Equatable, Sendable {
    public let kind: TilingKind
    public let tileSize: PatternSize

    public func cell(containing point: WorldPoint) -> CellIndex
    public func images(
        intersecting worldBounds: AxisAlignedRect
    ) -> [TilingImage]
    public func displayFold(_ point: WorldPoint) -> CanonicalPoint
}
```

The exact implementation may split formulas into private family helpers, but
callers receive one closed contract. Grid, half-drop, brick, and mirror return
one image per intersected cell. Rotational returns identity ordinal `0` and
rotated ordinal `1` for each intersected translation cell, then removes equal
images deterministically. `displayFold(_:)` and image transforms are tested
against one another at boundaries, negative coordinates, parity changes, and
large indices.

`TilingStrategy` construction validates that both tile dimensions are finite
integers in `64...4096`. Invalid strategy geometry fails before any fold or
projection call; renderer-facing invalid dimensions additionally surface as
the typed runtime error defined below.

### 5.3 Stamp footprint

Projection consumes a conservative oriented footprint instead of a circle
center:

```swift
public enum FootprintCoverageSymmetry: UInt8, Equatable, Sendable {
    case oriented
    case halfTurnInvariant
}

public struct StampFootprint: Equatable, Sendable {
    public let brushToWorld: Affine2D
    public let localBounds: AxisAlignedRect
    public let coverageSymmetry: FootprintCoverageSymmetry
}
```

The Slice 1 hard round uses a square local bound enclosing the circle.
Diagnostic harness programs use an asymmetric oriented footprint to prove
reflection, rotation, clipping, and brush-local continuity without shipping a
new product brush. The hard round declares `.halfTurnInvariant`; asymmetric
coverage and coordinate diagnostics declare `.oriented`. This declaration is
required to deduplicate p2 fixed-point coverage without incorrectly collapsing
two opposite orientations of a future directional footprint.

### 5.4 Cell fragment

Projection produces:

```swift
public struct CellFragment: Equatable, Sendable {
    public let cell: CellIndex
    public let imageOrdinal: UInt8
    public let canonicalFromBrush: Affine2D
    public let brushClip: ConvexClip
}
```

`canonicalFromBrush` places the stamp in canonical space with the complete cell
isometry. `brushClip` describes the portion of the original stamp belonging to
that cell in brush-local space. The fragment shader uses the same interpolated
brush-local position for coverage and clipping, so shape and future moving
grain remain continuous across fragments.

### 5.5 Enumerator

`TilingProjection.fragments(for:using:)`:

1. transforms all footprint corners into world space;
2. computes conservative world bounds;
3. asks the strategy for every finite `TilingImage` intersecting those bounds;
4. rejects images whose world bounds do not intersect the footprint bounds;
5. maps each image's four boundaries into brush-local half-planes;
6. emits one nonempty fragment per intersecting image;
7. deduplicates equal transformed fragments and coverage-equivalent p2 fixed
   images only when the footprint declares `.halfTurnInvariant`;
8. sorts fragments by row, column, image ordinal, and transform.

Nonempty means the transformed footprint quad and cell rectangle have a
positive-area convex intersection, not merely overlapping axis-aligned
bounds. Fixed-image deduplication compares canonical center, scale, and the
canonicalized clipped coverage polygon. It never merges `.oriented`
fragments merely because their centers match.

The renderer clamps radius to
`min(requestedRadius, 1000, 4 * min(tileWidth, tileHeight))` before creating a
footprint. This is the radius form of the approved diameter bound and retains
the recovered maximum four-tile reach. Enumeration is therefore finite and
bounded; a square maximum-radius footprint intersects at most `9 x 9` cell
positions before rotational images and deterministic deduplication.

Projection performs no file I/O, GPU calls, waits, or unbounded recursion.

## 6. Independent Coverage Oracle

`TilingCoverageOracle` is a slow diagnostic component. It lives in
`PatternEngine/Verification` so both Swift tests and the app harness can use
the same independent truth source.

For a supplied footprint, tile size, tiling, and supersampling rate, it returns
canonical coverage bytes. It:

- directly evaluates world-space footprint coverage;
- directly folds covered samples through its own tiling-kind switch;
- emits both p2 group images and removes fixed-point duplicates;
- writes canonical coverage without calling `TilingProjection`;
- uses deterministic sampling and stable iteration order;
- supports rectangular canonical output;
- evaluates the fixed asymmetric diagnostic shape;
- records canonical and brush-local diagnostic coordinates independently;
- exposes comparison results as typed hole and phantom counts.

A hole is oracle-covered but production-uncovered. A phantom is
production-covered but oracle-uncovered. Acceptance requires both counts to be
zero at exact integer probes and within one 8-bit coverage value for
antialiased boundary probes.

The oracle is never called from interactive input, `MTKViewDelegate.draw`, or
normal app startup.

## 7. Shared CPU/MSL Contract

The existing wire constants remain unchanged. New layouts append fields and
indices rather than renumbering prior values.

The existing dab-instance buffer stays at wire index `2`. Its element becomes
this exact 96-byte projected instance:

```c
typedef struct PatternClipHalfPlane {
    PatternFloat2 normal;      // offset 0
    float offset;              // offset 8
    float padding;             // offset 12; stride 16
} PatternClipHalfPlane;

typedef struct PatternProjectedStampInstance {
    PatternFloat2 canonicalXAxis;        // offset 0
    PatternFloat2 canonicalYAxis;        // offset 8
    PatternFloat2 canonicalTranslation;  // offset 16
    float radius;                        // offset 24
    PatternUInt32 clipCount;             // offset 28
    PatternClipHalfPlane clip0;           // offset 32
    PatternClipHalfPlane clip1;           // offset 48
    PatternClipHalfPlane clip2;           // offset 64
    PatternClipHalfPlane clip3;           // offset 80
} PatternProjectedStampInstance;          // stride 96
```

The affine maps normalized brush-local coordinates into canonical pixels.
`radius` preserves Slice 1's one-pixel antialias expansion and coverage
equation. `clipCount` is `0...4`; inactive planes are zero-filled. Reflection
and rotation live in the full affine basis rather than lossy scalar flags.

`ShaderABI` tests guard size, stride, alignment, and every field offset.
Runtime initialization retains the fail-fast ABI precondition.

## 8. Metal Rendering

### 8.1 Stamp pass

The vertex shader:

1. reads one `PatternProjectedStampInstance`;
2. generates the stamp's local quad;
3. applies `canonicalFromBrush`;
4. converts canonical pixels into tile clip space;
5. passes both canonical and original brush-local coordinates to the fragment
   stage.

The fragment shader:

1. evaluates all active clip half-planes;
2. discards samples outside the owning cell fragment;
3. evaluates hard-round coverage in unchanged brush-local coordinates;
4. returns the existing opaque-black straight-alpha source.

Existing source-over blend factors remain unchanged.

The real-metallib harness also creates
`patternDiagnosticFootprintFragment`, paired with the same production vertex
function and projected instances. It has three fixed modes:

- `asymmetricCoverage` renders the scalene brush-local triangle with vertices
  `(-0.75, -0.60)`, `(0.85, -0.20)`, and `(-0.10, 0.90)`;
- `canonicalCoordinates` encodes normalized canonical X/Y into red/green,
  exercising the future texturized, canvas-fixed coordinate path;
- `brushLocalCoordinates` encodes normalized brush-local X/Y into red/green,
  exercising the future moving-grain coordinate path.

The diagnostic fragment is harness-only and cannot be selected by interactive
app state. Its asymmetric coverage proves reflection and rotation orientation;
the two coordinate modes prove that neither coordinate system resets or jumps
across projected fragment seams. No product brush, grain asset, or material
behavior enters Slice 2.

Canonical-coordinate comparisons use circular channel distance so the valid
normalized wrap from `255` to `0` is continuous modulo the tile. Brush-local
coordinate comparisons use ordinary linear channel distance because
brush-local coordinates must remain uninterrupted across fragments.

### 8.2 Display pass

The display fragment maps screen to world, applies the selected tiling's
direct point fold, and samples canonical/live textures. CPU and MSL folds are
separate implementations checked against the oracle and real-Metal scenes.

Tiling kind becomes an explicit frame uniform using the reserved wire values.
Grid lines follow actual cell boundaries for each tiling instead of assuming
an unphased rectangular grid.

### 8.3 Commit and live behavior

The active stroke remains discardable. Every projected fragment stamps the
persistent live tile, and commit composites that tile into canonical exactly
once. Preview and commit use identical stored fragments and blend math.

Only the newly emitted fragment suffix is encoded each frame. Accumulated
stroke length must not increase per-frame stamp work.

### 8.4 Rectangular resources

Canonical, scratch, and live textures use independent integer width and height.
No square allocation shortcut remains. Slice 2 constructors and harness scenes
cover the minimum `64 x 64`, asymmetric examples, and the supported `4096`
dimension boundary without claiming every maximum stress combination fits the
current performance environment.

## 9. Renderer And App State

`GridRenderer` evolves into the generalized tiling renderer while retaining
its existing public input, pan, zoom, resize, cancel, and commit semantics.

It owns:

- immutable canonical tile dimensions for the current Slice 2 canvas;
- current `TilingKind`;
- generalized projector;
- persistent live/canonical resources;
- projected-instance pool;
- existing stroke lifecycle and completion mailbox.

Changing tiling is idle-only during Slice 2. An attempted switch during an
active or commit-pending stroke is rejected without changing renderer state.
Slice 3's transaction reducer later turns that policy into a document command.

`EditorCore` gains a minimal observable `EditorModel` containing only the
confirmed `TilingKind`. The app asks `GridRenderer` to apply a selection and
updates the model only after the renderer accepts it. The selector is disabled
while the renderer is non-idle; a race still fails closed in
`GridRenderer.setTiling(_:)` without model drift.

The minimal Mac UI adds one native tiling selector backed by that model. It
does not add brush, history, tool, layer, or persistence controls. The iPad
target depends on the same `EditorCore` state and compiles the selector without
making a device-interaction claim.

## 10. Harness And Scene Schema

The harness schema advances append-only. Slice 0 and Slice 1 scenes continue
to decode and run unchanged.

New programs cover:

- grid generalized-path regression;
- half-drop interior, phased edge, and corner;
- brick transpose;
- mirror X, Y, and XY orientation;
- rotational generator, fixed point, and orientation;
- large footprint crossing multiple cells;
- rotated asymmetric footprint;
- canonical-coordinate continuity;
- brush-local-coordinate continuity;
- rectangular tile;
- drawing from a noncentral visible cell;
- metadata-only tiling switch;
- live/commit equality;
- long projected stroke with no restamping.

Every scene family has a deliberate negative control that fails on the intended
pixel, hole/phantom, transform, byte-identity, or structural assertion before
its positive partner is accepted.

Artifacts include live screen, committed screen, canonical image, oracle
coverage where applicable, and benchmark JSON. Harness failures identify the
tiling, cell, channel, coordinate, expected value, actual value, and tolerance.

## 11. Error And State Safety

Programmer/wire failures remain fail-fast:

- CPU/MSL layout mismatch;
- unknown tiling wire value;
- impossible finite geometry;
- invalid clip construction.

Runtime failures are typed `MetalRendererError` values:

- projected-instance capacity exhausted;
- invalid tile dimensions;
- resource allocation failure;
- command or encoder failure;
- unsupported harness schema or assertion.

Failure rules:

- no partial canonical swap;
- no canonical mutation on cancel;
- no tiling change during a non-idle edit;
- no silent CPU fallback;
- no dropped fragment treated as success;
- failed frame submissions release only their own leases.

## 12. Verification Strategy

### 12.1 Pure tests

- half-open positive folds for all seven tilings;
- negative and large cell indices;
- half-drop and brick parity/sign;
- mirror axis transforms;
- rotational generator, translated centers, and fixed-point deduplication;
- affine inverse and round trips;
- cell bounds and fragment enumeration;
- four-plane clips;
- rectangular tile dimensions;
- exact minimum and capped maximum footprint sizes;
- asymmetric, reflected, rotated, and large footprints;
- canonical and brush-local coordinate continuity across fragments;
- oracle zero-hole/zero-phantom comparisons;
- deterministic fragment ordering;
- tiling switch preserves canonical byte identity.

### 12.2 ABI tests

- reserved tiling raw values remain `0...6`;
- new instance size, stride, alignment, and offsets match C/MSL;
- buffer and texture indices are append-only.

### 12.3 Real-Metal tests

- every new negative control fails for its intended reason;
- every positive scene matches oracle/pixel/structural assertions;
- legacy Slice 0 and Slice 1 scenes remain green;
- preview and commit differ by at most one 8-bit channel value;
- canonical bytes do not change during a tiling switch;
- long-stroke counters report zero restamped instances.

### 12.4 Manual Mac gate

- all seven tilings display their intended repeat;
- drawing in central and noncentral cells edits identical canonical content;
- half-drop/brick edges and corners show no holes or phantom copies;
- mirrors and rotational cells preserve asymmetric orientation;
- switching tiling changes display without changing existing pixels;
- pan, cursor-anchored zoom, resize, cancel, and pointer alignment remain
  correct;
- long projected strokes remain responsive.

### 12.5 Performance

Slice 2 retains Slice 1 budgets:

- brush processing p95 below `2 ms/frame`;
- 500-new-dab GPU work below `3 ms`;
- tiling display p95 below `2 ms`;
- missed frames below `1 percent`;
- no frame-time growth with accumulated stroke length;
- no unexplained p95 regression above `15 percent` from the accepted Slice 1
  baseline.

The milestone records GPU, OS, configuration, commit, artifact paths, fragment
counts, instance bytes, CPU spans, GPU spans, frames, and memory.

## 13. Delivery Order

1. Pure geometry, tiling definitions, and independent oracle.
2. Generalized grid fragment through the real Metal stamp/display path.
3. Half-drop and brick through the same path.
4. Mirror X/Y/XY and rotational transforms.
5. Rectangular resources and noncentral-cell editing.
6. Metadata-only switching and minimal selector.
7. Full scene matrix, negative controls, performance gate, manual gate, and
   milestone.

Each step ends in working software with focused tests, both app builds, a
review gate, and a small commit. Metal begins at step 2 and remains the only
production renderer.

## 14. Exit Criteria

Slice 2 is accepted only when:

- all seven tilings use generalized cell fragments;
- the CPU oracle and Metal output show zero holes and zero phantoms for the
  fixed matrix;
- large, rotated, reflected, and rectangular cases pass;
- drawing through visible repeat cells edits the same canonical pixels;
- tiling switches preserve canonical bytes exactly;
- live/commit, cancel, structural, and performance gates pass;
- macOS interaction is accepted;
- the generic iPadOS Simulator target builds;
- a measured milestone records evidence and retrospective;
- no Slice 3 transaction, undo, color, or eraser behavior enters scope.
