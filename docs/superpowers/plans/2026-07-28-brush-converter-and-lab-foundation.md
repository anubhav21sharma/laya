# Stage 3: Brush Converter And Brush Lab Foundation

**Date:** 2026-07-28
**Status:** Approved for implementation by the user's instruction to continue Stage 3
**Depends on:** `2026-07-26-world-class-brush-engine-design.md` and the completed
Stage 1–2 foundation milestone
**Scope:** Stage 3 only

## Goal

Deliver a format-neutral foreign-brush conversion pipeline, a command-line
converter, persistent compatibility diagnostics, a defensive Procreate parser
boundary, and an internal Brush Lab shell. Converted brushes must become normal
native `.layabrush` packages before they reach the compiler or drawing engine.

This stage exercises the Stage 2 definition, package, compiler, resource, and
compatibility seams. It does not add the Stage 4 deposition renderer or the
Stage 6 canvas-interaction backend.

## Non-Negotiable Boundaries

1. Foreign parsing never runs on the pointer, Pencil, Wacom, render, or frame
   scheduling path.
2. The app and renderer never consume Procreate dictionaries, keys, archives,
   or raw object graphs.
3. The converter emits a validated `BrushDefinition`, normalized native
   resources, and a structured compatibility report.
4. Every meaningful discovered rendering setting has exactly one disposition:
   `exact`, `approximated`, `unsupported`, or `resourceResampled`.
5. An unsupported required semantic is copied into
   `BrushCompatibilityMetadata.requiredSemanticKeys`; the existing compiler
   must continue to reject activation.
6. Wet settings are parsed and retained, but Wet Mix activation remains
   unsupported until Stage 6.
7. Third-party resource bytes never appear in diagnostics, logs, IR values, or
   test snapshots.
8. Conversion writes atomically through `BrushPackageIO`; no partial package is
   installed.
9. The parser is selected by signature and structure, not filename extension.
10. No third-party brushes or default Procreate assets are checked into the
    repository without explicit redistribution permission.

## Architecture

```text
untrusted foreign bytes
        |
        v
bounded container + plist readers
        |
        v
version-isolated ForeignBrushParser
        |
        v
ForeignBrushDocument
  - validated ForeignBrushIR
  - resource payload table
        |
        v
ForeignBrushMapper
        |
        +----> BrushConversionReport
        |
        v
BrushDefinition + normalized resources
        |
        v
BrushPackageCodec / BrushPackageIO
        |
        v
native .layabrush v2
        |
        +----> Brush Lab diagnostics
        |
        v
existing BrushProgramCompiler / BrushCompiler
```

`BrushConverter` depends on `PatternEngine`, `BrushFormat`, and the bounded
archive layer. It does not depend on `MetalRenderer`, SwiftUI, AppKit, or UIKit.
The `layabrush-convert` executable depends on `BrushConverter`. Brush Lab is a
thin app-facing consumer of native packages, reports, and existing compiler
diagnostics.

## Decisions Pinned By This Plan

### Native package report persistence

`.layabrush` manifest schema v2 adds an optional descriptor for
`conversion-report.json`. The descriptor records the canonical path, SHA-256,
and encoded byte count. `BrushPackage` exposes an optional decoded
`BrushConversionReport`.

- Report-free packages continue to encode as manifest v1 so older readers are
  not broken unnecessarily. A package with a report encodes as manifest v2.
- Manifest v1 packages remain readable and produce `conversionReport == nil`.
- A v1 manifest cannot reference a report.
- A v2 report descriptor and archive entry must either both exist or both be
  absent.
- The codec rejects a missing, extra, malformed, oversized, or hash-mismatched
  report.
- The report is capped at 2 MiB encoded.
- New converter output uses deterministic sorted-key JSON. A decoder preserves
  the original validated report bytes and re-emits them unchanged instead of
  requiring another OS/Foundation version to reproduce byte-identical JSON.
- The report is part of package equality and atomic save/reopen verification.
- The report does not change the renderer/cache content hash. Rendering truth
  remains the validated native definition and resources.
- Activation truth is not report-only: unsupported required entries must equal
  the definition's sorted `requiredSemanticKeys`.

This is not a sidecar. Moving or sharing a `.layabrush` retains its conversion
diagnostics.

### Conversion report contract

`BrushConversionReport` is owned by `BrushFormat` because it is persisted in a
native package. It contains:

