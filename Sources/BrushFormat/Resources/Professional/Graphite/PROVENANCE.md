# Graphite resource provenance

## Irregular tip

- Resource ID: `builtin.shape.graphite-tip`.
- Editable source: `Sources/graphite-tip-source.png` (SHA-256
  `d7ca83d2d1c163e0f9551035acb45281a592fbfc232a9d2202335224be914674`).
- Source creation: OpenAI built-in image generation on 2026-08-12, using the
  two project-owned paper photographs only as physical-fiber references.
- Normalization: centered square crop, 128 x 128 high-quality resize, integer
  luminance conversion, and 2nd/99.5th percentile expansion via
  `scripts/normalize-professional-brush-asset.swift tip 128`.
- Derived PNG SHA-256:
  `c607e7baa208457e272ea48ba0970ff084d4bab3f379672743c7331bab418fab`.
- Runtime R8 SHA-256:
  `fd896137448eb5582b3958eeb56f2a39c453e01a041f4cc7d12dc1dda84c0f79`.
- Maximum intended rendered diameter: 384 logical pixels; CPU box-average
  mips; nonzero support is compiled from the R8 base level.

## Independent paper grain

- Resource ID: `builtin.grain.graphite-paper`.
- Owned source: `brushes/procreate/DSC_0006.jpg`, 4000 x 6000, SHA-256
  `5ce41606b51036394f841f519b7af45e9316012145d48acbe76cc7a5e43d309f`.
- Transform: EXIF-up decode, centered square crop at 35% of the shortest edge,
  256 x 256 high-quality resize, integer luminance, separable 33 x 33 local
  illumination estimate, doubled high-pass detail around level 192,
  1st/99th percentile expansion to 96...255, and symmetric 32-pixel opposing
  edge blending for periodic seams.
- Derived PNG SHA-256:
  `09839ea5c534f96286a54b3dcaa43d001097d1ad3d66bfcb00089187aef40a1d`.
- Runtime R8 SHA-256:
  `519372f74c7df9047d5773f0373f6e6ec6a9db3037d78e03fd710450d2125b38`.
- Maximum intended rendered diameter: 768 logical pixels; canonical
  brush-local coordinates; CPU box-average mips.

All resources are project-owned inputs or project-authored generated artwork.
They are not copied, exact, or resampled Procreate Source Library resources.
