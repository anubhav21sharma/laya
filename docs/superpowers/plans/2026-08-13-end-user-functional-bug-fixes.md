# End-User Functional Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Save As, PNG export, locked-layer drawing, and Stage 4 Brush Lab replay work reliably through the normal end-user UI.

**Architecture:** Normal file operations use the same serialized quiescent-capture boundary as acceptance evidence and export staged files through explicit UTType-aware `Transferable` wrappers. Stroke admission rejects locked active layers before creating a transaction. Brush Lab fixes the exact renderer lifecycle leak or unfinished operation proven by the first periodic Airbrush card regression.

**Tech Stack:** Swift 6, SwiftUI, CoreTransferable, Metal, Swift Testing, XCTest.

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
- Produces: `StageDAppRouteEvidenceRecorder.withDisplayPreparationSuspended(for:operation:)`, `PatternProjectExportTransfer`, and `PNGExportTransfer`.

- [ ] Add behavioral tests proving an unconfigured product recorder suspends display preparation, waits for quiescence, resumes after errors, and exposes UTType-correct staged transfers.
- [ ] Run the focused tests and confirm the new expectations fail against the current implementation.
- [ ] Implement the shared quiescent capture boundary and explicit staged-file transfers.
- [ ] Route both Save As and PNG export through the boundary and clear staging on completion/cancellation.
- [ ] Run the focused tests and confirm they pass.

### Task 2: Locked-layer stroke admission

**Files:**
- Modify: `App/PatternSpike/EditorSessionController.swift`
- Test: `App/Tests/EditorSessionControllerTests.swift`

**Interfaces:**
- Consumes: `LayerStack.activeLayerForRasterMutation()`.
- Produces: `StrokeBeginAdmissionResult.activeLayerLocked`.

- [ ] Add a controller test that locks the active layer, submits a began sample, and requires an idle transaction, no renderer error, and a locked admission result.
- [ ] Run the exact test and confirm it fails because the current route reports `commandFailed`.
- [ ] Distinguish `LayerStackError.activeLayerLocked` at stroke admission and reject it without renderer work.
- [ ] Run the exact and surrounding controller tests and confirm they pass.

### Task 3: Stage 4 replay lifecycle

**Files:**
- Modify: `App/PatternSpike/BrushLab/BrushLabSession.swift`
- Test: `App/Tests/BrushLabSessionTests.swift`

**Interfaces:**
- Consumes: the first `BrushLabManualCard.fixedMatrix` card and production `replaySelectedManualCard()`.
- Produces: a completed replay with `controller.renderer.isIdle == true` inside a monotonic timeout.

- [ ] Add a bounded regression test for the exact first periodic Airbrush Stage 4 card.
- [ ] Run the exact test and capture whether the stall is stroke completion, event delivery, stable capture, or display preparation.
- [ ] Implement the minimal lifecycle correction at the proven boundary without reducing evidence.
- [ ] Run the exact replay test repeatedly and the full Brush Lab session suite.

### Task 4: End-to-end verification and integration

**Files:**
- Modify: `docs/superpowers/plans/2026-08-13-end-user-functional-bug-fixes.md`
- Modify: `docs/superpowers/reports/2026-08-04-stage-d-acceptance.md`

**Interfaces:**
- Consumes: the corrected app build and all focused regression tests.
- Produces: fresh automated and in-app evidence for all four user workflows.

- [ ] Run all app tests and relevant Swift package tests from a clean build product.
- [ ] Launch the app and verify Save As writes/reopens a project, PNG export writes a decodable nonempty image, locked-layer drawing stays error-free, and the Stage 4 replay re-enables its controls.
- [ ] Run `git diff --check`, inspect the full diff, and update this checklist and status documents with exact evidence.
- [ ] Commit the reviewed changes on `main` and push `origin/main`.
