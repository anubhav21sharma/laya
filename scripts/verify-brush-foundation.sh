#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/brush-foundation-artifacts"
scratch="$repo_root/.build/brush-foundation-swiftpm"
logical_baseline="$repo_root/Tests/EditorCoreTests/Fixtures/brush-logical-v1.json"
renderer_baseline="$repo_root/App/PatternSpike/Harness/Baselines/brush-foundation-v1.json"
scene_source="$repo_root/App/PatternSpike/Harness/Scenes"
logs="$artifacts/logs"

fail() {
  printf 'BRUSH FOUNDATION ERROR: %s\n' "$*" >&2
  exit 1
}

verify_clean_build_inputs() {
  git diff --quiet || fail "tracked working tree differs from committed HEAD"
  git diff --cached --quiet || fail "index differs from committed HEAD"
  if git ls-files --others --exclude-standard -- \
    Sources Tests App/PatternSpike Package.swift Package.resolved \
    scripts Config Configuration .github | grep -q .; then
    fail "untracked build input exists; evidence requires committed source"
  fi
}

run_logged() {
  local name="$1"
  shift
  "$@" >"$logs/$name.stdout.log" 2>"$logs/$name.stderr.log"
}

cd "$repo_root"
verify_clean_build_inputs
commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "HEAD is not a full commit identity"

rm -rf "$artifacts" "$scratch"
mkdir -p "$artifacts" "$logs" "$artifacts/scene-inputs"

# Slice 4 is the existing authoritative full matrix: it runs the serial Swift
# test suite, bootstrap, macOS/iPad build+analyze, and all 16 scene processes.
set +e
./scripts/verify-slice4.sh \
  >"$logs/slice4-gate.stdout.log" \
  2>"$logs/slice4-gate.stderr.log"
slice4_status=$?
set -e
case "$slice4_status" in
  0) ;;
  2)
    pending_line_count="$(
      grep -Ec '^SLICE4 PERFORMANCE PENDING: unstable real-Metal timing environment .+\.$' \
        "$logs/slice4-gate.stderr.log" || true
    )"
    completion_line="SLICE4 CORRECTNESS PASS; PERFORMANCE PENDING artifacts=$repo_root/.build/slice4-artifacts commit=$commit"
    completion_line_count="$(
      grep -Fxc "$completion_line" "$logs/slice4-gate.stderr.log" || true
    )"
    total_line_count="$(
      wc -l <"$logs/slice4-gate.stderr.log" | tr -d ' '
    )"
    if [[ -s "$logs/slice4-gate.stdout.log" \
        || "$pending_line_count" -ne 1 \
        || "$completion_line_count" -ne 1 \
        || "$total_line_count" -ne 2 ]]; then
      cat "$logs/slice4-gate.stderr.log" >&2
      fail "Slice 4 exit 2 was not the exact recognized pending condition"
    fi
    ;;
  *)
    cat "$logs/slice4-gate.stderr.log" >&2
    fail "Slice 0-4 correctness gate failed"
    ;;
esac

scene_names=(
  slice4-legacy-ink-parity
  slice4-pressure-scatter
  slice4-dry-grain-tilings
  slice4-glaze-live-commit
  slice4-wash-bounds
  slice4-prediction-taper-replay
  slice4-stale-epoch-cancel
  slice4-long-stroke-bounds
)
positive="$artifacts/positive"
negative="$artifacts/negative-control"
negative_work="$artifacts/negative-work"
binary="$repo_root/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
[[ -x "$binary" ]] || fail "Mac harness binary is unavailable: $binary"
mkdir -p "$positive" "$negative" "$negative_work"
for name in "${scene_names[@]}"; do
  cp "$scene_source/$name.json" "$artifacts/scene-inputs/$name.json"
  cp "$scene_source/$name-negative-control.json" \
    "$artifacts/scene-inputs/$name-negative-control.json"

  positive_output="$positive/$name"
  negative_output="$negative/$name"
  work_output="$negative_work/$name"
  mkdir -p "$positive_output" "$negative_output" "$work_output"

  set +e
  "$binary" \
    --harness-scene "$scene_source/$name-negative-control.json" \
    --output-directory "$work_output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  status=$?
  set -e
  printf '%s\n' "$status" >"$negative_output/exit-status.txt"
  [[ "$status" -eq 1 ]] \
    || fail "negative control exit was not exactly 1: $name"
  [[ ! -s "$negative_output/stdout.log" ]] \
    || fail "negative control wrote stdout: $name"
  [[ "$(grep -c '^HARNESS FAIL ' "$negative_output/stderr.log" || true)" -eq 1 ]] \
    || fail "negative control lacks one fail-closed stderr line: $name"

  "$binary" \
    --harness-scene "$scene_source/$name.json" \
    --output-directory "$positive_output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$positive_output/stdout.log" \
    2>"$positive_output/stderr.log" \
    || fail "positive scene failed: $name"
  [[ ! -s "$positive_output/stderr.log" ]] \
    || fail "positive scene wrote stderr: $name"
