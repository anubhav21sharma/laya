# Authored Procreate Charcoal Corpus Design

**Date:** 2026-08-01

**Status:** Approved, revised for replacement corpus

**Owner:** Laya brush-engine corrective program

**Source corpus:** `brushes/procreate/1_FREE_Charcoal_Set.brushset`

**Source SHA-256:** `efa2a655620844fc3cc0b2c26f81bf28f31d7b9e74677c31933c352cf13156cf`

## 1. Decision

Use the author-supplied `FREE Charcoal Set` as Laya's first real dry-brush
reference corpus. Conversion remains an offline toolchain operation: the app
and renderer never execute Procreate data or interpret Procreate keys.

`C Charcoal` (`CC70504F-0D16-4D26-88A6-BF47BDA8ADE8`) is the primary fidelity
target. `C Charcoal Soft` (`21AF8C6B-3FB1-4BF8-8F89-F5768271DA35`) is a
required secondary characterization target so the implementation cannot tune
only one preset accidentally.

Both targets are composite brushes. Each has an active parent `Brush.archive`
and an active `Sub01/Brush.archive`, with `dualBlendMode = 1`. Their active
shape and grain resources are Procreate Source Library references rather than
embedded bytes:

- shape: `Haggard-Oval.png` for both components;
- parent grain: `Brush-Preset-Bonobo.png`;
- sub-brush grain: `Brush-Artery-Charcoal-Corse.jpg`.

The current parser already recognizes and safely inspects all eight top-level
members, but it reports `procreate.unsupported-sub-brush` and does not retain
the nested component. Structural parsing therefore works today; faithful
mapping does not. Active sub-brush parsing and native composite dry-brush
support are prerequisites, not optional follow-up work.

The corpus also contains two author-supplied high-resolution paper photographs.
They may be used to author Laya-owned grain resources. Because the target tip
and grains are absent from the archive, the final native brush records all
three replacements as approximations. Exact Procreate pixel identity is not a
goal.

## 2. Validated Corpus Inventory

The order below is the order in `brushset.plist`, not parser sort order.

| Order | Member | Display name | Active top-level resources | Active sub-brush | Role |
| --- | --- | --- | --- | --- | --- |
| 1 | `C3A956C4-00DB-4CA9-B5A2-6F0199B591EC` | Procreate Pencil - Remake | built-in shape/grain references | `Sub01` | Parser regression case |
| 2 | `0DADE934-8FD1-4680-AA5E-66D699CF21A0` | COFE Pencil - F | built-in shape/grain references | `Sub01` | Later pencil reference |
| 3 | `21AF8C6B-3FB1-4BF8-8F89-F5768271DA35` | C Charcoal Soft | built-in shape/grain references | `Sub01` | Secondary charcoal target |
| 4 | `CC70504F-0D16-4D26-88A6-BF47BDA8ADE8` | C Charcoal | built-in shape/grain references | `Sub01` | Primary charcoal target |
| 5 | `89185C2C-2746-4934-A9DB-20983D28BEED` | Finger Smudge | embedded 1024 x 1024 shape and 1300 x 1300 grain | none | Resource parser fixture; defer behavior |
| 6 | `ACF77570-AD91-4352-86C7-2C48BF0D7108` | Eraser - Soft | embedded 800 x 800 grain; built-in shape | `Sub01` | Parser regression case |
| 7 | `77E04E60-98F7-4849-90E9-3F23C5B303DB` | Eraser - Medium | embedded 800 x 800 grain; built-in shape | `Sub01` | Parser regression case |
| 8 | `C430FF39-0164-4E0B-A7E6-B6200BB89F86` | Eraser - Hard | embedded 800 x 800 grain; built-in shape | none | Parser/resource regression case |

Every top-level brush has a QuickLook thumbnail. Several sub-brushes also have
their own thumbnail. Thumbnails are external visual references, not shape or
grain resources and not pixel-exact goldens. Author/signature pictures are
provenance only.

`Reset/` trees are backup snapshots. The adapter follows only the active root
and active `SubNN/` children. It must never double-count a reset copy as an
active component.

### 2.1 Companion paper sources

| File | SHA-256 | Observed role |
| --- | --- | --- |
| `DSC_0006.jpg` | `5ce41606b51036394f841f519b7af45e9316012145d48acbe76cc7a5e43d309f` | Smooth high-resolution paper source |
| `DSC_0175.jpg` | `929f5c3b301bfcee2acd0367b0147af4c27bc775547f50a347d3dc8c24a172d0` | More visibly fibrous high-resolution paper source |

These photographs are source material, not renderer-ready masks. Admission
requires deterministic luminance normalization, illumination removal,
seam construction, frequency checks, mip generation, and provenance.

The adjacent `.key` file is opaque ancillary material. It is not parsed,
shipped, or required by the brush conversion path.

## 3. Goals

1. Pin the replacement archive, paper sources, member order, and ownership.
2. Decode verified typed Procreate values through Laya's bounded readers.
3. Parse active `SubNN` components recursively with strict depth/count budgets.
4. Preserve parent/sub-brush identity, order, settings, resources, and blend
   relationship in the foreign IR and conversion report.
