# Slice 0: Foundation And Harness

**Status:** Accepted
**Gate:** `./scripts/verify-slice0.sh`

## Result

- Swift package tests passed.
- The macOS app built and rendered the blank canvas onscreen.
- The iPadOS simulator target compiled; no iPad hardware behavior is claimed.
- The real app metallib rendered the scripted scene offscreen.
- The negative-control scene exited nonzero before the positive scene passed.
- PNG and benchmark JSON were emitted under `.build/slice0-artifacts/positive/`.

## Decisions

- `App/project.yml` is the project source of truth; generated Xcode project files remain disposable.
- GPU verification stays in the app executable so tests cannot accidentally use a different metallib.
- Harness scenes use versioned JSON and exact BGRA checks with explicit tolerance.
- Slice 1 may build on `BlankRenderer`; it must replace the blank-pass name when the measured grid drawing pipeline arrives.

## Retrospective

The foundation now distinguishes pure contracts, app builds, real GPU assertions, and manual visual acceptance. No drawing, tiling, or document behavior is inferred from this gate.
