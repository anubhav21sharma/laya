# World-Class Brush Engine Design

**Date:** 2026-07-26

**Status:** Approved

**Primary target:** iPadOS 18+

**Secondary target:** macOS 14+ development and Wacom use

**Implementation status (2026-07-28):** Stage 1 characterization and Stage 2
engine foundation are correctness complete at commit
`4a1b7158a095d67e78ce70466f9577722268b483`. Physical-device performance,
Apple Pencil/Wacom feel, true input-to-photon latency, ProMotion stability,
thermal behavior, and memory-warning recovery remain unaccepted hardware
gates. See
`docs/superpowers/milestones/10-world-class-brush-engine-foundation.md`.

## 1. Purpose

Laya's brushes are a make-or-break product capability. The current engine
proves seamless raster drawing, deterministic dab generation, instanced Metal
stamping, pressure-aware interpolation, bounded replay, materials, history,
and compiled symmetry. It does not yet provide the breadth, fidelity,
performance discipline, tooling, or import-based conformance needed to compete
with Procreate and Photoshop.

This design defines a stamp-first brush engine that:

- feels immediate, smooth, natural, and predictable;
- expresses professional ink, pencil, charcoal, marker, airbrush, glaze,
  eraser, smudge, and wet-media behavior;
- supports iPad Pencil input and macOS tablet input through one normalized
  model;
- preserves the existing raster document, transaction, history, tiling, and
  symmetry invariants;
- treats large textures and complex dynamics as compiled GPU programs rather
  than work assembled during a stroke;
- imports Procreate brushes through a separate converter for compatibility
  testing without making Laya depend on a foreign file format;
- makes correctness and performance independently testable without operating
  the interactive UI.