5. Add a native composite dry-brush representation where components may have
   independent coverage, placement, dynamics, and resource transforms.
6. Author Laya-owned replacements for the missing oval tip and two grains.
7. Map both charcoal targets honestly into ordinary native packages.
8. Use independent raster and performance evidence to catch invisible,
   undersized, textureless, discontinuous, or expensive output.
9. Keep the converter and all Procreate knowledge outside the live input and
   frame paths.

## 4. Non-Goals

- Runtime parsing or execution of `.brush` or `.brushset` files.
- A public Procreate import UI in this corrective program.
- Exact pixel identity with Procreate.
- Fetching, copying, reconstructing, or redistributing Procreate built-ins.
- Treating all observed fields as understood.
- Flattening a full sub-brush into `dualShape`/`dualGrain` layers without
  evidence that the semantics are equivalent.
- Implementing `Finger Smudge` before the destination-sampling backend exists.
- Activating wet/mixing semantics through the dry deposition backend.
- Making a generated Laya raster its own visual oracle.

## 5. Architecture

```text
author-supplied .brushset + paper photographs
        |
        v
ForeignZIPReader + ForeignPropertyListReader
        |
        v
Procreate classic-v1 structural adapter
  - active parent and bounded active SubNN components
  - typed verified scalar settings
  - embedded resource descriptors
  - Source Library reference tokens
  - Reset trees excluded
        |
        v
ProcreateClassicV1BrushMapper
  - exact native mappings
  - measured approximations
  - explicit unsupported entries
  - Laya-owned resource substitutions
        |
        v
native composite BrushDefinition + BrushConversionReport
        |
        v
normal BrushCompiler / component dab generation / deposition renderer
```

The foreign format layer represents a small ordered component tree. The native
runtime representation is not Procreate-specific. A native composite brush is
an ordered list of independently compiled dry components plus an explicit
composition mode. One input sample may emit multiple component dabs, but each
component remains append-only, deterministic, bounded, and transform-correct.

The existing `BrushCoverageDefinition.shapes` and `.grains` describe layers
inside one component. They do not by themselves represent a Procreate
sub-brush with independent size, spacing, flow, scatter, and dynamics. The
mapper may collapse components only if characterization proves equivalence;
otherwise it must use the native composite model or block activation.

## 6. Bounded Active-Component Contract

The first version supports one parent plus one active `Sub01`, because that is
the characterized target surface. The representation remains an ordered array
so future versions can raise the limit without a schema rewrite.

- Only `<brush-id>/Brush.archive` and `<brush-id>/SubNN/Brush.archive` are
  active definitions.
- `Reset/**`, QuickLook, Signature, and AuthorPicture never become components.
- Component depth is one and active component count is at most two for parser
  version 2. Exceeding either limit produces a typed unsupported diagnostic.
- Missing, duplicate, non-contiguous, or path-conflicting active component
  members fail deterministically.
- Each component gets a stable identifier, ordinal, typed settings, resources,
  diagnostics, and source path.
- Parent and child share archive provenance but never share mutable parser
  state or silently inherit missing settings.
- Aggregate settings, object, resource-byte, pixel, and diagnostic budgets
  include every component and are checked before allocation.
- ZIP member order and dictionary iteration never determine semantic order.

## 7. Typed Archive Contract

`BoundedKeyedArchiveView` resolves direct values and UID references to bounded
nodes. The adapter retains direct Boolean, integer, finite real, string, and
null values rather than replacing every field with `.token("present")`.

The verified scalar surface includes identity/resource, stroke path, shape,
grain, rendering, pressure/input, color, taper, and `dualBlendMode` settings
already enumerated by the world-class brush-engine design. The same decoder is
used independently for parent and sub-brush. Recognition does not imply exact
mapping: every field still receives a conversion disposition.

- Unexpected node kinds fail with a typed archive error; they are not coerced.
- Negative zero is canonicalized to zero.
- Non-finite values, cycles, invalid UIDs, and budget violations remain hard
  failures.
- Unknown direct scalars may be retained in a stable raw namespace.
- Unknown object graphs remain presence-only with a diagnostic and never enter
  runtime definitions.
- Curves are decoded only after their concrete keyed layout is characterized
  with project-owned fixtures.

## 8. Resource Policy

### 8.1 Shape replacement

Neither charcoal target embeds `Haggard-Oval.png`. Laya authors an irregular,
soft-edged oval charcoal tip from project-owned material. It is not presented
as a reconstruction of Procreate's bytes. The resource must have meaningful
2D support, broad-side/edge variation, sufficient resolution for the declared
maximum diameter, and stable mips. Blank, one-pixel, promotional, clipped, or
nearly uniform tips fail admission.

### 8.2 Grain replacements

Two distinct owned grains are required unless measured evidence proves that
one source with two transforms adequately represents both roles:

- a fine paper-tooth replacement for `Brush-Preset-Bonobo.png`;
- a coarse/fibrous replacement for `Brush-Artery-Charcoal-Corse.jpg`.

