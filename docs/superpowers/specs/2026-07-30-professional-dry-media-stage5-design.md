# Stage 5 Professional Dry-Media Design

Date: 2026-07-30

Status: Approved for implementation

## 1. Decision

Stage 5 turns the Stage 4 deposition backend into four intentionally authored,
measured, and user-reviewable professional brush families:

1. Technical Ink;
2. Graphite Pencil;
3. Natural Charcoal;
4. Chisel Marker.

Stage 4 already proved the generic ink, dry-breakup, marker-overlap, resource,
cache, frame-scheduling, erase, tiling, radial, and deterministic replay
machinery. Stage 5 does not replace that architecture. It adds the authored
assets, family-specific definitions, calibration corpus, editor adoption, and
evidence gate required to claim that these four brushes are product brushes
rather than diagnostic fixtures.

The six Stage 5 delivery slices are:

1. calibration and asset foundation;
2. Technical Ink;
3. Graphite Pencil;
4. Natural Charcoal;
5. Chisel Marker and editor adoption;
6. cross-family evidence and acceptance.

## 2. Governing Documents

This design refines Stage 5 of
`2026-07-26-world-class-brush-engine-design.md` and preserves the Stage 4
boundary in `2026-07-28-brush-deposition-backend-design.md`.

When older documents call for the final 12–16 preset library during this pass,
the newer staged architecture governs:

- Stage 5 calibrates the four professional anchor families;
- Stage 6 adds canvas-interaction wet media;
- Stage 7 expands the final product library and performs hardware tuning.

Stage 5 therefore ships four professional dry/non-interacting anchors, not the
final 12–16-brush library.

## 3. Current State

The editor currently exposes Stage 4 diagnostic definitions:

- `builtin.native-ink`;
- `builtin.native-dry-media`;
- `builtin.native-glaze`;
- `builtin.native-marker`;
- `builtin.native-airbrush`;
- `builtin.native-eraser`.

Their source explicitly states that their tuning is for backend diagnosis and
is not a claim of final brush character. `technicalInk`, `dryPencil`, and
`glazeMarker` are deprecated aliases for those diagnostic anchors, not separate
professional brushes. There is no native charcoal definition.

The engine already supports:

- one or two shape layers;
- zero, one, or two grain layers;
- deterministic procedural and packaged texture resources;
- pressure, speed, direction, tilt, azimuth, roll, tangential pressure, age,
  distance, and deterministic random inputs;
- size, flow, opacity, spacing, rotation, scatter, hardness, grain, offset, and
  color mappings;
- taper, stabilization, prediction replacement, replay-tail rendering, and
  bounded scheduling;
- `.flow + .none`, `.flow + .dryBreakup`, and
  `.uniformGlaze + .markerOverlap`;
- symmetry-aware transformation of shape axes and grain frames.

Stage 5 uses those capabilities before adding new engine surface.

## 4. Immutable Stage 4 Boundary

`StageFourAnchorDefinitions` and the exact six-entry `AnchorBrushCatalog`
remain the Stage 4 diagnostic truth.

Stage 5 must not:

- rename or retune a Stage 4 anchor;
- change a Stage 4 semantic hash merely to admit Stage 5 work;
- replace a Stage 4 positive or negative evidence scene;
- weaken `verify-brush-stage4.sh`;
- make the Stage 5 gate self-attest Stage 4 correctness.

The Stage 5 gate invokes the complete Stage 4 software gate as a regression.
The designed physical/manual pending status from Stage 4 remains valid.

## 5. Catalog And Editor Model

### 5.1 Stable identities

The professional catalog has this exact order and identity:

| Family | Stable ID | Display name |
| --- | --- | --- |
| Ink | `builtin.professional-technical-ink` | `Technical Ink` |
| Pencil | `builtin.professional-graphite-pencil` | `Graphite Pencil` |
| Charcoal | `builtin.professional-natural-charcoal` | `Natural Charcoal` |
| Marker | `builtin.professional-chisel-marker` | `Chisel Marker` |

`ProfessionalBrushCatalog` owns those four entries. Definitions are immutable,
compile deterministically, declare `.realtime120`, and use no canvas
interaction.

`EditorBrushCatalog` supplies the editor-facing list:

1. the four professional entries, in the table order;
2. the retained diagnostic `Native Glaze`;
3. the retained diagnostic `Native Airbrush`.

The Stage 4 eraser remains the editor eraser until a later eraser-family
calibration pass. It must erase every Stage 5 brush through the same
destination-out path.

### 5.2 Migration

Selections using old diagnostic or legacy IDs resolve as follows:

| Incoming ID | Editor selection |
| --- | --- |
| `builtin.native-ink` | Technical Ink |
| `builtin.technical-ink` | Technical Ink |
| `builtin.native-dry-media` | Graphite Pencil |
| `builtin.dry-pencil` | Graphite Pencil |
| `builtin.native-marker` | Chisel Marker |
| `builtin.glaze-marker` | Chisel Marker |
| `builtin.native-glaze` | Native Glaze |
| `builtin.native-airbrush` | Native Airbrush |

Unknown IDs remain rejected. The existing stale bounded-wash diagnostic remains
unchanged.

## 6. Deterministic Professional Asset Pack

Stage 5 extends `BrushTextureIdentity` with:

| Identity | Kind | Source dimension |
| --- | --- | --- |
| `builtin.shape.technical-nib` | shape | 128 |
| `builtin.shape.graphite-tip` | shape | 128 |
| `builtin.shape.charcoal-tip` | shape | 128 |
| `builtin.shape.marker-chisel` | shape | 128 |
| `builtin.grain.graphite` | grain | 256 |
| `builtin.grain.charcoal` | grain | 256 |

The existing six Stage 4 textures remain 64×64 and byte-identical.

Every new base level is generated with deterministic integer or explicitly
rounded floating-point operations. Mip levels continue to use the existing CPU
area-average path. No GPU mip generator, file read, image decode, wall clock,
platform random generator, or device-dependent operation enters built-in
generation.

The authored character is:

- technical nib: crisp, subtly elongated, anti-aliased nib footprint;
- graphite tip: narrow, irregular elliptical graphite contact;
- charcoal tip: coarse, porous, irregular soft-edged contact;
- marker chisel: rounded chisel footprint with stable broad and narrow axes;
- graphite grain: fine multi-scale paper tooth with directional fibers;
- charcoal grain: coarse clustered tooth with cracks and larger voids.

The compiler and legacy resolver use each identity's declared source dimension.
Stage 4 resource byte counts remain exact because the old identities retain
their 64-pixel source dimension.

Professional definitions reference these resources as optional built-in
fallbacks. A future packaged asset can replace a fallback without changing the
definition or editor identity.

## 7. Family Definitions

All definitions use:

- maximum resource dimension: `4096`;
- maximum resident bytes: `64 MiB`;
- interaction: `.none`;
- wetness, bleed radius, and soften passes: zero;
- seed policy: `.perStroke`;
- compatibility native feature version: `1`;
- no required foreign semantic keys;
- antialiasing enabled.

### 7.1 Technical Ink

Technical Ink is a crisp stroke-following nib for line art.

- shape: `builtin.shape.technical-nib`;
- no grain;
- `.flow + .none`;
- base spacing `0.045`, maximum spacing `0.12`;
- base flow `0.90`, stroke opacity `1`;
- hardness `0.98`, aspect `0.92`;
- no placement scatter or jitter;
- pressure controls size from `0.18...1`;
- pressure controls flow from `0.65...1`;
- speed controls spacing multiplier from `0.80...1.15`;
- direction controls rotation through `0...2π`;
- stabilization `0.22`;
- start taper `1.25` diameters, end taper `1.5` diameters;
- taper minimum size `0.08`, minimum flow `0.25`;
- taper affects size and flow;
- replay mode `.replayTail` with `BrushRecipePolicy.replayTailLimits`.

### 7.2 Graphite Pencil

Graphite Pencil must support both light toothy construction lines and dark
repeated marks.

- shape: `builtin.shape.graphite-tip`;
- grains: `builtin.grain.graphite` in brush-local coordinates and
  `builtin.grain.paper` in canonical coordinates;
