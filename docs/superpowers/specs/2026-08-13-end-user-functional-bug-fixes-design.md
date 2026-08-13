# End-User Functional Bug Fixes Design

## Scope

Repair the four reproducible failures found in the 2026-08-13 in-app
functional pass without changing the editor's visible workflow:

- Save As must present a destination picker and write a valid
  `.patternproj` package.
- Export PNG must present a destination picker and write a nonempty,
  decodable PNG without racing display composition.
- Starting a stroke on the active locked layer must be rejected before any
  renderer work begins and must not surface an internal Metal error.
- A Stage 4 Brush Lab replay must complete and return the renderer and its
  controls to an idle state within a bounded user-facing interval.

## Design

File capture and export share one product-route coordinator. It serializes
captures, suspends paint display preparation, drives the controller and
renderer to quiescence, runs the capture, and resumes display preparation in
all success and failure cases. The normal product route uses this coordinator;
acceptance injection only chooses a direct destination and no longer controls
whether the safety boundary exists.

Temporary project and PNG files use one exporter state instead of two stacked
SwiftUI exporters. On iPadOS, a UTType-aware `FileDocument` owns the staged
bytes until SwiftUI finishes the export. On macOS, an `NSSavePanel` provides
the native synchronous destination workflow before the staged file is written
atomically to the selected URL. This avoids both the raw-`URL` representation
mismatch and the competing exporter modifiers that prevented Save As from
presenting reliably.

Stroke admission distinguishes a locked active layer from an unavailable
layer. A locked layer rejects the begin event, keeps the transaction idle, and
does not report a renderer error.

The Stage 4 replay repair targets the exact first periodic Airbrush card that
reproduces the UI stall. The renderer was already reaching idle; the stale
controls came from reading a non-observable renderer property directly. The
session now publishes replay loading for the whole operation and the view
derives its gates from observable session/controller state. Replay remains
deterministic and evidence-complete. One 30-second monotonic deadline covers
clear, preparation, stroke completion, capture, hashing, and evidence
publication. Deadline expiry or caller cancellation wins through one
single-resolution arbiter, cancels the in-flight work, invalidates the session
generation, and releases loading without publishing a stale replay.

## Error Handling

Capture/export coordination is fail-closed with a monotonic timeout. Errors
remain visible through the existing file error banner. Temporary files are
removed on completion, cancellation, encoding/read failure, and presentation
failure. Canceling the native save panel is a normal completion. Locked-layer
input is an expected rejected gesture, not an error.

## Verification

Each behavior receives a regression test that fails against `fdfcdd3` before
production changes. Focused tests run after each fix, followed by the complete
app test suites, diff checks, and a clean-build in-app round covering Save As,
PNG export, locked-layer drawing, and the formerly stuck Stage 4 replay.
