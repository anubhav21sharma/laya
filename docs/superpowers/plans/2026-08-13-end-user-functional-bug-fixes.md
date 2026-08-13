# End-User Functional Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Save As, PNG export, locked-layer drawing, and Stage 4 Brush Lab replay work reliably through the normal end-user UI.

**Architecture:** Normal file operations use the same serialized quiescent-capture boundary as acceptance evidence and export staged files through one UTType-aware presentation route (`NSSavePanel` on macOS and `FileDocument` on iPadOS). Stroke admission rejects locked active layers before creating a transaction. Brush Lab publishes replay loading and gates controls from observable state for the exact first periodic Airbrush card regression.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Metal, Swift Testing, XCTest.

## Global Constraints

- Preserve the current macOS and iPadOS editor UI and command structure.
- Do not weaken renderer idle, ownership, evidence, or deterministic replay checks.
- Every production change requires a test observed failing first.
- Preserve the Stage D direct-destination acceptance route.

---

### Task 1: Product file-operation safety and transfer representation

**Files:**
- Modify: `App/PatternSpike/ContentView.swift`
- Modify: `App/PatternSpike/Harness/StageDAppRouteEvidence.swift`
- Modify: `App/PatternSpike/Persistence/PatternProjectFileDocument.swift`
- Test: `App/Tests/ContentViewLifecycleTests.swift`

**Interfaces:**
- Consumes: `GridRenderer.suspendPaintDisplayPreparationForCapture()`, `GridRenderer.completePendingInteractiveStrokeAndAwaitIdle(...)`, staged file URLs.
- Produces: `StageDAppRouteEvidenceRecorder.withDisplayPreparationSuspended(for:operation:)`, `StagedEditorExportDocument`, and the native macOS export presenter.

- [x] Add behavioral tests proving an unconfigured product recorder suspends display preparation, waits for quiescence, resumes after errors, and exposes UTType-correct staged documents.
- [x] Run the focused tests and confirm the new expectations fail against the current implementation.
- [x] Implement the shared quiescent capture boundary and unified staged-file presentation.
- [x] Route both Save As and PNG export through the boundary and clear staging on completion/cancellation.
- [x] Run the focused tests and confirm they pass.

### Task 2: Locked-layer stroke admission

**Files:**
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Test: `App/Tests/EditorSessionControllerTests.swift`

**Interfaces:**
- Consumes: `LayerStack.activeLayerForRasterMutation()`.
- Produces: `StrokeBeginAdmissionResult.activeLayerLocked`.

- [x] Add a controller test that locks the active layer, submits a began sample, and requires an idle transaction, no renderer error, and a locked admission result.
- [x] Run the exact test and confirm it fails because the current route reports `commandFailed`.
- [x] Distinguish `LayerStackError.activeLayerLocked` at stroke admission and reject it without renderer work.
- [x] Run the exact and surrounding controller tests and confirm they pass.

### Task 3: Stage 4 replay lifecycle

**Files:**
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Test: `App/Tests/BrushLabSessionTests.swift`

**Interfaces:**
- Consumes: the first `BrushLabManualCard.fixedMatrix` card and production `replaySelectedManualCard()`.
- Produces: published `isLoading` state for the replay lifetime, one monotonic completion deadline, cancellation invalidation, and observable idle control gates.

- [x] Add a bounded regression test for the exact first periodic Airbrush Stage 4 card.
- [x] Run the exact test and prove that replay/evidence completes while the view remains stale on a non-observable renderer property.
- [x] Publish nesting-safe loading across each replay route and derive button gates from observable session/controller state without reducing evidence.
- [x] Bound the full Stage 4 replay with one 30-second monotonic deadline and make timeout/cancellation invalidate stale work through one single-resolution arbiter.
- [x] Run the exact replay, timeout, cancellation, focused regression, and in-app first-card workflows.

### Task 4: End-to-end verification and integration

**Files:**
- Modify: `docs/superpowers/plans/2026-08-13-end-user-functional-bug-fixes.md`
- Modify: `docs/superpowers/reports/2026-08-04-stage-d-acceptance.md`

**Interfaces:**
- Consumes: the corrected app build and all focused regression tests.
- Produces: fresh automated and in-app evidence for all four user workflows.

- [x] Run all app tests and relevant Swift package tests from a clean build product.
- [x] Launch the app and verify Save As writes a valid project, PNG export writes a decodable nonempty image, locked-layer drawing stays error-free, and the Stage 4 replay re-enables its controls.
- [x] Run `git diff --check`, inspect the full diff, and update this checklist and status documents with exact evidence.
- [x] Commit the reviewed changes on `main` and push `origin/main`.

## Verification Record

- Pre-review focused package selection: 7 tests in 3 suites passed in 1.550
  seconds.
- Final-source focused package selection: 9 tests in 3 suites passed in 1.428
  seconds. Log SHA-256:
  `43e8622c0a4f816f06a719587917378606c6e889a55150026b3792f8c9d71b1c`.
- Pre-review complete package run: 2,210 tests in 120 suites passed in
  1,975.207 seconds with zero failures. Final-source counts, including the
  deadline and cancellation regressions: 2,212 tests in 120 suites passed in
  1,711.875 seconds with zero failures.
- Final broad log SHA-256:
  `fe3eeea98194d98e4efcd2b074c001bc428405adfd5d56f273bdff35082ab943`.
- Fresh `PatternSpikeMac` Debug `build-for-testing`, including the signed UI
  runner, and fresh `PatternSpikePad` Debug iOS Simulator build both passed.
  Their final-source log SHA-256 values are
  `e046e48274b3897f9895662bdc2e52600d8468a3bc09d7b4e89470429bafc024`
  and
  `a96ca156230f6401c4e138354b8f65c4ff53e30cfe406dfba2d2fd35b6995bab`,
  respectively.
- Save As wrote a 527,211-byte schema-4 `.patternproj`; ZIP validation
  reported every manifest, layer, surface, tile, and tiling entry intact.
- Export PNG wrote a decodable 256 x 256 RGBA image containing 10,237 pixels
  with nonzero alpha.
- Drawing on the locked active layer remained an idle rejected gesture with no
  low-level renderer banner; a direct before/after canvas comparison changed
  only the transient brush-cursor rectangle and no painted pixels.
- The exact first periodic Airbrush card replay completed and re-enabled
  Export, Replay All Passes, and Clear Card in approximately 3.3 seconds;
  the final-source app repeated the workflow in approximately 2.2 seconds.
- The new exact XCTest UI regression builds, but its standalone final-source
  rerun never began the test method because the runner could not enable XCTest
  automation on this host within the 60-second initialization timeout. The
  result bundle reports zero passed tests and one runner-initialization
  failure. The same workflow was therefore exercised directly in the built
  app.
