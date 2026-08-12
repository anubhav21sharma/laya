# Technical Ink resource provenance

- Resource ID: `builtin.shape.technical-nib`
- Intended role: neutral anti-aliased technical-ink shape mask.
- Editable source: `Sources/technical-ink-tip-source.png` (SHA-256
  `c7e2c4fcced2bc0fb2c9ba2293018c233f832681451165f14ddd7af6b289bd23`).
- Source creation: OpenAI built-in image generation on 2026-08-12 from the
  project prompt for one isolated, continuous, neutral nib on black. No
  external brush image was supplied or copied.
- Normalization: `scripts/normalize-professional-brush-asset.swift tip 128`;
  centered square crop, CoreGraphics high-quality resize, integer Rec. 709
  luminance `(54R + 183G + 19B + 128) >> 8`, 2nd/99.5th percentile expansion,
  8-bit grayscale PNG and row-major R8 output.
- Derived PNG SHA-256:
  `be42efb232b3735000c2a8f641b86ce2ef7bc0045566252a3684b6b108de2806`.
- Runtime R8 SHA-256:
  `9d7f3309b05ca4de7d998e10c1984f4e16f958e2cba2dc6c328c573b9ee47ff9`.
- Support: nonzero authored tip inside a 128 x 128 mask with black border;
  maximum intended rendered diameter 512 logical pixels; CPU box-average mips.
- Ownership/license: project-authored generated artwork, admitted for Laya
  project use. It is not an exact or resampled third-party brush resource.