- report schema version;
- source format/version and source content SHA-256;
- converter identifier/version;
- target definition ID and native package semantic hash;
- sorted, unique compatibility entries;
- sorted, bounded parse diagnostics;
- a summary count for each disposition.

Each compatibility entry contains:

- stable source semantic key;
- zero or more sorted native semantic keys;
- disposition;
- bounded source and target summaries;
- a stable reason code and bounded human-readable message;
- optional structured approximation evidence;
- optional structured resource-transform evidence;
- `requiredForFaithfulRendering`.

Approximation evidence identifies its metric and records at least one finite
absolute or relative error. Resource-transform evidence
records the native resource ID, source/target media types and dimensions, plus
named operations such as resize, transcode, channel normalization, inversion,
orientation correction, or color-profile conversion.

The report validator enforces:

- deterministic ordering and unique source semantic keys;
- finite numeric evidence;
- bounded strings and entry counts;
- evidence appropriate to the selected disposition;
- exact agreement between required unsupported entries and
  `requiredSemanticKeys`;
- exact coverage of `sourceSettingKeys` by report entries;
- target identity agreement with the native definition/package hash;
- resource-transform target agreement with the packaged resource descriptor.

### Foreign intermediate representation

`ForeignBrushIR` is format-neutral and versioned. It stores:

- source and parser provenance;
- source brush identity, name, and author;
- sorted, unique typed settings;
- sorted, unique resource descriptors;
- sorted parse diagnostics.

Setting values are a closed `Codable` enum: boolean, integer, finite scalar,
token, vector, curve, color, or resource reference. Settings include an
explicit unit/domain and a bounded container-relative location. They never
contain `Any`, raw plist graphs, or `Data`.

Resource descriptors include role, media identity, content hash, encoded size,
dimensions, channel/color interpretation, inversion, and orientation. Payloads
live in a separate `ForeignBrushDocument.resourceData` table keyed by resource
ID. `ForeignBrushDocument` is a validated in-memory parser/mapper boundary, not
a `Codable` payload container; only the bounded, payload-free IR has a
deterministic JSON representation.

Unknown keys in known rendering dictionaries are meaningful and become
`unsupported` unless a version parser explicitly classifies them as metadata.
Unknown metadata is retained as an informational parse diagnostic.

### Semantic keys

Source keys use a stable versioned namespace:

```text
procreate.<format-family>.v<adapter-major>.<document-path>
synthetic.v1.<document-path>
```

Native keys use the existing definition paths, for example:

```text
placement.baseSpacingFraction
dynamics.size
coverage.shapes[0]
material.interaction
```

One source setting may map to multiple native keys. It still receives one
source-key disposition containing all target keys.

Native keys are checked against a versioned `BrushDefinition` semantic-key
registry. An ASCII-looking but unknown or malformed path is not accepted as an
`exact` mapping.

### Wet imports

Wet values are represented in the IR and mapped into the closest validated
native interaction definition. The definition declares the appropriate
required capability and required semantic key. Its report entries are
`unsupported` and required for faithful rendering. The package can be loaded
and inspected, but compilation cannot activate it until Stage 6.

### Foreign-input limits

Foreign limits are separate from the smaller native-package limits:

| Limit | Value |
|---|---:|
| source file bytes | 512 MiB |
| entries per container | 4,096 |
| aggregate entries across nested containers | 4,096 |
| nested container depth | 2 |
| cumulative expanded bytes | 1 GiB |
| expanded bytes per entry | 256 MiB |
| maximum compression ratio | 200:1 |
| path bytes | 1,024 |
| plist/object graph depth | 64 |
| dictionary or array elements | 16,384 |
| total graph nodes per brush | 100,000 |
| total collection references per brush | 100,000 |
| total resolved keyed-archive UID references per brush | 100,000 |
| string bytes | 64 KiB |
| opaque data value bytes | 256 MiB |
| settings per brush | 4,096 |
| curve points per setting | 1,024 |
| brushes per set | 512 |
| resources per brush | 64 |
| source image dimension | 16,384 |
| cumulative decoded pixels per brush | 268,435,456 |

The decoder stops while producing output when a limit is crossed; it does not
trust archive-declared expanded sizes. Encryption, unsupported flags, unsafe
paths, symlinks, duplicate normalized paths, invalid CRCs, malformed ZIP64,
cycles, invalid or dangling plist UIDs, non-finite numbers, and dangling resource
references fail closed.

