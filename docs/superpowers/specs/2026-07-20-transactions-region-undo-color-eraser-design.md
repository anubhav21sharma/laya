# Transactions, Region Undo, Color, And Eraser Design

**Date:** 2026-07-20
**Status:** Approved
**Slice:** 3

## 1. Purpose

Slice 3 turns the drawing kernel into an editor with one authoritative edit
lifecycle, exact bounded undo/redo, colored drawing, destination-out erasing,
undoable canvas metadata, and minimal product controls.

The slice adds:

- a total edit-transaction reducer;
- an EditorCore-owned linear command history;
- Metal-backed before/after raster revisions for changed canonical regions;
- undoable tiling and tile-size commands;
- top-left-anchored crop/fill tile resizing without scaling;
- straight-sRGB ink color;
- a live and committed destination-out eraser;
- platform-independent commands and key mapping;
- minimal draw, erase, color, history, clear, tiling, and size controls.

Slice 3 does not add professional brush dynamics, brush assets, layers,
selection interaction, transforms, persistence, export, or iPad device
acceptance.

## 2. Governing Decisions And Start Gate

`2026-07-18-pattern-product-rebuild-design.md` governs this slice. Recovered
feature documents are historical input and apply only where they do not
conflict with that approved rebuild.

Slice 2 remains `Pending Performance And Manual Acceptance`. Its functional
implementation and regression coverage permit Slice 3 work to start, but this
does not mark Slice 2 accepted or weaken any Slice 2 performance threshold.

The following recovered decisions remain valid:

- the pure edit reducer and ordered effects from
  `14-edit-transaction-module-design.md`;
- stroke-constant ink color and native `ColorPicker` from
  `08-colored-brush-design.md`;
- single-tool-per-stroke behavior, live eraser feedback, and
  destination-out committed pixels from `09-eraser-design.md`;
- commit-boundary, geometry-independent raster history from
  `10-undo-redo-design.md`;
- dirty-region capture from `notes/live-tile-perf-promotion-undo.md`;
- the established semantic key map in `16-reference-sheet.md`.

The following recovered decisions are superseded:

- full-tile, fixed-depth undo becomes changed-region history bounded by both
  100 commands and 200 MB;
- history order moves from MetalRenderer to EditorCore;
- tiling changes no longer flush history and become undoable metadata;
- tile-size changes no longer flush history and become undoable raster
  replacement commands;
- resizing never scales artwork;
- eraser strength never inherits neutral mouse pressure;
- renderer-owned or view-owned lifecycle guards are removed;
- per-dab blend-mode packing is replaced by a per-stroke composite mode.

Explicit user decisions for this slice:

- expose tile-size editing in Slice 3;
- eraser strength is model-owned, fixed at `1.0`, and has no visible control
  yet;
- resizing preserves the canonical top-left origin;
- shrinking crops the right and bottom;
- growing fills the new right and bottom area with transparent pixels;
- no resize path samples, interpolates, or scales existing pixels.

## 3. Product Invariants

1. One EditorCore reducer owns edit lifecycle and effect ordering.
2. Renderer state validates execution tokens but never decides editor policy.
3. Pointer-up produces exactly one document command after successful GPU
   completion.
4. Pointer-cancel produces no document command.
5. Failed operations leave canonical pixels, metadata, and history unchanged.
6. Undo restores exact stored bytes in every changed canonical region.
7. Redo restores the exact corresponding after bytes.
8. Tiling commands never rewrite canonical pixels or invalidate raster
   history.
9. A resize preserves every pixel in the top-left intersection byte-for-byte.
10. Live draw and erase compositing uses the same MSL function as commit.
11. Pointer-up changes no visible color, opacity, or edge coverage beyond one
    8-bit value.
12. Tool and color values are captured at stroke start and cannot change
    inside a stroke.
13. History never exceeds 100 commands or 200 MB of retained raster payload
    after a successful operation.
14. A new successful mutation clears redo; a failed mutation does not.
15. EditorCore exposes no Metal, SwiftUI, AppKit, or UIKit types.

## 4. Architecture

### 4.1 PatternEngine

PatternEngine remains the platform-free home of raster-neutral values:

- `PixelSize`;
- pixel-aligned rectangles and normalized region sets;
- `RasterRevision`;
- straight-sRGB color values;
- projected stamp geometry.

Region normalization clips rectangles to a supplied pixel size, removes empty
rectangles, and merges rectangles that overlap or touch. It does not merge
separated edge fragments into one full-width or full-height bounding box.

