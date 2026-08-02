#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="${1:-$repo_root/.build/brush-input-allocation-probe}"
configuration="${2:-release}"
probe="$scratch/$configuration/libLayaAllocationProbe.dylib"
helper="$scratch/$configuration/BrushInputAllocationProbeHarness"

swift build \
  --package-path "$repo_root" \
  --scratch-path "$scratch" \
  --configuration "$configuration" \
  --product BrushInputAllocationProbeHarness

mkdir -p "$(dirname "$probe")"
xcrun clang \
  -std=c11 \
  -O2 \
  -dynamiclib \
  -fvisibility=hidden \
  "$repo_root/Tools/AllocationProbe/LayaAllocationProbe.c" \
  -o "$probe"

[[ -x "$helper" ]] || {
  printf 'allocator probe helper is unavailable: %s\n' "$helper" >&2
  exit 1
}
[[ -f "$probe" ]] || {
  printf 'allocator probe dylib is unavailable: %s\n' "$probe" >&2
  exit 1
}

DYLD_INSERT_LIBRARIES="$probe" \
  "$helper" --self-test "$repo_root"
DYLD_INSERT_LIBRARIES="$probe" \
  "$helper" --velocity-filter "$repo_root"
DYLD_INSERT_LIBRARIES="$probe" \
  "$helper" --direction-corner "$repo_root"
DYLD_INSERT_LIBRARIES="$probe" \
  "$helper" --production "$repo_root"