- required `dualGrain` capability;
- `.flow + .dryBreakup`;
- base spacing `0.055`, maximum spacing `0.15`;
- base flow `0.28`, stroke opacity `0.88`;
- hardness `0.72`, aspect `0.34`;
- base scatter `0.015`, placement jitter `0.01`;
- pressure controls size from `0.25...1`;
- pressure controls flow from `0.10...1`;
- pressure controls opacity from `0.20...1`;
- speed controls spacing multiplier from `0.85...1.15`;
- direction controls rotation through `0...2π`;
- tilt controls hardness from `0.35...0.90`, inverted so higher tilt is softer;
- tilt controls grain scale from `0.75...1.40`;
- deterministic randomization is bounded to spacing `0.04`, scatter `0.08`,
  rotation `0.08` radians, grain `0.08`, material `0.05`;
- stabilization `0.12`;
- start taper `0.75` diameters, end taper `1` diameter;
- taper minimum size `0.20`, minimum flow `0.25`;
- replay mode `.replayTail`.

### 7.3 Natural Charcoal

Natural Charcoal is visibly coarser, broader, and less uniform than pencil.

- shapes: `builtin.shape.charcoal-tip` followed by a multiplied soft-round
  envelope;
- grains: `builtin.grain.charcoal` in brush-local coordinates and
  `builtin.grain.paper` in canonical coordinates;
- required `dualShape` and `dualGrain` capabilities, sorted by identifier;
- `.flow + .dryBreakup`;
- base spacing `0.09`, maximum spacing `0.22`;
- base flow `0.24`, stroke opacity `0.92`;
- hardness `0.58`, aspect `0.55`;
- base scatter `0.08`, placement jitter `0.035`;
- tilt controls size from `0.45...1.70`;
- pressure controls flow from `0.10...1`;
- pressure controls opacity from `0.25...1`;
- speed controls spacing multiplier from `0.75...1.25`;
- direction controls rotation through `0...2π`;
- speed controls scatter multiplier from `0.70...1.50`;
- tilt controls hardness from `0.22...0.82`, inverted;
- pressure controls grain scale from `0.80...1.40`, inverted;
- deterministic randomization is bounded to spacing `0.08`, scatter `0.18`,
  rotation `0.18` radians, grain `0.16`, material `0.12`;
- stabilization `0.05`;
- start and end taper `0.5` diameters;
- taper minimum size `0.35`, minimum flow `0.30`;
- replay mode `.replayTail`.

### 7.4 Chisel Marker

Chisel Marker has a stable translucent body, direction-following chisel angle,
and controlled overlap density.

- shape: `builtin.shape.marker-chisel`;
- no grain;
- `.uniformGlaze + .markerOverlap`;
- base spacing `0.035`, maximum spacing `0.10`;
- base flow `0.56`, stroke opacity `0.82`;
- hardness `0.96`, aspect `0.22`;
- no scatter or placement jitter;
- pressure controls size from `0.70...1`;
- speed controls flow from `0.75...1`, inverted;
- spacing is constant;
- direction controls rotation through `0...2π`;
- stabilization `0.12`;
- start and end taper `0.35` diameters;
- taper minimum size `0.85`, minimum flow `0.85`;
- material strength `0.95`, accumulation limit `0.82`;
- replay mode `.replayTail`.

## 8. Calibration Corpus

Stage 5 adds platform-free normalized traces. Exact samples are committed and
versioned; they do not depend on live hardware:

1. `professional-tap`;
2. `professional-slow-line`;
3. `professional-fast-line`;
4. `professional-pressure-ramp`;
5. `professional-tilt-sweep`;
6. `professional-direction-turn`;
7. `professional-corner`;
8. `professional-hatching`;
9. `professional-grid-seam`;
10. `professional-radial-spoke`.

The corpus carries capability flags and values required to exercise pressure,
altitude/tilt, azimuth where present, coalescing, prediction replacement, and
mouse fallback. Every trace has exactly one begin and one end, finite ordered
timestamps, and at least one authoritative movement sample except the tap.

`ProfessionalBrushCharacterizer` evaluates every professional brush against
every trace with:

- nominal diameter `40`;
- black ink;
- seed `0x5A17_E5`;
- 512×512 viewport centered at `(256, 256)`.

The logical characterization record includes:

- schema version;
- family and stable brush ID;
- definition semantic hash;
- trace name;
- sample and logical-dab counts;
- logical-dab digest;
- minimum and maximum diameter, flow, opacity, hardness, grain scale, rotation,
  and scatter magnitude observed in authoritative dabs;
- world-bounds union.