done
rm -rf "$negative_work"

run_logged foundation-tests \
  swift test --scratch-path "$scratch" --no-parallel
run_logged foundation-bootstrap ./scripts/bootstrap.sh

run_logged logical-and-parity \
  swift run --scratch-path "$scratch" BrushCharacterizationTool \
    record-foundation \
    --logical-output "$artifacts/brush-logical-v1.json" \
    --parity-output "$artifacts/anchor-adapter-parity.json" \
    --commit "$commit"
cmp -s "$logical_baseline" "$artifacts/brush-logical-v1.json" \
  || fail "fresh logical characterization differs from checked baseline"

run_logged renderer-characterization \
  swift run --scratch-path "$scratch" BrushCharacterizationTool \
    merge-renderer \
    --input-root "$artifacts/positive" \
    --output "$artifacts/brush-foundation-v1.json"
cmp -s "$renderer_baseline" "$artifacts/brush-foundation-v1.json" \
  || fail "fresh renderer characterization differs from checked baseline"

run_logged gate-build \
  swift build --scratch-path "$scratch" \
    --product BrushFoundationEvidenceGate
validator="$scratch/debug/BrushFoundationEvidenceGate"
[[ -x "$validator" ]] \
  || fail "BrushFoundationEvidenceGate executable is unavailable"

run_logged compiler-counter-probe \
  "$validator" record-compiler-counters \
    "$artifacts/compiler-counters.json" "$commit"

first="${scene_names[0]}"
first_benchmark="$artifacts/positive/$first/$first.benchmark.json"
gpu_name="$(plutil -extract hardware.gpuName raw -o - "$first_benchmark")"
[[ -n "$gpu_name" ]] || fail "benchmark GPU provenance is empty"
if [[ "$slice4_status" -eq 2 ]]; then
  lower_gpu="$(printf '%s' "$gpu_name" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower_gpu" == *paravirtual* ]] \
    || fail "only a paravirtual GPU may carry performance-pending status"
  printf "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment '%s'.\n" \
    "$gpu_name" >"$artifacts/performance-status.txt"
else
  printf 'accepted\n' >"$artifacts/performance-status.txt"
fi

set +e
"$validator" \
  "$logical_baseline" \
  "$renderer_baseline" \
  "$artifacts" \
  "$commit" \
  >"$logs/foundation-validator.stdout.log" \
  2>"$logs/foundation-validator.stderr.log"
validation_status=$?
set -e

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "commit": "%s",\n' "$commit"
  printf '  "configuration": "Debug",\n'
  printf '  "operatingSystem": "%s",\n' "$(sw_vers -productVersion)"
  printf '  "hardwareMachine": "%s",\n' "$(uname -m)"
  printf '  "hardwareModel": "%s",\n' "$(sysctl -n hw.model)"
  printf '  "gpuName": "%s",\n' "$gpu_name"
  printf '  "artifactRoot": "%s"\n' "$artifacts"
  printf '}\n'
} >"$artifacts/provenance.json"
system_profiler SPDisplaysDataType >"$artifacts/hardware.txt"
sw_vers >"$artifacts/operating-system.txt"
swift --version >"$artifacts/swift-toolchain.txt" 2>&1
xcodebuild -version >"$artifacts/xcode-toolchain.txt"
xcodegen version >"$artifacts/xcodegen-toolchain.txt"
printf '%s\n' "${scene_names[@]}" >"$artifacts/scene-matrix.txt"

[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while foundation evidence was running"
verify_clean_build_inputs
system_profiler SPDisplaysDataType >"$artifacts/hardware-terminal.txt"
sw_vers >"$artifacts/operating-system-terminal.txt"

case "$validation_status" in
  0)
    printf 'BRUSH FOUNDATION PASS artifacts=%s commit=%s\n' \
      "$artifacts" "$commit"
    ;;
  2)
    cat "$logs/foundation-validator.stderr.log" >&2
    printf 'BRUSH FOUNDATION CORRECTNESS PASS; PERFORMANCE PENDING artifacts=%s commit=%s\n' \
      "$artifacts" "$commit" >&2
    exit 2
    ;;
  *)
    cat "$logs/foundation-validator.stderr.log" >&2
    fail "strict foundation evidence validation failed"
    ;;
esac