The target architecture is designed as a semantic superset of the settings
documented by
[Procreate Brush Studio 5.4](https://help.procreate.com/procreate/handbook/5.4/brushes/brush-studio-settings).
Early stages explicitly report capabilities that are not implemented yet. The
design is not an attempt to reproduce Procreate's undisclosed renderer or copy
its assets, presets, user interface, or branding.

## 2. Decision Precedence And Existing Documentation

The following precedence applies when documents disagree:

1. Explicit user decisions made during this brush-engine design.
2. This approved design.
3. `2026-07-18-pattern-product-rebuild-design.md`.
4. `2026-07-23-compiled-periodic-radial-symmetry-design.md`.
5. `2026-07-22-professional-stroke-core-design.md`.
6. `16-reference-sheet.md` for as-built details not intentionally replaced
   here.
7. Earlier brush documents as historical reasoning.

This design preserves the original product's load-bearing invariants. It
intentionally changes the following prior decisions:

- iPadOS becomes the primary product target rather than a continuously
  buildable secondary target. The new engine baseline is iPadOS 18+.
- The long-term renderer is decomposed instead of continuing to grow the
  current `GridRenderer` monolith.
- Procreate conversion moves forward as an early internal conformance tool
  instead of remaining deferred user-facing import.
- The public Brush Studio is not an early milestone. An internal Brush Lab
  provides authoring and diagnostics first.
- Existing bounded wash is an anchor and compatibility behavior, not the
  final wet-media architecture.
- Wet Mix and smudge use a canvas-interaction backend. Full physical fluid
  simulation remains outside scope.

No existing functional or seam gate is weakened by this design.

## 3. Goals

1. Make built-in dry brushes hold the `realtime120` performance tier on the
   reference M-series ProMotion iPad.
2. Maintain a 60 Hz floor on the oldest supported performance-class device,
   initially represented by A14-class hardware.
3. Preserve deterministic output from normalized actual samples, brush
   definition, stroke seed, color, size, and document state.
4. Make shape, grain, placement, dynamics, rendering, interaction, symmetry,
   and input independent modules with explicit contracts.
5. Support professional dry media before expanding to wet interaction.
6. Design Wet Mix and smudge into the architecture now and implement them
   after the dry-media quality gate.
7. Compile brush settings and resources before the input-to-pixel path.
8. Provide a versioned native brush format that is independent of UI and
   foreign formats.
9. Convert foreign brushes with explicit exact, approximated, unsupported, and
   resource-resampled diagnostics.
10. Test the engine through pure traces, offscreen Metal rendering, image
    comparison, invariants, stress workloads, and hardware instrumentation.

## 4. Non-Goals

- A polished public brush editor in the first implementation program.
- A brush marketplace, cloud distribution, or licensed brush catalog.
- Runtime dependency on Procreate files or Procreate installation.
- Bundling or redistributing third-party brush assets.
- Pixel-identical reproduction of another application's proprietary
  renderer.
- Retained/vector stroke document storage.
- Changing canonical pixels when the document's tiling mode changes.
- Full Navier-Stokes fluid simulation or physically complete pigment models.
- Apple-specific tile shaders, sparse textures, or GPU-side symmetry
  projection before portable implementations are measured.
- Making every arbitrary imported brush satisfy the 120 Hz tier.

## 5. Product And Document Invariants

1. Canonical raster pixels remain the retained document source of truth.
2. Tiling and finite radial symmetry remain document metadata.
3. Changing tiling or symmetry never rewrites committed canonical pixels.
4. World-space path interpolation and brush dynamics occur before projection.
5. CPU and GPU projection agree at boundaries and use the existing half-open
   coordinate conventions.
6. Drawing in any visible repeated cell edits the same canonical content
   dictated by the active projection.
7. An active stroke remains discardable until pointer-up.
8. Pointer-up creates exactly one raster history command; pointer-cancel
   creates none.
9. Preview and commit use the same coverage and compositing equations.
10. Failed parsing, compilation, allocation, encoding, or GPU execution leaves
    the last committed document revision intact.
11. Cold-path decoding, texture preparation, shader compilation, and file I/O
    never occur in the input-to-pixel path.
12. Completed stroke length does not increase per-frame live-stroke work.
13. Actual samples alone determine canonical pixels. Prediction is transient
    and replaceable.
14. Random behavior is reproducible and independent of wall-clock time,
    process hash randomization, collection iteration order, or UUID creation.
15. Brush selection is captured at pointer-down. Mid-stroke editor changes
    affect only the next stroke.
16. The same evaluated logical stamp is transformed through every symmetry
    copy. A rotated or mirrored copy rotates or mirrors its direction, tip,
    scatter frame, and grain frame.
17. Symmetry does not rerun spacing, dynamics, or random generation for each
    copy.
18. Erase shares the brush footprint and dynamics system but uses
    destination-out accumulation and never deposits brush color.
19. No imported behavior is silently approximated.

## 6. Why A Stamp-First Engine

Procreate publicly documents brushes in terms of shape sources, grain sources,
stroke placement, stabilization, taper, rendering, Wet Mix, color dynamics,
input dynamics, Pencil response, and properties. Shape stamps remain the core
primitive even when the resulting media appears continuous.

Laya therefore keeps a stamp-first model:

```text
normalized input
  -> path and stabilization
  -> spacing and logical dab emission
  -> dynamics evaluation
  -> evaluated stamp coverage
  -> symmetry/tiling projection
  -> accumulation backend
  -> live stroke surface
  -> canonical commit
```

This model does not imply a simplistic sequence of CPU-generated circles. A
logical stamp may use affine shape deformation, multiple textures, canvas- or
stroke-anchored grain, scatter, color variation, edge treatment, destination
sampling, and carried paint state. The brush compiler specializes these
features into a bounded execution program.

## 7. Architecture

### 7.1 Module Ownership

#### PatternEngine

PatternEngine remains platform-free and owns:

- normalized brush input values;
- actual, coalesced, predicted, and estimated-update provenance;
- stabilization and attributed path interpolation;
- spacing and logical dab emission;
- deterministic random streams;
- brush-definition value types;
- dynamics mappings and curve evaluation;
- logical dab batches;
- symmetry-independent stamp frames;
- replay decisions and authoritative stroke state.

It imports no UIKit, AppKit, SwiftUI, Metal, or MetalKit.

#### EditorCore

EditorCore owns:

- selected brush identity and user-facing metadata;
- semantic size, opacity, color, tool, and mode intent;
- stroke-configuration capture in edit transactions;
- enable state and command routing;
- references to native brush definitions, not compiled Metal resources.

#### MetalRenderer

MetalRenderer owns:

- brush compilation for a concrete Metal device;
- texture decode products and GPU resource residency;
- pipeline specialization and caches;
- deposition and canvas-interaction backends;
- transient prediction and authoritative live surfaces;
- symmetry/tiling projection consumption;
- canonical commit;
- GPU timing, counters, offscreen rendering, and failure containment.

#### Pattern App

Platform adapters own:

- `UITouch` and `NSEvent` extraction;
- Pencil, mouse, and tablet capability discovery;
- batching coalesced and predicted samples;
- screen/drawable coordinate conversion at the platform boundary;
- the internal Brush Lab interface.

Device adapters contain no interpolation, brush dynamics, tiling, material,
randomness, or history policy.

#### BrushConverter

A separate shared library and command-line executable own:

- defensive foreign-container parsing;
- `ForeignBrushIR`;
- semantic mapping into native brush definitions;
- compatibility and resource-cost reporting;
- writing `.layabrush`.

The production app reads `.layabrush`; it does not parse Procreate files.

### 7.2 Renderer Decomposition

`GridRenderer` remains a temporary facade while responsibilities move into:

- `BrushCompiler`
- `BrushResourceCache`
- `StrokeRenderCoordinator`
- `DepositionEncoder`
- `CanvasInteractionEncoder`
- `LiveStrokeSurfaces`
- `FrameScheduler`
- `BrushTelemetry`

The facade may coordinate these components, but it must no longer implement
brush parsing, dynamics, resource construction, input processing, both
backends, history integration, and display scheduling in one file.

## 8. Normalized Input

The input model must represent:

- position and timestamp;
- normalized pressure;
- altitude and azimuth;
- roll or barrel rotation when available;
- tangential pressure when available;
- estimated-property updates;
- source device and capability flags;
- actual, coalesced, predicted, or estimated-update provenance;
- derived world-space velocity and direction.

iPad uses Pencil-capable `UITouch` values plus coalesced and predicted touches.
macOS uses native tablet-event values when a Wacom or compatible driver
exposes pressure, tilt, rotation, and tangential pressure. Missing capabilities
remain absent; they are not replaced with misleading device data. Recipes
define explicit defaults or alternate mappings for absent inputs.

Predicted samples render into a replaceable tail. They never advance the
authoritative interpolator, spacing carry, deterministic random cursor,
reservoir, history, or canonical pixels. When actual samples arrive, the
prediction tail is cleared and rebuilt from the last authoritative checkpoint.

Input traces use this normalized representation so a recorded Pencil or Wacom
stroke can be replayed without the UI or original hardware.

## 9. Native Brush Model

### 9.1 BrushDefinition

`BrushDefinition` is immutable, versioned, Codable, and renderer-independent.
It contains:

- identity, name, author/provenance, schema version, and capability flags;
- one or more shape resources and their combination policy;
- one or more grain resources and their anchoring/movement policy;
- placement settings such as spacing, jitter, scatter, rotation, and offset;
- stabilization and taper;
- dynamics mappings from input and stroke state to brush outputs;
- color behavior;
- material and rendering configuration;
- Wet Mix or smudge configuration when present;
- size, opacity, spacing, and resource limits;
- deterministic seed policy;
- performance intent and compatibility metadata.

Mappings support bounded sources such as pressure, tilt, azimuth, roll,
velocity, direction, stroke distance, stroke age, and deterministic random
values. A mapping applies an explicit curve, scale, clamp, optional inversion,
and optional jitter. Curves compile into fixed-size lookup tables or equivalent
specialized functions.

### 9.2 CompiledBrush

`BrushCompiler` transforms a `BrushDefinition` and a device capability profile
into an immutable `CompiledBrush` containing:

- validated and normalized settings;
- a compact dynamics program;
- backend selection;
- specialized pipeline keys and function constants;
- immutable uniform templates;
- prepared tip/grain texture pyramids;
- resource residency requirements;
- a capability and approximation report;
- a measured or estimated performance tier.

Compilation is asynchronous and cancelable. Selecting an uncompiled brush
leaves the previous brush active until compilation succeeds. A loading or
error state is visible in Brush Lab. Stroke handling never waits for
compilation.

### 9.3 `.layabrush`

The native package contains:

- a versioned manifest;
- a `BrushDefinition`;
- lossless source textures or other declared resources;
- content hashes;
- optional generated preview and provenance metadata.

Device-specific compiled textures and Metal pipelines are caches, never the
portable source of truth. Unknown future manifest fields are ignored when
safe; unsupported required capabilities produce an explicit load failure.

## 10. Logical Dab And Symmetry Semantics

A `LogicalDab` is generated once from the authoritative path. It contains the
fully evaluated stamp frame and material inputs before document projection:

- center and tangent frame;
- affine size, aspect, rotation, and shape transform;
- flow and opacity contribution;
- shape/grain coordinates and anchoring;
- scatter offset;
- color adjustment;
- material parameters;
- deterministic random outputs;
- conservative world-space bounds.

The active compiled symmetry transforms the entire evaluated dab. It does not
reinterpret its direction in screen space. Therefore:

- rotated copies rotate directional tips, grain, scatter, and stroke-facing
  texture;
- mirrored copies mirror handed features and preserve the mathematically
  correct reflected frame;
- every copy shares the same logical spacing and random decisions;
- projected fragments preserve seam-continuous coordinates.

For later Wet Mix under finite radial symmetry, each copy samples its own
destination footprint. A shared logical reservoir evolves once per logical
dab using an order-independent aggregate of copy pickup, so results do not
depend on transform enumeration order. Periodic fragments that refer to the
same canonical location do not duplicate reservoir interaction.

## 11. Material Model

Materials are composed from four independent concepts.

### 11.1 Coverage

Coverage determines where a stamp exists:

- shape source and optional secondary shape;
- hardness and edge falloff;
- aspect, rotation, deformation, and scatter;
- grain sampling and anchoring;
- texture modulation;
- tip threshold and antialiasing.

### 11.2 Accumulation

Accumulation determines how repeated coverage builds:

- opaque deposition;
- flow-based buildup;
- uniform glaze;
- intense glaze;
- constant-opacity or accumulation-limited behavior;
- destination-out erase.

Stroke opacity is applied once at the live-surface composition boundary unless
the selected rendering model explicitly specifies another semantic.

### 11.3 Interaction

Interaction determines whether the brush reads or modifies existing paint:

- none;
- pickup;
- smudge/drag;
- wet dilution, charge, pull, and carried-paint exchange.

### 11.4 Edge Treatment

Edge treatment adds dry breakup, marker overlap character, wet edge
concentration, bleed-like softening, or other bounded edge behavior without
changing path generation.

This decomposition allows a tip, grain, and dynamics configuration to be used
for paint, erase, or smudge while changing only the material behavior.

## 12. Narrow Hybrid Renderer

The engine has one shared front half and two accumulation backends.

```text
Input -> Path -> Dynamics -> LogicalDabBatch -> Projection -> Coverage
                                                         |
                              +--------------------------+------------------+
                              |                                             |
                    DepositionBackend                         InteractionBackend
                    dry/ink/glaze/erase                       smudge/Wet Mix
```

### 12.1 DepositionBackend

Dry, ink, glaze, marker, airbrush, and erase use specialized instanced render
pipelines:

- logical dabs are batched;
- projection expands them into the required canonical fragments or supplies
  transform tables to instancing;
- brush selection chooses a pipeline once per batch;
- shader variants remove unused per-pixel branches;
- one shape/grain resource set remains bound across a stroke batch;
- buffers are preallocated rings and grow only on bounded cold paths.

### 12.2 InteractionBackend

Smudge and Wet Mix use ordered dirty-tile compute:

- only tiles intersecting the evaluated footprint plus its bounded interaction
  halo are touched;
- destination reads and writes use explicit ping-pong or equivalent
  hazard-safe storage;
- logical dab order is preserved;
- carried brush state is bounded;
- no ordinary stroke triggers a full-canvas simulation;
- interaction work may be split across frames without changing the
  authoritative ordering.

This is not two unrelated brush engines. Coverage, input, path, dynamics,
randomness, textures, projection, live-stroke ownership, commit, and telemetry
remain shared. Backend selection happens once per stroke or batch, never once
per dab or pixel.

The initial implementation builds only the portable deposition backend. The
portable interaction backend follows after dry-media quality. Apple tile
shaders, sparse textures, and additional GPU projection are admitted only
after profiling proves a material benefit.

## 13. Resource And Texture Architecture

Large brush textures are handled outside the stroke path:

1. `.layabrush` preserves the lossless source asset.
2. The compiler validates dimensions, channels, color interpretation, and
   decoded byte cost.
3. Decode, grayscale conversion where appropriate, mip generation, and
   resampling occur off the main actor.
4. Working textures use private GPU storage and device-appropriate formats.
5. The compiler chooses a working pyramid from device limits, expected maximum
   projected stamp size, visual fidelity, and the active resource budget.
6. Any resource resampling is reported; it is never a silent compatibility
   claim.

The active brush is pinned in GPU memory. Recently used compiled brushes live
in a byte-budgeted LRU cache; inactive resources are evicted under memory
pressure. Neighboring library brushes may be warmed opportunistically, but
prefetch cannot displace the active brush or block drawing.

The first portable implementation does not require virtual textures. If a
source texture cannot be represented faithfully inside the device working-set
policy, compilation returns `unsupportedResourceCost` or an explicitly
reported resampled variant. Sparse residency is considered only after measured
brushes demonstrate that ordinary mipmapped resources are insufficient.

Pipeline states are specialized and cached by content-independent pipeline
keys. The app may seed a Metal binary archive or equivalent pipeline cache,
but a missing cache affects warm-up time rather than brush semantics.

## 14. Frame Scheduling And Latency

The frame scheduler:

- follows the display's supported refresh rate rather than fixing the canvas
  to 60 Hz;
- consumes normalized sample batches within a fixed per-frame CPU budget;
- acquires the drawable late, after brush preparation;
- uses preallocated triple-buffered or equivalently synchronized uploads;
- submits authoritative work without blocking the main actor;
- renders a replaceable prediction tail for apparent latency;
- carries excess authoritative work into later frames rather than silently
  increasing spacing or removing dynamics;
- records event-to-submit, CPU preparation, GPU encoding, GPU completion, and
  missed-frame telemetry.

Quality degradation is explicit. The engine may shorten the predicted tail,
evict inactive resources, or schedule a valid brush at its declared 60 Hz
tier. It may not silently change the authoritative stamp sequence, random
stream, symmetry count, coverage, or material equation.

## 15. Performance Contract

Performance classification is per compiled brush and device capability
profile:

- `realtime120`: expected to remain within a 120 Hz frame contract on the
  reference M-series ProMotion iPad;
- `realtime60`: visually faithful and responsive, but not guaranteed to remain
  within the 120 Hz contract;
- `unsupportedResourceCost`: faithful execution cannot fit the device's
  bounded memory or latency policy.

All built-in dry brushes must qualify as `realtime120` on the reference
M-series device and sustain at least 60 Hz on the A14-class floor. Heavy
imported and Wet Mix brushes may validly report `realtime60`.

Initial regression thresholds retain the established harness budgets where
applicable:

- brush CPU preparation p95 below 2 ms for standard dry workloads;
- the established 500-dab dry GPU workload below 3 ms;
- bounded live work independent of completed stroke length;
- no synchronous input-thread file, decode, pipeline, or GPU wait.

Hardware acceptance additionally records full-frame p50/p95/p99, missed-frame
fraction, input-event-to-submit latency, GPU occupancy, memory high-water, and
thermal behavior during sustained drawing. Exact device baselines are checked
in as measured benchmark profiles rather than guessed constants. True
input-to-photon validation remains a hardware gate and cannot be claimed from
software timestamps alone.

## 16. Procreate Conversion

### 16.1 Boundary

Conversion is a separate utility:

```text
Procreate file
  -> defensive parser
  -> ForeignBrushIR
  -> semantic mapper
  -> BrushDefinition + compatibility report
  -> .layabrush
```

`ForeignBrushIR` describes discovered foreign concepts without pretending they
already have Laya semantics. It retains provenance, normalized settings,
decoded resource references, and unrecognized-field diagnostics.

The mapper classifies every meaningful setting:

- **exact:** represented with the same documented semantic;
- **approximated:** mapped with a named and quantified difference;
- **unsupported:** retained in the report but not claimed as functional;
- **resource-resampled:** behavior is supported but a source asset was
  transformed for the device or native package.

Imported Wet Mix definitions may parse and convert before the interaction
backend exists, but their required rendering capability remains unsupported.

### 16.2 Defensive Parsing

The Procreate format is undocumented and version-dependent. The parser:

- identifies containers by signatures and structure, not filename extension
  alone;
- isolates version-specific decoding from semantic mapping;
- limits archive entries, paths, nesting, dimensions, and decompressed bytes;
- rejects path traversal and malformed asset references;
- treats files as untrusted input;
- is fuzzed independently of the application;
- preserves enough diagnostics to add later format variants without changing
  `.layabrush`.

The implementation may learn from independently developed interoperability
work, including Krita's Procreate import experiments, while avoiding copied
source unless its license is deliberately accepted and recorded.

Conversion is local and user-initiated. Laya distributes neither Procreate
brushes nor third-party brush artwork, bypasses no encryption or access
control, and makes no claim that converted output is endorsed by Procreate.
This is an engineering boundary, not legal advice; distribution decisions
still require an appropriate legal review.

## 17. Internal Brush Lab

The first editor is an internal engineering and calibration tool. It provides:

- native brush and converted-brush loading;
- grouped semantic settings;
- shape and grain previews;
- a live drawing pad using the production engine;
- normalized input and logical-dab trace inspection;
- deterministic seed controls;
- actual versus predicted tail visualization;
- symmetry and tiling test modes;
- compiled pipeline and resource summaries;
- exact/approximated/unsupported import diagnostics;
- CPU/GPU timing, dab count, dirty-tile count, texture residency, cache
  pressure, and frame percentiles;
- export of reproducible trace bundles and rendered evidence.

The Brush Lab is allowed to expose technical terminology and raw diagnostics.
No effort is spent polishing it into the final public Brush Studio until the
engine and brush families meet the quality bar.

## 18. Testing And Verification

### 18.1 Pure Tests

Pure tests cover:

- input normalization and missing-capability defaults;
- coalesced, predicted, actual, and estimated-update ordering;
- pressure/tilt/velocity/direction curve evaluation;
- dynamic spacing and interpolation;
- deterministic random streams and stable seed consumption;
- taper, scatter, rotation, and affine stamp frames;
- recipe validation, migration, and compilation decisions;
- performance-tier classification logic;
- foreign parsing limits and semantic compatibility reports.

### 18.2 Trace Replay

Versioned traces contain normalized input, brush definition hash, seed, color,
size, projection configuration, and expected logical dab summaries. They run
without SwiftUI, AppKit, UIKit, Pencil, Wacom, or manual interaction.

The same trace must:

- emit the same authoritative logical dabs;
- preserve random values when prediction is added or removed;
- remain bounded for arbitrarily long strokes;
- cancel without output;
- produce one transaction at completion.

### 18.3 Offscreen Metal Harness

The existing offscreen harness expands to test:

- every built-in brush family;
- draw, erase, glaze, and later interaction backends;
- maximum supported stamp sizes;
- shape and grain mip selection;
- seams under every periodic symmetry;
- finite radial rotation and reflection;
- prediction replacement and replay;
- preview/commit equality;
- large-resource selection and cache eviction;
- device allocation and encoder failure;
- wet dirty regions and halos when that backend arrives.

Positive scenes have deliberate negative controls. Thresholds are not loosened
to accept a new renderer.

### 18.4 Metamorphic And Differential Tests

Useful invariants include:

- translating an input trace by a tiling period preserves folded pixels;
- changing display zoom does not alter canonical brush output;
- prediction on versus off produces identical committed pixels;
- batching the same logical dabs differently produces identical output;
- symmetry transform order does not change output;
- CPU reference coverage agrees with GPU coverage within declared tolerance;
- old and new dry paths agree for compatibility brushes before the old path is
  removed.

Converted brushes are compared with manually captured reference strokes from
the source application using fixed settings and normalized test gestures.
Because the foreign renderer is proprietary, these comparisons grade semantic
and perceptual behavior rather than claiming universal pixel identity.

### 18.5 Performance And Hardware Tests

Automated workloads include:

- rapid short strokes and taps;
- long continuous strokes;
- high-frequency direction changes;
- maximum-size tips;
- high scatter and low spacing;
- maximum supported symmetry multiplication;
- large texture selection churn;
- sustained ten-minute drawing for thermal and cache behavior;
- later, wide wet strokes with worst-case dirty halos.

iPad hardware validates Pencil pressure, tilt, azimuth, prediction, ProMotion,
latency, memory warnings, suspend/resume, and thermal behavior. macOS hardware
validates mouse fallback and Wacom capabilities exposed through native tablet
events.

## 19. Error Handling

- Invalid native definitions fail validation before GPU allocation.
- Missing optional resources use only an explicitly declared fallback.
- Missing required resources fail compilation.
- Unsupported foreign settings remain visible in the compatibility report.
- Oversized foreign archives or images fail with bounded diagnostic errors.
- Pipeline compilation failure leaves the previously compiled brush active.
- Mid-stroke device or encoder failure discards transient work and preserves
  the last committed revision.
- Memory pressure evicts inactive caches first. If the active brush cannot
  remain resident, the stroke does not start and the UI reports the reason.
- No partial brush package is installed. Conversion writes atomically.
- Telemetry and errors include brush hash, backend, pipeline key, resource
  bytes, device profile, and stage without including third-party asset
  contents.

## 20. Rollout

### Stage 1: Characterization Baseline

- Capture deterministic traces, reference images, logical dab streams, seam
  evidence, memory, and timing for current brushes.
- Preserve current tests and add missing negative controls.

### Stage 2: Engine Foundation

- Add the normalized input model, immutable `BrushDefinition`, `.layabrush`,
  deterministic dynamics program, `LogicalDabBatch`, compiler, resource cache,
  and current-brush compatibility adapter.
- Produce no intended pixel change for compatibility brushes.

### Stage 3: Converter And Brush Lab Foundation

- Add the shared converter library, CLI, `ForeignBrushIR`, compatibility
  reports, defensive corpus, and the diagnostic Brush Lab shell.
- Load native and converted definitions through the compatibility adapter so
  real foreign settings and assets exercise the compiler before the new
  renderer is considered complete.
- Parse foreign wet settings but do not claim them as supported.

### Stage 4: Deposition Backend

- Add specialized dry, ink, glaze, marker, airbrush, and erase pipelines.
- Compare old and new paths through trace and offscreen evidence.
- Remove the old brush path after compatibility gates pass.

### Stage 5: Professional Dry-Media Gate

- Calibrate ink, pencil, charcoal, and marker anchor families.
- Require every built-in dry brush to pass functional, seam, perceptual,
  memory, and `realtime120` gates.

### Stage 6: Canvas-Interaction Backend

- Add ordered dirty-tile smudge and Wet Mix.
- Add reservoir, pickup, pull, dilution, charge, edge, and halo conformance.
- Promote converted wet brushes only when their required capabilities pass.

### Stage 7: Product Calibration

- Expand the built-in library.
- Tune Pencil and Wacom behavior on hardware.
- Remove temporary comparison code.
- Design the public Brush Studio only after the engine stabilizes.

This is a program-level architecture. Each stage is independently planned,
reviewed, and committed; the next implementation plan covers Stages 1 and 2,
and later stages receive their own plans. A later stage does not bypass the
correctness gates of an earlier stage merely because hardware performance
evidence is pending.

## 21. Acceptance

The architecture is accepted when:

- the existing raster, transaction, history, tiling, and symmetry invariants
  remain intact;
- built-in dry brushes meet their quality and performance contracts;
- authoritative output is deterministic and independent of prediction;
- large resources never decode or upload during stroke input;
- the deposition and interaction backends share one logical brush front half;
- Procreate conversion emits honest compatibility reports and native packages;
- Brush Lab and offscreen tests reproduce issues without interactive UI;
- failures preserve committed document state;
- no compatibility or performance degradation is silent.

## 22. Research References

- [Procreate Brush Studio Settings 5.4](https://help.procreate.com/procreate/handbook/5.4/brushes/brush-studio-settings)
- [Adobe Photoshop Mixer Brush](https://helpx.adobe.com/photoshop/using/painting-mixer-brush.html)
- [Adobe Fresco Mixer Brushes](https://helpx.adobe.com/fresco/desktop/draw-paint-animate-and-share/mixer-brushes.html)
- [Krita Pixel Brush Engine](https://docs.krita.org/en/reference_manual/brushes/brush_engines/pixel_brush_engine.html)
- [Krita Color Smudge Brush Engine](https://docs.krita.org/en/reference_manual/brushes/brush_engines/color_smudge_engine.html)
