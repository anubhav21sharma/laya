#!/usr/bin/env bash
set -eEuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_arch="$(uname -m)"
mac_destination="platform=macOS,arch=$host_arch"
run_name="${1:-run}"
case "$run_name" in
  *[!A-Za-z0-9._-]*|'')
    printf 'invalid run name: %s\n' "$run_name" >&2
    exit 2
    ;;
esac

root="$repo_root/.build/stage-d-acceptance/$run_name"
scratch="$root/swiftpm"
derived_mac="$root/DerivedDataMac"
derived_pad="$root/DerivedDataPad"
derived_ui="$root/DerivedDataUI"
logs="$root/logs"
runtime="$root/runtime"
package_manifest="$root/package-manifest.json"
app_manifest="$repo_root/.build/StageDAppRouteArtifacts/app-route-manifest.json"
xcresult="$root/StageDAppRoutes.xcresult"
final_manifest="$root/acceptance-manifest.json"
run_manifest="$root/run-manifest.json"
reference_manifest="${STAGE_D_ACCEPTANCE_REFERENCE_MANIFEST:-}"
review_evidence="${STAGE_D_ACCEPTANCE_REVIEW_EVIDENCE:-}"
required_ui_test='PatternSpikeMacUITests/StageDAppRouteUITests/testProductionControlsShortcutsAndPersistenceWriteEvidence'
commit="$(git -C "$repo_root" rev-parse HEAD)"
generated_at="${STAGE_D_ACCEPTANCE_DATE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

fail() {
  printf 'STAGE D ACCEPTANCE FAIL: %s\n' "$*" >&2
  exit 1
}

unexpected_error() {
  local status=$?
  printf 'STAGE D ACCEPTANCE FAIL: command exited %s\n' "$status" >&2
  exit "$status"
}
trap unexpected_error ERR

require_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required tool is unavailable: $1"
}

require_clean_worktree() {
  local worktree_status current_commit
  current_commit="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$current_commit" == "$commit" ]] \
    || fail "HEAD changed during acceptance: $commit -> $current_commit"
  worktree_status="$(
    git -C "$repo_root" status --porcelain --untracked-files=all
  )"
  [[ -z "$worktree_status" ]] \
    || fail "working tree must be clean so evidence matches git commit $commit"
}

run_broad_gate() {
  local broad_log="$logs/broad-suite.log"
  local verifier_log="$logs/broad-baseline-verifier.log"
  set +e
  swift test \
    --package-path "$repo_root" \
    --scratch-path "$scratch" \
    --no-parallel \
    >"$broad_log" 2>&1
  set -e
  if ! "$repo_root/scripts/verify-swift-testing-baseline.sh" \
    "$broad_log" \
    "$repo_root/Tests/Baselines/stage-d-known-issues.txt" \
    >"$verifier_log" 2>&1
  then
    cat "$verifier_log" >&2
    fail "broad suite reviewed baseline"
  fi
}

run_logged() {
  local name="$1"
  shift
  if ! "$@" >"$logs/$name.log" 2>&1; then
    cat "$logs/$name.log" >&2
    fail "$name"
  fi
}

run_suite() {
  local scenario="$1"
  local filter="$2"
  local log="$logs/$scenario.log"
  if ! swift test \
    --package-path "$repo_root" \
    --scratch-path "$scratch" \
    --no-parallel \
    --filter "$filter" \
    >"$log" 2>&1
  then
    cat "$log" >&2
    fail "package suite failed: $scenario"
  fi
}