### 4.2 EditorCore

EditorCore owns intent and order:

- `EditorTransaction`, the total lifecycle reducer;
- semantic editor commands and platform-independent key mapping;
- `DocumentHistory`, including undo/redo cursor movement and pruning;
- typed history commands containing metadata or opaque raster revision IDs;
- observable tool, color, tile, tiling, busy, and history enable-state.

EditorCore never captures, restores, or interprets raster bytes.

### 4.3 MetalRenderer

MetalRenderer owns raster execution:

- `RasterRevisionStore`, containing opaque before/after pixel payloads;
- changed-region capture and restore;
- canonical resource replacement for resize;
- color-aware hard-round stamping;
- source-over and destination-out live/commit compositing;
- tokenized asynchronous completion results;
- GPU harness scenes and timing.

### 4.4 Pattern App

The app layer owns one main-actor session controller. It:

1. receives normalized pointer, keyboard, menu, and control intents;
2. applies them to `EditorTransaction`;
3. executes returned effects in exact array order;
4. sends renderer completion results back as reducer events;
5. coordinates `DocumentHistory` preparation and finalization;
6. reflects derived state into `EditorModel`.

Native input adapters translate platform events at the boundary. They do not
contain drawing, history, tiling, or compositing policy.

## 5. Transaction Reducer

### 5.1 State

The governing top-level states remain:

```swift
public enum EditorTransactionState: Equatable, Sendable {
    case idle
    case drawing(DrawingTransaction)
    case selectingDraft(SelectionRegion?)
    case selectionReady(SelectionRegion)
    case transforming(SelectionRegion)
}
```

`SelectionRegion` contains the unfolded canonical origin and a nonempty,
pixel-aligned folded rectangle. This preserves the raw/folded distinction
needed by later affine transforms without adding selection UI in this slice.

Slice 3 activates `idle` and `drawing`. The remaining states, values, events,
effects, and total transition behavior are installed now so later selection
work extends one lifecycle owner instead of creating another.

`DrawingTransaction` contains:

```swift
public struct DrawingTransaction: Equatable, Sendable {
    public var token: EditorTransactionToken
    public var tool: StrokeTool
    public var phase: DrawingPhase
}

public enum DrawingPhase: Equatable, Sendable {
    case collecting
    case commitPending
}
```

The reducer also owns an optional pending non-stroke operation. Therefore an
undo, redo, clear, tiling change, or resize may remain asynchronous while the
top-level edit state is `idle` without creating a second lifecycle owner.
`isBusy` is derived from drawing phase or this pending operation.

### 5.2 Events

Events cover:

- pointer began, moved, ended, and cancelled;
- tool intent;
- color intent;
- clear, undo, and redo;
- tiling intent;
- tile-size intent;
- reserved selection and transform intents;
- renderer operation success or failure;
- focus/window cancellation.

Every state/event pair returns a defined next value and an ordered effect
array. Unexpected input becomes a safe no-op or a typed busy rejection, never
an implicit renderer transition.

Reserved selection behavior follows the recovered transaction design:

- a zero-area draft remains `selectingDraft(nil)` and can never lift pixels;
- ending a nonempty draft produces `selectionReady(region)`;
- transform intent lifts only from `selectionReady(region)`;
- abandoning a draft or ready selection clears its overlay;
- commands or configuration changes during transform cancel transform,
  clear its overlay, then perform the requested intent;
- pointer cancellation removes any draft, ready selection, or transform
  without creating history.

### 5.3 Effects

Effects include:

- begin, append, commit, or cancel stroke;
- apply undo or redo raster/metadata command;
- clear canonical raster;
- change tiling;
- replace tile-size resources;
- update color or active tool;
- clear future selection state;
- report a typed user-facing failure.

Effects contain semantic values and operation tokens. They contain no native
event or SwiftUI types.

### 5.4 Ordering

Ordered behavior is load-bearing:

- tool change during collecting:
  `cancelStroke`, then `updateTool`;
- color change during collecting:
  `cancelStroke`, then `updateColor`;
- undo/redo/clear during collecting:
  `cancelStroke`, then requested command;
- tiling or resize during collecting:
  `cancelStroke`, then requested configuration command;
- pointer cancel:
  `cancelStroke` only;
- pointer end:
  `requestCommit`, then wait for completion;
- commit success:
  finalize canonical swap, append history, then return idle;
