# PatternSpike: keyboard-shortcut + config-state architecture — DECIDED spec

Authoritative reconciliation of three lenses. Grounded in a fresh read of `ContentView.swift`, `CanvasRepresentable.swift`, `PatternCanvasView.swift`, `PatternSpikeApp.swift`, `Geometry.swift`, `Viewport`, `BrushDynamics.swift`, `ScriptedScene.swift`. Min targets iOS 17 / macOS 14. Render path OUT OF SCOPE.

## 0. Verified facts that the lenses missed or got wrong

These change the spec, so they go first:

*   `PatternEngine` ALREADY has a `TilingChoice`: `ScriptedScene.TilingChoice: String, Sendable, CaseIterable` with the *same* 7 cases (`grid`, `halfDrop`, `brick`, `mirrorX`, `mirrorY`, `mirrorBoth`, `rotational`). The lenses' "promote the app's nested `TilingChoice` into `PatternEngine` under that name" would **collide**. Ruling in §5: app gets a top-level `TilingChoice` in the app target (not the engine); we do NOT touch the engine enum. (Unifying the two is a separate, optional cleanup — noted but not required here.)
*   `Viewport` is **not a trivial value type**: it carries `screenSize` and a `precondition(zoom > 0)`, and its math (`screenToWorld`/`worldToScreen`) is consumed in the draw hot path via `spike.viewport`. This *strengthens* the unanimous "viewport stays renderer-local" call (§4).
*   The app is a single Xcode target (`App/PatternSpike`), no separate app-logic SPM module. New files land in `App/PatternSpike/`. The model is plain app-layer Swift; unit tests need a seam that does NOT require that Xcode target to be importable from `swift test` (see §7 — this is the one genuinely awkward bit and I address it honestly).
*   `brushScreenRadius()` depends on `spike.viewport.zoom` and backing scale — both view/renderer-local. It is a *read*, not config. It must NOT move into the model (it would force the model to know zoom). Stays a view query (§4).
*   `clearCanvas()` also nils `session` (`session = nil; spike.clearCanvas()`). Clear is a real imperative canvas command with side effects beyond config, so it is NOT modeled as a config bool. Confirmed: command-token approach (§2).

## 1. DECISION: state container = Option A (`@Observable EditorModel`)

Adopt A. One `@Observable @MainActor final class EditorModel` owns all config and exposes semantic action methods. Toolbar binds to it; keyboard calls the same methods; `CanvasRepresentable` observes it and pushes one-way to the view.

*   **Reject B** (view→`@State` callback). It patches *this* keypress but keeps the source of truth trapped in a `ContentView` value; unreachable by a future `Scene`-level `.commands` menu, not unit-testable without a host view, and it re-introduces a second (view→state) data direction — the exact bidirectional coupling that caused the original desync.
*   **Reject full C** (Action enum + `reduce(state:action:)` + effects). For ~4 config fields and ~9 actions the reducer indirection is pure tax. A is a strict subset of C's surface, so if undo/redo or document persistence ever lands, A refactors into a reducer cleanly — not a dead end.
*   **No `EditorAction` enum either.** The scale lens wanted a thin `EditorAction` enum + `dispatch(_:)` "for testability." Ruling: actions-as-methods are already directly unit-testable (`let m = EditorModel(); m.brushLarger(); #expect(...)`). An enum + switch buys nothing here except a second thing to keep in sync with the methods. The **key→action map** is the declarative table (§3); that is the only place a closed action vocabulary needs to be reified, and a dictionary of closures expresses it without an enum.

Right-sized verdict: A is the smallest design that makes desync impossible *by construction* (one owner, all inputs call the same mutators) while supporting first-class cross-platform shortcuts and a future menu. Not a no-scale `@State` patch; not a framework.

### Where it lives

Created once at the App level so a future `.commands` menu (which lives at `Scene`/`App` scope, outside the view tree) can reach the same instance:

```swift
// PatternSpikeApp.swift
@main
struct PatternSpikeApp: App {
    @State private var model = EditorModel()       // @Observable + @State: idiomatic on 17/14
    var body: some Scene {
        WindowGroup { ContentView(model: model) }  // explicit init; see note
        // Future: .commands { EditorCommands(model: model) }
    }
}

ContentView takes it as a stored let model: EditorModel (or @Environment(EditorModel.self) if we also .environment(model) — pick explicit init for now, fewer moving parts; switch to environment when the menu lands). Reading model's @Observable properties inside body/update registers the dependency, so the view reacts to changes from ANY input path.

Do NOT keep the harness path entangled: PatternSpikeApp.init() still does the HarnessLaunch early-exit before any model use matters (model is @State, constructed lazily by SwiftUI only when the scene builds — harness exits first).
2. The EditorModel: config + semantic ACTION API

New file App/PatternSpike/EditorModel.swift.

import Observation
import simd

@Observable
@MainActor
final class EditorModel {
    // --- Single source of truth for config. Toolbar READS these; actions WRITE them. ---
    private(set) var tiling: TilingChoice = .grid
    private(set) var tileSize: Double = EditorConfig.tile.initial    // 256
    private(set) var brush: Double    = EditorConfig.brush.initial   // 20
    private(set) var showGrid: Bool   = false
    
    // Edge-triggered imperative canvas command (clear). Not config => not a stored
    // bool that needs resetting. Representable forwards on change. (§4)
    private(set) var clearToken = CommandToken()
    
    // --- Semantic actions: the ONLY mutators. Every input path calls these. ---
    func setTiling(_ c: TilingChoice) { tiling = c }
    func cycleTiling(by d: Int = 1)   { tiling = tiling.cycled(by: d) }   // wraps
    func selectTiling(index1 i: Int)  { if let t = TilingChoice.at(index1: i) { tiling = t } }
    
    func brushLarger()  { brush = EditorConfig.brush.stepped(brush, up: true) }
    func brushSmaller() { brush = EditorConfig.brush.stepped(brush, up: false) }
    
    func tileLarger()   { tileSize = EditorConfig.tile.stepped(tileSize, up: true) }
    func tileSmaller()  { tileSize = EditorConfig.tile.stepped(tileSize, up: false) }
    
    func toggleGrid()   { showGrid.toggle() }
    func clear()        { clearToken.bump() }
}

private(set) is deliberate: the toolbar can read and call actions but can NEVER assign tileSize = _ directly, so the step/clamp rule can't be bypassed (that bypass is exactly what keyDown did differently from the toolbar today).Complete action list with signatures:ActionSignatureNotesset tilingsetTiling(_ c: TilingChoice)toolbar icon tapcycle tiling fwd/backcycleTiling(by d: Int = 1)+1 / -1; wrapsselect by indexselectTiling(index1 i: Int)keys 1-7brush largerbrushLarger()geometric ×1.25brush smallerbrushSmaller()geometric ÷1.25tile largertileLarger()additive +32tile smallertileSmaller()additive -32toggle gridtoggleGrid()clearclear()bumps clearTokenDedup: ranges/steps as NAMED CONSTANTS in ONE placeSame file (or EditorConfig.swift). This is where ContentView lines 59/62 and keyDown lines 197–203 — three different hand-written step/clamp expressions — collapse to one definition each.

/// A config field's domain + how one "step" moves through it. Clamps internally.
struct SteppedRange {
    let initial: Double
    let range: ClosedRange<Double>
    let nudge: (Double, _ up: Bool) -> Double   // pure; pre-clamp transform
    func stepped(_ v: Double, up: Bool) -> Double {
        nudge(v, up).clamped(to: range)
    }
}

enum EditorConfig {
    // tile: additive ±32, 64...1024, rounded (matches today's toolbar + keyDown)
    static let tile = SteppedRange(initial: 256, range: 64...1024) { v, up in
        (v + (up ? 32 : -32)).rounded()
    }
    // brush: geometric x/÷1.25, 2...2000, rounded (matches today's toolbar; keyDown
    // omitted the .rounded() - toolbar wins, this UNIFIES them)
    static let brush = SteppedRange(initial: 20, range: 2...2000) { v, up in
        (up ? v * 1.25 : v / 1.25).rounded()
    }
}

clamped(to:) moves out of ContentView's private scope into Comparable+Clamped.swift (non-private) so SteppedRange and anything else share it (§5).

Both toolbar AND keyboard call the SAME path: toolbar stepper closures call model.tileLarger()/.tileSmaller()/.brushLarger()/.brushSmaller(); keyboard map (§3) calls the identical methods. Neither writes tileSize/brush directly. The math lives only in EditorConfig.
3. KEYBOARD: SwiftUI .onKeyPress, cross-platform, focus solved

Decision: move keyboard up into SwiftUI .onKeyPress on the canvas layer; DELETE the AppKit keyDown override; set acceptsFirstResponder = false.

Rationale:

    .onKeyPress is available on iOS 17 / macOS 14 — within min targets. One code path for both platforms; iPad hardware keyboard works for free (it has none today).

    Bare keys (+ - < > 0 1-7, g) are the current set — .onKeyPress reads raw characters, which is what these need. .keyboardShortcut is for modifier-bearing, menu-discoverable commands (⌘-something); it is the path a future .commands menu uses and it will call the SAME action methods. Both mechanisms coexist and terminate in the model. We use .onKeyPress now; .keyboardShortcut is additive later.

The focus problem and its solution (the crux)

The canvas needs first-responder for pointer drawing; .onKeyPress needs SwiftUI key focus. These are different mechanisms at different layers and do not conflict:

    Pointer events (mouseDown/mouseDragged/touchesBegan...) are delivered by hit-testing to the NSView/UIView regardless of key-focus. Drawing does NOT require first-responder.

    Key events route via SwiftUI focus to the .focusable() container.

The trap (scale lens caught this; it's correct): if PatternCanvasView keeps acceptsFirstResponder == true AND a keyDown override, the AppKit view sits in the responder chain and intercepts keys before SwiftUI. So we MUST remove both acceptsFirstResponder (set to false) and keyDown — otherwise the new .onKeyPress is shadowed on macOS. This is non-negotiable and is the reason the bug-fix is "by construction."

// ContentView body, on the canvas layer:
@FocusState private var canvasFocused: Bool

CanvasRepresentable(model: model)
    .focusable()                    // container is the key target
    .focused($canvasFocused)
    .focusEffectDisabled()          // no focus ring on a paint surface
    .onAppear { canvasFocused = true }
    .onKeyPress { press in EditorKeymap.handle(press, model) }

The toolbar buttons use .buttonStyle(.plain) and on macOS do not steal persistent key focus from a @FocusState-owned focusable in practice; if a clip ever shows keys dying after a toolbar tap, re-assert canvasFocused = true — but ship without it first.

Exact key map (one table; adding a shortcut = one line)

enum EditorKeymap {
    @MainActor
    static func handle(_ press: KeyPress, _ m: EditorModel) -> KeyPress.Result {
        switch press.characters {
        case "0":         m.clear();          return .handled
        case "+", "=":    m.brushLarger();    return .handled
        case "-":         m.brushSmaller();   return .handled
        case ">":         m.tileLarger();     return .handled
        case "<":         m.tileSmaller();    return .handled
        case "g":         m.toggleGrid();     return .handled      // NEW: grid via keyboard
        case "1", "2", "3", "4", "5", "6", "7":
            m.selectTiling(index1: Int(press.characters)!)       // safe: literal digits
            return .handled
        default:          return .ignored
        }
    }
}

This exactly reproduces the current 0 / + = - / > / < / 1-9 behavior (8 and 9 were no-ops before and remain .ignored; only 1–7 are valid), and ADDS g for grid (previously toolbar-only) so the keyboard and toolbar action vocabularies match. The map is the single key→action source; a .commands menu later reuses the same m.* methods, never a second copy of this switch.
4. CanvasRepresentable: one-way consume; what stays renderer-local

One-way push (preserves the old-onMake-bug fix)

CanvasRepresentable takes model instead of three scalars. apply(to:) reads model props and calls the existing idempotent view setters — identical one-way flow, just a single source.

struct CanvasRepresentable {            // NSViewRepresentable / UIViewRepresentable
    var model: EditorModel
    
    // make*: create view, wire gestures (unchanged), apply(to:) once.
    // update*: apply(to:) - reading model props here registers @Observable deps,
    //          so SwiftUI re-invokes update* on ANY action. Same trigger as today.
    
    private func apply(to v: PatternCanvasView, _ coord: Coordinator) {
        v.setTiling(model.tiling)
        v.setBrushSize(model.brush)
        v.setTileSize(model.tileSize)
        v.setShowGridLines(model.showGrid)          // grid joins one-way flow
        coord.applyClearIfChanged(model.clearToken, v) // edge-triggered (below)
    }
}


No build-pass @State mutation. The representable only READS the model during update* and WRITES the view (an external object). All model WRITES happen in event handlers (button taps, onKeyPress, gesture callbacks) — never in body / update*. So the original "mutate @State during the view-build pass → SwiftUI drops it" failure cannot recur.

Edge-triggered clear (so apply running every update doesn't re-clear every frame):

struct CommandToken: Equatable { private var n = 0; mutating func bump() { n += 1 } }
// Coordinator:
var lastClear = CommandToken()
func applyClearIfChanged(_ t: CommandToken, _ v: PatternCanvasView) {
    if t != lastClear { v.clearCanvas(); lastClear = t }  // clearCanvas() nils session + clears
}

CanvasController shrinks to nothing → deleted

    clear() → clearToken edge-triggered through apply (above).

    setGridLines(_:) → showGrid config pushed through apply.

    brushScreenRadius() → stays a view read (depends on viewport.zoom + backing scale). The Coordinator keeps a weak var view (it already does) and exposes the read for the hover cursor: controller/coordinator's single surviving job. Implementation: keep a tiny accessor the onContinuousHover closure can call — either a slimmed CanvasController with ONLY brushScreenRadius(), or read through coordinator.view?.brushScreenRadius(). Ruling: keep a one-method CanvasController (least churn to ContentView's hover handler) but strip clear/setGridLines. It is a read-only query, creates no desync surface.

Zoom/pan: STAY renderer-local. DO NOT join the model. (unanimous, upheld)

spike.viewport stays renderer-owned, view-mutated by gestures, exactly as today. Arguments (all three lenses agreed; verified facts reinforce):

    No second writer to desync against. The model exists to kill toolbar<->keyboard desync. Zoom/pan has no toolbar UI and no shortcut — nothing to desync.

    Gesture-frequency churn. ScrollWheel/pinch/two-finger-pan mutate at 60–120/s. Routing through @Observable would fire SwiftUI invalidations and re-run update* at input rate for zero observers.

    Viewport is renderer-shaped, not document config: it needs screenSize, asserts zoom > 0, and feeds the draw hot path (screenToWorld per sample). It is "where you're looking," not "what the pattern is." The model owns the latter.

Generalizable rule: the model owns config touched by ≥2 input paths or any UI mirror; per-view continuous/ephemeral state (viewport, in-flight stroke session, coalesced touches, pressure) stays in the view/renderer. If "reset view"/"fit" ever lands, expose it like clear: an edge-triggered command token the representable forwards to spike.viewport — WITHOUT mirroring live zoom/pan into the model.

Drawing input (raw/coalesced touches, pressure, StrokeSession) stays entirely in PatternCanvasView — untouched.
5. Where TilingChoice and clamp/step helpers move

    TilingChoice: promote out of PatternCanvasView to a top-level enum in the app target — new file App/PatternSpike/TilingChoice.swift. Make it CaseIterable, Equatable (Equatable needed for cycled, firstIndex and the toolbar's tiling == item.choice). Add helpers:

enum TilingChoice: CaseIterable, Equatable {
    case grid, halfDrop, brick, mirrorX, mirrorY, mirrorBoth, rotational
    func cycled(by d: Int) -> TilingChoice {
        let all = Self.allCases, n = all.count
        let i = all.firstIndex(of: self)!
        return all[((i + d) % n + n) % n]
    }
    static func at(index1 i: Int) -> TilingChoice? {
        let all = allCases
        return all.indices.contains(i - 1) ? all[i - 1] : nil
    }
}

Do NOT hoist into PatternEngine — it already has a different ScriptedScene.TilingChoice (String-raw, harness-only). Reusing the engine enum app-wide is possible (same cases) but couples the app's UI enum to the harness's serialization enum and is out of scope. Keep them separate; the app enum is pure app-layer UI vocabulary. makeStrategy()'s switch stays in PatternCanvasView and switches on the now-global TilingChoice (engine wiring stays at the view). Update the 6 PatternCanvasView.TilingChoice references (ContentView x2 incl. tilingItems, CanvasRepresentable x2, the nested-enum deletion, and setTiling's param).

(Optional future cleanup, NOT this spec: collapse app TilingChoice and ScriptedScene.TilingChoice into one shared engine enum. Tracked, deferred.)

    clamped(to:): move from ContentView's private extension Comparable (lines 129–131) to non-private App/PatternSpike/Comparable+Clamped.swift. Used by SteppedRange.stepped. The duplicated inline min/max in keyDown disappears with keyDown itself.

    Step/clamp literals (32, 1.25, 64...1024, 2...2000): ONLY in EditorConfig. Verification step in migration confirms none survive elsewhere.

6. MIGRATION — each step compiles, app runs, builds stay green

Order chosen so the bug dies at step 4 and every step is independently shippable.

Step 1 — extract shared types, zero behavior change.

    Add Comparable+Clamped.swift (move the ext out of ContentView).

    Add EditorConfig.swift (SteppedRange + tile/brush).

    Repoint the TWO ContentView stepper closures to EditorConfig.tile.stepped/.brush.stepped. (keyDown still duplicates — fixed step 4.) Build + run: toolbar identical; step math now single-sourced.

Step 2 — promote TilingChoice.

    New TilingChoice.swift (top-level enum + cycled/at). Delete nested enum in PatternCanvasView. Fix all 6 references. Mechanical; identical behavior.

Step 3 — introduce EditorModel; switch ContentView + representable.

    Add EditorModel.swift (config + actions + clearToken + CommandToken).

    PatternSpikeApp: @State private var model; pass to ContentView.

    ContentView: drop the 4 config @State; take let model; toolbar icons → model.setTiling; steppers → model.tileLarger/Smaller/brushLarger/Smaller; grid button → model.toggleGrid(); clear button → model.clear(). Remove the controller.setGridLines call (grid now flows through config).

    CanvasRepresentable: take model; apply reads model + pushes setShowGridLines; add edge-triggered applyClearIfChanged. Slim CanvasController to brushScreenRadius() only (drop clear/setGridLines).

    Now toolbar<->model unified. Core risk step: manually sweep every toolbar control (tiling x7, tile ±, brush ±, grid, clear) — confirm one-way push still works. Keyboard still in keyDown (untouched) — desync still visible via keyboard ONLY, which is expected until step 4.

Step 4 — move keyboard to SwiftUI; THIS KILLS THE BUG.

    Add EditorKeymap.swift.

    ContentView: add @FocusState canvasFocused + .focusable()/.focused/.focusEffectDisabled()/.onAppear{focus}/.onKeyPress{EditorKeymap.handle} on the canvas layer.

    PatternCanvasView: delete keyDown, set acceptsFirstResponder = false.

    Verify: bare keys mutate the model → toolbar updates LIVE (bug gone by construction); drawing still works after a keypress and after a toolbar tap; iPad HW keyboard now drives shortcuts.

Step 5 — tidy + (optional, later) menu.

    Grep-confirm no step literal (32, 1.25, the ranges) survives outside EditorConfig; CanvasController is one method; zoom/pan untouched throughout.

    (Deferred) .commands { EditorCommands(model:) } at Scene scope with .keyboardShortcut calling the same model.* — pure addition.

Files NEW: EditorModel.swift, EditorConfig.swift, TilingChoice.swift, Comparable+Clamped.swift, EditorKeymap.swift (+ test target, §7). Files EDITED: ContentView.swift, CanvasRepresentable.swift, PatternCanvasView.swift, PatternSpikeApp.swift. UNTOUCHED: all Sources/PatternEngine + Sources/MetalRenderer (render path out of scope); Viewport stays the zoom/pan home; drawing/session/touch code in the view.
7. VERIFICATION — honest about the unit/manual split

Unit-testable (pure types, no UIKit/AppKit/SwiftUI/GPU):

    EditorModel actions: clamp boundaries (brushLarger() xN caps at 2000; brushSmaller() floors at 2; tileLarger/Smaller cap 1024/64), geometric vs additive nudging, toggleGrid() flips, clear() bumps clearToken and the token compares unequal.

    cycleTiling(by:) wraps both directions over all 7 cases and returns to start after a full cycle; selectTiling(index1:) accepts 1–7, ignores 0/8/9.

    EditorConfig.tile/brush.stepped(...) math and clamped(to:).

    EditorKeymap.handle mapping: feed a synthesized character, assert the model mutated as expected and the KeyPress.Result is .handled/.ignored. (Pure — it just switches on press.characters and calls model methods.)

The seam + test target (the genuinely awkward part, stated plainly): The app code lives in the PatternSpike Xcode app target, which swift test (SPM) cannot import. Two honest options:

    (preferred) Move the testable types into an SPM module. Put EditorModel, EditorConfig, SteppedRange, TilingChoice, clamped(to:), and EditorKeymap's pure handle into a new SPM target, e.g. Sources/PatternApp/, that both the Xcode app target and a Tests/PatternAppTests swift-testing target depend on. These types import only Observation/simd/SwiftUI (for KeyPress) — no GPU, no app target. NOTE: KeyPress is SwiftUI; an SPM target CAN import SwiftUI, so EditorKeymap is fine there. The Xcode app target adds PatternApp as a package dependency.

    (fallback) XCTest/swift-testing inside the Xcode project as a unit-test bundle targeting the app — works but isn't drivable by the existing swift test CLI/harness. Use only if adding an SPM module is undesired.

Ruling: do the SPM module (PatternApp) — it's the seam that makes the action layer testable headlessly and keeps the app target thin. Add swift-testing-based PatternAppTests. This is small: ~5 value/observable types with no platform deps beyond SwiftUI's KeyPress.

    As built: this SPM module shipped as EditorCore (Sources/EditorCore/), not PatternApp, with test target EditorCoreTests. It grew beyond the ~5 types above (it now also holds BrushPreset, EditorTransaction, SelectionRect, Stabilizer, Comparable+Clamped). Read every PatternApp/PatternAppTests reference below as EditorCore/EditorCoreTests. See 16-reference-sheet.md for the as-built module graph.

NOT unit-testable — manual checking required (be explicit):

    Key-event focus: that .onKeyPress actually receives keys with the canvas focusable, that deleting acceptsFirstResponder + keyDown removed the AppKit interception, and that drawing still works after a keypress / toolbar tap. SwiftUI/AppKit/UIKit key + pointer routing cannot be exercised by swift test or by the Metal render harness.

    The render harness drives the GPU, NOT SwiftUI/AppKit input (confirmed: HarnessLaunch early-exits before any window/runloop; it replays ScriptedScene through the renderer). It verifies the render path — which is out of scope here — and cannot press keys or click toolbars.

    Manual sweep checklist (macOS + iPad-with-HW-keyboard): each toolbar control reflects state after keyboard changes and vice versa; 1-7 select; 8/9 no-op; + - < > 0 g behave; zoom/pan still gesture-only; clear nukes canvas once per press.

So: action/clamp/store/keymap logic → automated swift-testing in PatternApp; focus + input routing → manual, documented checklist. Honest seam, honest gap.
8. Where the lenses disagreed — and the ruling

    EditorAction enum + dispatch(_:) (scale lens) vs actions-as-methods (SwiftUI + pragmatist). RULING: actions-as-methods. The enum's only claimed win was testability, but methods are already directly testable. The declarative "closed action set" lives where it's actually needed — the key→action map (§3) — not as a redundant enum mirroring the methods. (If a reducer is ever needed, A→C is a clean refactor.)

    clear representation: CommandSink closure (pragmatist) vs edge-triggered token (SwiftUI). RULING: edge-triggered CommandToken through the existing one-way apply. It keeps clear inside the single one-way pump (one funnel, testable: assert token bumped) with no extra closure-wiring object; the Coordinator compares last-seen vs current. The pragmatist's CommandSink is a fine alternative but introduces a second push channel (handler set at make); the token reuses the channel we already have.

    Where TilingChoice goes (all three said "into PatternEngine"). RULING: OVERRULED on the basis of code reading — PatternEngine already owns a different ScriptedScene.TilingChoice. App enum becomes a top-level type in the app target (TilingChoice.swift), not the engine. Unifying with the engine enum is deferred as optional cleanup.

    Testability seam (scale lens asserted "directly unit-testable"; none nailed the SPM-vs-Xcode-target wrinkle). RULING: the app target is NOT swift test-importable, so the testable types must move into a new Sources/PatternApp SPM module with a PatternAppTests swift-testing target. This is the concrete seam the lenses hand-waved.

    Viewport in the model. Pragmatist initially sketched viewport in the model then retracted it; SwiftUI + scale said renderer-local from the start. RULING: renderer-local, unanimous final position — reinforced by Viewport's screenSize/precondition/hot-path facts (§4).

    @Environment vs explicit-init for the model in ContentView. SwiftUI lens used .environment; pragmatist used @State + .environment. RULING: explicit let model init now (fewer moving parts, one less thing to misconfigure); flip to @Environment(EditorModel.self) when the Scene-level .commands menu lands and the model genuinely needs App-scope reach. Either is fine; explicit is the smaller step today.

9. Scorecard vs requirements

    Single source of truth: ✅ EditorModel private(set) props; all paths call actions; direct assignment impossible.

    Step/clamp once: ✅ EditorConfig + clamped(to:); literals nowhere else.

    Scalable: ✅ new shortcut = 1 EditorKeymap line; new field = 1 prop + 1 EditorConfig entry + 1 apply line; new input = call existing actions; menu = additive .commands.

    Cross-platform keyboard: ✅ .onKeyPress; focus via @FocusState distinct from pointer first-responder; AppKit keyDown + acceptsFirstResponder removed so keys aren't intercepted.

    Drawing stays in view ✅; viewport renderer-local with argument (§4).

    One-way to renderer preserved ✅; no build-pass @State mutation; idempotent setters; edge-triggered clear.

    Engine/render path untouched ✅.