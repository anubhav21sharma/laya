# Compiled Periodic And Radial Symmetry Design

**Date:** 2026-07-23

**Status:** Approved design; awaiting written-spec review

**Parent specifications:**

- `2026-07-18-pattern-product-rebuild-design.md`
- `2026-07-20-generalized-seam-correct-tiling-design.md`

## 1. Purpose

Extend Laya from seven rectangular periodic choices to two explicit document
domains:

1. **Seamless Pattern**, for infinite periodic artwork with a finite repeat
   unit and repeat-unit export.
2. **Radial / Mandala**, for finite point-centred artwork generated from one
   linked canonical sector.

The extension includes square, triangular, hexagonal, rotational, reflected,
and kaleidoscopic families without replacing canonical raster ownership,
region history, the Metal production renderer, or the independent CPU oracle.

This design uses named, validated presets compiled into geometry descriptors.
It does not add a general runtime wallpaper-group interpreter or user-defined
symmetry generators.

## 2. Relationship To Existing Specifications

The product rebuild specification remains authoritative except for the
explicit amendments below:

- Wallpaper groups beyond the original seven choices move from deferred scope
  into this symmetry expansion.
- A finite radial document domain is added beside the periodic document
  domain.
- Radial canonical storage may require the chunk-capable `RasterSurface` path
  even if the periodic eight-layer baseline does not otherwise trigger it.
- User-facing repeat export for the new triangular families is a
  metric-resolved rectangular supercell.

The following decisions remain unchanged:

- canonical pixels are the retained source of truth;
- periodic changes preserve canonical bytes;
- interpolation happens in world space before projection;
- production rendering is Metal-only;
- the CPU oracle is independent;
- history stores changed raster regions;
- per-layer symmetry remains deferred;
- retained/vector strokes remain deferred.

The generalized Slice 2 tiling design remains the compatibility contract for
the existing seven modes. Their raw values, output, boundary rules, and file
meaning do not change.

## 3. Scope

### 3.1 Included

Seamless Pattern presets:

| Family | User-facing presets | Mathematical model |
| --- | --- | --- |
| Translation | Grid, Half Drop, Brick, Third Offset | `p1` with rectangular or oblique lattice presets |
| Rectangular mirror | Mirror X, Mirror Y, Mirror XY | parallel or perpendicular reflection groups |
| Half-turn | Rotational | existing `p2` |
| Square | Square Rotation, Square Kaleidoscope | `p4`, `p4m` |
| Triangular/hexagonal | Hexagons, Rotation 3, Rotation 6 | `p1`, `p3`, `p6` on a triangular lattice |
| Periodic kaleidoscope | Kaleidoscope 60 degrees, Kaleidoscope 30 degrees | `p3m1` / `*333`, `p6m` / `*632` |

Radial / Mandala presets:

- Plain Canvas;
- Mirror;
- Rotation `C_n`;
- Mandala / radial kaleidoscope `D_n`;
- arbitrary integer ray count within the measured supported range;
- quick ray presets `4`, `6`, `8`, `12`, and `16`.

The initial performance target for the maximum radial ray count is `32`. The
shipped maximum is the largest value through `32` that passes all correctness,
latency, and memory gates. The maximum is a capability value, not a silently
clamped input.

Third Offset has a row or column axis. Its phase cycles through `0`, `1/3`,
and `2/3` over three adjacent rows or columns. Existing Half Drop and Brick
remain the corresponding two-phase `0`, `1/2` presets.

### 3.2 Deferred

- Per-layer tiling or per-layer radial geometry.
- Mixing periodic and radial domains in one document.
- Changing radial group, ray count, centre, or reference axis after lock.
- User-authored generators or arbitrary wallpaper-group programs.
- Wallpaper groups not represented by the named presets above.
- Retained editable strokes.
- Polar-coordinate raster storage.
- A CPU production renderer or fallback.

## 4. Governing Decisions

### 4.1 Two document domains, one editor

The document selects one domain at creation:

```text
DocumentDomain
  |-- periodic(PeriodicConfiguration)
  `-- finite(FiniteConfiguration)
        |-- plain
        `-- radial(RadialConfiguration)
```

The domain controls projection, display sampling, grid geometry, and export.
Brushes, erasing, selection, fill, layers, raster history, compositing, input,
and transaction ordering remain shared.

Every layer in the initial implementation uses the document geometry.
Per-layer symmetry remains a later document-model expansion.

### 4.2 Compiled descriptors, not growing switches

