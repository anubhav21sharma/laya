#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s FULL_SUITE_LOG BASELINE_FILE\n' "$0" >&2
  exit 2
fi

log="$1"
baseline="$2"

if [[ ! -f "$log" ]]; then
  printf 'Swift Testing baseline verification failed: log does not exist: %s\n' "$log" >&2
  exit 2
fi

if [[ ! -f "$baseline" ]]; then
  printf 'Swift Testing baseline verification failed: baseline does not exist: %s\n' "$baseline" >&2
  exit 2
fi

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/swift-testing-baseline.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
records="$work_directory/records"
actual="$work_directory/normalized-records.txt"
mkdir "$records"

LC_ALL=C awk -v output_directory="$records" '
function normalizedLocation(line, location) {
  if (match(line, / at [^[:space:]]+\.swift:[0-9]+:[0-9]+:/)) {
    location = substr(line, RSTART, RLENGTH)
    sub(/:[0-9]+:[0-9]+:$/, ":<line>:<column>:", location)
    return substr(line, 1, RSTART - 1) location substr(line, RSTART + RLENGTH)
  }
  return line
}

function flushRecord(file) {
  if (!capturing) {
    return
  }
  file = sprintf("%s/%06d", output_directory, ++record_count)
  printf "%s", record > file
  close(file)
  capturing = 0
  record = ""
}

/^✘ Test .* recorded an issue/ {
  flushRecord()
  record = normalizedLocation($0) ORS
  capturing = 1
  next
}

capturing && /^(◇|✔|✘) / {
  flushRecord()
  next
}

capturing {
  record = record $0 ORS
}

END {
  flushRecord()
}
' "$log"

shopt -s nullglob
for record in "$records"/*; do
  base64 <"$record" | tr -d '\n'
  printf '\n'
done | LC_ALL=C sort >"$actual"

if ! cmp -s "$actual" "$baseline"; then
  printf 'Swift Testing baseline verification failed.\n' >&2
  printf 'Expected %s records; observed %s records.\n' \
    "$(wc -l <"$baseline" | tr -d ' ')" \
    "$(wc -l <"$actual" | tr -d ' ')" >&2
  diff -u "$baseline" "$actual" >&2 || true
  exit 1
fi

printf 'Swift Testing baseline verified: %s complete issue records.\n' \
  "$(wc -l <"$actual" | tr -d ' ')"
