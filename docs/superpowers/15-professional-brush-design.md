Professional Brush Engine Pass (before layers)

Date: 2026-07-09

Status: planned

Decision: pause layers until brush feel, brush dynamics, brush materials, and brush-settings UI are professional enough to be a product advantage.
Why this exists

The current raster brush system is a strong v1: dual-texture shape × grain, pressure size/flow, flow/opacity separation, texturized grain, PNG grain path, brush editor, and render-harness coverage. That proves the pipeline. It does not yet prove the product.

For this app, brush quality is make-or-break. Layers are important, but they are a consumer of brush output. Adding layers before the brush is good would multiply weak brush behavior across a larger state model and make later changes more expensive.
Product bar

The target is not "has textured brushes"; the target is professional brush behavior:

    rich stylus response: pressure, tilt, direction, speed, stroke age, and seeded randomness;

    stable feel: no spacing jitter, no opacity jump, no seam artifacts, low latency;

    expressive brush families: ink, pencil, chalk, charcoal, marker, airbrush, gouache, watercolor-ish wash, dry brush;

    professional editing UI: brush library, brush studio, live preview pad, grouped settings, curve controls, texture previews;

    reproducible verification: pure tests for dynamics, GPU harness for pixels, live gate for feel.

Non-goals

    Full fluid simulation.

    Retained/vector document model.

    Cloud brush library or paid marketplace.

    Layer work.

    Solving parked live selection/transform UI.

Architecture ruling

Keep emit-and-forget for committed document storage: canonical pixels are still the retained artifact, and undo still snapshots at the commit seam.

Allow a transient live-stroke buffer only while a stroke is active. Professional brushes need it for touch taper, end taper, prediction correction, stroke-local wet behavior, and preview replay. Once a stroke commits, only pixels survive.
1. BrushInput module

Files: App/PatternSpike/InputAdapter.swift, Sources/PatternEngine/StrokeSample.swift, App/PatternSpike/PatternCanvasView.swift

Problem: StrokeSample currently exposes only position and pressure. That interface cannot express pro stylus behavior. Current future work would keep leaking device logic into the view.

Solution: make BrushInput the seam from platform events to normalized brush samples.

Proposed sample fields:
Swift

public struct StrokeSample: Equatable, Sendable {
    public var position: Point
    public var pressure: Double
    public var timestamp: Double
    public var altitude: Double?
    public var azimuth: Double?
    public var roll: Double?
    public var velocity: Double
    public var phase: SamplePhase
    public var source: InputSource
}

SamplePhase: .real, .coalesced, .predicted. InputSource: .mouse, .trackpad, .pencil, .stylus, .unknown.

Implementation notes:

    iOS: read UITouch.force, altitudeAngle, azimuthAngle(in:), coalesced touches, predicted touches.

    macOS: read pressure when available; synthesize velocity from timestamps; leave tilt/roll nil.

    Keep defaults so harness scenes can construct simple samples.

    Add tests for clamp/default/velocity behavior without needing UIKit/AppKit.

Leverage: one interface feeds all brush dynamics. Locality: platform input quirks stay in one module.
2. BrushDynamics module

Files: Sources/PatternEngine/BrushParams.swift, Sources/PatternEngine/StrokeSession.swift, Sources/PatternEngine/BrushDynamics.swift, Sources/EditorCore/BrushPreset.swift

Problem: dynamics are shallow scalar fields. Size, flow, scatter, rotation, hardness, and pressure logic are split between preset, params, session, and shader assumptions.

Solution: introduce one evaluator:
Swift

public struct BrushDynamicsEngine {
    public func evaluate(sample: StrokeSample, 
                         context: BrushStrokeContext, 
                         recipe: BrushRecipe) -> DabAttributes
}

DabAttributes becomes the single engine-pure description of one stamp:

    radius

    flow

    opacity contribution

    spacing

    rotation

    scatter offset

    hardness

    grain offset/scale

    color adjustment

    wetness/material parameters

