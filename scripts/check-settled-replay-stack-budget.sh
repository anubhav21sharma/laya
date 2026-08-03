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
measure generator_before "$debug_binary" validateSettledReplayGeneratorBefore non-external swift-function
measure after_before "$debug_binary" advanceSettledReplayGeneratorChunkAfterBeforeCheck non-external swift-function
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
before_path=$((generator_before + generator_semantic))

measure generator_begin "$debug_binary" BrushStrokeGeneratorV5begin external fragment
measure generator_append "$debug_binary" BrushStrokeGeneratorV6append_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment
measure generator_finish "$debug_binary" BrushStrokeGeneratorV6finish_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment
begin_path=$((replay_begin + generator_begin + begin_partial + begin_closure + validate_dab))
append_path=$((replay_append + generator_append + append_partial + append_closure + validate_dab))
finish_path=$((replay_finish + generator_finish + finish_partial + finish_closure + validate_dab))
replay_path=$(maximum "$begin_path" "$append_path" "$finish_path")
after_path=$((after_before + transition + $(maximum \
  $((state_after + generator_semantic)) "$replay_path")))
generator=$((generator_base + $(maximum "$before_path" "$after_path")))

require_composite structural "$structural"
require_composite input "$input"
require_composite generator "$generator" "$generator_debug_limit"

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
  'BrushStrokeGeneratorV5begin external fragment' \
  'BrushStrokeGeneratorV6append_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment' \
  'BrushStrokeGeneratorV6finish_4emityAA05WorldD6SampleV_yAA10LogicalDabVKXEtKF external fragment'
do
  set -- $release_spec
  "$frame_checker" "$release_binary" "$1" "$release_limit" "$2" "$3"
done

printf 'SETTLED REPLAY STACK BUDGET PASS toolchain="Xcode 26.6 / Swift 6.3.3 / LLVM 21.0.0"\n'