Records are sorted by `(brushID, traceName)`, reject duplicates and nonfinite
metrics, and encode with sorted JSON keys.

## 9. Functional Contracts

Pure characterization must prove:

- all four definitions compile and have distinct semantic hashes;
- repeating the corpus with the same seed is byte-identical;
- adding or replacing prediction does not change authoritative records;
- Technical Ink pressure increases size and flow, remains scatter-free, and
  rotates with travel direction;
- Graphite Pencil pressure increases size, flow, and opacity; tilt changes
  hardness and grain scale; mouse fallback remains finite and useful;
- Natural Charcoal produces wider size and scatter spans than Graphite Pencil,
  plus a wider deterministic randomized grain-offset range; its §7.3
  tilt/pressure grain-scale endpoints remain exact and it remains
  deterministically seeded;
- Chisel Marker rotates with travel direction, preserves its accumulation
  family, and keeps scatter zero;
- no brush requests wet interaction;
- every brush remains within declared replay, texture, and resident-memory
  limits.

## 10. Metal Evidence

The Stage 5 offscreen matrix has one positive and one deliberate negative
control for each professional family:

- `professional-technical-ink`;
- `professional-graphite-pencil`;
- `professional-natural-charcoal`;
- `professional-chisel-marker`.

Each positive scene writes:

- live, committed, and canonical PNGs;
- a characterization JSON record;
- a benchmark JSON record;
- resolved shape/grain identities;
- brush definition ID and semantic hash;
- compiler/cache counters;
- preview/commit delta;
- seam/radial invariant results where applicable.

Each negative control flips one named family requirement and must fail closed
with exit `1`, no stdout, and exactly one structured stderr line.

The matrix proves:

- nonempty visible output;
- preview/commit maximum channel delta at most one;
- prediction on/off equality;
- periodic translation equality;
- radial rotation and reflected handedness;
- bounded completed-stroke-independent live work;
- no compiler, resource, file, pipeline creation, or GPU wait on input;
- exact professional resource identities and mip counts;
- destination-out eraser compatibility.

## 11. Manual Perceptual Evidence

Automated tests cannot decide whether a brush feels or looks professional.
Brush Lab therefore exports a fixed manual matrix for each of the four
professional brushes:

- tap at minimum, nominal, and maximum review sizes;
- slow and fast straight strokes;
- pressure ramp;
- tilt sweep;
- curve and sharp corner;
- cross-hatching and repeated buildup;
- periodic seam crossing;
- radial rotation and reflection;
- eraser retrace;
- mouse fallback;
- Pencil/tablet input when hardware exists.

Each card records:

- edge quality;
- taper/termination;
- texture cohesion;
- pressure response;
- tilt/direction response;
- buildup;
- seam/symmetry behavior;
- eraser match;
- responsiveness;
- notes.

All assessments begin unset. Software may generate cards and evidence, but it
must never self-mark perceptual fields as passed.

## 12. Performance And Memory

Every professional brush declares `.realtime120`.

Software thresholds:

- CPU preparation p95 below `2 ms`;
- established 500-dab GPU workload below `3 ms` on qualifying physical
  hardware;
- no completed-stroke-length growth;
- zero production input-path allocation events after warmup;
- active resources remain pinned under pressure;
- inactive professional resources are evictable;
- resident bytes never exceed the definition or device budget.

Paravirtual and simulator measurements are diagnostic. They cannot establish
60 Hz or `realtime120`.

Physical profiles remain pending until hardware exists:

- reference M-series ProMotion iPad;
- A14-class 60 Hz floor;
- Apple Pencil;
- Wacom;
- sustained thermal drawing;
- memory warning;
- suspend/resume;
- true input-to-photon capture.

Stage 5 performance and physical evidence is distinct from Stage 4 evidence.
It may reuse the eight established profile identifiers, but it must not copy
or relabel Stage 4 profile bytes. Every supplied Stage 5 profile binds raw
input and timing samples to all four professional definition IDs, their exact
semantic hashes, and their resolved resource topology. This includes both
grain resources for graphite and charcoal. Every profile/brush trace reuses
the frozen Stage 4 device, input provenance, event ordering, minimum duration,
minimum sample-count, derived-metric, and threshold contract for that exact
profile. A generic trace copied or relabeled between profiles is invalid.

