# Compiled Symmetry Phase 5: Product Completion

- **Status:** Implementation complete — physical-device performance acceptance pending
- **Date:** 2026-07-24
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Parent product specification:**
  `docs/superpowers/specs/2026-07-18-pattern-product-rebuild-design.md`

## 1. Scope

Phase 5 closes the product-facing work left by the compiled periodic/radial
symmetry expansion:

1. versioned project persistence and legacy periodic migration;
2. atomic archive replacement and immutable decoded results;
3. the complete source/repeat/finite-scene export matrix;
4. performance and memory evidence;
5. macOS and iPadOS acceptance records;
6. a milestone retrospective with remaining environment-only risk.

This phase does not introduce per-layer symmetry, editable retained strokes,
new wallpaper groups, or a CPU production renderer.

## 2. Persistence Contract

### 2.1 Schema versions

`schemaVersion == 1` represents the documented legacy periodic project:

- the manifest owns identity, timestamps, canonical raster dimensions, and
  saved viewport;
- `tiling.json` stores one numeric legacy `TilingKind` raw value `0...6`;
- the committed pattern raster is one lossless PNG.

`schemaVersion == 2` is the first compiled-symmetry project:

- domain is `periodic` or `finite`;
- preset identifiers use append-only raw values `0...17`;
- periodic parameters store repeat width, repeat height, and orientation;
- finite Plain stores no radial parameters;
- radial stores kind, ray count, centre, reference angle, and lock state;
- the raster metric and canonical-surface layout version are explicit;
- periodic and Plain store one lossless raster;
- radial stores a surface manifest plus lossless pages keyed by signed logical
  page coordinate.

The decoder migrates v1 into an immutable v2-shaped result. Encoding writes
only v2. No persisted raw value is renumbered or inferred from a display
label.

### 2.2 Validation order

The reader performs these steps before raster decode or allocation:

1. parse bounded JSON data;
2. require a supported schema and canonical surface layout;
3. validate identifiers, dimensions, finite numbers, viewport, and paths;
4. build the typed document configuration;
5. compile it through `SymmetryDescriptorCompiler`;
6. compare the persisted raster metric with the compiled metric;
7. validate surface kind, page coordinates, page count, and declared byte
   cost against the compiled layout;
8. only then decode lossless raster payloads.

Unknown presets, invalid parameter combinations, metric mismatch, layout
mismatch, page-set mismatch, unsupported cost, unsafe archive paths, and
raster failures are distinct typed load errors. No invalid value reaches
Metal uniforms or texture allocation.

### 2.3 Radial page identity

Radial persistence stores at most one image for each compiled resident page
and no image for a nonresident page. Filenames derive only from signed logical
page coordinates. Atlas slots are not serialized: load recompiles the layout
and packs the logical pages deterministically. Missing resident pages decode
as transparent. A save writes one complete replacement manifest for its
current sparse page set; it never carries stale page entries forward from the
previous archive.

### 2.4 Atomic save

Save constructs the complete archive beside the destination, closes and
reopens it for structural validation, then atomically replaces the live file.
It never patches a live archive. Any failure removes the temporary archive
and preserves the previous destination bytes.

Open returns an immutable decoded project. The app allocates replacement
renderer resources and adopts them only after every manifest, raster, and
renderer operation succeeds.

## 3. Export Matrix

| Domain | Source canonical | Baked repeat | Flattened scene |
| --- | --- | --- | --- |
| Periodic rectangular | exact stored raster | metric repeat | repeated scene |
| Periodic square | exact stored raster | metric repeat | repeated scene |
| Periodic triangular | exact stored raster | rectangular supercell | repeated scene |
| Plain | exact finite raster | unavailable | finite canvas |
| Radial | logical canonical pages | unavailable | finite canvas |

PNG preserves transparency. TIFF preserves lossless BGRA content. JPEG
requires an explicit opaque background. Export consumes committed state only,
runs off the input path, and never mutates pixels, geometry, history,
viewport, guide visibility, or lock state.

Kaleidoscope 30 degrees remains the periodic acceptance case: its rectangular
supercell must pass independent seam sampling and a `3 x 3` repetition scan.

## 4. Implementation Slices

### Slice 5.1 — Schema, migration, and validation

- Replace the `PatternFile` placeholder with Codable wire models.
- Add immutable decoded project and surface values.
- Add v1 legacy periodic migration.
- Add v2 periodic, Plain, and radial decode/encode.
- Recompile every decoded configuration before accepting its surface.
- Add typed failure tests for every validation class and a format matrix for
  all stable preset identifiers.

Exit: pure tests prove deterministic v2 encoding, legacy migration, valid
round trips, and rejection before raster allocation.

### Slice 5.2 — Archive and lossless rasters

- Add a bounded ZIP reader/writer without a production network dependency.
- Reject duplicate entries, traversal, symlink-like names, unsupported
  compression, oversized metadata, and oversized expanded payloads.
- Add ImageIO PNG encode/decode for single rasters and radial pages.
- Save through temporary archive plus atomic replacement.
- Add byte-identical round trips and injected-failure atomicity tests.

Exit: periodic, Plain, and radial archives reopen with identical committed
pixels; every failed save preserves the prior archive.

### Slice 5.3 — Renderer/app adoption

- Add committed-surface capture and replacement APIs.
- Make renderer replacement a preflighted all-or-nothing operation.
- Add app save/open commands and background cold-path tasks.
- Present typed errors and keep the current document on failure.

Exit: save/open integration covers all domains, radial lock state, focus
changes, active drafts, and failed adoption.

### Slice 5.4 — Export completion

- Add source-canonical and flattened-scene APIs beside the existing metric
  repeat and finite-canvas exporters.
- Add PNG/TIFF/JPEG encoding with explicit alpha policy.
- Cover every preset and every unavailable domain/format combination.
- Prove export non-mutation and Kaleidoscope 30 rectangular repeatability.

Exit: the full matrix is pixel-correct and typed.

### Slice 5.5 — Evidence and milestone

- Run focused and complete Swift tests.
- Regenerate the Xcode project.
- Build and analyze macOS and generic iPad Simulator targets.
- Run the dedicated real-Metal persistence/export matrix.
- Capture available timing and memory diagnostics.
- Record physical-device and UI-only acceptance debt without treating it as a
  correctness blocker.

Exit: Phase 5 milestone documents evidence, deviations, and remaining risk.

## 5. Required Tests

- v1 raw values `0...6` migrate without changed meaning.
- v2 values `0...17` round-trip without renumbering.
- Periodic parameters round-trip for rectangular, square, and triangular
  families.
- Plain rejects radial fields and radial rejects absent or conflicting fields.
- Mirror requires one ray; Rotation/Mandala require `2...32`.
- Centres, angles, dimensions, metric coefficients, and viewport values reject
  NaN and infinity before engine value construction.
- Persisted metrics match recompiled metrics within a fixed serialization
  tolerance.
- Radial page keys are a duplicate-free subset of the compiled resident
  logical page set; omitted pages are transparent.
- Duplicate, unexpected, or out-of-budget pages fail with typed errors.
- Invalid files never invoke the injectable raster decoder/allocation seam.
- Archive failures preserve the existing destination.
- Active live/replay pixels and undo history are never serialized.
- Save/open and every export leave the current document unchanged until an
  explicit successful adoption.

## 6. Documentation Ruling

This plan follows both governing documents. The only clarification is that
schema v1 is now pinned to legacy numeric values `0...6`; no implementation
previously existed, so this records the first concrete representation of the
already-documented legacy contract rather than changing a shipped format.