BrushRecipe replaces the flat BrushPreset internals over time. It should support value mappings:

    source: pressure, speed, tilt, direction, roll, stroke age, stroke distance, random;

    transform: linear, power, curve table;

    output range;

    optional jitter with deterministic seed.

Implementation notes:

    First adapter maps existing BrushPreset into BrushRecipe.

    Keep existing presets pixel-equivalent initially.

    Then add new mappings behind tests.

    StrokeSession should ask BrushDynamicsEngine for attributes instead of computing them inline.

Leverage: every future brush behavior crosses one testable seam. Locality: brush feel changes stop spreading through the session, renderer, and UI.
3. LiveStroke module

Files: Sources/PatternEngine/StrokeSession.swift, Sources/MetalRenderer/LiveTile.swift, App/PatternSpike/PatternCanvasView.swift

Problem: append-only live dabs are fast but too rigid for professional stroke behavior. Prediction correction, end taper, and wet behavior need transient replay.

Solution: split active-stroke mechanics:

    StrokeSession: pure input-to-dab generation.

    LiveStroke: transient active-stroke state, sample buffer, emitted dab buffer, replay window.

    LiveTile: GPU accumulation target.

Modes:

    append-only for simple brushes;

    replay-last-N for predicted/coalesced correction and taper;

    replay-whole-stroke for expensive wet brushes only when needed.

Implementation notes:

    Keep commit seam unchanged.

    Start with append-only parity.

    Add replay-last-N only after tests prove identical simple-brush output.

    Add hard caps for sample/dab buffer length.

Leverage: professional stroke behavior without changing document storage. Locality: active-stroke complexity is isolated.
4. BrushRenderer and BrushMaterials modules

Files: Sources/MetalRenderer/BrushTextures.swift, Sources/MetalRenderer/BrushTextureResolver.swift, Sources/MetalRenderer/Shaders.metal, Sources/CShaderTypes/include/ShaderTypes.h, Sources/MetalRenderer/SpikeRenderer.swift

Problem: current renderer is mostly dry source-over stamps. Good for v1; insufficient for marker, dry media, smudge/pickup, and watercolor-ish brushes.

Solution: define material modes:

    .dry: pencil/chalk/charcoal tooth;

    .ink: crisp opaque line;

    .glaze: marker/translucent buildup;

    .wash: watercolor-ish transparent wash;

    .smudge: later, pigment pickup/drag.

Add per-stroke BrushMaterialUniforms separate from dab attributes. Keep per-dab struct reserved for attributes that truly vary per stamp.

Implementation notes:

    Add mipmapped tip/grain textures.

    Expand asset library: 512px tips, 1024px tileable grains.

    Keep texturized grain seam-safe by default.

    Wet V1 should be bounded: no fluid sim; use canonical sampling + blur/bleed/pickup approximations.

Leverage: many brushes reuse the same material implementation. Locality: shader complexity groups by material mode instead of being patched per preset.
5. BrushLibrary and BrushStudio UI

Files: App/PatternSpike/ContentView.swift, App/PatternSpike/BrushEditorPanel.swift, new app views.

Problem: current brush UI is clunky because it crams preset icons, flow/opacity sliders, and a generic Form popover into the top toolbar. It works as debug UI, not as pro creative UI.

Solution: replace it with a professional brush workflow:

    top toolbar: compact brush chip only (preview, name, size), color swatch, tools, undo/redo;

    brush library panel: categorized preset list with generated stroke previews;

    brush studio: dedicated sheet/sidebar with grouped settings and live drawing pad.

Brush Studio layout:

    left: setting categories;

    center: controls;

    right/bottom: live preview pad.

Categories:

    Stroke

    Stabilization

    Taper

    Tip

    Grain

    Rendering

    Wet Mix

    Dynamics

    Pencil

    Properties

