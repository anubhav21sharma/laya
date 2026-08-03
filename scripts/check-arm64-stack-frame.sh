#!/bin/bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  printf 'usage: %s BINARY SYMBOL_FRAGMENT MAXIMUM_BYTES [external|non-external|any] [fragment|swift-function|swift-nonthrowing-function|swift-equality|swift-closure|swift-partial-apply|swift-merged-function|swift-merged-closure]\n' "$0" >&2
  exit 64
fi

binary=$1
fragment=$2
maximum=$3
scope=${4:-external}
match_kind=${5:-fragment}

if [[ ! -f "$binary" ]]; then
  printf 'stack-frame binary does not exist: %s\n' "$binary" >&2
  exit 66
fi
if [[ ! "$maximum" =~ ^[0-9]+$ ]] || [[ "$maximum" -le 0 ]]; then
  printf 'maximum bytes must be a positive integer: %s\n' "$maximum" >&2
  exit 64
fi
case "$scope" in
  external|non-external|any) ;;
  *)
    printf 'unsupported symbol scope: %s\n' "$scope" >&2
    exit 64
    ;;
esac
case "$match_kind" in
  fragment|swift-function|swift-nonthrowing-function|swift-equality|swift-closure|swift-partial-apply|swift-merged-function|swift-merged-closure) ;;
  *)
    printf 'unsupported symbol match kind: %s\n' "$match_kind" >&2
    exit 64
    ;;
esac

symbols=$(
  xcrun nm -nm "$binary" \
    | awk -v fragment="$fragment" -v scope="$scope" \
        -v match_kind="$match_kind" '
        index($NF, fragment) == 0 { next }
        scope == "external" && $0 !~ / external / { next }
        scope == "non-external" && $0 !~ / non-external / { next }
        match_kind == "swift-function" && $NF !~ /KFZ?$/ { next }
        match_kind == "swift-nonthrowing-function" \
          && $NF !~ /tFZ?$/ { next }
        match_kind == "swift-equality" \
          && $NF !~ /V23__derived_struct_equals.*tFZ$/ { next }
        match_kind == "swift-closure" && $NF !~ /EfU[0-9]*_$/ { next }
        match_kind == "swift-partial-apply" \
          && $NF !~ /EfU[0-9]*_TA$/ { next }
        match_kind == "swift-merged-function" && $NF !~ /KFZTm$/ { next }
        match_kind == "swift-merged-closure" && $NF !~ /EfU[0-9]*_Tm$/ { next }
        { print $NF }
      '
)
symbol_count=$(printf '%s\n' "$symbols" | awk 'NF { count += 1 } END { print count + 0 }')
if [[ "$symbol_count" -ne 1 ]]; then
  printf 'expected one %s %s symbol containing %s, found %s\n' \
    "$scope" "$match_kind" "$fragment" "$symbol_count" >&2
  exit 65
fi
symbol=$(printf '%s\n' "$symbols" | awk 'NF { print; exit }')

disassembly=$(mktemp "${TMPDIR:-/tmp}/laya-stack-frame.XXXXXX")
trap 'rm -f "$disassembly"' EXIT
xcrun llvm-objdump --disassemble-symbols="$symbol" "$binary" \
  >"$disassembly"

frame_bytes=0
saw_instruction=0
saw_subtraction=0
instruction_count=0
while IFS= read -r line; do
  if [[ "$line" == *"<$symbol>:"* ]]; then
    saw_instruction=1
    continue
  fi
  [[ "$saw_instruction" -eq 1 ]] || continue
  [[ "$line" =~ ^[[:space:]]*[0-9a-fA-F]+: ]] || continue
  instruction_count=$((instruction_count + 1))

  if [[ "$saw_subtraction" -eq 0 \
        && "$line" =~ (stp|str).*\[sp,[[:space:]]*#-0x([0-9a-fA-F]+)\]! ]]; then
    frame_bytes=$((frame_bytes + 16#${BASH_REMATCH[2]}))
    continue
  fi
  if [[ "$saw_subtraction" -eq 0 \
        && "$line" =~ \[sp,[^]]*\]! ]]; then
    printf 'unknown ARM64 preindexed stack allocation: %s\n' "$line" >&2
    exit 65
  fi
  if [[ "$line" =~ sub[[:space:]]+sp,[[:space:]]*sp, ]]; then
    saw_subtraction=1
    if [[ "$line" =~ \;[[:space:]]*=0x([0-9a-fA-F]+) ]]; then
      frame_bytes=$((frame_bytes + 16#${BASH_REMATCH[1]}))
    elif [[ "$line" =~ \#0x([0-9a-fA-F]+) ]]; then
      immediate=$((16#${BASH_REMATCH[1]}))
      if [[ "$line" == *"lsl #12"* ]]; then
        immediate=$((immediate << 12))
      fi
      frame_bytes=$((frame_bytes + immediate))
    else
      printf 'unknown ARM64 stack subtraction: %s\n' "$line" >&2
      exit 65
    fi
    continue
  fi
  if [[ "$saw_subtraction" -eq 1 ]]; then
    break
  fi
done <"$disassembly"

if [[ "$instruction_count" -eq 0 ]]; then
  printf 'could not parse any instructions for %s\n' "$symbol" >&2
  exit 65
fi
if [[ "$frame_bytes" -gt "$maximum" ]]; then
  printf 'STACK FRAME FAIL bytes=%s maximum=%s symbol=%s\n' \
    "$frame_bytes" "$maximum" "$symbol" >&2
  exit 1
fi

printf 'STACK FRAME PASS bytes=%s maximum=%s symbol=%s\n' \
  "$frame_bytes" "$maximum" "$symbol"
