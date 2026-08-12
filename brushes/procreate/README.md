# Procreate charcoal replacement corpus

This directory pins the author-supplied `FREE Charcoal Set` and two
project-owned paper photographs used by Laya's offline brush-conversion and
resource-authoring tests. The archive is never parsed by the production app and
is not bundled in release products.

`corpus.json` is the acceptance boundary. Replacing an archive or photograph
requires a new manifest revision, an explicitly reviewed SHA-256 change, and a
green `ProcreateCharcoalCorpusTests` run. Accepted hashes must never be edited
silently.

The target Procreate Source Library files are absent from the archive. Laya
uses independently owned role-equivalent substitutions and records them as
approximations, never as exact or resampled Procreate resources.

`1_FREE_Charcoal_Set.key` is opaque ancillary material. It is excluded from
parsing, fixtures, packages, and release targets.