Control design:

    sliders with numeric fields;

    segmented controls for modes;

    toggles for pressure/tilt bindings;

    small curve editor for response curves;

    texture thumbnails for tip/grain;

    reset button per section.

Implementation notes:

    Build BrushPreviewRenderer first.

    Use it for brush library rows and studio preview, so thumbnails are real engine output.

    Keep current BrushEditorPanel until BrushStudio reaches parity, then delete it.

Leverage: one preview path verifies UI and engine output together. Locality: brush UI no longer depends on toolbar layout.
Implementation order
Phase 0: spec and safety rails

    Add this plan to status and roadmap.

    Create Brush V2 tracking issues from this plan if needed.

    Add a "brush-first before layers" note to README/status.

Phase 1: professional UI shell, current engine

    Create BrushLibraryPanel.

    Create BrushStudioView.

    Move current brush settings into grouped BrushStudio categories.

    Replace toolbar brush controls with a compact brush chip + size control.

    Keep current model/setters.

Phase 2: BrushPreviewRenderer

    Add pure preview stroke definitions.

    Add renderer path that draws a preset preview into an offscreen texture.

    Use generated preview images in brush library rows.

    Add harness scene proving preview path uses same brush settings as real strokes.

Phase 3: BrushInput V2

    Extend StrokeSample.

    Implement iOS/macOS adapters.

    Update harness constructors.

    Add velocity computation and tests.

    Add coalesced touch handling to iOS path if missing or incomplete.

Phase 4: BrushDynamicsEngine

    Add BrushRecipe, BrushDynamicsEngine, DabAttributes.

    Add adapter from existing BrushPreset.

    Move current radius/flow/scatter/rotation logic out of StrokeSession.

    Add mapping sources: pressure, speed, tilt, random, distance.

    Add curve table support.

Phase 5: stroke behavior polish

    Add touch taper and end taper.

    Add spacing jitter and opacity jitter.

    Add improved stabilization modes.

    Add replay-last-N LiveStroke path for prediction/taper where needed.

    Add tests for deterministic output and no spacing collapse.

Phase 6: material modes and assets

    Add richer tip/grain asset pack.

    Add mipmapped resolver path.

    Add .dry, .ink, .glaze material modes.

    Add bounded .wash mode.

    Add material-specific harness scenes.

Phase 7: preset calibration

Ship 12-16 calibrated presets:

    Studio Pen

    Technical Pen

    Dry Ink

    Soft Airbrush

    Hard Airbrush

    HB Pencil

    6B Pencil

    Charcoal

    Chalk

    Pastel

    Marker

    Gouache

    Watercolor Wash

    Dry Brush

Each preset needs:

    library preview;

    one harness scene or shared family scene;

    live feel pass on macOS and iPad if available;

    seam check if texturized grain is enabled.

Phase 8: performance gate

Measure:

    input-to-pixel latency on iPad;

    sustained FPS while drawing;

    max dabs/frame;

    GPU time for stamp, composite, material pass;

    memory for brush assets and transient LiveStroke buffer.

(Do not move to layers until this pass is green enough.)
Verification matrix

    Pure tests: input normalization, velocity, dynamics mappings, curves, taper, stabilization, preset defaults, custom detection.

    GPU harness: tip/grain asset load, texturized grain seam, dry media, ink taper, marker buildup, wash behavior, preview renderer parity.

    UI checks: BrushLibrary selection, BrushStudio editing, reset/revert, custom detection, preview refresh, toolbar chip.

    Live checks: pen feel, pressure response, tilt response, latency, opacity no-jump, prediction correction.

Exit criteria before layers

    Brush UI no longer feels like debug controls.

    At least 12 presets feel distinct and useful.

    iPad stylus input uses pressure + tilt where available.

    Core dynamics live behind BrushDynamicsEngine.

    Current render harness stays green.

    New brush-family harness scenes are green.

    No known opacity/spacing/seam regressions.