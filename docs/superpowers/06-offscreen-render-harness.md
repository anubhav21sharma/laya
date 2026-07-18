# Offscreen Metal render-to-PNG test harness — self-verifiable GPU path

**Status: DONE (2026-06-28)**. Built, verified end-to-end (positive + negative control), all builds/tests green. See the `verifier-metal` skill (`.claude/skills/verifier-metal/SKILL.md`) for the run/read protocol.

## Why

PatternSpike's only real output is GPU-rendered pixels, so verifying a rendering change means launch -> drive input -> screenshot. In an agent session the last two steps are blocked: macOS denies **Screen Recording** (`screencapture` -> "could not create image from display") and **Accessibility** (System Events can't read windows or synthesize input) — TCC gates that can't be granted programmatically. When the half-drop "phantom 4th dot" bug was fixed, the engine geometry was provable on the CPU but the actual GPU `dab_fragment`/clip path could only be confirmed by the **user eyeballing a build**. (Worse: a throwaway CPU verification harness used a sign-flipped half-drop orbit and sent the fix on a long false-alarm chase.) This harness lets the agent render the REAL GPU pipeline to PNG, `Read` the image, and assert pixels — no human, no display.

## What was built

**A launch mode of the real app** (not a new test/CLI target): the app is folder-synced and has no shared scheme on disk, and `xcodebuild test` risks "no GPU on a headless runner" — but the real app binary always has both the compiled metallib and a GPU. `MTLCreateSystemDefaultDevice()` + offscreen render-to-texture + `getBytes` need no window or screen-recording permission.

* `Sources/MetalRenderer/RenderCapture.swift` — `writePNG`/`readBGRA`/`alphaAt`/`loadBGRA`/`matches` (BGRA `getBytes` -> CGImage `order32Little|premultipliedFirst` -> PNG). In the lib so a future GPU-backed XCTest reuses it.
* `Sources/MetalRenderer/SpikeRenderer.swift` — `renderTilingOffscreen(width:height:viewport:)` (drawable-free twin of `draw(in:)` -> owned offscreen texture, white clear, no present, sync). Also hardened the `Dab`/`DabInstance` stride check `assert` -> `precondition` (mismatch corrupts every GPU dab in release).
* `Sources/PatternEngine/ScriptedScene.swift` — declarative scene (tiling, tile size, dabs, radius) with `strategy()`/`dynamics()` mirroring `PatternCanvasView`.
* `App/PatternSpike/RenderHarness.swift` — replays a scene through `StrokeSession` -> `addOverlayDabs` -> `commitOverlay`, writes `<scene>-canonical.png` + `<scene>-screen.png`, runs per-scene `PixelAssert`s. Scene catalog: `halfdrop-phantom`, `brick-phantom`, `interior-control`.
* `App/PatternSpike/HarnessLaunch.swift` + `PatternSpikeApp.swift` — `--render-harness <dir>` / `PATTERN_RENDER_HARNESS` triggers `runAndExit` before any UI; prints `HARNESS OK|FAIL`, exits 0/1. Sandbox-aware: falls back to the container temp dir and prints `HARNESS OUTDIR <real path>`. Also `--tiling-switch` (exploration): draws a multi-seam-crossing zigzag under half-drop, commits, then re-samples the same tile as half-drop + brick (`RenderHarness.tilingSwitch`) — surfaced the intrinsic "cross-tiling reuse breaks committed content" behavior (see the status-note known-issue).
* `Package.swift` + `Tests/MetalRendererTests/LayoutTests.swift` — CPU-only stride guard (runs under `swift test`, no GPU).
* `.claude/skills/verifier-metal/SKILL.md` — the reusable verify protocol.

## How to run / verify

```bash
APP=/Users/anubshar/git/pattern/App
xcodebuild -project "$APP/PatternSpike.xcodeproj" -scheme PatternSpike -destination 'platform=macOS' -configuration Debug build
BIN="$(xcodebuild -project "$APP/PatternSpike.xcodeproj" -scheme PatternSpike -destination 'platform=macOS' -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/TARGET_BUILD_DIR =/{d=$2} / FULL_PRODUCT_NAME =/{n=$2} END{print d"/"n}')"
"$BIN/Contents/MacOS/PatternSpike" --render-harness /tmp/ph --all; echo "exit=$?"
```

Take PNG paths from the `HARNESS OK/FAIL` lines (sandbox writes to the container temp, not `/tmp`); `Read <scene>-screen.png`.

**Verified 2026-06-28:** positive run -> all `HARNESS OK`, exit 0; `halfdrop-phantom-screen.png` shows a clean staggered half-drop (no phantom dots). Negative control (clip disabled) -> `halfdrop-phantom` and `brick-phantom` `HARNESS FAIL` with `canonical (15,60) alpha=121 want BLANK got INK`, exit 1, and the screen PNG visibly shows the phantom doubling — proving the asserts have teeth. `swift test` 110 green; macOS + iOS Xcode builds green.

## Known limitations / future

* Golden-image regression (`RenderCapture.matches` + committed goldens) is scaffolded but not wired to a blessing workflow — add when a stable baseline is wanted.
* A runner with literally no Metal device errors out; `swift test` remains the CPU net.
* The offscreen tiling pass renders at zoom 1, origin (0,0); add viewport params to scenes if a zoom/pan-dependent bug ever needs capturing.