A stable preset identifier plus validated parameters compiles on the cold
path into `CompiledSymmetry`. Production does not calculate group closure or
discover fundamental domains during input handling.

Conceptually:

```swift
struct CompiledSymmetry {
    var presetID: SymmetryPresetID
    var domain: CompiledDomain
    var family: SymmetryKernelFamily
    var images: [CompiledIsometry]
    var ownership: CompiledOwnership
    var displayProgram: CompiledDisplayProgram
    var rasterMetric: RasterMetric2D
    var exportCapability: SymmetryExportCapability
    var cost: SymmetryCostBound
}

enum SymmetryKernelFamily {
    case rectangular
    case triangular
    case radial
}
```

This is a closed, validated runtime value. It is not a serialized arbitrary
program and cannot contain user-supplied shader code.

### 4.3 Three family-specialized kernels

The hot path dispatches to rectangular, triangular, or radial geometry.
Common code owns:

- conservative brush bounds;
- affine composition;
- convex clipping;
- brush-local coordinate preservation;
- deterministic fragment ordering;
- canonical dirty regions;
- live/commit instance generation;
- transaction and history integration.

Family code owns:

- cell or sector enumeration;
- direct point fold;
- group images;
- boundary ownership;
- fixed-point and fixed-axis stabilizers.

This keeps the hot path bounded without restoring a tiling-specific brush
implementation.

### 4.4 The independent oracle remains independent

The CPU oracle shares primitive numeric value types and the preset selector
only. It does not consume:

- compiled production images;
- production ownership fragments;
- production display programs;
- projected stamp instances;
- Metal buffers.

For every preset, the oracle directly implements the point fold or group orbit
from the named mathematical definition.

## 5. Core Invariants

The following requirements are load-bearing:

1. Canonical raster bytes remain the retained document source of truth.
2. Periodic preset changes never rewrite canonical bytes.
3. Returning to a prior periodic configuration restores its exact prior
   rendering.
4. Radial geometry is immutable after its first successful raster edit.
5. World-space interpolation precedes symmetry projection.
6. Group operations are Euclidean translations, rotations, or reflections in
   world space; no symmetry generator scales artwork.
7. A fixed raster metric may map world geometry into texture coordinates. It
   is representation metadata, not a symmetry operation.
8. Every raster-changing tool uses the same document-domain projector.
9. Every shared boundary has one deterministic owner.
10. Coincident group images are removed only when complete stamp evaluation,
    including material coordinates, is equivalent.
11. CPU and Metal agree for folds, transforms, ownership, coverage, and
    sampled output.
12. No overflow, invalid geometry, or renderer failure may partially mutate
    committed pixels.
13. Unsupported work is rejected explicitly; fragments are never silently
    dropped.
14. Production never silently substitutes a CPU renderer.
15. Persisted preset and ABI identifiers are append-only.
16. Canonical raster resolution changes are explicit crop/expand operations,
    never implicit consequences of changing a symmetry preset.

## 6. Periodic Domain

### 6.1 Storage semantics

A periodic document retains one complete repeat-unit raster. Symmetry copies
inside that unit are real committed pixels, as they are for the existing `p2`
pair. One user operation writes the complete orbit atomically.

The complete repeat raster is intentional:

- it preserves reversible metadata-only preset changes;
- it keeps the existing seven modes byte-compatible;
- it provides a directly repeatable rectangular export;
- it avoids making different periodic presets assign incompatible meanings to
  differently shaped retained masks.

Changing a periodic preset may make existing pixels non-symmetric or
non-seamless under the new preset. This remains the approved reinterpretation
behavior. New edits are correct for the active preset.

### 6.2 Lattice representation

A periodic definition contains two independent world-space translation basis
vectors. Rectangular, half-drop, brick, square, and triangular layouts are
presets over that common representation.

For a world point `p` and basis matrix `B = [u v]`, lattice coordinates are:

```text
q = inverse(B) * (p - origin)
```

Half-open cell indices are obtained from `floor(q)`. Conservative enumeration
maps a footprint bound into lattice coordinates, expands to candidate integer
indices, then rejects candidates using exact convex intersection.

Half Drop and Brick preserve their approved signs and output. Their current
parity formulas compile into equivalent lattice/phase descriptors; the
descriptor migration must prove byte equality rather than merely visual
similarity.

The new periodic presets have these exact meanings:

| Preset | Retained/generated symmetry |
| --- | --- |
| Square Rotation | four orientation-preserving images, `p4` |
| Square Kaleidoscope | `45-45-90` mirrored triangle, `p4m` / `*442` |
| Hexagons | translation-only triangular lattice with a hexagonal guide |
| Rotation 3 | three orientation-preserving images, `p3` |
| Rotation 6 | six orientation-preserving images, `p6` |
| Kaleidoscope 60 degrees | equilateral mirrored triangle, `p3m1` / `*333` |
| Kaleidoscope 30 degrees | `30-60-90` mirrored triangle, `p6m` / `*632` |

### 6.3 Rectangular supercells

User-facing bitmap repeat export remains rectangular.

Square families use a square supercell. Triangular families use an orthogonal
rectangular supercell containing two primitive triangular-lattice cells. For a
triangular basis:

```text
u = (s, 0)
v = (s / 2, sqrt(3) * s / 2)
```

an orthogonal supercell is generated by:

```text
horizontal = u
vertical = 2 * v - u
```

The group is exact in continuous world space. `RasterMetric2D` maps that
continuous supercell into finite rectangular texture storage. Brush coverage
continues to evaluate in brush-local/world coordinates, so this representation
mapping does not stretch brush shapes or restart grain.

Raw and baked repeat exports use the same half-open periodic sampler.
Square-pixel export resolution is chosen from the requested density and the
supercell world aspect. The export is validated by repeating its bytes in a
`3 x 3` scene and comparing all translated seams.

### 6.4 Kaleidoscope 30 degrees

Kaleidoscope 30 degrees is a periodic `p6m` / `*632` preset, not a radial
mandala:

- triangular translation lattice;
- a `30-60-90` mirrored fundamental triangle;
- two-, three-, and six-fold rotation centres;
- six mirror directions;
- twelve point-group images per primitive lattice cell;
- at most twenty-four generic orbit images in the rectangular index-two
  supercell before fixed-point deduplication.

The compiler emits a bounded image table, ownership fragments, stabilizer
metadata, display parameters, and a worst-case projection cost. The renderer
never discovers those relationships during a stroke.

### 6.5 Polygon ownership

Production broad-phase bounds may remain axis-aligned, but exact cell domains
are convex polygons. Triangles use three half-planes and parallelograms use
four.

The four-plane GPU clip contract remains sufficient. Any domain requiring
more than four planes is decomposed into deterministic triangles or
quadrilaterals before packing.

The compiler assigns one owner to each directed shared edge. Vertices use the
same lexicographic lattice and image ordering. The rule must work for negative
indices and must not depend on floating-point hash iteration order.

## 7. Radial / Mandala Domain

### 7.1 Finite point groups

For locked centre `c`, reference angle `a`, and ray count `n`:

- Rotation `C_n` has canonical sector angle `2 * pi / n`.
- Mandala / kaleidoscope `D_n` has canonical sector angle `pi / n` and
  reflects alternating sectors.
- Mirror is `D_1`.
- Plain Canvas is the identity case and retains the full finite raster.

Rotation and Mandala accept `n >= 2`; Mirror fixes `n = 1`; Plain has no ray
parameter.

The stored ray count `n` is the number of rotational repeats. `C_n` displays
`n` sectors. `D_n` displays `2n` alternating mirrored sectors. The setup
preview and axis overlay show the resulting sector count before lock.

For a sampled point, the fold:

1. subtracts `c`;
2. evaluates radius and angle relative to `a`;
3. reduces the angle into the appropriate sector;
4. reflects alternate sectors for `D_n`;
5. maps the result into symmetry-local Cartesian coordinates.

The retained representation is Cartesian. No polar texture is permitted
because polar unwrapping would make pixel scale radius-dependent and distort
brush coverage.

### 7.2 Linked canonical sector

A radial document retains only the canonical sector. Visible segments are
generated by display sampling and export.

Therefore:

- drawing through any segment edits the same source;
- erasing through any segment erases the same source;
- undo records canonical sector regions only;
- redraws cannot diverge between segments while the symmetry is active;
- full-canvas export resolves all generated segments.

Radial documents do not expose repeat-tile export.

### 7.3 Sector surface and memory

The canonical sector extends from the locked centre to the maximum distance
from that centre to any finite-canvas corner. World operations and display
samples are clipped to the finite canvas before they fold into that sector.

An arbitrary off-centre sector can have a large empty axis-aligned bounding
box. The implementation must not require all padding pixels to be resident.
`RadialSectorSurface` therefore uses a Cartesian page/chunk atlas when a
single bounded texture would exceed the resident-memory budget. Only pages
intersecting the sector mask are allocated.

The compiler estimates:

- retained sector area;
- intersecting page count;
- maximum resident bytes per visible layer;
- worst-case fragments for the supported brush radius;
- worst-case images at the configured ray count.

An unsupported configuration fails before the first raster edit. It is not
accepted and later degraded.

### 7.4 Geometry locking

Before the first successful raster edit, the radial setup may change:

- cyclic versus dihedral group;
- arbitrary ray count;
- quick ray preset;
- centre;
- reference axis.

The first successful raster edit atomically commits both:

1. the locked geometry;
2. the raster mutation.

If validation, projection, allocation, or Metal submission fails, neither
commits.

After lock:

- geometry controls are read-only;
- undoing the first edit does not unlock geometry;
- clearing all pixels does not unlock geometry;
- a different geometry requires a new document.

This prevents history and saved canonical pixels from changing meaning.

Finite-canvas resize is not a radial geometry change. It follows the existing
crop-or-expand rule without scaling: the centre and reference axis remain at
their document-world coordinates and sector pixels are not resampled. A crop
operates on canonical orbits: a source pixel survives while any generated
image remains inside the new canvas, and is removed only when its complete
orbit is outside. Expansion allocates newly reachable pages as transparent,
except where a surviving canonical orbit already supplies the newly visible
image. Resize does not unlock geometry.

## 8. Stamp Equivalence And Deduplication

The existing `.oriented` versus `.halfTurnInvariant` distinction is
insufficient for three-, four-, and six-fold groups.

Each fully evaluated stamp declares an invariance contract that includes:

- coverage shape;
- shape texture;
- grain coordinate frame;
- material sampling;
- any directional dynamics baked into the stamp.

The default is identity-only. A stamp may explicitly declare half-turn,
arbitrary rotation, reflection, or rotation-and-reflection invariance only
when the complete evaluation is unchanged.

Production always removes byte-equal fragments. It removes
coverage-equivalent coincident images only when the relative group operation
belongs to the stamp's declared invariance.

Consequences:

- a homogeneous round dab at a six-fold centre is written once;
- a directional chisel at that centre may intentionally create six
  orientations;
- a reflected texture is not collapsed unless its material frame is also
  reflection-invariant;
- opacity and eraser strength do not multiply accidentally at fixed points or
  mirror axes.

## 9. Shared Raster-Mutation Contract

Brush, eraser, fill, and selection transform do not implement symmetry
themselves.

Conceptually:

```text
world-space raster operation
  -> active document-domain projector
  -> canonical fragments and dirty regions
  -> validate complete bounded work
  -> Metal preview
  -> atomic canonical commit
  -> region history
```

The projector accepts transformed convex footprints rather than dab centres.
It preserves brush-local coordinates through rotations and reflections.

Fill maps visible seeds through the same fold and deduplicates identical
canonical seeds before flood evaluation.

Selection and transform snapshot canonical source bytes before writing.
Selections crossing a symmetry boundary are decomposed through the same
ownership fragments, preventing read-after-write feedback between generated
images.

Canonical dirty regions are page-aware. One document command may own a
deterministically ordered set of regions across several radial pages, but it
still counts as one undo/redo step and commits atomically.

## 10. Interaction And UI

### 10.1 New document

Creation presents:

- Seamless Pattern;
- Radial / Mandala;
- Plain Canvas as the identity finite preset.

### 10.2 Pattern inspector

The pattern inspector exposes only parameters valid for the selected family:

- world repeat width and height for rectangular families;
- world spacing and orientation for square or triangular families;
- row or column axis for Third Offset;
- preset selector;
- grid visibility;
- family-specific grid presets.

Periodic changes compile while the editor is idle and apply as one undoable
metadata transaction. The last valid descriptor remains active until the new
one is completely validated and installed.

World repeat geometry is reversible symmetry metadata. Canonical pixel
resolution is a separate crop/expand command with no scaling; it may change
raster bytes and therefore follows the existing raster-resize transaction
rather than the metadata-only preset transaction.

### 10.3 Radial setup

The radial setup exposes:

- Rotation or Mandala/Kaleidoscope;
- arbitrary integer rays;
- quick ray presets;
- centre pin;
- reference-axis rotation;
- grid visibility;
- a visible “Locks when drawing starts” state.

After lock, the geometry remains visible but read-only. Controls are not
silently ignored.

### 10.4 Grid overlay

The overlay derives from the compiled definition:

- repeat cells and phase for rectangular presets;
- squares and rotation/mirror centres for square presets;
- triangular domains, mirror edges, and 2/3/6-fold centres for triangular
  presets;
