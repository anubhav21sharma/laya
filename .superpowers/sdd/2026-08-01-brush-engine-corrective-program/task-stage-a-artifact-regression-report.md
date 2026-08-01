# Stage A corrective report: professional harness artifact isolation

## Scope

Restore the Stage 5 professional artifact contract without re-admitting the
four rejected professional presets to the product catalog or changing the
intentional-red corrective brush baseline.

## Root-cause trace

1. `ProfessionalBrushHarnessRunnerTests` reproduced six issues: four positive
   scenes rejected their canonical PNG, aggregate validation rejected another
   raster, and end-to-end validation rejected scene identity.
2. `DepositionHarnessRunner.run` derives its render target from
   `HarnessScene.width` and `HarnessScene.height`. `finishProfessionalRun`
   passes those scene-sized textures and observation byte arrays to the UUID
   backed atomic PNG writer.
3. The writer emits one valid PNG at the supplied dimensions. Its temporary
   files and each test's output root were already unique; no shared-path or
   concatenated-byte corruption was found.
4. `RasterObservationValidator` and `SceneInputValidator` independently bind
   Stage 5 artifacts to 128 by 128 pixels.
5. Commit `bedb765` changed the four shared positive scene JSON files from
   128 by 128 to 512 by 512 so Task 2's long direct-input traces would not be
   clipped. The last passing revision used 128 by 128. Therefore the runner
   correctly wrote 512 by 512 files that the Stage 5 contract correctly
   rejected: the corrective tests had taken ownership of artifact fixtures
   they did not own.

## TDD evidence

Before the fix, the full reproduction was:

```text
swift test --filter ProfessionalBrushHarnessRunnerTests
11 tests, 6 issues, exit 1
four canonical-is-not-one-128x128 failures
one prediction-off-is-not-one-128x128 failure
one scene schema-or-filename-identity failure
```

The minimal regression
`artifactSceneDimensionsStayIndependentFromCorrectiveCanvases` loads the real
repository scene corpus and checks the hand-derived 128 by 128 Stage 5
contract. Its RED run failed on width and height for all four positive scenes:

```text
swift test --filter artifactSceneDimensionsStayIndependentFromCorrectiveCanvases
1 test, 8 issues, exit 1
actual width/height: 512; expected width/height: 128
```

After the isolation fix, the same command passed one test with zero issues.

## Fix

- Restored all four positive Stage 5 scene fixtures to 128 by 128.
- Removed the corrective renderer's dependency on repository scene sizes.
- Gave corrective functional traces a dedicated, test-owned 512 by 512 canvas
  and a bounds regression proving every trace retains a 32-pixel safety margin.
- Left the professional product catalog unchanged; the four presets remain
  Brush Lab/manual candidates.

## Verification

```text
swift test --filter ProfessionalBrushHarnessRunnerTests
12 tests, 0 issues, exit 0

swift test --filter 'ProfessionalBrushEvidenceValidatorTests|PatternRasterPNGCodecTests|rawBGRAAndCoveragePNGArtifactsAreActuallyWritten'
21 tests, 0 issues, exit 0

swift test --filter 'BrushCorrectiveFunctionalTests|ProfessionalStrokeTraceTests'
12 tests, 7 intentional issues, exit 1
```

The intentional-red baseline retained the exact five reported defects and
measurements: retained Technical Ink body 280, endpoint retreat 24 pixels,
Graphite p50/p95 width 10/10, Charcoal changed pixels/median alpha 0/0, and
Chisel protrusion 13.5 pixels. `git diff --check` passed.

## Residual risk

- The five corrective brush failures intentionally remain red until their
  owning implementation stages; this task only restores fixture isolation.
- The corrective canvas size is local test infrastructure, not a product or
  artifact format contract.
- Physical-device quality and performance remain outside this regression's
  scope; no iPad-dependent claim is made.
