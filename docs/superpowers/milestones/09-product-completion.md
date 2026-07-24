# Compiled Symmetry Phase 5: Product Completion

- **Status:** Implementation Complete — Physical-Device Performance Acceptance Pending
- **Date:** 2026-07-24
- **Branch:** `main`
- **Governing specification:**
  `docs/superpowers/specs/2026-07-23-compiled-periodic-radial-symmetry-design.md`
- **Parent product specification:**
  `docs/superpowers/specs/2026-07-18-pattern-product-rebuild-design.md`
- **Implementation plan:**
  `docs/superpowers/plans/2026-07-24-product-completion.md`

## Status Ruling

Phase 5 completes the product-facing work explicitly assigned by the compiled
periodic/radial symmetry plan:

- versioned project persistence with legacy periodic migration;
- bounded archives, deterministic lossless raster storage, and atomic direct
  archive replacement;
- committed-state capture and all-or-nothing renderer adoption;
- source-canonical, baked-repeat, and flattened-scene export APIs;
- PNG, TIFF, and explicitly flattened JPEG encoding;
- macOS manual save/open acceptance and iPad Simulator adaptive-layout
  acceptance;
- complete automated, build, analysis, interoperability, and resource
  evidence.

No known Phase 5 correctness bug or governing-specification deviation remains
open. Physical Apple-GPU and Apple Pencil performance acceptance remains an
environment-only gate.

The broader parent product still lists autosave recovery, multi-layer app
adoption, and a user-facing image-export picker. Those items were not in the
approved compiled-symmetry Phase 5 scope and are not represented as completed
here. The project-file schema already models multiple layers, while the
current app bridge deliberately accepts its existing single visible,
unlocked, normal pattern layer only.

## Project Persistence

`PatternFile` now owns a typed and versioned project contract:

- schema v1 decodes only legacy periodic selector values `0...6` and migrates
  them without changing meaning;
- schema v2 encodes append-only stable selector values `0...17`;
- encode output is deterministic;
- periodic, Plain, and radial configurations are recompiled through
  `SymmetryDescriptorCompiler` before raster decode or allocation;
- persisted raster metrics and surface layouts must match the compiled result;
- dimensions, finite values, viewport state, paths, layer structure, radial
  parameters, and declared costs fail closed with typed errors;
- metadata is bounded to 1 MiB and project rasters to `4096 x 4096`;
- reserved-name, traversal, duplicate-path, raster/page collision, unsupported
  compression, encrypted-entry, link, checksum, overlap, and ZIP64 inputs are
  rejected.

Periodic and Plain documents persist one exact premultiplied-BGRA8 PNG.
Radial documents persist a duplicate-free subset of compiled logical sector
pages. Page coordinates, rather than packed atlas slots, are the stable
identity. Missing resident pages remain transparent and are packed
deterministically when loaded.

The archive writer creates a complete stored ZIP beside the destination,
reopens it for structural validation, and atomically replaces the destination.
Injected failure preserves the prior destination bytes. The generated archive
also passes the macOS system `unzip -t` implementation, so acceptance is not
limited to the project reader.

## Renderer And App Adoption

`CommittedDocumentSnapshot` captures committed pixels, configuration,
viewport, and radial lock state. It rejects pending commits or raster
mutations and excludes live, replay, draft, and undo-history state.

Loading builds a fresh renderer and adopts it only after the complete archive,
metadata, rasters, compiled configuration, and renderer initialization
succeed. Any failure leaves the active editor unchanged.

The macOS app exposes Open and Save As in both the top bar and focused
commands. It declares the `.patternproj` document type, presents typed load or
save errors, uses security-scoped URLs where required, and preserves the
saved viewport.

Manual import testing found and closed one lifecycle defect: SwiftUI could
reuse the existing `NSViewRepresentable` after a successful import, causing
`MetalCanvas` to trap because its native view belonged to the previous editor
controller. `EditorCanvasHost` now keys the native canvas by controller
identity. A behavioral regression mounts the host, swaps controllers, and
proves that a new native view backed by the replacement renderer is created.

## Export Matrix

