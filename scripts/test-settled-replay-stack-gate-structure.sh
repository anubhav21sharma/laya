#!/bin/bash

set -euo pipefail

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
gate="$script_directory/check-settled-replay-stack-budget.sh"
unlisted_mutant=$(mktemp "$script_directory/.settled-stack-gate-mutant.XXXXXX")
unreachable_mutant=$(mktemp "$script_directory/.settled-stack-gate-mutant.XXXXXX")
bogus_edge_mutant=$(mktemp "$script_directory/.settled-stack-gate-mutant.XXXXXX")
duplicate_assignment_mutant=$(mktemp "$script_directory/.settled-stack-gate-mutant.XXXXXX")
missing_edge_mutant=$(mktemp "$script_directory/.settled-stack-gate-mutant.XXXXXX")
trap 'rm -f "$unlisted_mutant" "$unreachable_mutant" "$bogus_edge_mutant" "$duplicate_assignment_mutant" "$missing_edge_mutant"' EXIT

sed '/^set -euo pipefail$/a\
orphan_review_mutant_branch=1\
printf '\''orphan=%s\\n'\'' "$orphan_review_mutant_branch"' \
  "$gate" > "$unlisted_mutant"
chmod +x "$unlisted_mutant"

if output=$("$unlisted_mutant" /dev/null /dev/null 2>&1); then
  printf 'stack-gate unlisted orphan mutation unexpectedly passed\n' >&2
  exit 1
fi
if [[ "$output" != *'STACK STRUCTURE FAIL unexpected_branch=orphan_review_mutant_branch'* ]]; then
  printf 'stack-gate unlisted orphan failed for the wrong reason:\n%s\n' \
    "$output" >&2
  exit 1
fi
if [[ "$output" == *'STACK FRAME'* ]]; then
  printf 'stack-gate unlisted orphan reached binary measurement\n' >&2
  exit 1
fi

sed \
  -e '/^set -euo pipefail$/a\
orphan_review_mutant_branch=1\
printf '\''orphan=%s\\n'\'' "$orphan_review_mutant_branch"' \
  -e '/^audited_branches=($/a\
  orphan_review_mutant_branch' \
  "$gate" > "$unreachable_mutant"
chmod +x "$unreachable_mutant"

if output=$("$unreachable_mutant" /dev/null /dev/null 2>&1); then
  printf 'stack-gate listed unreachable mutation unexpectedly passed\n' >&2
  exit 1
fi
if [[ "$output" != *'STACK STRUCTURE FAIL unreachable_branch=orphan_review_mutant_branch root=cursor_advance_composite'* ]]; then
  printf 'stack-gate listed unreachable mutation failed for the wrong reason:\n%s\n' \
    "$output" >&2
  exit 1
fi
if [[ "$output" == *'STACK FRAME'* ]]; then
  printf 'stack-gate listed unreachable mutation reached binary measurement\n' >&2
  exit 1
fi

sed \
  -e '/^set -euo pipefail$/a\
orphan_review_mutant_branch=1\
printf '\''orphan=%s\\n'\'' "$orphan_review_mutant_branch"' \
  -e '/^audited_branches=($/a\
  orphan_review_mutant_branch' \
  -e '/^audited_branch_edges=($/a\
  orphan_review_mutant_branch:cursor_advance_branch' \
  "$gate" > "$bogus_edge_mutant"
chmod +x "$bogus_edge_mutant"

if output=$("$bogus_edge_mutant" /dev/null /dev/null 2>&1); then
  printf 'stack-gate bogus edge mutation unexpectedly passed\n' >&2
  exit 1
fi
if [[ "$output" != *'STACK STRUCTURE FAIL stale_declared_edge=orphan_review_mutant_branch:cursor_advance_branch'* ]]; then
  printf 'stack-gate bogus edge mutation failed for the wrong reason:\n%s\n' \
    "$output" >&2
  exit 1
fi
if [[ "$output" == *'STACK FRAME'* ]]; then
  printf 'stack-gate bogus edge mutation reached binary measurement\n' >&2
  exit 1
fi

sed '/^set -euo pipefail$/a\
timed_emitter_prediction_branch=1' \
  "$gate" > "$duplicate_assignment_mutant"
chmod +x "$duplicate_assignment_mutant"

if output=$("$duplicate_assignment_mutant" /dev/null /dev/null 2>&1); then
  printf 'stack-gate duplicate assignment mutation unexpectedly passed\n' >&2
  exit 1
fi
if [[ "$output" != *'STACK STRUCTURE FAIL node=timed_emitter_prediction_branch assignments=2 expected=1'* ]]; then
  printf 'stack-gate duplicate assignment failed for the wrong reason:\n%s\n' \
    "$output" >&2
  exit 1
fi
if [[ "$output" == *'STACK FRAME'* ]]; then
  printf 'stack-gate duplicate assignment reached binary measurement\n' >&2
  exit 1
fi

sed \
  '/^  timed_emitter_validate_branch:timed_emitter_prediction_branch$/d' \
  "$gate" > "$missing_edge_mutant"
chmod +x "$missing_edge_mutant"

if output=$("$missing_edge_mutant" /dev/null /dev/null 2>&1); then
  printf 'stack-gate missing edge mutation unexpectedly passed\n' >&2
  exit 1
fi
if [[ "$output" != *'STACK STRUCTURE FAIL missing_declared_edge=timed_emitter_validate_branch:timed_emitter_prediction_branch'* ]]; then
  printf 'stack-gate missing edge mutation failed for the wrong reason:\n%s\n' \
    "$output" >&2
  exit 1
fi
if [[ "$output" == *'STACK FRAME'* ]]; then
  printf 'stack-gate missing edge mutation reached binary measurement\n' >&2
  exit 1
fi

printf 'STACK STRUCTURE MUTATION PASS unlisted_orphan=rejected listed_unreachable_orphan=rejected bogus_edge=rejected duplicate_assignment=rejected missing_multi_parent_edge=rejected before_measurement=true\n'