The existing stored-entry `SafeArchive` behavior used by native packages stays
unchanged. Foreign deflate support is isolated behind the converter boundary so
it cannot silently broaden `.layabrush` decoding. Foreign ZIP parsing initially
accepts stored and raw-deflate entries, the UTF-8 name flag, and deflate option
flags only. It rejects data descriptors until an owned Procreate fixture proves
they are required. Names without the UTF-8 flag must be ASCII, and normalized
NFC paths are checked for duplicates before extraction.

Property lists are parsed directly from bytes into a converter-owned immutable
graph; neither `PropertyListSerialization` nor `NSKeyedUnarchiver` is a security
boundary. Binary-property-list offsets, record extents, lengths, references,
and all records (including unreachable records) are validated before semantic
mapping. Traversal is iterative, collection and UID edges have independent
budgets, acyclic sharing is allowed, and cycles fail closed.

UIDs remain inert values. A separate bounded keyed-archive view recognizes only
the explicitly supported `NSKeyedArchiver` envelope, resolves bounded in-range
UID references without instantiating classes, and exposes whitelisted graph
shapes to version-specific adapters. XML property lists use a plist-specific
streaming parser. They accept only the exact standard Apple plist doctype
without entity resolution and reject other doctypes, entity declarations,
namespaces, CDATA, and non-plist markup.

### Procreate variants and evidence

Procreate's format is undocumented and version-dependent. Each supported
layout gets a separate adapter behind `ForeignBrushParser`.

The support matrix distinguishes legacy exported `.brush`/`.brushset`
containers from Procreate 5.4's Files/iCloud organization, where individual
`.brush` files live inside folder-based libraries and sets. Neither layout is
treated as one frozen official archive specification.

The initial structural adapter recognizes only independently observed
exported-container shapes: an archive containing brush resources and a binary
property-list `Brush.archive`, or a legacy set with `brushset.plist` and member
brush directories. Recognition alone is not semantic support. A setting is
mapped only after its meaning is established by:

1. controlled one-setting-at-a-time source-application experiments;
2. at least two independently created samples when the setting permits;
3. a checked-in byte-free fixture description or a redistributable fixture;
4. a stable adapter key and a conversion test.

Unverified fields are reported as unsupported, never guessed from their names.
The implementation may study GPL interoperability work, but it will not copy
GPL source into this project unless that license decision is separately
approved and recorded.

The first evidence-backed support boundary is intentionally narrow:

- structural inspection and import reporting;
- main-brush metadata and preview;
- embedded custom shape/grain extraction and PNG validation;
- dry single-stamp spacing, size, and opacity bounds;
- shape/grain orientation and inversion;
- pressure size/opacity curves only after controlled fixtures establish their
  units and formulas.

Dual/sub-brushes, moving grain, glaze/rendering modes, Wet Mix, color dynamics,
tilt/azimuth/barrel roll, taper, stabilization, material channels, and
unavailable default Source Library resources remain explicitly unsupported
until their semantics and assets are established. They are never silently
downgraded into a generic stamp.

### Brush-set conversion and CLI behavior

One input may yield multiple `.layabrush` packages. Each brush converts and
writes atomically. A failed brush does not delete successful siblings; the
process returns a nonzero status and writes a machine-readable batch report.

Default output names are sanitized display names plus a short source hash.
Existing files are not overwritten unless `--replace` is supplied. Diagnostics
go to stderr; stdout is reserved for the stable JSON result when `--json` is
used. No network access occurs.

Pixel-preserving lossless normalization is still classified
`resourceResampled` because the approved taxonomy uses that term for any
source-asset transformation. The structured operations distinguish a pure
transcode from resize or color/channel changes.

## Implementation Tasks

### Task 1 — Persist honest conversion reports in `.layabrush`

Add:

- `Sources/BrushFormat/BrushConversionReport.swift`
- manifest v2 report descriptor;
- optional report ownership in `BrushPackage`;
- deterministic sorted-key encoding for newly generated reports, plus decoding
  and byte-preserving re-emission of any hash-bound valid JSON representation
  in `BrushPackageCodec`;
- v1 decode compatibility;
- report validation and report/package cross-validation.

Tests first cover:

- valid report round-trip and deterministic bytes;
- v1 decode to a package without a report, including a frozen archive produced
  at the Stage 2 commit;
