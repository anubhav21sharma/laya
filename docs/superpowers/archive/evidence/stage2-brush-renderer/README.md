# Stage 2 Brush Renderer Evidence Archive

These 16 schema-5 Slice 4 scene definitions originated in commit
`bf3a6cba109fe612cc2bcde0b941475441287583`
(`feat(brush): complete professional stroke core`).

They are archived because the generic stamp renderer and bounded-wash backend
have been removed in favor of the native deposition backend. The archived
scene JSON is preserved byte-for-byte from its originating source location.
Its historical expected digests and pixels are non-gating and must not be
regenerated or rebaselined against the deposition renderer.

The replacement Stage 4 evidence scenes are:

- `deposition-ink`
- `deposition-dry`
- `deposition-glaze`
- `deposition-marker`
- `deposition-airbrush`
- `deposition-erase`
- `deposition-custom-asymmetric`
- `deposition-layer-matrix`
- `deposition-stamp-size-mips`
- `deposition-kinematics`
- `deposition-periodic-seams`
- `deposition-radial-reflection`
- `deposition-prediction`
- `deposition-preview-commit`
- `deposition-cache-pinning`
- `deposition-failure-matrix`

Each replacement scene has its own paired `-negative-control` scene in the
active PatternSpike harness scene directory.
