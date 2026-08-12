#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/brush-foundation-artifacts"
scratch="$repo_root/.build/brush-foundation-swiftpm"
derived="$repo_root/.build/BrushFoundationDerivedData"
scene_source="$repo_root/App/PatternSpike/Harness/Scenes"
logs="$artifacts/logs"

fail() {
  printf 'BRUSH FOUNDATION ERROR: %s\n' "$*" >&2
  exit 1
}

verify_clean_build_inputs() {
  git diff --quiet \
    || fail "tracked working tree differs from committed HEAD"
  git diff --cached --quiet \
    || fail "index differs from committed HEAD"
  if git ls-files --others --exclude-standard -- \
    Sources Tests App/PatternSpike Package.swift Package.resolved \
    scripts Config Configuration .github docs/superpowers \
    | grep -q .; then
    fail "untracked build input exists; evidence requires committed source"
  fi
}

run_logged() {
  local name="$1"
  local status
  shift
  if "$@" >"$logs/$name.stdout.log" 2>"$logs/$name.stderr.log"; then
    return
  else
    status=$?
  fi
  cat "$logs/$name.stderr.log" >&2
  fail "$name failed with exit $status"
}

cd "$repo_root"
verify_clean_build_inputs
commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || fail "HEAD is not a full commit identity"

rm -rf "$artifacts" "$scratch" "$derived"
mkdir -p \
  "$artifacts/scene-inputs" \
  "$artifacts/positive" \
  "$artifacts/negative-control" \
  "$artifacts/negative-work" \
  "$logs"

run_logged foundation-tests \
  swift test --scratch-path "$scratch" --no-parallel
run_logged foundation-bootstrap ./scripts/bootstrap.sh
run_logged foundation-mac-build xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMacHarness \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath "$derived" \
  build CODE_SIGNING_ALLOWED=NO

binary="$derived/Build/Products/Debug/PatternSpikeHarness.app/Contents/MacOS/PatternSpikeHarness"
[[ -x "$binary" ]] \
  || fail "Mac harness binary is unavailable: $binary"

scene_names=(
  deposition-airbrush
  deposition-cache-pinning
  deposition-custom-asymmetric
  deposition-dry
  deposition-erase
  deposition-failure-matrix
  deposition-glaze
  deposition-ink
  deposition-kinematics
  deposition-layer-matrix
  deposition-marker
  deposition-periodic-seams
  deposition-prediction
  deposition-preview-commit
  deposition-radial-reflection
  deposition-stamp-size-mips
)

for name in "${scene_names[@]}"; do
  positive_scene="$scene_source/$name.json"
  negative_scene="$scene_source/$name-negative-control.json"
  [[ -f "$positive_scene" && -f "$negative_scene" ]] \
    || fail "native deposition scene pair is missing: $name"
  cp "$positive_scene" "$artifacts/scene-inputs/$name.json"
  cp "$negative_scene" \
    "$artifacts/scene-inputs/$name-negative-control.json"

  positive_output="$artifacts/positive/$name"
  negative_output="$artifacts/negative-control/$name"
  negative_work="$artifacts/negative-work/$name"
  mkdir -p "$positive_output" "$negative_output" "$negative_work"

  set +e
  "$binary" \
    --harness-scene "$negative_scene" \
    --output-directory "$negative_work" \
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
  [[ "$(wc -l <"$negative_output/stderr.log" | tr -d ' ')" -eq 1 ]] \
    || fail "negative control did not write one stderr line: $name"
  grep -q '^HARNESS FAIL .\+$' "$negative_output/stderr.log" \
    || fail "negative control lacks the fail-closed marker: $name"

  "$binary" \
    --harness-scene "$positive_scene" \
    --output-directory "$positive_output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$positive_output/stdout.log" \
    2>"$positive_output/stderr.log" \
    || fail "positive scene failed: $name"
  [[ ! -s "$positive_output/stderr.log" ]] \
    || fail "positive scene wrote stderr: $name"
done
rm -rf "$artifacts/negative-work"

run_logged foundation-gate-build \
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
configuration="$(
  plutil -extract build.configuration raw -o - "$first_benchmark"
)"
operating_system="$(
  plutil -extract operatingSystem raw -o - "$first_benchmark"
)"
[[ -n "$gpu_name" ]] || fail "benchmark GPU provenance is empty"
[[ -n "$configuration" ]] \
  || fail "benchmark configuration provenance is empty"
[[ -n "$operating_system" ]] \
  || fail "benchmark operating-system provenance is empty"
printf 'accepted\n' >"$artifacts/performance-status.txt"

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "commit": "%s",\n' "$commit"
  printf '  "configuration": "%s",\n' "$configuration"
  printf '  "operatingSystem": "%s",\n' "$operating_system"
  printf '  "hardwareMachine": "%s",\n' "$(uname -m)"
  printf '  "hardwareModel": "%s",\n' "$(sysctl -n hw.model)"
  printf '  "gpuName": "%s",\n' "$gpu_name"
  printf '  "artifactRoot": "%s"\n' "$artifacts"
  printf '}\n'
} >"$artifacts/provenance.json"
plutil -p "$artifacts/provenance.json" >/dev/null \
  || fail "foundation provenance JSON is invalid"

system_profiler SPDisplaysDataType >"$artifacts/hardware.txt"
sw_vers >"$artifacts/operating-system.txt"
swift --version >"$artifacts/swift-toolchain.txt" 2>&1
xcodebuild -version >"$artifacts/xcode-toolchain.txt"
xcodegen version >"$artifacts/xcodegen-toolchain.txt"
printf '%s\n' "${scene_names[@]}" >"$artifacts/scene-matrix.txt"

run_logged foundation-validator \
  "$validator" "$artifacts" "$commit"

[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while foundation evidence was running"
verify_clean_build_inputs

printf 'BRUSH FOUNDATION PASS artifacts=%s commit=%s\n' \
  "$artifacts" "$commit"