| Domain | Source canonical | Baked repeat | Flattened scene |
| --- | --- | --- | --- |
| Periodic rectangular | exact stored raster | metric repeat | repeated scene |
| Periodic square | exact stored raster | metric repeat | repeated scene |
| Periodic triangular | exact stored raster | rectangular supercell | repeated scene |
| Plain | exact finite raster | unavailable | finite canvas |
| Radial | logical canonical pages | unavailable | finite canvas |

All fourteen periodic presets complete baked-repeat export. Legacy half-drop,
brick, mirror, and rotational period multipliers are preserved. Triangular
families use their compiled rectangular supercell. Kaleidoscope 30 passes
independent seam checks and a `3 x 3` repetition scan.

PNG and TIFF preserve dimensions and lossless premultiplied pixels. JPEG
requires a valid quality and explicit opaque background. Export is bounded to
`8192 x 8192`, consumes committed snapshots only, and does not mutate pixels,
history, viewport, configuration, guides, or radial lock state. Finite and
radial domains return a typed unavailable result for baked repeat rather than
claiming periodicity.

## Complete Automated Gate

```bash
/usr/bin/time -lp swift test \
  --scratch-path .build/phase5-final \
  --no-parallel
```

Result: exit `0`; `653 tests in 25 suites` passed with zero issues in
`317.196 seconds` (`321.85 seconds` wall clock).

The complete process reported:

- maximum resident set size: `269,549,568` bytes;
- peak memory footprint: `18,630,720` bytes;
- zero swaps.

These figures include the Swift test runner, compiler products, independent
oracle work, and real-Metal harnesses. They are regression diagnostics, not a
shipping-app memory budget measurement.

The gate includes:

- deterministic v1 migration and v2 format matrices;
- malformed/hostile archive and atomic-save failures;
- PNG/TIFF exactness and JPEG compositing;
- committed-snapshot and renderer-adoption failure matrices;
- every periodic repeat preset and finite/radial export;
- standard-system ZIP interoperability;
- the new imported-session native-view identity regression;
- independent periodic and radial oracles plus real-Metal production paths.

## Product Builds And Analysis

`./scripts/bootstrap.sh` regenerated `App/PatternSpike.xcodeproj` and completed
without warnings from unhandled generated plist inputs.

The macOS and generic iPad Simulator `Debug` builds exited `0`:

```bash
xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

The equivalent `analyze` commands both ended with
`** ANALYZE SUCCEEDED **`. Both generated Info plists pass `plutil -lint`.

## Manual Acceptance

### macOS

Attached-terminal UI acceptance covered both storage models:

- a `320 x 256` periodic document with committed marks saved as
  `.patternproj`;
- the archive passed system `unzip -t`;
- a fresh open restored exact dimensions, pixels, viewport-backed display,
  grid control, and tiling selection;
- an eight-ray Mandala committed a dab and permanently exposed the radial
  geometry lock;
- the radial archive contained the manifest, tiling, layer, surface, and one
  sparse logical page;
- a fresh open restored the radial pixels, eight-ray configuration, and
  locked state.

The debug-HUD grave/tilde shortcut is covered by direct key-routing and
compact-layout tests. Desktop key injection did not reliably deliver that
physical key to the app, so this run does not claim a second automated UI
verification of the shortcut.

### iPad Simulator

`PatternSpikePad` built, installed, and launched on an iPad Pro 11-inch
simulator. Portrait and landscape screenshots confirmed adaptive canvas,
toolbar, inspector, and touch-sized controls.

The first rotation exposed that the generated iPad plist did not declare
every supported orientation. The plist now explicitly lists portrait,
portrait upside down, landscape left, and landscape right. After regeneration,
rebuild, reinstall, and relaunch, landscape filled and adapted correctly.

## Remaining Acceptance Debt

- Capture p50/p95 projection, dab, display, commit, and export timings on
  representative physical Apple GPUs.
- Record sustained FPS, transfer traffic, thermal behavior, and peak resident
  app memory across representative canvas, ray-count, and brush-size cases.
- Exercise Apple Pencil input, pressure, prediction, and rotation behavior on
  physical iPad hardware.

The existing compiler caps and Phase 4 radial evidence harness continue to
reject over-budget work before installation. Paravirtual Metal results and
whole-test-process memory figures are retained as diagnostics, not substituted
for the remaining physical-device acceptance.