- centre, axes, and canonical sector for radial presets.

Grid visibility never changes the selected preset or disables drawing
controls.

## 11. Renderer And ABI

Existing `TilingKind` raw values `0...6` remain reserved and unchanged.
New persisted preset identifiers append; no value is reused.

The current direct `tilingKind` display switch is replaced incrementally by:

- a family identifier;
- packed family parameters;
- a bounded static isometry table;
- packed ownership/domain fragments;
- raster metric;
- export/display capability flags.

The compiler creates these buffers outside the input-to-pixel path. A stroke
does not allocate group tables, calculate inverses, or validate file data.

Metal may expand a base placement through a static image table to reduce CPU
instance traffic, but GPU expansion must produce the same deterministic
logical fragments as the CPU production enumerator.

All C/Swift/MSL structure sizes, offsets, alignments, indices, and maximum
counts receive append-only ABI tests.

## 12. Persistence

The document manifest adds versioned fields equivalent to:

```text
domain kind
preset identifier
validated preset parameters
radial lock state
radial centre/reference axis/ray count when applicable
raster metric
canonical surface layout version
```

Existing documents decode as periodic documents with their current
`TilingKind`. Existing raw values keep their exact meaning.

Periodic and Plain surfaces retain the existing lossless layer-raster
representation. A paged radial surface stores a small surface manifest plus
lossless page images keyed by signed page coordinate. Missing pages are
transparent. Save writes the complete new page set to a temporary archive and
atomically replaces the destination; it never patches the live archive in
place.

The file reader validates all values before allocating raster resources:

- known domain and preset;
- finite geometry;
- supported ray count;
- nonsingular lattice;
- legal raster metric;
- bounded page and instance cost;
- compatible surface layout version.

Unknown presets, invalid parameters, or unsupported costs produce typed load
errors. A corrupt file never reaches shader uniforms.

## 13. Export

Periodic documents provide:

- source canonical repeat raster;
- metric-resolved baked rectangular repeat unit;
- flattened repeated scene/preview.

Radial and Plain documents provide:

- flattened finite canvas;
- optional transparency;
- no repeat-tile claim.

Kaleidoscope 30-degree export is accepted only when:

- the rectangular supercell passes the independent periodic sampler;
- a `3 x 3` repetition has no ownership holes or phantom copies;
- translated seams sample equal bytes under the export contract;
- 2/3/6-fold centres and mirror edges match the CPU oracle within the approved
  antialias tolerance.

Export never mutates document pixels or geometry.

## 14. Failure Handling

- Invalid descriptor compilation leaves the last valid descriptor installed.
- A failed periodic change does not enter history.
- A failed first radial edit leaves both lock state and pixels unchanged.
- Instance or page-budget overflow rejects the complete operation.
- Renderer failure releases only resources owned by the failed operation.
- No partial canonical swap is permitted.
- No dropped fragment is reported as success.
- No unsupported preset renders as Grid or Plain.
- No CPU production fallback is permitted.

## 15. Verification

### 15.1 Descriptor and pure geometry tests

- Existing seven presets compile to their exact approved mappings.
- Group closure, inverse, determinant, and lattice preservation.
- Expected generic orbit cardinality for every preset.
- Exact stabilizer cardinality at axes and rotation centres.
- Half-open ownership for negative, positive, and large indices.
- Lattice inverse and round trip.
- Triangle and quadrilateral clipping.
- Deterministic descriptor and fragment ordering.
- Compiler rejection of singular, non-finite, and over-budget geometry.

### 15.2 Independent oracle tests

- Zero holes and zero phantom coverage for every preset.
- Rectangular, square, and triangular repeat geometries.
- Asymmetric and reflected brush shapes.
- Moving/directional grain coordinates.
- Minimum, common, and maximum legal brush radii.
- Negative and large world coordinates.
- Every mirror edge and cell vertex.
- Metadata-only periodic changes preserve canonical bytes.

Kaleidoscope 30 degrees additionally covers:

- all three fundamental-triangle edges;
- 2-, 3-, and 6-fold centres;
- generic orbit cardinality in primitive and rectangular supercells;
- a large footprint crossing multiple triangular cells;
- repeat export tiled `3 x 3`.

Radial tests additionally cover:

- ray counts `2`, `3`, `4`, prime counts `5` and `7`, quick presets, and the
  shipped maximum;
- cyclic and dihedral folds;
- the exact centre;
- every reference-sector boundary;
- off-centre geometry;
- a footprint crossing the centre and many sectors;
- lock, failed-lock, undo-first-edit, redo, clear, save, and load.

