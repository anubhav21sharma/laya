#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/slice4-artifacts"
positive="$artifacts/positive"
negative="$artifacts/negative-control"
negative_work="$artifacts/negative-work"
logs="$artifacts/gate-logs"
scenes="$repo_root/App/PatternSpike/Harness/Scenes"
derived="$repo_root/.build/DerivedData"
derived_pad="$repo_root/.build/DerivedDataPad"
binary="$derived/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"

fail() {
  printf 'SLICE4 GATE ERROR: %s\n' "$*" >&2
  exit 1
}

cd "$repo_root"

git diff --quiet || fail "tracked working tree differs from committed HEAD"
git diff --cached --quiet || fail "index differs from committed HEAD"
if git ls-files --others --exclude-standard -- \
  Sources Tests App/PatternSpike Package.swift Package.resolved \
  scripts Config Configuration .github | grep -q .; then
  fail "untracked build input exists; Slice 4 evidence requires committed source"
fi

commit="$(git rev-parse HEAD)"
rm -rf "$artifacts"
mkdir -p "$positive" "$negative" "$negative_work" "$logs"

run_logged() {
  local name="$1"
  shift
  "$@" >"$logs/$name.stdout.log" 2>"$logs/$name.stderr.log"
}

# Slice 3 already reruns Slice 0, Slice 1 with PATTERN_SKIP_PERFORMANCE=1,
# and the complete Slice 2 correctness matrix. A paravirtual host is allowed
# to leave only Slice 3 timing acceptance pending after all of that evidence
# has passed; every other nonzero exit remains fatal.
set +e
./scripts/verify-slice3.sh \
  >"$logs/slice0-through-3-correctness.stdout.log" \
  2>"$logs/slice0-through-3-correctness.stderr.log"
prior_status=$?
set -e
if [[ "$prior_status" -ne 0 ]]; then
  prior_stderr="$logs/slice0-through-3-correctness.stderr.log"
  pending_line_count="$(grep -Ec '^SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment .+\.$' "$prior_stderr" || true)"
  gate_line_count="$(grep -Fxc 'SLICE3 GATE ERROR: stable real-Metal performance acceptance remains pending' "$prior_stderr" || true)"
  total_line_count="$(wc -l <"$prior_stderr" | tr -d ' ')"
  if [[ "$prior_status" -ne 1 || "$pending_line_count" -ne 1 \
      || "$gate_line_count" -ne 1 || "$total_line_count" -ne 2 ]]; then
    cat "$prior_stderr" >&2
    fail "Slice 0-3 correctness regression failed"
  fi
fi
run_logged pure-pattern-tests swift test --no-parallel --filter PatternEngineTests
run_logged full-tests swift test --no-parallel
run_logged bootstrap ./scripts/bootstrap.sh
run_logged mac-build xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath "$derived" \
  build CODE_SIGNING_ALLOWED=NO
run_logged mac-analyze xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath "$derived" \
  analyze CODE_SIGNING_ALLOWED=NO
run_logged ipad-build xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_pad" \
  build CODE_SIGNING_ALLOWED=NO
run_logged ipad-analyze xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_pad" \
  analyze CODE_SIGNING_ALLOWED=NO

[[ -x "$binary" ]] || fail "Mac harness binary is unavailable: $binary"

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

for name in "${scene_names[@]}"; do
  positive_output="$positive/$name"
  negative_output="$negative/$name"
  work_output="$negative_work/$name"
  mkdir -p "$positive_output" "$negative_output" "$work_output"

  set +e
  "$binary" \
    --harness-scene "$scenes/$name-negative-control.json" \
    --output-directory "$work_output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  status=$?
  set -e
  printf '%s\n' "$status" >"$negative_output/exit-status.txt"
  [[ "$status" -eq 1 ]] || fail "negative control exit was not exactly 1: $name"
  [[ ! -s "$negative_output/stdout.log" ]] \
    || fail "negative control wrote stdout: $name"
  [[ "$(grep -c '^HARNESS FAIL ' "$negative_output/stderr.log" || true)" -eq 1 ]] \
    || fail "negative control lacks one fail-closed stderr line: $name"

  "$binary" \
    --harness-scene "$scenes/$name.json" \
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

run_logged evidence-gate-build swift build --product SliceFourEvidenceGate
validator="$repo_root/.build/debug/SliceFourEvidenceGate"
[[ -x "$validator" ]] || fail "SliceFourEvidenceGate executable is unavailable"

set +e
"$validator" "$positive" "$negative" "$scenes" "$commit" \
  >"$logs/evidence-validator.stdout.log" \
  2>"$logs/evidence-validator.stderr.log"
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
  printf '  "artifactRoot": "%s"\n' "$artifacts"
  printf '}\n'
} >"$artifacts/provenance.json"
system_profiler SPDisplaysDataType >"$artifacts/hardware.txt"
sw_vers >"$artifacts/operating-system.txt"
printf '%s\n' "${scene_names[@]}" >"$artifacts/scene-matrix.txt"

# Repeat source and machine provenance at the terminal boundary so a long gate
# cannot publish evidence after the tree, commit, or host changed underneath it.
[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while Slice 4 evidence was running"
git diff --quiet || fail "tracked working tree changed while Slice 4 evidence was running"
git diff --cached --quiet || fail "index changed while Slice 4 evidence was running"
if git ls-files --others --exclude-standard -- \
  Sources Tests App/PatternSpike Package.swift Package.resolved \
  scripts Config Configuration .github | grep -q .; then
  fail "untracked build input appeared while Slice 4 evidence was running"
fi
system_profiler SPDisplaysDataType >"$artifacts/hardware-terminal.txt"
sw_vers >"$artifacts/operating-system-terminal.txt"

case "$validation_status" in
  0)
    printf 'SLICE4 GATE PASS artifacts=%s commit=%s\n' "$artifacts" "$commit"
    ;;
  2)
    cat "$logs/evidence-validator.stderr.log" >&2
    printf 'SLICE4 CORRECTNESS PASS; PERFORMANCE PENDING artifacts=%s commit=%s\n' \
      "$artifacts" "$commit" >&2
    exit 2
    ;;
  *)
    cat "$logs/evidence-validator.stderr.log" >&2
    fail "strict evidence validation failed"
    ;;
esac
