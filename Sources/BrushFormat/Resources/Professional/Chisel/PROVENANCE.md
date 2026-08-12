# Chisel Marker resource provenance

- Resource ID: `builtin.shape.marker-chisel`.
- Editable source: `Sources/chisel-tip-source.png` (SHA-256
  `bde10cd09780d0f580892d777b04da42bd09ce65d2855e801d7986a7f10d0dbc`).
- Source creation: OpenAI built-in image generation on 2026-08-12 from the
  project prompt for one isolated, straight-on, broad vertical marker contact
  on black.
- Normalization: centered square crop, 128 x 128 high-quality resize, integer
  luminance, and 2nd/99.5th percentile expansion via
  `scripts/normalize-professional-brush-asset.swift tip 128`.
- Derived PNG SHA-256:
  `24e997d9b90a4df2378ac95687f48551d3660bf3c38185fc6620ea38612538d8`.
- Runtime R8 SHA-256:
  `3dabef4087df68a0f0ecf4d588eebc9f485fe407d542f85fe68cfd8bd5dae643`.
- Support: narrow horizontal / broad vertical R8 mask, compiled support,
  maximum intended diameter 512 logical pixels, CPU box-average mips.
- Ownership/license: project-authored generated artwork for Laya project use;
  not an exact or resampled third-party resource.
