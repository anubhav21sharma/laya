#!/usr/bin/env bash
set -eEuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${1:-$repo_root/.build/brush-corrective-acceptance/full-matrix}"
records="$root/comparison-records.jsonl"
summary="$root/comparison-summary.json"

fail() {
  printf 'BRUSH CORRECTIVE COMPARISON FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -d "$root/runs" ]] || fail "matrix runs are unavailable: $root"
benchmarks=()
while IFS= read -r path; do benchmarks+=("$path"); done < <(
  find "$root/runs" -name '*.benchmark.json' -type f | sort
)
[[ "${#benchmarks[@]}" -eq 24 ]] \
  || fail "expected 24 benchmark records; found ${#benchmarks[@]}"

: >"$records"
for benchmark in "${benchmarks[@]}"; do
  directory="$(dirname "$benchmark")"
  scene="$(basename "$(dirname "$directory")")"
  evidence="$directory/$scene.professional-evidence.json"
  long_stroke="$directory/professional-long-stroke.raw.json"
  [[ -f "$evidence" && -f "$long_stroke" ]] \
    || fail "paired professional evidence is missing: $benchmark"

  jq -e '
    .invariantResults.strokeCompilerCacheCountersUnchanged == true and
    .invariantResults.boundedLiveWork == true and
    .telemetry.authoritativeBacklog == 0 and
    .telemetry.predictedBacklog == 0 and
    .compilerCounters.beforeStroke == .compilerCounters.afterStroke
  ' "$evidence" >/dev/null \
    || fail "professional input-path invariant failed: $evidence"
  jq -e '
    .compilerCountersBefore == .compilerCountersAfter and
    ([.identityFrames[].authoritativeLogicalDabBacklogRemaining] | max) == 0 and
    ([.identityFrames[].retainedDabCount] | max) <= .replayMaximumDabs and
    ([.identityFrames[].visibleProjectedInstanceCount] | max)
      <= .replayMaximumProjectedInstances
  ' "$long_stroke" >/dev/null \
    || fail "long-stroke bounded-work invariant failed: $long_stroke"

  jq \
    --arg artifactPath "${benchmark#"$repo_root/"}" \
    --arg run "$(basename "$(dirname "$(dirname "$directory")")")" \
    --arg profileDirectory "$(basename "$directory")" \
    --slurpfile professional "$evidence" \
    --slurpfile longStroke "$long_stroke" \
    '
    {
      artifactPath: $artifactPath,
      run: $run,
      sceneName,
      profileDirectory: $profileDirectory,
      traceProfile: .strokeRuntime.traceProfile,
      canonicalBGRA8Digest,
      logicalDabDigest,
      framesPerSecond:
        (.strokeRuntime.frameCount * 1000000000 /
          .strokeRuntime.wallDurationNanoseconds),
      attributedInputFramesPerSecond:
        (.strokeRuntime.attributedFrameCount * 1000000000 /
          .strokeRuntime.wallDurationNanoseconds),
      frameP95Nanoseconds: .strokeRuntime.frame.p95,
      frameP99Nanoseconds: .strokeRuntime.frame.p99,
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
      authoritativeQueueDepth: .strokeRuntime.authoritativeQueueDepth,
      predictedQueueDepth: .strokeRuntime.predictedQueueDepth,
      authoritativeQueueHighWater:
        .strokeRuntime.authoritativeQueueHighWater,
      predictedQueueHighWater: .strokeRuntime.predictedQueueHighWater,
      professionalBacklogHighWater:
        $professional[0].telemetry.backlogHighWater,
      memoryHighWaterBytes:
        .stageDAcceptanceRendererEvidence.residentResourceHighWaterBytes,
      cpuPlanCacheHits:
        .stageDAcceptanceRendererEvidence.cpuPlanCacheHitCount,
      cpuPlanCacheMisses:
        .stageDAcceptanceRendererEvidence.cpuPlanCacheMissCount,
      gpuPlanCacheHits:
        .stageDAcceptanceRendererEvidence.gpuPlanCacheHitCount,
      gpuPlanCacheMisses:
        .stageDAcceptanceRendererEvidence.gpuPlanCacheMissCount,
      planMetalBufferAllocations:
        .stageDAcceptanceRendererEvidence.planMetalBufferAllocationCount,
      authoritativeReplayCount: .strokeRuntime.authoritativeReplayCount,
      predictedReplayCount: .strokeRuntime.predictedReplayCount,
      inputPathCompilerCountersUnchanged:
        $professional[0].invariantResults
          .strokeCompilerCacheCountersUnchanged,
      longStrokeCompilerCountersUnchanged:
        ($longStroke[0].compilerCountersBefore ==
          $longStroke[0].compilerCountersAfter),
      longStrokeMaximumBacklog:
        ([$longStroke[0].identityFrames[]
          .authoritativeLogicalDabBacklogRemaining] | max)
    }
    ' "$benchmark" >>"$records"
done

jq -s '
  def range(field):
    ([.[] | field] | {minimum: min, maximum: max});
  {
    schemaVersion: 1,
    status: "softwarePerformancePassed",
    recordCount: length,
    runCount: ([.[].run] | unique | length),
    brushCount: ([.[].sceneName] | unique | length),
    traceProfiles: ([.[].traceProfile] | unique | sort),
    canonicalAndLogicalHashesStablePerBrush:
      (group_by(.sceneName) | all(
        ([.[].canonicalBGRA8Digest] | unique | length) == 1 and
        ([.[].logicalDabDigest] | unique | length) == 1
      )),
    inputPathCompilerCountersUnchanged:
      all(.inputPathCompilerCountersUnchanged and
        .longStrokeCompilerCountersUnchanged),
    actualReplayCountTotal: ([.[].authoritativeReplayCount] | add),
    predictedReplayCountTotal: ([.[].predictedReplayCount] | add),
    longStrokeMaximumBacklog:
      ([.[].longStrokeMaximumBacklog] | max),
    ranges: {
      framesPerSecond: range(.framesPerSecond),
      attributedInputFramesPerSecond:
        range(.attributedInputFramesPerSecond),
      frameP95Nanoseconds: range(.frameP95Nanoseconds),
      frameP99Nanoseconds: range(.frameP99Nanoseconds),
      prepareP95Nanoseconds: range(.prepareP95Nanoseconds),
      prepareP99Nanoseconds: range(.prepareP99Nanoseconds),
      eventToSubmitP95Nanoseconds:
        range(.eventToSubmitP95Nanoseconds),
      eventToSubmitP99Nanoseconds:
        range(.eventToSubmitP99Nanoseconds),
      gpuP95Nanoseconds: range(.gpuP95Nanoseconds),
      gpuP99Nanoseconds: range(.gpuP99Nanoseconds),
      missedFrameFraction: range(.missedFrameFraction),
      eventToSubmitMissFraction:
        range(.eventToSubmitMissFraction),
      authoritativeQueueHighWater:
        range(.authoritativeQueueHighWater),
      predictedQueueHighWater:
        range(.predictedQueueHighWater),
      professionalBacklogHighWater:
        range(.professionalBacklogHighWater),
      memoryHighWaterBytes: range(.memoryHighWaterBytes),
      cpuPlanCacheHits: range(.cpuPlanCacheHits),
      cpuPlanCacheMisses: range(.cpuPlanCacheMisses),
      gpuPlanCacheHits: range(.gpuPlanCacheHits),
      gpuPlanCacheMisses: range(.gpuPlanCacheMisses),
      planMetalBufferAllocations:
        range(.planMetalBufferAllocations)
    },
    records: .
  }
' "$records" >"$summary"

jq -e '
  .recordCount == 24 and
  .runCount == 3 and
  .brushCount == 4 and
  (.traceProfiles | length) == 2 and
  .canonicalAndLogicalHashesStablePerBrush and
  .inputPathCompilerCountersUnchanged and
  .actualReplayCountTotal == 0 and
  .predictedReplayCountTotal == 0 and
  .longStrokeMaximumBacklog == 0 and
  .ranges.prepareP95Nanoseconds.maximum < 2000000 and
  .ranges.eventToSubmitP95Nanoseconds.maximum < 8000000 and
  .ranges.eventToSubmitMissFraction.maximum <= 0.01 and
  .ranges.missedFrameFraction.maximum == 0 and
  .ranges.authoritativeQueueHighWater.maximum <= 1 and
  .ranges.predictedQueueHighWater.maximum <= 1
' "$summary" >/dev/null \
  || fail "comparison summary did not pass"

printf 'BRUSH CORRECTIVE COMPARISON PASS summary=%s\n' "$summary"