- commit failure:
  discard scratch/live, append nothing, report error, then return idle.

Once GPU work is submitted, conflicting input receives a temporary busy
rejection. Visible controls are disabled from the same derived `isBusy` value.

`GridStrokeLifecycle` is removed after reducer migration. Renderer-side token
checks remain execution invariants, not lifecycle policy.

## 6. Document History

### 6.1 Command Types

History is linear and contains typed commands:

```swift
public enum DocumentHistoryCommand: Equatable, Sendable {
    case raster(RasterHistoryCommand)
    case tiling(MetadataChange<TilingKind>)
    case tileResize(TileResizeHistoryCommand)
}
```

`RasterHistoryCommand` covers draw, erase, and clear. It stores:

- semantic label;
- normalized changed-region descriptors;
- opaque before revision ID;
- opaque after revision ID;
- retained raster byte cost.

`TileResizeHistoryCommand` stores:

- before and after `PixelSize`;
- opaque full-raster before and after revision IDs;
- retained raster byte cost.

Metadata commands store no raster payload. History values contain no Metal
objects.

### 6.2 Cursor Semantics

- Undo selects the previous command without moving the cursor.
- The controller executes the required renderer or metadata effect.
- Only success moves the cursor backward.
- Redo uses the symmetric two-phase rule.
- A new successful mutation discards commands after the cursor.
- Failure leaves cursor, commands, revisions, pixels, and metadata unchanged.

This two-phase contract prevents asynchronous GPU failure from corrupting
history order.

### 6.3 Limits And Pruning

After each successful new command:

1. clear redo;
2. append the command;
3. prune oldest commands until count is at most 100;
4. continue pruning until retained raster payload is at most 200 MB;
5. release every revision no longer referenced by history or an in-flight
   operation.

Metadata commands count toward 100 commands but contribute zero raster bytes.
Undo and redo sides share one byte total.

A single Slice 3 raster operation cannot exceed the 200 MB cap: two complete
4096-by-4096 BGRA8 rasters require 128 MiB before row-alignment overhead.
Disk-backed revisions remain deferred until layers or later whole-document
operations can exceed the cap.

History is not serialized and is released when the document closes.

## 7. Raster Revisions

### 7.1 Changed Regions

Each emitted projected fragment contributes a conservative pixel rectangle
covering its transformed stamp and antialias fringe. A per-stroke accumulator:

1. clips each rectangle to canonical bounds;
2. discards empty rectangles;
3. merges overlapping or touching rectangles;
4. retains separated seam-edge rectangles independently.

The accumulator survives release of already-rendered live instances. History
therefore depends on emitted geometry, not on the bounded live upload buffer.

Conservative extra pixels are allowed. Missing a changed pixel is forbidden.

### 7.2 Payload Storage

`RasterRevisionStore` packs each region into Metal-owned storage with explicit
origin, size, byte offset, aligned bytes-per-row, and total retained bytes.
Opaque revision IDs are distinct from `RasterSurface.revision`.

For a stroke commit:

1. normalize the dirty-region set;
2. allocate both before and after payloads;
3. capture before bytes from canonical front;
4. render canonical front plus live into canonical scratch;
5. capture matching after bytes from scratch;
6. submit one command buffer;
7. on success, swap canonical textures and publish the history command;
8. on failure, discard provisional payloads and retain the prior front.

All required payload allocation happens before mutation is submitted.

### 7.3 Restore

Undo and redo are copy-on-write:

1. copy current canonical front into scratch;
2. restore selected region payloads into scratch;
3. submit;
4. swap only on successful completion.

This avoids partial in-place restore when encoding or GPU execution fails.
Every accepted mutation, undo, and redo advances the public surface generation.
Stored history revision IDs remain immutable content handles.

### 7.4 Clear

Clear uses one full-tile region. Before and transparent after payloads are
secured before submission. Undo restores exact prior bytes; redo restores exact
transparent bytes.

## 8. Tiling And Tile-Size Commands

### 8.1 Tiling

A tiling change:

- is allowed only when the reducer is not busy;
- records before and after `TilingKind`;
- changes display/projection metadata only;
- leaves canonical bytes and raster revision payloads untouched;
- becomes active only after renderer acceptance;
- is undoable and redoable through the same history cursor.

Draw commands remain valid across tiling commands because they reference
canonical bytes, not repeat interpretation.

### 8.2 Resize

Both dimensions validate within `64...4096`. A resize is a full-raster history
command:

1. allocate replacement canonical front/scratch, live texture, and complete
   before/after revision payloads;
2. clear replacement textures to transparent;
3. copy the exact top-left intersection:
   `min(oldWidth, newWidth) × min(oldHeight, newHeight)`;
4. leave new right/bottom pixels transparent;
5. keep tiling and viewport world center unchanged;
6. submit and publish only on success.

No shader sampling, interpolation, filtering, or scaling is permitted.

Undo allocates and restores the old dimensions and bytes before swapping.
Redo does the same for the new dimensions and bytes. Older raster commands
remain valid: linear history requires undoing the resize before reaching
commands created at the previous size. A new edit after undo clears resize
redo and every later command tied to the abandoned size.

## 9. Color And Eraser Rendering

### 9.1 Color

Ink color is a finite straight-sRGB RGBA value with components in `0...1`.
Default is `(0, 0, 0, 1)`. The app uses native SwiftUI `ColorPicker` with
opacity support.

Color is captured at stroke begin. Every projected GPU stamp instance carries
an aligned `float4 color`, preserving the future per-dab color-adjustment seam.
CPU and MSL layout tests guard size, stride, alignment, and every field offset.

The hard-round fragment emits:

```text
source.rgb = selected straight RGB
source.a   = geometric coverage × selected alpha
```

The existing stamp blend stores the accumulated live texture in premultiplied
BGRA8 form.

### 9.2 Eraser

Active stroke tool is `draw` or `erase`. `B` selects draw; `E` selects erase.
Tool and composite mode are constant for the entire stroke.

Eraser strength is model-owned and fixed at `1.0` in Slice 3. It never reads
neutral mouse pressure. Erase stamping writes zero RGB and accumulated coverage
alpha into the live texture. Selected ink color is preserved for the next draw
stroke.

Composite mode is a per-stroke uniform, not a per-instance attribute.
Single-tool-per-stroke behavior makes per-dab blend flags unnecessary
bandwidth.

One MSL helper is called by both display and commit:

```text
draw:  sourceOver(live, canonical)
erase: canonical × (1 - live.a)
```

The erase equation applies to premultiplied RGB and alpha. Multiple overlapping
erase dabs first accumulate coverage in the live texture, then destination-out
uses that accumulated coverage once. Pointer-up therefore cannot change the
visible eraser result.

## 10. Controls And Commands

Slice 3 introduces minimal product structure:

- stable left rail: Draw and Erase;
- compact top bar: ink color, undo, redo, and clear;
- right inspector: tiling plus tile width/height and explicit Apply;
- typed error presentation without replacing the committed canvas.

Tile size remains outside the top bar. Width and height are edited as a draft;
Apply produces one resize command. The committed model updates only after
successful completion.

Platform-independent key mapping:

| Input | Intent |
| --- | --- |
| `B` | select Draw |
| `E` | select Erase |
| `0` | clear |
| `1...7` | select tiling by stable index |
| `Command-Z` | undo |
| `Command-Shift-Z` | redo |
| Escape | cancel active transient edit |
| Space drag | pan, unchanged |

Toolbar, inspector, keyboard, and macOS menu commands terminate in the same
semantic intent methods. Native adapters may inspect native events only to
construct platform-free key values and modifiers.

Undo, redo, clear, tiling, size Apply, and tool changes disable while submitted
GPU work is pending. `canUndo` and `canRedo` derive from history position plus
transaction busy state.

## 11. Error And State Safety

Expected runtime failures use typed errors and preserve prior state:

- invalid or nonfinite color;
- invalid tile dimensions;
- revision allocation failure;
- replacement texture allocation failure;
- command queue/buffer/encoder failure;
- GPU command failure;
- missing or mismatched revision payload;
- stale completion token;
- command attempted while busy.

Programmer-only invariants use assertions or preconditions:

- CPU/MSL layout mismatch;
- region outside its declared pixel size after normalization;
- duplicate live operation token;
- history payload byte accounting mismatch;
- renderer completion for an operation it never accepted.

The renderer retains the last committed front texture until replacement work
succeeds. History finalization never occurs before renderer success.

## 12. Verification

### 12.1 Pure Tests

EditorCore and PatternEngine tests cover:

- every transaction state/event pair;
- exact ordered effects for cancellation followed by command/config/tool
  intent;
