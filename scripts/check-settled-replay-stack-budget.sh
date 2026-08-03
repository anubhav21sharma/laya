#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s DEBUG_BINARY RELEASE_BINARY\n' "$0" >&2
  exit 64
fi

debug_binary=$1
release_binary=$2
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
frame_checker="$script_directory/check-arm64-stack-frame.sh"

if [[ ! -x "$frame_checker" ]]; then
  printf 'stack-frame checker is not executable: %s\n' "$frame_checker" >&2
  exit 66
fi

expected_xcode=$'Xcode 26.6\nBuild version 17F113'
actual_xcode=$(xcodebuild -version)
if [[ "$actual_xcode" != "$expected_xcode" ]]; then
  printf 'unsupported stack-gate Xcode toolchain:\n%s\n' "$actual_xcode" >&2
  exit 65
fi
swift_version=$(xcrun swift --version 2>&1)
if [[ "$swift_version" != *'Apple Swift version 6.3.3 '* ]]; then
  printf 'unsupported stack-gate Swift toolchain: %s\n' "$swift_version" >&2
  exit 65
fi
clang_version=$(xcrun clang --version 2>&1)
if [[ "$clang_version" != *'Apple clang version 21.0.0 '* ]]; then
  printf 'unsupported stack-gate LLVM toolchain: %s\n' "$clang_version" >&2
  exit 65
fi

debug_limit=65536
generator_debug_limit=57344
release_limit=16384
measurement_limit=1048576

measure() {
  local destination=$1
  local binary=$2
  local fragment=$3
  local scope=$4
  local kind=$5
  local output
  local value

  output=$(
    "$frame_checker" "$binary" "$fragment" "$measurement_limit" \
      "$scope" "$kind"
  )
  value=$(printf '%s\n' "$output" | sed -n 's/.*bytes=\([0-9][0-9]*\).*/\1/p')
  if [[ -z "$value" ]]; then
    printf 'missing stack-frame byte count for %s\n' "$fragment" >&2
    exit 65
  fi
  printf -v "$destination" '%s' "$value"
}

maximum() {
  local result=0
  local value
  for value in "$@"; do
    if (( value > result )); then result=$value; fi
  done
  printf '%s\n' "$result"
}

require_composite() {
  local name=$1
  local value=$2
  local maximum=${3:-$debug_limit}
  if (( value > maximum )); then
    printf 'STACK COMPOSITE FAIL name=%s bytes=%s maximum=%s\n' \
      "$name" "$value" "$maximum" >&2
    exit 1
  fi
  printf 'STACK COMPOSITE PASS name=%s bytes=%s maximum=%s\n' \
    "$name" "$value" "$maximum"
}

require_phase_worker_dispatch_only() {
  local source=$1
  shift
  local worker
  local occurrences
  for worker in "$@"; do
    occurrences=$(grep -Ec "${worker}\\(" "$source")
    if (( occurrences != 2 )); then
      printf 'STACK STRUCTURE FAIL worker=%s occurrences=%s expected=2\n' \
        "$worker" "$occurrences" >&2
      exit 1
    fi
  done
  printf 'STACK STRUCTURE PASS phase_workers=%s dispatch=advanceOne\n' "$#"
}

require_closed_branch_names() {
  local source=$1
  shift
  local actual
  local expected
  local missing
  local unexpected
  actual=$(sed -n 's/^\([a-z][a-z0-9_]*_branch\)=.*/\1/p' "$source" \
    | LC_ALL=C sort -u)
  expected=$(printf '%s\n' "$@" | LC_ALL=C sort -u)
  unexpected=$(comm -13 \
    <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
    | head -1)
  if [[ -n "$unexpected" ]]; then
    printf 'STACK STRUCTURE FAIL unexpected_branch=%s\n' \
      "$unexpected" >&2
    exit 1
  fi
  missing=$(comm -23 \
    <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
    | head -1)
  if [[ -n "$missing" ]]; then
    printf 'STACK STRUCTURE FAIL missing_branch=%s\n' "$missing" >&2
    exit 1
  fi
  printf 'STACK STRUCTURE PASS closed_branches=%s\n' "$#"
}

require_audited_branch_values() {
  local name
  local value
  for name in "$@"; do
    value=${!name-}
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      printf 'STACK STRUCTURE FAIL unaudited_branch_value=%s\n' "$name" >&2
      exit 1
    fi
  done
  printf 'STACK STRUCTURE PASS audited_branch_values=%s\n' "$#"
}

