#!/usr/bin/env bash
set -eEuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matrix_root="${BRUSH_CORRECTIVE_ACCEPTANCE_ROOT:-$repo_root/.build/brush-corrective-acceptance/full-matrix}"
harness="${BRUSH_CORRECTIVE_HARNESS:-$repo_root/.build/CorrectiveHarnessDerived/Build/Products/Release/PatternSpikeHarness.app/Contents/MacOS/PatternSpikeHarness}"
scene_root="$repo_root/App/PatternSpike/Harness/Scenes"
commit="$(git -C "$repo_root" rev-parse HEAD)"

fail() {
  printf 'BRUSH CORRECTIVE ACCEPTANCE FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in jq shasum git find sort; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "required tool is unavailable: $tool"
done
[[ -x "$harness" ]] || fail "release harness is unavailable: $harness"
if [[ -e "$matrix_root" ]]; then
  [[ -d "$matrix_root" && -z "$(find "$matrix_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail "acceptance root already exists and is not empty: $matrix_root"
fi
mkdir -p "$matrix_root/runs" "$matrix_root/negative-controls"

scenes=(
  professional-chisel-marker
  professional-graphite-pencil
  professional-natural-charcoal
  professional-technical-ink
)
profiles=(10-second accelerated-10-minute)

for run in 1 2 3; do
  for scene in "${scenes[@]}"; do
    for profile in "${profiles[@]}"; do
      output="$matrix_root/runs/run-$run/$scene/$profile"
      mkdir -p "$output"
      "$harness" \
        --harness-scene "$scene_root/$scene.json" \
        --output-directory "$output" \
        --git-commit "$commit" \
        --configuration Release \
        --performance-trace "$profile" \
        >"$output/stdout.log" 2>"$output/stderr.log" \
        || fail "run $run failed for $scene $profile"
      [[ ! -s "$output/stderr.log" ]] \
        || fail "run $run wrote stderr for $scene $profile"
      grep -q "^HARNESS PASS scene=$scene " "$output/stdout.log" \
        || fail "run $run lacks pass marker for $scene $profile"
    done
  done
done

for scene in "${scenes[@]}"; do
  output="$matrix_root/negative-controls/$scene"
  negative="$scene-negative-control"
  mkdir -p "$output"
  set +e
  "$harness" \
    --harness-scene "$scene_root/$negative.json" \
    --output-directory "$output" \
    --git-commit "$commit" \
    --configuration Release \
    >"$output/stdout.log" 2>"$output/stderr.log"
  code=$?
  set -e
  [[ "$code" -eq 1 ]] \
    || fail "negative control exit was not one for $scene"
  [[ ! -s "$output/stdout.log" ]] \
    || fail "negative control wrote stdout for $scene"
  expected="HARNESS FAIL $negative expectation 'professionalDefinitionIdentityExact' did not match"
  [[ "$(<"$output/stderr.log")" == "$expected" ]] \
    || fail "negative control message was not exact for $scene"
done

benchmark_list="$matrix_root/benchmark-files.txt"
find "$matrix_root/runs" -name '*.benchmark.json' -type f | sort \
  >"$benchmark_list"
[[ "$(wc -l <"$benchmark_list" | tr -d ' ')" -eq 24 ]] \
  || fail "expected 24 timed benchmark records"

while IFS= read -r benchmark; do
  jq -e '
    .strokeRuntime.authoritativeReplayCount == 0 and
    .strokeRuntime.predictedReplayCount == 0 and
    .strokeRuntime.authoritativeQueueHighWater <= 1 and
    .strokeRuntime.predictedQueueHighWater <= 1 and
    .strokeRuntime.traceOverflowCount == 0 and
    .strokeRuntime.attestation.unconsumedInputEventCount == 0 and
    .strokeRuntime.attestation.discardedFrameEventCount == 0 and
    .strokeRuntime.missedFrameCount == 0 and
    .strokeRuntime.prepare.p95 < 2000000 and
    .strokeRuntime.eventToSubmit.p95 < 8000000 and
    (.strokeRuntime.eventToSubmitMissCount /
      .strokeRuntime.attributedFrameCount) <= 0.01 and
    .stageDAcceptanceRendererEvidence.backend == "productionSparseMetal" and
    .stageDAcceptanceRendererEvidence.activeCommandOperationCount == 0 and
    .stageDAcceptanceRendererEvidence.activeStrokeSurfaceCount == 0 and
    .stageDAcceptanceRendererEvidence.activeTileLeaseCount == 0 and
    .stageDAcceptanceRendererEvidence.activeUploadSlotCount == 0 and
    .stageDAcceptanceRendererEvidence.pendingPlanCompletionCount == 0
  ' "$benchmark" >/dev/null \
    || fail "runtime gate failed: $benchmark"
done <"$benchmark_list"

for scene in "${scenes[@]}"; do
  hashes="$matrix_root/$scene.hashes.txt"
  while IFS= read -r benchmark; do
    jq -r '[.canonicalBGRA8Digest, .logicalDabDigest] | @tsv' "$benchmark"
  done < <(find "$matrix_root/runs" -path "*/$scene/*/*.benchmark.json" -type f | sort) \
    >"$hashes"
  [[ "$(sort -u "$hashes" | wc -l | tr -d ' ')" -eq 1 ]] \
    || fail "canonical or logical digest changed across runs for $scene"
done

source_state="$matrix_root/source-state.txt"
source_files="$matrix_root/source-file-sha256.txt"
git -C "$repo_root" status --porcelain=v1 >"$source_state"
(
  cd "$repo_root"
  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] && shasum -a 256 "$path"
  done < <(
    git ls-files --cached --others --exclude-standard -z | sort -z
  )
) >"$source_files"
source_state_sha256="$(shasum -a 256 "$source_files" | awk '{print $1}')"
harness_sha256="$(shasum -a 256 "$harness" | awk '{print $1}')"

jq -s \
  --arg commit "$commit" \
  --arg sourceStateSHA256 "$source_state_sha256" \
  --arg harnessSHA256 "$harness_sha256" \
  '
  def p99: sort | .[((length * 0.99 | ceil) - 1)];
  {
    schemaVersion: 1,
    status: "softwarePerformancePassed",
    commit: $commit,
    sourceStateSHA256: $sourceStateSHA256,
    harnessSHA256: $harnessSHA256,
    runCount: 3,
    brushCount: 4,
    traceProfileCountPerBrushRun: 2,
    timedTraceCount: length,
    canonicalAndLogicalHashesStable: true,
    negativeControlCount: 4,
    runtime: {
      prepareP95NanosecondsMaximum: ([.[].strokeRuntime.prepare.p95] | max),
      prepareP99NanosecondsMaximum: ([.[].strokeRuntime.prepare.p99] | max),
      eventToSubmitP95NanosecondsMaximum:
        ([.[].strokeRuntime.eventToSubmit.p95] | max),
      eventToSubmitP99NanosecondsMaximum:
        ([.[].strokeRuntime.eventToSubmit.p99] | max),
      gpuP95NanosecondsMaximum: ([.[].strokeRuntime.gpu.p95] | max),
      gpuP99NanosecondsMaximum: ([.[].strokeRuntime.gpu.p99] | max),
      missedFrameFractionMaximum:
        ([.[] | .strokeRuntime.missedFrameCount /
          .strokeRuntime.frameCount] | max),
      eventToSubmitMissFractionMaximum:
        ([.[] | .strokeRuntime.eventToSubmitMissCount /
          .strokeRuntime.attributedFrameCount] | max),
      authoritativeQueueHighWaterMaximum:
        ([.[].strokeRuntime.authoritativeQueueHighWater] | max),
      predictedQueueHighWaterMaximum:
        ([.[].strokeRuntime.predictedQueueHighWater] | max),
      authoritativeReplayCountTotal:
        ([.[].strokeRuntime.authoritativeReplayCount] | add),
      cacheHitCountTotal: ([.[].strokeRuntime.cacheHitCount] | add),
      cacheMissCountTotal: ([.[].strokeRuntime.cacheMissCount] | add),
      memoryHighWaterBytesMaximum:
        ([.[].stageDAcceptanceRendererEvidence.residentResourceHighWaterBytes] | max),
      planMetalBufferAllocationCountMaximum:
        ([.[].stageDAcceptanceRendererEvidence.planMetalBufferAllocationCount] | max)
    },
    records: map({
      sceneName,
      profile: .strokeRuntime.traceProfile,
      canonicalBGRA8Digest,
      logicalDabDigest,
      frameCount: .strokeRuntime.frameCount,
      logicalDurationNanoseconds: .strokeRuntime.logicalDurationNanoseconds,
      prepareP95Nanoseconds: .strokeRuntime.prepare.p95,
      prepareP99Nanoseconds: .strokeRuntime.prepare.p99,
      eventToSubmitP95Nanoseconds: .strokeRuntime.eventToSubmit.p95,
      eventToSubmitP99Nanoseconds: .strokeRuntime.eventToSubmit.p99,
      gpuP95Nanoseconds: .strokeRuntime.gpu.p95,
      gpuP99Nanoseconds: .strokeRuntime.gpu.p99,
      missedFrameFraction:
        (.strokeRuntime.missedFrameCount / .strokeRuntime.frameCount),
      eventToSubmitMissFraction:
        (.strokeRuntime.eventToSubmitMissCount /
          .strokeRuntime.attributedFrameCount),
      authoritativeQueueHighWater:
        .strokeRuntime.authoritativeQueueHighWater,
      predictedQueueHighWater: .strokeRuntime.predictedQueueHighWater,
      residentResourceHighWaterBytes:
        .stageDAcceptanceRendererEvidence.residentResourceHighWaterBytes,
      cpuPlanCacheHitCount:
        .stageDAcceptanceRendererEvidence.cpuPlanCacheHitCount,
      cpuPlanCacheMissCount:
        .stageDAcceptanceRendererEvidence.cpuPlanCacheMissCount,
      gpuPlanCacheHitCount:
        .stageDAcceptanceRendererEvidence.gpuPlanCacheHitCount,
      gpuPlanCacheMissCount:
        .stageDAcceptanceRendererEvidence.gpuPlanCacheMissCount
    })
  }
  ' $(<"$benchmark_list") >"$matrix_root/summary.json"

(
  cd "$matrix_root"
  find . -type f ! -name artifact-sha256.txt -print0 \
    | sort -z | xargs -0 shasum -a 256
) >"$matrix_root/artifact-sha256.txt"

printf 'BRUSH CORRECTIVE ACCEPTANCE PASS summary=%s\n' \
  "$matrix_root/summary.json"