run_ui_gate() {
  local status_file="$root/ui-status.txt"
  local pid elapsed status
  rm -rf "$xcresult"
  set +e
  xcodebuild test-without-building \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -destination "$mac_destination" \
    -derivedDataPath "$derived_ui" \
    -resultBundlePath "$xcresult" \
    -only-testing:"$required_ui_test" \
    -parallel-testing-enabled NO \
    ARCHS="$host_arch" \
    STAGE_D_ACCEPTANCE_COMMIT="$commit" \
    >"$logs/xcode-ui.log" 2>&1 &
  pid=$!
  elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge 300 ]]; then
      kill -INT "$pid" 2>/dev/null || true
      grace=0
      while kill -0 "$pid" 2>/dev/null && [[ "$grace" -lt 10 ]]; do
        sleep 1
        grace=$((grace + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        grace=0
        while kill -0 "$pid" 2>/dev/null && [[ "$grace" -lt 5 ]]; do
          sleep 1
          grace=$((grace + 1))
        done
      fi
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid"
      status=$?
      printf 'timeout:%s\n' "$status" >"$status_file"
      set -e
      cat "$logs/xcode-ui.log" >&2
      fail "Xcode UI worker did not finish within 300 seconds"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
  status=$?
  printf '%s\n' "$status" >"$status_file"
  set -e
  if [[ "$status" -ne 0 ]]; then
    cat "$logs/xcode-ui.log" >&2
    fail "Xcode UI route gate exited $status"
  fi
}

require_tool git
require_tool swift
require_tool xcodebuild
require_tool xcodegen
require_tool xcrun

require_clean_worktree
[[ -n "$review_evidence" && -f "$review_evidence" ]] \
  || fail "STAGE_D_ACCEPTANCE_REVIEW_EVIDENCE must name a review JSON file"
if [[ -n "$reference_manifest" ]]; then
  [[ -f "$reference_manifest" ]] \
    || fail "reference run manifest is unavailable: $reference_manifest"
fi
[[ ! -e "$root" ]] \
  || fail "run directory already exists; use a fresh run name: $root"
mkdir -p "$logs" "$runtime/wall" "$runtime/accelerated"
rm -rf "$repo_root/.build/stage-d-sampling-allocation-probe-tests"

run_suite \
  stage-d.color \
  'DocumentColorTests|DocumentColorPipelineTests|DocumentPaintEncodedImportSourceTests'
run_suite \
  stage-d.sparse-sampling \
  'PaintTileSnapshotRetentionTests|DocumentPaintSurfaceStoreTests|TiledRasterSurfaceTests|SparseTileSamplingPlanTests|SparseTileSamplingPipelineTests'
run_suite \
  stage-d.stroke-lifecycle \
  'StrokeFrameSchedulerTests|StrokeTileSurfaceEncoderTests|DocumentPaintRenderContextTests|StrokeRuntimeTelemetryTests'
run_suite \
  stage-d.modes \
  'TilingProjectionTests|RadialShaderTests|PeriodicRepeatExportTests|RendererResizeTests'
run_suite \
  stage-d.layers \
  'LayerCompositorTests|LayerStackTests|DocumentHistoryTests'
run_suite \
  stage-d.persistence-export \
  'PatternProjectPackageCodecTests|PatternProjectBridgeTests|DocumentPaintStableCollectionTests|PatternProjectArchiveTests'
run_suite \
  stage-d.negative-controls \
  'StageDAcceptanceTests|DocumentPaintSurfaceTransactionTests|DocumentPaintSurfaceMetalBackendTests|ProfessionalBrushEvidenceValidatorTests'
run_broad_gate

run_logged xcodegen \
  xcodegen generate --spec "$repo_root/App/project.yml"
run_logged mac-debug-build \
  xcodebuild build-for-testing \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -configuration Debug \
    -destination "$mac_destination" \
    -derivedDataPath "$derived_mac" \
    ARCHS="$host_arch" \
    CODE_SIGNING_ALLOWED=NO
run_logged mac-ui-build-for-testing \
  xcodebuild build-for-testing \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -configuration Debug \
    -destination "$mac_destination" \
    -derivedDataPath "$derived_ui" \
    ARCHS="$host_arch"
run_logged mac-release-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -configuration Release \
    -destination "$mac_destination" \
    -derivedDataPath "$derived_mac" \
    ARCHS="$host_arch" \
    CODE_SIGNING_ALLOWED=NO
run_logged mac-harness-release-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMacHarness \
    -configuration Release \
    -destination "$mac_destination" \
    -derivedDataPath "$derived_mac" \
    ARCHS="$host_arch" \
    CODE_SIGNING_ALLOWED=NO
run_logged pad-debug-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikePad \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_pad" \
    CODE_SIGNING_ALLOWED=NO
run_logged pad-release-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikePad \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_pad" \
    CODE_SIGNING_ALLOWED=NO

app_binary="$derived_mac/Build/Products/Release/PatternSpikeHarness.app/Contents/MacOS/PatternSpikeHarness"
[[ -x "$app_binary" ]] || fail "macOS app binary is unavailable"
scene="$repo_root/App/PatternSpike/Harness/Scenes/deposition-ink.json"

run_logged runtime-wall \
  "$app_binary" \
    --harness-scene "$scene" \
    --output-directory "$runtime/wall" \
    --git-commit "$commit" \
    --configuration Release \
    --performance-trace 10-second
run_logged runtime-accelerated \
  "$app_binary" \
    --harness-scene "$scene" \
    --output-directory "$runtime/accelerated" \
    --git-commit "$commit" \
    --configuration Release \
    --performance-trace accelerated-10-minute

if ! "$repo_root/scripts/run-brush-input-allocation-probe.sh" \
  "$root/allocation-swiftpm" release all \
  >"$logs/allocation.log" 2>&1
then
  cat "$logs/allocation.log" >&2
  fail "allocation probe"
fi

run_logged acceptance-probe-build \
  swift build \
    --package-path "$repo_root" \
    --scratch-path "$scratch" \
    --product StageDAcceptanceProbe
probe="$scratch/debug/StageDAcceptanceProbe"
[[ -x "$probe" ]] || fail "StageDAcceptanceProbe is unavailable"

require_clean_worktree
run_logged package-manifest \
  "$probe" emit-package \
    --git-commit "$commit" \
    --generated-at "$generated_at" \
    --suite "stage-d.color=$logs/stage-d.color.log" \
    --suite "stage-d.sparse-sampling=$logs/stage-d.sparse-sampling.log" \
    --suite "stage-d.stroke-lifecycle=$logs/stage-d.stroke-lifecycle.log" \
    --suite "stage-d.modes=$logs/stage-d.modes.log" \
    --suite "stage-d.layers=$logs/stage-d.layers.log" \
    --suite "stage-d.persistence-export=$logs/stage-d.persistence-export.log" \
    --suite "stage-d.negative-controls=$logs/stage-d.negative-controls.log" \
    --wall-benchmark "$runtime/wall/deposition-ink.benchmark.json" \
    --accelerated-benchmark \
      "$runtime/accelerated/deposition-ink.benchmark.json" \
    --allocation-log "$logs/allocation.log" \
    --broad-suite-log "$logs/broad-suite.log" \
    --broad-baseline-verifier-log \
      "$logs/broad-baseline-verifier.log" \
    --review-evidence "$review_evidence" \
    --output "$package_manifest"

rm -f "$app_manifest"
run_ui_gate
[[ -s "$app_manifest" ]] \
  || fail "Xcode UI test did not write the application-route manifest"

require_clean_worktree
aggregate_arguments=(
  aggregate
  --manifest "$package_manifest"
  --manifest "$app_manifest"
  --xcresult "$xcresult"
  --required-ui-test "$required_ui_test"
)
if [[ -n "$reference_manifest" ]]; then
  aggregate_arguments+=(
    --reference-manifest "$reference_manifest"
    --output "$final_manifest"
  )
else
  aggregate_arguments+=(--output "$run_manifest")
fi
run_logged aggregate "$probe" "${aggregate_arguments[@]}"

trap - ERR
if [[ -n "$reference_manifest" ]]; then
  printf 'STAGE D ACCEPTANCE PASS manifest=%s\n' "$final_manifest"
else
  printf 'STAGE D ACCEPTANCE RUN CAPTURED manifest=%s; rerun with STAGE_D_ACCEPTANCE_REFERENCE_MANIFEST set\n' \
    "$run_manifest"
fi