Each positive professional scene also emits:

- a raw three-sample, exactly 500-record deposition measurement;
- a raw 128-input long-stroke trace and CPU/GPU measurements for the exact
  `began`, 126 `moved`, and `ended` live-input frames, excluding raster commit;
- per-frame logical-dab identity ranges and previous/emitted high-waters,
  generated projected-instance high-waters, and submitted GPU work counts;
- compiler/resource counter snapshots before and after each hot workload;
- source commit, renderer executable, GPU, OS, brush identity, semantic hash,
  and resource topology provenance; and
- a digest index binding every raw performance artifact.

The long-stroke workload uses a fixed `512 × 512` grid context and exactly
128 mouse inputs. Its alternating endpoints are `(64, 256)` and `(448, 256)`,
so every measured segment has equal length and the replay tail reaches steady
bounded work during the early quartile. Replay limits bound retained and
per-frame encoded work, not cumulative whole-stroke totals. The validator
derives new logical dabs and zero restamped logical dabs from contiguous
identity ranges, binds the final logical high-water to the lifetime logical
dab total, derives generated projected work from monotonic cumulative
high-waters, and binds its final high-water to the lifetime generated
projected-instance total. Submitted GPU instance counts independently prove
the encoder work bound.

The Stage 5 validator derives the GPU maximum, zero hot-path compiler/resource
counter deltas, zero completed-stroke restamping, and bounded long-stroke
quartile growth from those raw artifacts. It also requires the signed
least-squares slope across all 128 CPU samples and all 128 GPU samples to be
at most `0.001 ms/frame`; negative warm-up decay remains valid. No status
boolean can assert these claims. All four brushes must be below `3 ms` for a
physical result to complete; paravirtual, virtual, simulator, and unknown GPUs
remain pending even when their diagnostic numbers are below budget.

## 13. Stage 5 Gate

`scripts/verify-brush-stage5.sh` runs on a clean committed source tree and:

1. invokes the complete Stage 4 gate and accepts only its software-correct
   pass/performance-pending terminal states;
2. runs all Swift tests without parallelism;
3. runs focused professional catalog, characterization, compiler, renderer,
   cache, and editor tests;
4. builds and analyzes macOS and iPad simulator targets;
5. runs every Stage 5 positive and negative Metal scene;
6. exports the logical characterization baseline;
7. exports the fixed manual card catalog;
8. verifies source, artifact, and toolchain provenance;
9. validates exact file sets, schemas, hashes, sorted records, negative
   controls, and performance status with an artifact-only validator.

Exit statuses:

- `0`: software, manual, and supplied physical evidence all pass;
- `2`: all software checks pass while manual and/or physical evidence remains
  pending;
- `1`: any software, schema, artifact, or supplied evidence failure.

Raw caller-provided pass strings are rejected.

## 14. Error Handling

- A professional definition that fails validation or compilation is a
  programmer error caught by tests and the gate.
- Selecting a brush that fails asynchronous compilation leaves the previous
  compiled brush active and reports the existing typed diagnostic.
- Unknown or mismatched built-in texture identities fail compilation.
- Missing optional professional resources use only their declared built-in
  fallback.
- Stage 5 gate artifacts are generated in `.build` and never become source
  truth.
- A missing manual or physical profile is pending, not silently passed.
- A supplied malformed or failing profile fails the gate.

## 15. Non-Goals

Stage 5 does not add:

- smudge, pickup, reservoir, dilution, charge, Wet Mix, or dirty halos;
- a public Brush Studio;
- an editable user brush library;
- the final 12–16 preset pack;
- layers;
- proprietary Procreate brush assets;
- a claim of Procreate or Photoshop pixel identity;
- physical-device claims without measured evidence.

## 16. Acceptance

Stage 5 software implementation is complete when:

- the four professional IDs, assets, definitions, editor migrations, and
  ordering are exact;
- all functional, deterministic, seam, radial, eraser, resource, memory, and
  software performance checks pass;
- Stage 4 remains software-correct without retuning its anchors;
- both app targets build and analyze;
- the artifact-only validator accepts the final committed source;
- manual and unavailable physical evidence is reported explicitly rather than
  fabricated.

Product acceptance additionally requires the user to approve the manual cards
and qualifying physical devices to satisfy their measured profiles.