- v1-with-report rejection;
- missing/extra report entry;
- hash, byte-count, schema, JSON, ordering, duplication, bounds, and non-finite
  failures;
- source-setting and required-semantic coverage mismatch;
- semantic renderer hash unchanged by diagnostic-only report metadata.

Commit boundary: `feat(brush-format): persist conversion reports`

### Task 2 — Add the converter core and validated IR

Add SwiftPM products/targets:

- `BrushConverter`;
- `BrushConverterTests`;
- `layabrush-convert`.

Implement the validated IR, provenance, typed values, resource descriptors,
diagnostics, parser/mapper protocols, and deterministic encoders. Introduce no
Procreate keys yet.

Tests cover all bounds, ordering, uniqueness, finite values, resource-table
agreement, deterministic encoding, and absence of UI/Metal dependencies.

Commit boundary: `feat(converter): add foreign brush IR`

### Task 3 — Prove semantic coverage with a synthetic adapter

Add a small synthetic v1 foreign format used only by tests and the CLI's
diagnostic mode. Map shape, grain, spacing, flow, opacity, size pressure,
rotation, scatter, accumulation, and a deliberately unsupported wet setting.

The mapper must:

- create only validated native definitions;
- produce one disposition per meaningful setting;
- populate `sourceSettingKeys` exactly;
- populate `requiredSemanticKeys` exactly;
- normalize resources and record transformations;
- round-trip through `.layabrush`;
- activate supported dry output through the existing compiler in integration
  tests;
- load but reject activation for the wet fixture.

Compiler activation is the Stage 3 boundary for packages with custom converted
shape or grain resources. Their native `BrushProgram` intentionally has no
legacy `compatibilityRecipe`, because the legacy renderer only recognizes its
fixed built-in asset IDs. Stage 4 wires compiled custom textures into
deposition. A separate built-in-only synthetic fixture proves exact reverse
adapter parity without weakening the legacy asset allowlist.

Commit boundary: `feat(converter): map typed foreign brushes`

### Task 4 — Add the defensive foreign container and plist layer

Implement bounded ZIP structure probing and streaming stored/deflate reads
inside `BrushConverter`. Reuse or factor native path/CRC/ZIP64 checks without
changing the native codec's accepted compression policy. Keep data descriptors
disabled until fixture evidence requires them, enforce aggregate entry and
expanded-byte budgets across nested containers, and verify actual streamed
output length, compression ratio, end state, input consumption, and CRC.

Parse XML and binary property lists directly from bytes into a bounded
converter-owned allowed-type graph. Do not use `PropertyListSerialization` or
`NSKeyedUnarchiver` in the untrusted-input path. Treat UIDs as inert references
and expose them only through a bounded, cycle-checked keyed-archive view that
never instantiates source classes.

Add a byte-oriented defensive corpus for signatures, traversal, duplicate
paths, symlinks, encryption, flags, CRC, ZIP64, compression bombs, nesting,
plist offsets/extents, hidden malformed records, cycles/UIDs/depth/counts,
collection-reference budgets, external-entity attempts, non-finite numbers,
strings/data, and dangling assets. Boundary tests use injectable small limits
and run twice to prove deterministic outcomes.

Commit boundary: `feat(converter): bound foreign brush parsing`

### Task 5 — Add version-isolated Procreate adapters

Implement structure recognition, resource extraction, source provenance, and
only evidence-backed semantic keys. Keep classic exported archives and newer
5.4 storage/export layouts isolated when their structures differ.

Add converter-owned fixture manifests. Raw fixtures are accepted only when
they are created by the project or have explicit redistribution permission.
User-owned private brushes may be used locally for manual comparison but never
committed.

Commit boundary: `feat(converter): parse supported procreate brushes`

### Task 6 — Finish the production CLI

Implement probe, inspect, convert, batch, JSON report, output naming,
`--replace`, and stable exit statuses. Use `BrushPackageIO.save` for every
output. Validate saved output by reopening it.

Add subprocess tests for dry success, wet diagnostic output, mixed batch
results, collision handling, atomic failure, deterministic reports, and no
partial output.

Commit boundary: `feat(converter): add layabrush CLI`

### Task 7 — Add the internal Brush Lab shell

Add an internal-only window/scene that can:

- load native `.layabrush` packages;
- display conversion and compiler diagnostics;
- show shape/grain previews and definition groups;
- select deterministic seed and inspect normalized input/logical dabs;
- draw through the production canvas/renderer;
- toggle actual/predicted tail and symmetry/tiling diagnostics;
- display existing timing, dab, dirty-region, residency, cache, and frame data;
- export a reproducible trace/evidence bundle.

The shell owns no foreign parser. It receives converted native packages only.
No public Brush Studio polish or persistent library management is included.

Commit boundary: `feat(brush-lab): add diagnostic shell`

### Task 8 — Independent fuzzing and Stage 3 evidence

Add a converter-only fuzz executable/harness and corpus. It must link neither
the app nor Metal. Run deterministic corpus tests under the normal suite and
record longer fuzz campaigns separately with seed, duration, toolchain, commit,
and crash artifacts.

Add a Stage 3 evidence gate that verifies:

- all unit and integration tests;
- package v1/v2 compatibility;
- dry compile activation and wet rejection;
- defensive corpus;
- CLI atomicity;
- Brush Lab package/report loading without UI interaction;
- macOS and iPad builds/analysis;
- source, artifact, and toolchain provenance.

Commit boundary: `test(converter): add stage 3 evidence gate`

## Verification Strategy

Fast checks run after every task:

```bash
swift test --filter BrushFormatTests
swift test --filter BrushConverterTests
swift test --filter MetalRendererTests
git diff --check
```

Task-specific CLI and app tests are added as their targets exist. Before every
Stage 3 commit:

```bash
swift test --no-parallel
./scripts/bootstrap.sh
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikeMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -project App/PatternSpike.xcodeproj -scheme PatternSpikePad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedDataPad build CODE_SIGNING_ALLOWED=NO
```

The final Stage 3 gate additionally runs static analysis, the defensive corpus,
subprocess CLI tests, package round trips, offscreen compiler checks, and the
converter fuzz smoke seed set.

Manual Procreate comparisons use fixed source settings and normalized gestures.
They grade semantic/perceptual similarity and do not claim proprietary-renderer
pixel identity.

## Research Provenance

- Procreate's current handbook documents individual `.brush` files and
  folder-based brush organization from 5.4:
  <https://help.procreate.com/procreate/handbook/brushes/brush-library>
- The official Brush Studio 5.4 semantic reference is:
  <https://help.procreate.com/procreate/handbook/5.4/brushes/brush-studio-settings>
- The independently developed Krita prototype inspected for structural
  evidence is GPL-3.0-or-later at commit
  `e4015e7a994a0bcca05daed842e5dab195f1be39`:
  <https://invent.kde.org/freyalupen/procreate-to-krita-brush-converter>
- The prototype describes itself as experimental and unfinished. It is neither
  a correctness oracle nor an official format specification.
- The older Brushporter repository contains only README/license material at
  commit `acbb4199fac928469b595032006aad2b5d7294db`:
  <https://github.com/asterryplace/brushporter>

No GPL implementation is copied or translated. Production behavior is derived
from independently recorded structural observations plus controlled,
team-owned fixtures. The exact clean-room and distribution position still
requires appropriate legal review before public release.

## Spec Alignment

This plan implements design sections 16–18 and rollout Stage 3 without changing
the renderer, transaction, history, tiling, symmetry, or stroke invariants.

The manifest v2 report attachment is an implementation detail required to
fulfil the existing requirement that compatibility diagnostics survive native
package loading. Isolating compressed foreign archives from `SafeArchive`'s
native stored-entry policy narrows risk and does not change the approved
architecture.

No Stage 4 or Stage 6 feature is pulled forward. Dry conversion targets the
existing compatibility adapter. Wet settings are inspectable but remain
unactivatable.

## Completion Boundary

Stage 3 is complete only when:

- format-neutral IR and mapper contracts are validated and deterministic;
- `.layabrush` retains an honest compatibility report across save/reload;
- supported Procreate variants are signature/structure probed and
  version-isolated;
- every meaningful setting receives exactly one disposition;
- dry converted packages exercise the existing compiler successfully;
- wet packages retain settings and fail activation explicitly;
- the CLI is atomic, batch-aware, and machine-reportable;
- the defensive corpus and independent fuzzer cover the parser boundary;
- Brush Lab loads native/converted packages and exposes the required
  diagnostics without owning foreign parsing;
- existing application and renderer gates remain green.