- collecting and commit-pending behavior;
- success, failure, and stale completion tokens;
- pointer cancel producing no command;
- history undo/redo selection and two-phase cursor finalization;
- redo invalidation only after successful mutation;
- 100-command pruning;
- 200 MB pruning;
- zero-byte metadata accounting;
- revision lifetime calculation;
- region clipping, empty removal, overlap/touch merge, and separated seam-edge
  retention;
- conservative dirty bounds for every tiling;
- top-left shrink crop and growth transparent fill;
- exact resize intersection preservation;
- color validation and default values;
- fixed independent eraser strength;
- platform-free key mapping.

### 12.2 ABI Tests

CPU-only tests assert exact MSL/Swift size, stride, alignment, and field offsets
after color is appended to projected stamp instances and composite-mode
uniforms are appended to frame data.

### 12.3 Real-Metal Harness

Harness schema advances for Slice 3 and adds negative-first scene pairs:

- colored draw with nonblack RGB and nonopaque alpha;
- eraser live/commit parity;
- destination-out canonical alpha and RGB;
- region undo/redo across separated seam edges;
- clear, undo, and redo;
- tiling undo with zero canonical byte change;
- resize shrink/crop, grow/fill, undo, and redo;
- failed-operation preservation where failure injection is deterministic.

Artifacts include live, committed, undone, redone, and canonical PNGs as
applicable; exact structural metrics; retained history bytes/commands; changed
regions; and benchmark JSON. Canonical comparisons are byte-exact. Preview and
commit channels differ by at most one 8-bit value.

Each new harness family receives one temporary negative control that proves its
target assertion fails. Broken behavior is never retained.

### 12.4 Regression And Build

- Slice 0 and Slice 1 functional gates;
- every Slice 2 correctness scene and structural assertion, replayed without
  claiming Slice 2 performance acceptance or changing `verify-slice2.sh`;
- all Swift tests;
- Xcode project regeneration;
- macOS Debug build;
- generic iPadOS Simulator Debug build;
- scope, ignore, and repository-hygiene checks.

### 12.5 Manual Mac Gate

- Draw and Erase controls remain in stable positions.
- `B`, `E`, `0`, `1...7`, `Command-Z`, and `Command-Shift-Z` work after
  drawing and after clicking controls.
- Color picker changes draw RGB and opacity.
- Eraser removes artwork live with no pointer-up change.
- Undo/redo works for draw, erase, clear, tiling, and resize.
- Tiling undo changes display without changing canonical pixels.
- Shrink crops only right/bottom.
- Growth adds transparent right/bottom space.
- Resize undo/redo restores exact dimensions and visible pixels.
- Busy controls disable during submitted GPU work.
- Pan, cursor-anchored zoom, resize, stroke direction, and pointer alignment
  remain correct.

### 12.6 Performance

Slice 3 retains all governing absolute budgets and records:

- brush processing;
- dab GPU time;
- tiling GPU time;
- commit time;
- raster revision capture/restore time;
- history resident bytes;
- event-to-submit latency;
- missed frames.

No retry, sample filtering, threshold relaxation, or synthetic timing may turn
an unstable device result into acceptance. Performance remains pending until a
stable real-Metal environment can produce valid evidence.

## 13. Delivery Order

1. Pure pixel regions, color values, history commands, and bounded history.
2. Total transaction reducer and semantic key mapping.
3. Metal revision storage and atomic restore.
4. Transaction-controlled draw commit and history integration.
5. Colored projected stamps and parity scenes.
6. Destination-out eraser and parity scenes.
7. Tiling metadata history.
8. Top-left crop/fill resize and full-raster history.
9. Minimal controls, menu/keyboard routing, and error presentation.
10. Complete negative-first harness matrix, automated gate, benchmarks,
    milestone, and manual checklist.

Each step must preserve all prior functional coverage. No later feature may
reintroduce renderer-owned lifecycle policy or bypass history finalization.

## 14. Exit Criteria

Slice 3 is accepted only when:

- transaction state/event behavior is total and ordered tests pass;
- draw, erase, and clear each create exactly one successful raster command;
- cancel and failed operations create none;
- undo and redo restore exact changed regions;
- history respects both bounds and releases pruned revisions;
- tiling undo changes metadata only;
- resize is undoable, top-left anchored, and never scales;
- color reaches real Metal output;
- eraser live and commit results match;
- all new negative controls fail for their intended reason;
- all prior functional gates and both platform builds pass;
- manual Mac interaction is accepted;
- stable real-Metal performance gates pass when suitable hardware is
  available.