require_branch_root_reachability() {
  local root=$1
  local reachable=$root
  local changed=1
  local edge
  local child
  local parent
  local branch
  while (( changed != 0 )); do
    changed=0
    for edge in "${audited_branch_edges[@]}"; do
      child=${edge%%:*}
      parent=${edge#*:}
      if printf '%s\n' "$reachable" | grep -Fqx "$parent" \
          && ! printf '%s\n' "$reachable" | grep -Fqx "$child"
      then
        reachable=$(printf '%s\n%s' "$reachable" "$child")
        changed=1
      fi
    done
  done
  for branch in "${audited_branches[@]}"; do
    if ! printf '%s\n' "$reachable" | grep -Fqx "$branch"; then
      printf 'STACK STRUCTURE FAIL unreachable_branch=%s root=%s\n' \
        "$branch" "$root" >&2
      exit 1
    fi
  done
  printf 'STACK STRUCTURE PASS reachable_branches=%s root=%s\n' \
    "${#audited_branches[@]}" "$root"
}

assignment_expression() {
  local source=$1
  local name=$2
  awk -v assignment="$name" '
    $0 ~ ("^" assignment "=") { emitting = 1 }
    emitting {
      print
      if ($0 !~ /\\$/) { exit }
    }
  ' "$source"
}

require_unique_audited_node_assignments() {
  local source=$1
  local node
  local count
  for node in "${audited_nodes[@]}"; do
    count=$(grep -Ec "^${node}=" "$source")
    if (( count != 1 )); then
      printf 'STACK STRUCTURE FAIL node=%s assignments=%s expected=1\n' \
        "$node" "$count" >&2
      exit 1
    fi
  done
  printf 'STACK STRUCTURE PASS unique_node_assignments=%s\n' \
    "${#audited_nodes[@]}"
}

actual_formula_edges() {
  local source=$1
  local nodes="${audited_nodes[*]}"
  awk -v nodes="$nodes" '
    BEGIN {
      nodeCount = split(nodes, node, " ")
      for (idx = 1; idx <= nodeCount; idx += 1) {
        known[node[idx]] = 1
      }
    }
    function emitEdges(parent, expression, idx, child, pattern) {
      for (idx = 1; idx <= nodeCount; idx += 1) {
        child = node[idx]
        if (child == parent) { continue }
        pattern = "(^|[^[:alnum:]_])" child "([^[:alnum:]_]|$)"
        if (expression ~ pattern) { print child ":" parent }
      }
    }
    {
      if (!emitting) {
        equals = index($0, "=")
        candidate = equals > 1 ? substr($0, 1, equals - 1) : ""
        if (candidate in known) {
          parent = candidate
          expression = ""
          emitting = 1
        }
      }
      if (emitting) {
        expression = expression "\n" $0
        if ($0 !~ /\\$/) {
          emitEdges(parent, expression)
          emitting = 0
        }
      }
    }
  ' "$source"
}

require_declared_edges_match_formulas() {
  local source=$1
  local root=$2
  local actual
  local declared
  local duplicate
  local missing
  local stale
  local edge
  local branch
  local has_parent
  local assertion_count
  duplicate=$(printf '%s\n' "${audited_branch_edges[@]}" \
    | LC_ALL=C sort | uniq -d | head -1)
  if [[ -n "$duplicate" ]]; then
    printf 'STACK STRUCTURE FAIL duplicate_declared_edge=%s\n' \
      "$duplicate" >&2
    exit 1
  fi
  actual=$(actual_formula_edges "$source" | LC_ALL=C sort)
  declared=$(printf '%s\n' "${audited_branch_edges[@]}" | LC_ALL=C sort)
  missing=$(comm -13 \
    <(printf '%s\n' "$declared") <(printf '%s\n' "$actual") \
    | head -1)
  if [[ -n "$missing" ]]; then
    printf 'STACK STRUCTURE FAIL missing_declared_edge=%s\n' \
      "$missing" >&2
    exit 1
  fi
  stale=$(comm -23 \
    <(printf '%s\n' "$declared") <(printf '%s\n' "$actual") \
    | head -1)
  if [[ -n "$stale" ]]; then
    printf 'STACK STRUCTURE FAIL stale_declared_edge=%s\n' \
      "$stale" >&2
    exit 1
  fi
  for branch in "${audited_branches[@]}"; do
    has_parent=0
    for edge in "${audited_branch_edges[@]}"; do
      if [[ "${edge%%:*}" == "$branch" ]]; then
        has_parent=1
        break
      fi
    done
    if (( has_parent == 0 )); then
      printf 'STACK STRUCTURE FAIL branch_without_parent=%s\n' \
        "$branch" >&2
      exit 1
    fi
  done
  assertion_count=$(grep -Ec \
    "^require_composite[[:space:]].*\\\$\\{?${root}\\}?" "$source")
  if (( assertion_count != 1 )); then
    printf 'STACK STRUCTURE FAIL root=%s assertions=%s expected=1\n' \
      "$root" "$assertion_count" >&2
    exit 1
  fi
  printf 'STACK STRUCTURE PASS formula_edges=%s asserted_root=%s\n' \
    "${#audited_branch_edges[@]}" "$root"
}

audited_branches=(
  dynamics_input_branch dynamics_response_branch
  dynamics_ordered_term_branch dynamics_ordered_output_branch
  dynamics_ordered_branch dynamics_evaluator_branch
  dynamics_taper_branch dynamics_placement_branch
  dynamics_color_jitter_branch dynamics_primary_grain_branch
  dynamics_secondary_grain_branch dynamics_random_branch
  tip_layer_branch tip_include_branch tip_projection_branch
  dynamics_support_branch dynamics_native_branch dynamics_branch
  cursor_evaluate_branch timed_optional_angle_branch
  timed_interpolated_branch timed_candidate_branch timed_next_branch
  timed_consume_branch stabilizer_branch timed_emitter_validate_branch
  timed_emitter_last_tick_branch timed_emitter_begin_branch
  timed_emitter_advance_branch timed_emitter_prediction_branch
  timed_emitter_finish_branch timed_initialization_branch
  stage_c_timed_branch cursor_complete_branch cursor_prepare_branch
  cursor_initial_branch cursor_begin_branch cursor_pending_segment_branch
  cursor_finish_preparation_branch cursor_finish_timed_advance_branch
  cursor_finish_timed_termination_branch cursor_after_branch
  cursor_path_branch cursor_source_candidate_branch cursor_source_branch
  cursor_segment_spatial_branch cursor_segment_timed_branch
  cursor_segment_decide_branch cursor_segment_settle_branch
  cursor_segment_lifecycle_branch cursor_advance_branch
  cursor_selection_branch cursor_prepared_branch cursor_commit_branch
)
audited_nodes=(
  "${audited_branches[@]}"
  cursor_accept_composite cursor_advance_composite
)

# Every audited branch has an explicit dependency path to the composite that
# is asserted against the generator stack limit. Edges point child:parent.
audited_branch_edges=(
  dynamics_input_branch:dynamics_response_branch
  dynamics_input_branch:dynamics_ordered_term_branch
  dynamics_response_branch:dynamics_evaluator_branch
  dynamics_response_branch:dynamics_secondary_grain_branch
  dynamics_ordered_term_branch:dynamics_ordered_output_branch
  dynamics_ordered_output_branch:dynamics_ordered_branch
  dynamics_ordered_branch:dynamics_evaluator_branch
  dynamics_evaluator_branch:dynamics_branch
  dynamics_taper_branch:dynamics_native_branch
  dynamics_placement_branch:dynamics_native_branch
  dynamics_color_jitter_branch:dynamics_native_branch
  dynamics_primary_grain_branch:dynamics_native_branch
  dynamics_secondary_grain_branch:dynamics_native_branch
  dynamics_random_branch:dynamics_native_branch
  tip_layer_branch:dynamics_support_branch
  tip_include_branch:tip_projection_branch
  tip_projection_branch:dynamics_support_branch
  dynamics_support_branch:dynamics_native_branch
  dynamics_native_branch:dynamics_branch
  dynamics_branch:cursor_evaluate_branch
  cursor_evaluate_branch:cursor_accept_composite
  cursor_accept_composite:cursor_advance_composite
  timed_optional_angle_branch:timed_interpolated_branch
  timed_interpolated_branch:timed_candidate_branch
  timed_candidate_branch:timed_next_branch
  timed_candidate_branch:timed_consume_branch
  timed_next_branch:cursor_source_candidate_branch
  timed_consume_branch:cursor_segment_timed_branch
  stabilizer_branch:cursor_prepare_branch
  timed_emitter_validate_branch:timed_emitter_begin_branch
  timed_emitter_validate_branch:timed_emitter_advance_branch
  timed_emitter_validate_branch:timed_emitter_prediction_branch
  timed_emitter_validate_branch:timed_emitter_finish_branch
  timed_emitter_last_tick_branch:timed_emitter_advance_branch
  timed_emitter_last_tick_branch:timed_emitter_prediction_branch
  timed_emitter_last_tick_branch:timed_emitter_finish_branch
  timed_emitter_begin_branch:timed_initialization_branch
  timed_emitter_advance_branch:stage_c_timed_branch
  timed_emitter_prediction_branch:stage_c_timed_branch
  timed_emitter_finish_branch:cursor_finish_timed_termination_branch
  timed_initialization_branch:cursor_initial_branch
  stage_c_timed_branch:cursor_pending_segment_branch
  stage_c_timed_branch:cursor_finish_timed_advance_branch
  stage_c_timed_branch:cursor_after_branch
  cursor_complete_branch:cursor_prepare_branch
  cursor_prepare_branch:cursor_advance_branch
  cursor_initial_branch:cursor_advance_branch
  cursor_begin_branch:cursor_advance_branch
  cursor_pending_segment_branch:cursor_advance_branch
  cursor_finish_preparation_branch:cursor_advance_branch
  cursor_finish_timed_advance_branch:cursor_advance_branch
  cursor_finish_timed_termination_branch:cursor_advance_branch
  cursor_after_branch:cursor_advance_branch
  cursor_path_branch:cursor_advance_branch
  cursor_source_candidate_branch:cursor_source_branch
  cursor_source_branch:cursor_advance_branch
  cursor_segment_spatial_branch:cursor_advance_branch
  cursor_segment_timed_branch:cursor_advance_branch
  cursor_segment_decide_branch:cursor_advance_branch
  cursor_segment_settle_branch:cursor_advance_branch
  cursor_segment_lifecycle_branch:cursor_advance_branch
  cursor_advance_branch:cursor_selection_branch
  cursor_selection_branch:cursor_advance_composite
  cursor_prepared_branch:cursor_advance_composite
  cursor_commit_branch:cursor_advance_composite
)

generator_source="$script_directory/../Sources/PatternEngine/BrushStrokeGenerator.swift"
require_phase_worker_dispatch_only "$generator_source" \
  prepareInitialPath prepareBeginSource preparePendingSegment \
  prepareFinishSource prepareFinishTimedAdvance \
  prepareFinishTimedTermination advancePath afterPath advanceSource \
  prepareSegmentSpatial prepareSegmentTimed decideSegment \
  settleSegmentDuplicate advanceSegmentLifecycle
require_closed_branch_names "$0" "${audited_branches[@]}"
require_unique_audited_node_assignments "$0"
require_branch_root_reachability cursor_advance_composite
require_declared_edges_match_formulas "$0" cursor_advance_composite

# Coordinator frames and closures. Private fragments include the source-level
# function name plus enough mangling context to exclude closure/partial symbols.
measure p "$debug_binary" prepareSettledReplayTransfer external swift-function
measure structure "$debug_binary" validateSettledReplayStructure non-external swift-function
measure lifecycle "$debug_binary" validateSettledReplayLifecycle non-external swift-function
measure append_work "$debug_binary" appendSettledReplayWork non-external swift-function
measure input_loop "$debug_binary" advanceSettledReplayInputChunks non-external swift-function
measure input_transition "$debug_binary" validateSettledReplayInputTransition non-external swift-function
measure generator_loop "$debug_binary" C35advanceSettledReplayGeneratorChunks non-external swift-function
measure generator_chunk "$debug_binary" C34advanceSettledReplayGeneratorChunk33_ non-external swift-function
measure transition "$debug_binary" replaySettledGeneratorTransition non-external swift-function
measure replay_begin "$debug_binary" replaySettledBegin non-external swift-function
measure replay_append "$debug_binary" replaySettledAppend non-external swift-function
measure replay_finish "$debug_binary" replaySettledFinish non-external swift-function
measure state_after "$debug_binary" validateSettledReplayStateAfter non-external swift-function
measure validate_dab "$debug_binary" validateSettledReplayDab non-external swift-function
measure begin_closure "$debug_binary" replaySettledBegin non-external swift-closure
measure append_closure "$debug_binary" replaySettledAppend non-external swift-closure
measure finish_closure "$debug_binary" replaySettledFinish non-external swift-closure
measure begin_partial "$debug_binary" replaySettledBegin non-external swift-partial-apply
measure append_partial "$debug_binary" replaySettledAppend non-external swift-partial-apply
measure finish_partial "$debug_binary" replaySettledFinish non-external swift-partial-apply

# Input checkpoint equality.
measure input_eq "$debug_binary" BrushInputDeriverV23__derived_struct_equals external fragment
measure filter_eq "$debug_binary" StrokeVelocityFilterV23__derived_struct_equals external fragment
measure filter_storage_eq "$debug_binary" StrokeVelocityFilterSegmentStorage33_ non-external swift-equality

# Generator equality and each segmented semantic branch it can enter. The
# explicit helpers keep future stored fields from recreating one monolithic
# synthesized frame; the field-inventory test makes additions fail closed.
measure generator_eq "$debug_binary" BrushStrokeGeneratorV2eeoiy external fragment
measure generator_configuration "$debug_binary" BrushStrokeGeneratorV18configurationEqual non-external fragment
measure generator_stabilization "$debug_binary" BrushStrokeGeneratorV23stabilizationStateEqual non-external fragment
measure generator_direction "$debug_binary" BrushStrokeGeneratorV19directionStateEqual non-external fragment
measure generator_path "$debug_binary" BrushStrokeGeneratorV14pathStateEqual non-external fragment
measure generator_emission "$debug_binary" BrushStrokeGeneratorV18emissionStateEqual non-external fragment
measure program_eq "$debug_binary" BrushProgramC2eeoiy external fragment
measure stabilizer_eq "$debug_binary" StrokeStabilizerV23__derived_struct_equals external fragment
measure stabilizer_storage_eq "$debug_binary" StrokeStabilizerPointStorage33_ non-external swift-equality
measure direction_tracker_eq "$debug_binary" BrushDirectionTrackerV23__derived_struct_equals external fragment
measure corner_emitter_eq "$debug_binary" BrushCornerEmitterV23__derived_struct_equals external fragment
measure interpolated_sample_eq "$debug_binary" InterpolatedStrokeSampleV23__derived_struct_equals external fragment
measure path_eq "$debug_binary" CentripetalCatmullRomPathInterpolatorV23__derived_struct_equals external fragment
measure random_eq "$debug_binary" BrushRandomV23__derived_struct_equals external fragment
measure ink_eq "$debug_binary" InkColorV23__derived_struct_equals external fragment
measure point_eq "$debug_binary" WorldPointV23__derived_struct_equals external fragment

# Schema-v2 emission continuation. The value is deliberately separate from
# BrushStrokeGenerator, so the old coordinator composite cannot account for
# its construction/page/resume frames until C12 owns it. Measure the public
# fail-closed roots plus every non-inlined branch in the debug call tree.
measure cursor_construct "$debug_binary" BrushStrokeGeneratorV14emissionCursor external fragment
measure cursor_init "$debug_binary" EmissionCursorV9generator6sample27maximumPathSubdivisionCount non-external fragment
measure cursor_page "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV12emitNextPage external fragment
measure cursor_step "$debug_binary" EmissionCursorV10advanceOne non-external fragment
measure cursor_prepare "$debug_binary" EmissionCursorV7prepare non-external fragment
measure cursor_path "$debug_binary" EmissionCursorV11advancePath non-external fragment
measure cursor_source "$debug_binary" EmissionCursorV13advanceSource non-external fragment
measure cursor_segment_spatial "$debug_binary" EmissionCursorV21prepareSegmentSpatial non-external fragment
measure cursor_segment_timed "$debug_binary" EmissionCursorV19prepareSegmentTimed non-external fragment
measure cursor_segment_decide "$debug_binary" EmissionCursorV13decideSegment non-external fragment
measure cursor_segment_settle "$debug_binary" EmissionCursorV22settleSegmentDuplicate non-external fragment
measure cursor_segment_lifecycle "$debug_binary" EmissionCursorV23advanceSegmentLifecycle non-external fragment
measure cursor_initial "$debug_binary" EmissionCursorV18prepareInitialPath non-external fragment
measure cursor_after_path "$debug_binary" EmissionCursorV9afterPath non-external fragment
measure cursor_begin_source "$debug_binary" EmissionCursorV18prepareBeginSource non-external fragment
measure cursor_prepare_segment "$debug_binary" EmissionCursorV21preparePendingSegment non-external fragment
measure cursor_finish_source "$debug_binary" EmissionCursorV19prepareFinishSource non-external fragment
measure cursor_prepare_source "$debug_binary" EmissionCursorV13prepareSource non-external fragment
measure cursor_stage_c_timed "$debug_binary" BrushStrokeGeneratorV17stageCTimedCursor non-external fragment
measure cursor_finish_timed_advance "$debug_binary" EmissionCursorV25prepareFinishTimedAdvance non-external fragment
measure cursor_finish_timed_termination "$debug_binary" EmissionCursorV29prepareFinishTimedTermination non-external fragment
measure cursor_complete "$debug_binary" EmissionCursorV8complete non-external fragment
measure generator_reset "$debug_binary" BrushStrokeGeneratorV17resetRuntimeState non-external fragment
measure footprint_validate "$debug_binary" BrushStrokeFootprintEnvelope33_FCAB7D0E8C2617936E49D6F33D25623ALLV8validate non-external fragment
measure generator_stabilizer "$debug_binary" BrushStrokeGeneratorV23processStageCStabilizer non-external fragment
measure stabilizer_process "$debug_binary" StrokeStabilizerV9processV2 external fragment
measure generator_corner_validate "$debug_binary" BrushStrokeGeneratorV29validateCornerCanonicalDomain non-external fragment
measure generator_timed_init "$debug_binary" BrushStrokeGeneratorV23initializeTimedEmission non-external fragment
measure stage_c_candidate "$debug_binary" stageCCandidate33_FCAB7D0E8C2617936E49D6F33D25623ALL6sample14sourceDistance9direction4kind11isPredicted14cornerSequence non-external swift-function
measure stage_c_sample "$debug_binary" BrushStrokeGeneratorV12stageCSample non-external fragment
measure timed_begin "$debug_binary" TimedStrokeEmitterV5begin external fragment
measure timed_advance "$debug_binary" TimedStrokeEmitterV7advance external fragment
measure timed_prediction "$debug_binary" TimedStrokeEmitterV10prediction external fragment
measure timed_finish "$debug_binary" TimedStrokeEmitterV6finish external fragment
measure timed_emitter_validate "$debug_binary" TimedStrokeEmitterV8validate026_93A8D2497DE33A4E0A7046812J5DC127LL non-external fragment
measure timed_emitter_provenance "$debug_binary" TimedStrokeEmitterV31validateAuthoritativeProvenance026_93A8D2497DE33A4E0A7046812L5DC127LL non-external fragment
measure timed_emitter_canonical "$debug_binary" TimedStrokeEmitterV12canonicalKey026_93A8D2497DE33A4E0A7046812K5DC127LL non-external fragment
measure timed_emitter_last_tick "$debug_binary" TimedStrokeEmitterV13lastTickIndex026_93A8D2497DE33A4E0A7046812L5DC127LL non-external fragment
measure timed_emitter_index_after "$debug_binary" TimedStrokeEmitterV10indexAfter026_93A8D2497DE33A4E0A7046812K5DC127LL non-external fragment
measure timed_emitter_reset "$debug_binary" TimedStrokeEmitterV5reset external fragment
measure corner_cursor "$debug_binary" BrushCornerEmitterV6cursor external fragment
measure corner_next "$debug_binary" BrushCornerEmissionCursorV13nextCandidate external fragment
measure direction_begin "$debug_binary" BrushDirectionTrackerV5begin external fragment
measure direction_update "$debug_binary" BrushDirectionTrackerV6update external swift-function
measure path_begin "$debug_binary" CentripetalCatmullRomPathInterpolatorV5begin external fragment
measure path_advance "$debug_binary" CentripetalCatmullRomPathInterpolatorV13advanceCursor external fragment
measure path_cancel "$debug_binary" CentripetalCatmullRomPathInterpolatorV6cancel external fragment
measure path_next "$debug_binary" AttributedStrokePathAdvanceCursorV11nextSegment external fragment
measure emission_merger_next "$debug_binary" StrokeEmissionMergerV4next external fragment
measure cursor_source_candidate "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV06SourceG0 non-external swift-function
measure cursor_spatial "$debug_binary" prepareSpatialCandidate non-external swift-function
measure cursor_decide "$debug_binary" decidePreparedCandidates non-external swift-function
measure cursor_commit "$debug_binary" commitPreparedCandidates non-external fragment
measure cursor_source_commit "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV06SourceG033_FCAB7D0E8C2617936E49D6F33D25623ALLV6commit non-external fragment
measure cursor_source_prepared "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV06SourceG033_FCAB7D0E8C2617936E49D6F33D25623ALLV17preparedCandidate non-external fragment
measure cursor_source_commit_prepared "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV06SourceG033_FCAB7D0E8C2617936E49D6F33D25623ALLV23commitPreparedCandidate non-external fragment
measure cursor_segment_prepared "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV07SegmentG033_FCAB7D0E8C2617936E49D6F33D25623ALLV17preparedCandidate non-external fragment
measure cursor_segment_commit_prepared "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV07SegmentG033_FCAB7D0E8C2617936E49D6F33D25623ALLV23commitPreparedCandidate non-external fragment
measure cursor_prepared "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV17preparedCandidate33_ non-external fragment
measure cursor_commit_root "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV23commitPreparedCandidate33_ non-external fragment
measure cursor_segment_finish "$debug_binary" BrushStrokeGeneratorV14EmissionCursorV07SegmentG033_FCAB7D0E8C2617936E49D6F33D25623ALLV06finishH0 non-external fragment
measure timed_next "$debug_binary" TimedStrokeEmissionCursorV13nextCandidate external fragment
measure timed_consume "$debug_binary" TimedStrokeEmissionCursorV20consumeNextCandidate external swift-function
measure timed_candidate "$debug_binary" TimedStrokeEmissionCursorV14timedCandidate non-external fragment
measure timed_interpolated "$debug_binary" TimedStrokeEmissionCursorV18interpolatedSample non-external fragment
measure timed_replacing "$debug_binary" TimedStrokeEmissionCursorV18replacingTimestamp non-external fragment
measure timed_canonical "$debug_binary" TimedStrokeEmissionCursorV12canonicalKey non-external fragment
measure timed_optional_linear "$debug_binary" TimedStrokeEmissionCursorV14optionalLinear non-external fragment
measure timed_optional_angle "$debug_binary" TimedStrokeEmissionCursorV13optionalAngle non-external fragment
measure timed_normalized_angle "$debug_binary" TimedStrokeEmissionCursorV15normalizedAngle non-external fragment
measure timed_stable_double "$debug_binary" TimedStrokeEmissionCursorV12stableLinear026_93A8D2497DE33A4E0A7046812L5DC127LL__8fractionS2d non-external fragment
measure timed_stable_float "$debug_binary" TimedStrokeEmissionCursorV12stableLinear026_93A8D2497DE33A4E0A7046812L5DC127LL__8fractionS2f non-external fragment
measure timed_finite "$debug_binary" TimedStrokeEmissionCursorV8isFinite non-external fragment
measure cursor_accept "$debug_binary" BrushStrokeGeneratorV21emitAcceptedCandidate non-external fragment
measure cursor_evaluate "$debug_binary" BrushStrokeGeneratorV12evaluatedDab non-external fragment
measure cursor_identity "$debug_binary" BrushStrokeGeneratorV24preflightLogicalIdentity external fragment
measure cursor_install "$debug_binary" BrushStrokeGeneratorV24installAcceptedCandidate non-external fragment
measure cursor_random "$debug_binary" BrushRandomV10nextValues external fragment
measure stroke_context_init "$debug_binary" BrushStrokeContextV15nominalDiameter5color9direction external fragment

# Complete dynamics call tree reached by evaluatedDab. The selector completes
# before native assembly begins. This is intentionally fail-closed: adding a
# new non-inlined phase requires charging that frame to candidate acceptance
# instead of treating evaluatedDab as a leaf.
measure dynamics_root "$debug_binary" BrushDynamicsB0V8evaluate6sample external fragment
measure dynamics_native "$debug_binary" BrushDynamicsB0V14evaluateNative non-external swift-nonthrowing-function
measure dynamics_selector "$debug_binary" BrushDynamicsB0V09evaluatedD0 non-external swift-nonthrowing-function
measure dynamics_legacy "$debug_binary" BrushDynamicsB0V014evaluateLegacyD0 non-external swift-nonthrowing-function
measure dynamics_inputs_legacy "$debug_binary" BrushDynamicsB0V6Inputs33_7B02F200D8D2D730B1CECB3C373E8F93LLV6sample7contextAfA24InterpolatedStrokeSample non-external fragment
measure dynamics_inputs_native "$debug_binary" BrushDynamicsB0V6Inputs33_7B02F200D8D2D730B1CECB3C373E8F93LLV6sample7context13normalization non-external fragment
measure dynamics_input_value "$debug_binary" BrushDynamicsB0V6Inputs33_7B02F200D8D2D730B1CECB3C373E8F93LLV5value3forSf non-external fragment
measure dynamics_input_missing "$debug_binary" BrushDynamicsB0V6Inputs33_7B02F200D8D2D730B1CECB3C373E8F93LLV5value3for17missingInputValue non-external fragment
measure dynamics_ordered "$debug_binary" BrushDynamicsB0V15evaluateOrdered non-external fragment
measure dynamics_ordered_output "$debug_binary" BrushDynamicsB0V21evaluateOrderedOutput non-external fragment
measure dynamics_ordered_term "$debug_binary" BrushDynamicsB0V16applyOrderedTerm non-external fragment
measure dynamics_contracted "$debug_binary" BrushDynamicsB0V22contractedOrderedValue non-external fragment
measure dynamics_legacy_response "$debug_binary" BrushDynamicsB0V8evaluate33_7B02F200D8D2D730B1CECB3C373E8F93LL_ non-external fragment
measure dynamics_sampled "$debug_binary" BrushDynamicsB0V12sampledValue non-external fragment
measure dynamics_taper "$debug_binary" BrushDynamicsB0V13taperEnvelope non-external fragment
measure dynamics_envelope "$debug_binary" BrushDynamicsB0V8envelope non-external fragment
measure dynamics_placement "$debug_binary" BrushDynamicsB0V21nativePlacementJitter non-external fragment
measure dynamics_shape "$debug_binary" shapeFrameL_ non-external fragment
measure dynamics_color_jitter "$debug_binary" BrushDynamicsB0V17nativeColorJitter non-external fragment
measure dynamics_jitter_value "$debug_binary" BrushDynamicsB0V17nativeJitterValue non-external fragment
measure dynamics_material_family "$debug_binary" BrushDynamicsB0V20nativeMaterialFamily non-external fragment
measure dynamics_primary_grain_closure "$debug_binary" AA8Affine2DVAA0C20GrainLayerDefinitionVXEfU_ non-external swift-closure
measure dynamics_primary_grain_partial "$debug_binary" AA8Affine2DVAA0C20GrainLayerDefinitionVXEfU_TA non-external swift-partial-apply
measure dynamics_secondary_grain_closure "$debug_binary" AA8Affine2DVAA0C20GrainLayerDefinitionVXEfU0_ non-external swift-closure
measure dynamics_secondary_grain_partial "$debug_binary" AA8Affine2DVAA0C20GrainLayerDefinitionVXEfU0_TA non-external swift-partial-apply
measure dynamics_grain "$debug_binary" BrushDynamicsB0V16nativeGrainFrame non-external fragment
measure dynamics_adjusted_color "$debug_binary" BrushDynamicsB0V13adjustedColor non-external fragment
measure dynamics_apply_color "$debug_binary" BrushDynamicsB0V013applyingColorD0 non-external fragment
measure dynamics_material_inputs "$debug_binary" BrushDynamicsB0V14materialInputs non-external fragment
measure dynamics_random "$debug_binary" BrushDynamicsB0V18nativeRandomValues non-external swift-nonthrowing-function
measure dynamics_random_value "$debug_binary" BrushDynamicsB0V18nativeRandomValues33_7B02F200D8D2D730B1CECB3C373E8F93LL13compatibility10strokeSeed7ordinalAA0c7LogicalfG0VAA0cfG0V_s6UInt64VANtF5valueL_ non-external fragment
measure random_extension "$debug_binary" BrushRandomV18extensionUnitFloat external fragment
measure random_sensor_term "$debug_binary" BrushRandomV19sensorTermUnitFloat external fragment
measure affine_concatenating "$debug_binary" Affine2DV13concatenating external fragment
measure ink_color_init "$debug_binary" InkColorV3red5green4blue5alpha external fragment
measure logical_dab_init "$debug_binary" LogicalDabV8position12brushToWorld6radius8diameter7spacing4flow13strokeOpacity8rotation7scatter8hardness11grainOffset0R5Scale0R8Rotation5color0V10Adjustment14materialFamily0X12Contribution14sourceDistance7ordinal11isPredicted17secondaryColorMix012primaryGraingH0014secondaryGraingH00X6Inputs12randomValues014secondaryShapegH0 external fragment
measure tip_layer_init "$debug_binary" BrushTipSupportLayerV10definition5xAxis external fragment
measure tip_layer_finite "$debug_binary" BrushTipSupportLayerV8isFinite non-external fragment
measure tip_projection "$debug_binary" BrushTipSupportO18projectionInterval7primary external fragment
measure tip_accumulator_init "$debug_binary" BrushTipSupportO21ProjectionAccumulator33_60C24F33D8AAD4452DB3F5F8F1479A63LLV7tangent non-external fragment
measure tip_accumulator_include "$debug_binary" BrushTipSupportO21ProjectionAccumulator33_60C24F33D8AAD4452DB3F5F8F1479A63LLV7include non-external fragment
measure tip_accumulator_interval "$debug_binary" BrushTipSupportO21ProjectionAccumulator33_60C24F33D8AAD4452DB3F5F8F1479A63LLV8interval non-external fragment
measure tip_dot "$debug_binary" BrushTipSupportO3dot33_60C24F33D8AAD4452DB3F5F8F1479A63LL non-external fragment
measure tip_bounds "$debug_binary" BrushTipSupportO14boundsInterval33_60C24F33D8AAD4452DB3F5F8F1479A63LL non-external fragment
measure footprint_carry "$debug_binary" BrushFootprintSpacingO9nextCarry external fragment

# BrushProgram semantic equality branches.
measure definition_helper "$debug_binary" BrushProgramC16definitionsEqual non-external fragment
measure dynamics_helper "$debug_binary" BrushProgramC13dynamicsEqual non-external fragment
measure termination_helper "$debug_binary" BrushProgramC17terminationsEqual non-external fragment
measure capabilities_helper "$debug_binary" BrushProgramC25requiredCapabilitiesEqual non-external fragment
measure ignored_helper "$debug_binary" BrushProgramC32ignoredOptionalCapabilitiesEqual non-external fragment
measure backend_helper "$debug_binary" BrushProgramC22requestedBackendsEqual non-external fragment
measure stage_helper "$debug_binary" BrushProgramC19stageCMetadataEqual non-external fragment
measure definition_eq "$debug_binary" BrushDefinitionV23__derived_struct_equals external fragment
measure dynamics_eq "$debug_binary" BrushDynamicsProgramV23__derived_struct_equals external fragment
measure termination_eq "$debug_binary" BrushTerminationProgramO21__derived_enum_equals external fragment

# Stage-C metadata semantic equality branches.
measure stage_eq "$debug_binary" BrushStageCProgramMetadataC2eeoiy external fragment
measure normalization_helper "$debug_binary" BrushStageCProgramMetadataC19normalizationsEqual non-external fragment
measure sensor_helper "$debug_binary" BrushStageCProgramMetadataC19sensorProgramsEqual non-external fragment
measure stabilization_helper "$debug_binary" BrushStageCProgramMetadataC19stabilizationsEqual non-external fragment
measure direction_helper "$debug_binary" BrushStageCProgramMetadataC15directionsEqual non-external fragment
measure emission_helper "$debug_binary" BrushStageCProgramMetadataC14emissionsEqual non-external fragment
measure tips_helper "$debug_binary" BrushStageCProgramMetadataC16tipSupportsEqual non-external fragment
measure endpoint_helper "$debug_binary" BrushStageCProgramMetadataC17endpointLagsEqual non-external fragment
measure travel_helper "$debug_binary" BrushStageCProgramMetadataC25travelDirectionFlagsEqual non-external fragment
measure compiled_helper "$debug_binary" BrushStageCProgramMetadataC27compiledSensorProgramsEqual non-external fragment
measure normalization_eq "$debug_binary" BrushSensorNormalizationDefinitionV23__derived_struct_equals external fragment
measure sensor_definition_eq "$debug_binary" BrushSensorProgramDefinitionV23__derived_struct_equals external fragment
measure stabilization_definition_eq "$debug_binary" BrushStabilizationDefinitionO21__derived_enum_equals external fragment
measure direction_eq "$debug_binary" BrushDirectionDefinitionV23__derived_struct_equals external fragment
measure emission_eq "$debug_binary" BrushEmissionDefinitionV23__derived_struct_equals external fragment
measure tip_eq "$debug_binary" BrushTipSupportDefinitionV23__derived_struct_equals external fragment

# Compiled sensor program: all output helpers share the same nested output/term
# equality path, but every helper is measured so a single field cannot regress.
measure compiled_eq "$debug_binary" CompiledBrushSensorProgramC2eeoiy external fragment
measure output_eq "$debug_binary" CompiledBrushOutputProgramV23__derived_struct_equals external fragment
measure sensor_term_eq "$debug_binary" CompiledBrushSensorTermV23__derived_struct_equals external fragment
compiled_fields=0
for helper_fragment in \
  C9sizeEqual C9flowEqual C12opacityEqual C12spacingEqual \
  C13rotationEqual C12scatterEqual C13hardnessEqual C10grainEqual \
  C12offsetXEqual C12offsetYEqual C8hueEqual C15saturationEqual \
  C15brightnessEqual C22secondaryColorMixEqual
do
  measure output_helper "$debug_binary" \
    "CompiledBrushSensorProgram${helper_fragment}" non-external fragment
  candidate=$((output_helper + output_eq + sensor_term_eq))
  if (( candidate > compiled_fields )); then compiled_fields=$candidate; fi
done

stage_fields=$(maximum \
  $((normalization_helper + normalization_eq)) \
  $((sensor_helper + sensor_definition_eq)) \
  $((stabilization_helper + stabilization_definition_eq)) \
  $((direction_helper + direction_eq)) \
  $((emission_helper + emission_eq)) \
  $((tips_helper + tip_eq)) \
  "$endpoint_helper" "$travel_helper" \
  $((compiled_helper + compiled_eq + compiled_fields)))

program_fields=$(maximum \
  $((definition_helper + definition_eq)) \
  $((dynamics_helper + dynamics_eq)) \
  $((termination_helper + termination_eq)) \
  "$capabilities_helper" "$ignored_helper" "$backend_helper" \
  $((stage_helper + stage_eq + stage_fields)))

generator_semantic=$(maximum \
  $((generator_configuration + $(maximum \
    $((program_eq + program_fields)) "$ink_eq"))) \
  $((generator_stabilization + stabilizer_eq + stabilizer_storage_eq)) \
  $((generator_direction + $(maximum \
    "$direction_tracker_eq" "$corner_emitter_eq" \
    "$interpolated_sample_eq"))) \
  $((generator_path + $(maximum "$path_eq" "$point_eq"))) \
  $((generator_emission + $(maximum "$random_eq" "$point_eq"))))
generator_semantic=$((generator_eq + generator_semantic))

structural=$((p + structure + $(maximum "$lifecycle" "$append_work")))
input=$((p + input_loop + input_transition + input_eq + filter_eq + filter_storage_eq))
generator_base=$((p + generator_loop + generator_chunk))

measure generator_begin "$debug_binary" BrushStrokeGeneratorV5begin_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment
measure generator_append "$debug_binary" BrushStrokeGeneratorV6append_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment
measure generator_finish "$debug_binary" BrushStrokeGeneratorV6finish_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment
begin_path=$((replay_begin + generator_begin + begin_partial + begin_closure + validate_dab))
append_path=$((replay_append + generator_append + append_partial + append_closure + validate_dab))
finish_path=$((replay_finish + generator_finish + finish_partial + finish_closure + validate_dab))
replay_path=$(maximum "$begin_path" "$append_path" "$finish_path")
after_path=$((transition + $(maximum \
  $((state_after + generator_semantic)) "$replay_path")))
generator=$((generator_base + after_path))

require_composite structural "$structural"
require_composite input "$input"
require_composite generator "$generator" "$generator_debug_limit"

cursor_construct_composite=$((cursor_construct + cursor_init))

dynamics_input_branch=$(maximum \
  "$dynamics_input_value" \
  $((dynamics_input_missing + dynamics_input_value)))
dynamics_response_branch=$((dynamics_legacy_response + $(maximum \
  "$dynamics_input_branch" "$dynamics_sampled" "$random_extension")))
dynamics_ordered_term_branch=$((dynamics_ordered_term + $(maximum \
  "$dynamics_input_branch" "$dynamics_sampled" "$random_sensor_term")))
dynamics_ordered_output_branch=$((dynamics_ordered_output + $(maximum \
  "$dynamics_ordered_term_branch" "$dynamics_contracted")))
dynamics_ordered_branch=$((dynamics_ordered + dynamics_ordered_output_branch))
dynamics_evaluator_branch=$((dynamics_selector + $(maximum \
  "$dynamics_inputs_legacy" "$dynamics_inputs_native" \
  $((dynamics_legacy + dynamics_response_branch)) \
  "$dynamics_ordered_branch")))
dynamics_taper_branch=$((dynamics_taper + dynamics_envelope))
dynamics_placement_branch=$((dynamics_placement + random_extension))
dynamics_color_jitter_branch=$((dynamics_color_jitter \
  + dynamics_jitter_value + random_extension))
dynamics_primary_grain_branch=$((dynamics_primary_grain_partial \
  + dynamics_primary_grain_closure + dynamics_grain))
dynamics_secondary_grain_branch=$((dynamics_secondary_grain_partial \
  + dynamics_secondary_grain_closure + $(maximum \
    "$dynamics_response_branch" "$dynamics_grain")))
dynamics_random_branch=$((dynamics_random + dynamics_random_value \
  + random_extension))
tip_layer_branch=$((tip_layer_init + tip_layer_finite))
tip_include_branch=$((tip_accumulator_include + $(maximum \
  "$tip_dot" "$tip_bounds")))
tip_projection_branch=$((tip_projection + $(maximum \
  "$tip_accumulator_init" "$tip_include_branch" \
  "$tip_accumulator_interval")))
dynamics_support_branch=$(maximum \
  "$tip_layer_branch" "$tip_projection_branch" "$footprint_carry")
dynamics_native_branch=$((dynamics_native + $(maximum \
  "$dynamics_taper_branch" "$dynamics_placement_branch" \
  "$dynamics_shape" "$affine_concatenating" \
  "$dynamics_color_jitter_branch" "$dynamics_material_family" \
  "$dynamics_primary_grain_branch" "$dynamics_secondary_grain_branch" \
  $((dynamics_adjusted_color + ink_color_init)) \
  $((dynamics_apply_color + ink_color_init)) \
  "$dynamics_material_inputs" "$dynamics_random_branch" \
  "$dynamics_support_branch" "$logical_dab_init")))
dynamics_branch=$((dynamics_root + $(maximum \
  "$dynamics_evaluator_branch" "$dynamics_native_branch")))
cursor_evaluate_branch=$((cursor_evaluate + $(maximum \
  "$stroke_context_init" "$dynamics_branch")))
cursor_accept_composite=$((cursor_accept + $(maximum \
  "$cursor_identity" "$cursor_random" "$cursor_evaluate_branch" \
  "$cursor_install")))
timed_optional_angle_branch=$((timed_optional_angle \
  + timed_normalized_angle))
timed_interpolated_branch=$((timed_interpolated + $(maximum \
  "$timed_replacing" "$timed_stable_double" \
  $((timed_stable_float + timed_stable_double)) \
  $((timed_optional_linear + timed_stable_float \
    + timed_stable_double)) \
  "$timed_optional_angle_branch")))
timed_candidate_branch=$((timed_candidate + $(maximum \
  "$timed_interpolated_branch" "$timed_stable_double" \
  "$timed_finite" "$timed_canonical")))
timed_next_branch=$((timed_next + timed_candidate_branch))
timed_consume_branch=$((timed_consume + timed_candidate_branch))
stabilizer_branch=$((generator_stabilizer + stabilizer_process))
timed_emitter_validate_branch=$((timed_emitter_validate \
  + timed_emitter_canonical))
timed_emitter_last_tick_branch=$((timed_emitter_last_tick \
  + timed_emitter_canonical))
timed_emitter_begin_branch=$((timed_begin + $(maximum \
  "$timed_emitter_validate_branch" "$timed_emitter_provenance" \
  "$timed_emitter_canonical")))
timed_emitter_advance_branch=$((timed_advance + $(maximum \
  "$timed_emitter_validate_branch" "$timed_emitter_provenance" \
  "$timed_emitter_canonical" "$timed_emitter_last_tick_branch")))
timed_emitter_prediction_branch=$((timed_prediction + $(maximum \
  "$timed_emitter_validate_branch" "$timed_emitter_canonical" \
  "$timed_emitter_last_tick_branch" "$timed_emitter_index_after")))
timed_emitter_finish_branch=$((timed_finish + $(maximum \
  "$timed_emitter_validate_branch" "$timed_emitter_provenance" \
  "$timed_emitter_canonical" "$timed_emitter_last_tick_branch" \
  "$timed_emitter_index_after" "$timed_emitter_reset")))
timed_initialization_branch=$((generator_timed_init \
  + timed_emitter_begin_branch))
stage_c_timed_branch=$((cursor_stage_c_timed + $(maximum \
  "$stage_c_sample" "$timed_emitter_advance_branch" \
  "$timed_emitter_prediction_branch")))
cursor_complete_branch=$((cursor_complete + generator_reset))
cursor_prepare_branch=$((cursor_prepare + $(maximum \
  "$footprint_validate" "$generator_reset" "$stabilizer_branch" \
  "$generator_corner_validate" "$direction_update" "$path_advance" \
  "$cursor_complete_branch")))
cursor_initial_branch=$((cursor_initial + $(maximum \
  "$path_begin" "$timed_initialization_branch" "$direction_begin")))
cursor_begin_branch=$((cursor_begin_source + $(maximum \
  "$stage_c_candidate" "$cursor_prepare_source")))
cursor_pending_segment_branch=$((cursor_prepare_segment + $(maximum \
  "$stage_c_candidate" "$corner_cursor" "$stage_c_timed_branch")))
cursor_finish_preparation_branch=$((cursor_finish_source + $(maximum \
  "$stage_c_candidate" "$cursor_prepare_source")))
cursor_finish_timed_advance_branch=$((cursor_finish_timed_advance \
  + stage_c_timed_branch))
cursor_finish_timed_termination_branch=$(( \
  cursor_finish_timed_termination + timed_emitter_finish_branch))
cursor_after_branch=$((cursor_after_path + $(maximum \
  "$path_cancel" "$stage_c_timed_branch" "$cursor_prepare_source")))
cursor_path_branch=$((cursor_path + $(maximum \
  "$path_next" "$direction_update")))
cursor_source_candidate_branch=$((cursor_source_candidate + $(maximum \
  "$timed_next_branch" "$emission_merger_next" \
  "$cursor_source_commit")))
cursor_source_branch=$((cursor_source + cursor_source_candidate_branch))
cursor_segment_spatial_branch=$((cursor_segment_spatial + cursor_spatial \
  + $(maximum "$stage_c_candidate" "$corner_next")))
cursor_segment_timed_branch=$((cursor_segment_timed + timed_consume_branch))
cursor_segment_decide_branch=$((cursor_segment_decide + cursor_decide \
  + emission_merger_next))
cursor_segment_settle_branch=$((cursor_segment_settle \
  + cursor_segment_commit_prepared + cursor_commit + corner_next))
cursor_segment_lifecycle_branch=$((cursor_segment_lifecycle \
  + cursor_segment_finish))
cursor_advance_branch=$(maximum \
  "$cursor_prepare_branch" "$cursor_initial_branch" \
  "$cursor_begin_branch" "$cursor_pending_segment_branch" \
  "$cursor_finish_preparation_branch" \
  "$cursor_finish_timed_advance_branch" \
  "$cursor_finish_timed_termination_branch" "$cursor_path_branch" \
  "$cursor_after_branch" \
  "$cursor_source_branch" "$cursor_segment_spatial_branch" \
  "$cursor_segment_timed_branch" "$cursor_segment_decide_branch" \
  "$cursor_segment_settle_branch" \
  "$cursor_segment_lifecycle_branch")
cursor_selection_branch=$((cursor_step + cursor_advance_branch))
cursor_prepared_branch=$((cursor_prepared + $(maximum \
  "$cursor_source_prepared" "$cursor_segment_prepared")))
cursor_commit_branch=$((cursor_commit_root + $(maximum \
  $((cursor_source_commit_prepared + cursor_source_commit)) \
  $((cursor_segment_commit_prepared + cursor_commit)))))
cursor_advance_composite=$((cursor_page + $(maximum \
  "$cursor_selection_branch" "$cursor_prepared_branch" \
  "$cursor_accept_composite" "$cursor_commit_branch")))
printf 'STACK COMPONENT dynamics_evaluator=%s dynamics_native=%s dynamics=%s cursor_accept=%s selection=%s prepared=%s commit=%s page=%s\n' \
  "$dynamics_evaluator_branch" "$dynamics_native_branch" \
  "$dynamics_branch" "$cursor_accept_composite" \
  "$cursor_selection_branch" "$cursor_prepared_branch" \
  "$cursor_commit_branch" "$cursor_page"
require_audited_branch_values "${audited_branches[@]}"
require_composite cursor_construct "$cursor_construct_composite" "$generator_debug_limit"
require_composite timed_next "$timed_next_branch" "$generator_debug_limit"
require_composite cursor_advance "$cursor_advance_composite" "$generator_debug_limit"

# Optimized private helpers may be folded into their roots. Gate every stable
# production/equality root that must survive; inlined private work is therefore
# charged to one of these optimized frames instead of silently disappearing.
for release_spec in \
  'prepareSettledReplayTransfer non-external fragment' \
  'BrushInputDeriverV23__derived_struct_equals external fragment' \
  'StrokeVelocityFilterV23__derived_struct_equals external fragment' \
  'BrushStrokeGeneratorV2eeoiy external fragment' \
  'BrushProgramC2eeoiy external fragment' \
  'BrushStageCProgramMetadataC2eeoiy external fragment' \
  'CompiledBrushSensorProgramC2eeoiy non-external fragment' \
  'BrushStrokeGeneratorV5begin_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment' \
  'BrushStrokeGeneratorV6append_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment' \
  'BrushStrokeGeneratorV6finish_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment' \
  'BrushStrokeGeneratorV14emissionCursor external fragment' \
  'BrushStrokeGeneratorV14EmissionCursorV12emitNextPage external fragment' \
  'BrushDynamicsB0V8evaluate6sample external fragment'
do
  set -- $release_spec
  "$frame_checker" "$release_binary" "$1" "$release_limit" "$2" "$3"
done

printf 'SETTLED REPLAY STACK BUDGET PASS toolchain="Xcode 26.6 / Swift 6.3.3 / LLVM 21.0.0"\n'