The supplied photographs are the preferred owned sources. The normalization
pipeline records crop, orientation, illumination correction, grayscale curve,
seam synthesis, frequency shaping, output size, and hashes. Outputs must pass:

- opposite-edge seam error below the project threshold;
- useful low-, mid-, and high-frequency energy;
- no dominant repeated row, column, line, or isolated defect;
- useful modulation through the full mip chain and declared zoom range;
- deterministic bytes and documented source provenance.

Every missing built-in mapping is `approximated` with a specific reason. A
registry uses exact case-sensitive source names and never performs network or
fuzzy lookup.

## 9. Native Composite Contract

The primary and sub-brush components retain independent:

- shape and grain layers;
- nominal size multiplier and effective support;
- spacing, flow, opacity, scatter, rotation, and jitter;
- pressure and tilt responses;
- random stream namespace;
- resource transforms and grain anchoring.

Composition order and mode are explicit and deterministic. Stable randomness
is keyed by stroke seed, logical sample/dab identity, component ordinal, and
channel—not by loop or collection iteration order. Symmetry and tiling compose
the complete component transform, so tip direction and grain orientation
rotate/refelect with the replica as specified by their coordinate modes.

Component emission must not replay retained stroke history. One sample may
produce up to the fixed component count, with preallocated batches and a
bounded per-frame work budget. Erase uses the same component geometry and
footprint as paint. Undo/redo stores the resulting canonical pixels under the
existing history contract; it does not retain Procreate structures.

If the native component model or renderer cannot reproduce a required active
field, conversion remains inspectable but activation fails. It must not
silently flatten the two brushes into one mask.

## 10. Finger Smudge Boundary

`Finger Smudge` is valuable because it supplies real embedded resource bytes
for normalizer, package, mip, and cache tests. It is not a dry-charcoal target.
Its visual behavior needs destination sampling and the ordered smudge/wet
backend. Until that backend exists, conversion reports the behavior as
required-unsupported and cannot activate the package.

## 11. Quality And Performance Evidence

The top-level and sub-brush QuickLook thumbnails are external visual
references. Tests compare stable characteristics rather than exact pixels:

- visible bounds, median width, broad-side/edge ratio, and cursor agreement;
- alpha percentiles and changed-pixel coverage at low/neutral/high pressure;
- edge irregularity without isolated single-pixel noise;
- low/mid/high frequency energy and anisotropy;
- tonal buildup over repeated passes;
- straight, curved, reversal, stationary, and endpoint behavior;
- grain anchoring through zoom, periodic seams, and radial transforms;
- component contribution by rendering parent-only, child-only, and combined.

Negative controls independently disable the parent, disable the child, replace
the tip with one pixel, remove each grain, shrink support, zero flow, introduce
a seam, merge component random streams, and force retained-stroke replay. Each
must fail its intended gate.

Performance uses production-path checkpoints. Large sources are normalized
offline; decoded textures, mips, sampler state, pipeline state, and compiled
dynamics are warm before pointer-down. Evidence covers cold selection, warm
long strokes, large size, plain/periodic/radial modes, maximum symmetry, cache
churn, memory pressure, 10-second traces, and accelerated 10-minute traces.
The two-component brush must stay within a declared component cost budget and
must never produce unbounded input or GPU backlog.

Manual look/feel review remains deferred until all corrective stages and the
full automated performance round complete. Pending manual status does not
block implementation, but it prevents product acceptance.

## 12. Repository And Product Boundaries

- `1_FREE_Charcoal_Set.brushset` and the two paper photographs are immutable,
  hash-pinned corpus inputs.
- A small adjacent manifest records ownership, hashes, member order, targets,
  active component topology, and missing built-ins.
- The opaque `.key` file is excluded from conversion, tests, and release
  products unless its purpose is separately established and approved.
- Converter integration tests may read the real corpus; unit and fuzz tests use
  project-generated byte fixtures.
- Generated native packages and evidence remain under `.build` until resources
  and definitions are deliberately admitted.
- Release app targets do not bundle the source corpus, parser, or converter.
- Final packages contain only native definitions/reports and Laya-owned
  resources.

## 13. Acceptance

Corpus adoption is software-complete when:

1. Archive, photograph hashes, set name, eight-member order, and target IDs are
   verified automatically.
2. All eight top-level brushes inspect without crash through bounded readers.
3. Parent and active `Sub01` definitions for both charcoal targets decode
   deterministically; Reset copies are excluded.
4. Parent/sub settings and missing resource identities are retained and each
   receives exactly one conversion disposition.
5. The native composite model preserves independent component dynamics and
   deterministic ordering without replaying stroke history.
6. All three owned replacements pass provenance and resource-quality gates.
7. Both targets convert twice to byte-identical native packages; unsupported
   required semantics block activation.
8. Natural Charcoal passes visibility, footprint, component-contribution,
   buildup, texture, transform, erase, history, determinism, and production
   performance gates.
9. `Finger Smudge` resources are testable, but its package remains inactive
   until the destination-sampling backend exists.
10. The production app never parses Procreate input during drawing.
11. Manual quality remains explicitly pending until the final review round.
