#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  all|tip-support-spacing|sensor-program|input-derivation|stage-c|stage-c-emission)
    scope=$1
    scratch="$repo_root/.build/brush-input-allocation-probe"
    configuration="${2:-release}"
    ;;
  *)
    scratch="${1:-$repo_root/.build/brush-input-allocation-probe}"
    configuration="${2:-release}"
    scope="${3:-all}"
    ;;
esac
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

run_probe() {
  DYLD_INSERT_LIBRARIES="$probe" \
    "$helper" "$1" "$repo_root"
}

case "$scope" in
  all)
    run_probe --self-test
    run_probe --velocity-filter
    run_probe --input-derivation
    run_probe --direction-corner
    run_probe --stabilizer-v2
    run_probe --stage-c-generator
    run_probe --stage-c-emission
    run_probe --timed-emitter
    run_probe --tip-support-spacing
    run_probe --sensor-program
    run_probe --production
    ;;
  tip-support-spacing)
    run_probe --self-test
    run_probe --tip-support-spacing
    ;;
  sensor-program)
    run_probe --self-test
    run_probe --sensor-program
    ;;
  input-derivation)
    run_probe --self-test
    run_probe --input-derivation
    ;;
  stage-c)
    run_probe --self-test
    run_probe --stage-c-generator
    run_probe --stage-c-emission
    run_probe --production
    ;;
  stage-c-emission)
    run_probe --self-test
    run_probe --stage-c-emission
    ;;
  *)
    printf 'unsupported allocator probe scope: %s\n' "$scope" >&2
    exit 1
    ;;
esac