### 15.3 Real-Metal tests

- Positive and single-cause negative scenes for every new family.
- Production versus oracle coverage.
- Brush-local coordinate continuity.
- Live/commit equality within one 8-bit channel value.
- Draw and erase at generic points, axes, and fixed centres.
- No silent fallback.
- No discarded fragment.
- Existing Slice 0 through Slice 4 scenes remain green.

### 15.4 UI and integration tests

- Domain selection creates the intended inspector.
- Pattern parameters remain editable only while the editor is idle.
- Radial controls lock after the first successful edit.
- A failed first edit does not lock them.
- Keyboard shortcuts do not capture focused numeric entry.
- Grid visibility does not disable preset, clear, or drawing controls.
- Drawing through noncentral generated content edits the correct canonical
  source.
- Undo/redo, clear, tool changes, and export remain available after symmetry
  operations.

### 15.5 Performance and memory

Record per family:

- compiled image and fragment counts;
- CPU projection p50/p95;
- GPU stamp and display p50/p95;
- live-stroke instance traffic;
- resident raster/page bytes;
- export time and peak memory;
- ray count, lattice size, brush radius, and device.

The existing interactive budgets remain targets:

- brush processing p95 below `2 ms/frame`;
- 500-new-dab GPU work below `3 ms`;
- display p95 below `2 ms`;
- missed frames below `1 percent`;
- no accumulated-stroke-length growth.

If a requested configuration cannot meet hard correctness or resident-memory
bounds, descriptor compilation rejects it. Performance evidence determines
the shipped radial ray maximum; it does not permit incorrect rendering below
that maximum.

## 16. Delivery Sequence

### Phase 1: Descriptor foundation and legacy parity

- Stable preset identifiers and document-domain values.
- Descriptor compiler and validation.
- Rectangular family kernel.
- Existing seven modes expressed through descriptors.
- Byte-for-byte legacy fixtures and real-Metal parity.

### Phase 2: Square families

- `p4` Square Rotation.
- `p4m` Square Kaleidoscope.
- Four-fold stabilizers and square mirror triangles.
- Export and UI presets.

### Phase 3: Triangular families

- Triangular lattice and raster metric.
- Hexagons, `p3`, and `p6`.
- `p3m1` Kaleidoscope 60 degrees.
- `p6m` Kaleidoscope 30 degrees as the proving acceptance case.
- Rectangular supercell export and 2/3/6-fold evidence.

### Phase 4: Radial domain

- Radial configuration and lock transaction.
- Cartesian sector surface and required page/chunk residency.
- `C_n`, `D_n`, arbitrary rays, and quick presets.
- Finite display/export and radial verification matrix.

### Phase 5: Product completion

- Persistence migration.
- Full export matrix.
- Performance and memory evidence.
- macOS manual acceptance.
- iPadOS build and adaptive-control acceptance.
- Milestone retrospective and remaining-risk record.

Every phase ends with working production Metal, an independent oracle, focused
tests, app builds, and a small reviewable commit series.

## 17. Exit Criteria

The expansion is complete only when:

- all named presets compile through the descriptor architecture;
- existing seven modes remain byte-compatible;
- Kaleidoscope 30 degrees produces a genuinely repeatable rectangular export;
- radial edits remain linked through one canonical sector;
- radial geometry cannot change after lock;
- every raster-changing tool uses the shared projector;
- CPU oracle and real Metal show no holes or phantom copies;
- fixed-point dabs do not multiply opacity unless distinct oriented images are
  mathematically intended;
- periodic changes preserve canonical bytes;
- persistence and unknown-preset failures are typed and atomic;
- no CPU production fallback or dropped-fragment success path exists;
- performance and memory evidence establish the shipped ray limit;
- parent-spec deviations are reflected in the product documentation and
  milestone.

## 18. Reference Behavior

Amaziograph is a product reference, not a file-format or implementation
contract. Its current handbook documents twenty iPad symmetries, including
Mandala, Rotation, Kaleidoscope 30/60 degrees, hexagonal rotations, square
kaleidoscope, and offset tiles. It also distinguishes tile-exportable
symmetries from rotational and mandala artwork.

Laya deliberately differs in two areas:

- radial geometry becomes immutable after the first committed edit;
- per-layer symmetry remains deferred.

References:

- <https://amaziograph.com/manual/>
- <https://www.amaziograph.com/manual/AmaziographUserManual.pdf>
