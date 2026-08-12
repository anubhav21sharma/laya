# Natural Charcoal resource provenance

These resources are project-owned substitutes with the same physical roles as
three absent Procreate Source Library names. They are deliberately not called
exact, copied, or resource-resampled.

## Irregular oval tip

- Resource ID: `builtin.shape.charcoal-tip`.
- Substitutes for role only: `Haggard-Oval.png`.
- Editable source: `Sources/charcoal-tip-source.png`, 1254 x 1254, SHA-256
  `7d9fc69a7c1e481ab8f302fd903c196673137158a544ddde86aa17d0cf73785f`.
- Source creation: OpenAI built-in image generation on 2026-08-12. Prompt:
  one isolated broad irregular charcoal oval, porous interior and eroded edge,
  grayscale on flat black, informed only by the project paper photographs.
- Transform: centered square crop, 128 x 128 high-quality resize, integer
  Rec. 709 luminance, 2nd/99.5th percentile expansion.
- Derived PNG SHA-256:
  `d894b2560a86e2c6425b1f197a2be1effe98ebed0beeb33269a8a595078014ad`.
- Runtime R8 SHA-256:
  `2a971cb99a62679fe00dd13bea9320c166100f84456a23fb6c82642872de3e69`.
- Support: compiled from nonzero R8 coverage with a black outer border;
  maximum useful diameter 512 logical pixels; CPU box-average mips.

## Fine paper-tooth grain

- Resource ID: `builtin.grain.charcoal-fine-paper`.
- Substitutes for role only: `Brush-Preset-Bonobo.png`.
- Owned source: `brushes/procreate/DSC_0175.jpg`, 3536 x 4624, SHA-256
  `929f5c3b301bfcee2acd0367b0147af4c27bc775547f50a347d3dc8c24a172d0`.
- Transform: EXIF-up decode; centered square crop at 35% of the shortest edge;
  256 x 256 high-quality resize; integer luminance; separable 33 x 33 local
  illumination removal; doubled high-pass detail around level 192;
  1st/99th percentile expansion to 96...255; 32-pixel symmetric opposing-edge
  blend for periodic seams.
- Derived PNG SHA-256:
  `a15c7ae3bfa8b1d2717bfaebb1660f945477bdae6909aab68318f00a4a3d6b3f`.
- Runtime R8 SHA-256:
  `da3803d73034a64619886d1bfcd3d710a46995d7b827cc0a0a6c9338e1886bff`.
- Intended role: fine parent paper tooth; canonical coordinates; maximum
  useful diameter 1024 logical pixels; CPU box-average mips.

## Coarse fibrous charcoal grain

- Resource ID: `builtin.grain.charcoal`.
- Substitutes for role only: `Brush-Artery-Charcoal-Corse.jpg`.
- Editable source: `Sources/charcoal-coarse-grain-source.png`, 1254 x 1254,
  SHA-256
  `d05f0d96a52a908227830e9133e51834e6ec08c1bdb81a3009b38f133df10c64`.
- Source creation: OpenAI built-in image generation on 2026-08-12. Prompt:
  edge-to-edge coarse fibrous charcoal/paper texture, grayscale, no lighting
  gradient or central subject, informed by both project paper photographs.
- Transform: the same 35% crop, luminance, illumination correction, contrast,
  and periodic 32-pixel edge blend used for the fine grain.
- Derived PNG SHA-256:
  `9a835e125011c1e1a572c2d77a683422dc2bada1ea4c17c5372d84b59dd2688d`.
- Runtime R8 SHA-256:
  `cadd1bc2f935d0a52e9ddaaddd11e5fc2831f833c51c6963e492ac75439a9edb`.
- Intended role: coarse child-component breakup; canonical coordinates;
  maximum useful diameter 1024 logical pixels; CPU box-average mips.

Normalization toolchain: Apple Swift 6.3.3, CoreGraphics/ImageIO from the
installed macOS SDK, and
`scripts/normalize-professional-brush-asset.swift` as committed. The source
photographs are project-supplied/owned. The generated source artwork is
project-authored for Laya. Replacement requires new hashes, provenance, and a
new substitution-manifest revision.
