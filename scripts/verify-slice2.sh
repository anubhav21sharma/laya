#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/slice2-artifacts"
scenes="$repo_root/App/PatternSpike/Harness/Scenes"
derived_data="$repo_root/.build/DerivedData"
pad_derived_data="$repo_root/.build/DerivedDataPad"
binary="$derived_data/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
mutable_slice1_artifacts="$repo_root/.build/slice1-artifacts"
accepted_baseline_pointer="$repo_root/.build/accepted-baselines/current-slice1"

gate_error() {
  printf 'SLICE2 GATE ERROR: %s\n' "$*" >&2
  return 1
}

canonical_directory() {
  local directory="$1"
  [[ -d "$directory" ]] || {
    gate_error "baseline directory does not exist: $directory"
    return 1
  }
  (cd "$directory" && pwd -P)
}

path_is_within() {
  local path="$1"
  local parent="$2"
  [[ "$path" == "$parent" || "$path" == "$parent/"* ]]
}

normalize_baseline_candidate() {
  local candidate="$1"
  local candidate_path root positive mutable

  candidate_path="$(canonical_directory "$candidate")" || return 1
  mutable="$(canonical_directory "$mutable_slice1_artifacts")" || return 1

  if path_is_within "$candidate_path" "$mutable"; then
    gate_error "mutable Slice 1 artifact baseline is forbidden: $candidate_path"
    return 1
  fi

  if [[ -f "$candidate_path/SHA256SUMS" && -d "$candidate_path/positive" ]]; then
    root="$candidate_path"
    positive="$(canonical_directory "$candidate_path/positive")" || return 1
  elif [[ "${candidate_path##*/}" == "positive" && \
          -f "${candidate_path%/*}/SHA256SUMS" ]]; then
    positive="$candidate_path"
    root="$(canonical_directory "${candidate_path%/*}")" || return 1
  else
    gate_error "accepted Slice 1 baseline must contain SHA256SUMS and positive/: $candidate_path"
    return 1
  fi

  if ! path_is_within "$positive" "$root"; then
    gate_error "accepted Slice 1 positive directory escapes its baseline root: $positive"
    return 1
  fi
  if path_is_within "$root" "$mutable" || path_is_within "$positive" "$mutable"; then
    gate_error "mutable Slice 1 artifact baseline is forbidden: $positive"
    return 1
  fi
  case "$root$positive" in
    *'|'*)
      gate_error "accepted baseline path contains unsupported delimiter: $root"
      return 1
      ;;
  esac

  printf '%s|%s\n' "$root" "$positive"
}

resolve_accepted_baseline() {
  local candidate line line_count pointer_directory

  if [[ -n "${SLICE1_BASELINE_DIR:-}" ]]; then
    normalize_baseline_candidate "$SLICE1_BASELINE_DIR"
    return
  fi

  if [[ -L "$accepted_baseline_pointer" ]]; then
    normalize_baseline_candidate "$accepted_baseline_pointer"
    return
  fi
  if [[ -f "$accepted_baseline_pointer" ]]; then
    candidate=""
    line_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_count=$((line_count + 1))
      candidate="$line"
    done <"$accepted_baseline_pointer"
    if [[ "$line_count" -ne 1 || -z "$candidate" ]]; then
      gate_error "accepted baseline pointer file must contain exactly one nonempty path"
      return 1
    fi
    if [[ "$candidate" != /* ]]; then
      pointer_directory="$(cd "$(dirname "$accepted_baseline_pointer")" && pwd -P)"
      candidate="$pointer_directory/$candidate"
    fi
    normalize_baseline_candidate "$candidate"
    return
  fi
  if [[ -e "$accepted_baseline_pointer" ]]; then
    gate_error "accepted baseline pointer is neither a directory symlink nor a regular pointer file"
    return 1
  fi

  return 0
}

validate_checksum_manifest() {
  local root="$1"
  local manifest="$root/SHA256SUMS"
  local line hash relative count positive mutable entry_parent entry

  [[ -f "$manifest" && ! -L "$manifest" ]] || {
    gate_error "accepted baseline checksum manifest is missing or symlinked: $manifest"
    return 1
  }
  positive="$(canonical_directory "$root/positive")" || return 1
  mutable="$(canonical_directory "$mutable_slice1_artifacts")" || return 1

  count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || {
      gate_error "accepted baseline checksum manifest contains an empty line"
      return 1
    }
    hash="${line%% *}"
    if ! printf '%s\n' "$hash" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
      gate_error "accepted baseline checksum manifest contains an invalid SHA-256"
      return 1
    fi
    relative="${line#"$hash"}"
    relative="${relative# }"
    relative="${relative# }"
    relative="${relative#\*}"
    case "$relative" in
      positive/*) ;;
      *)
        gate_error "accepted baseline manifest path is outside positive/: $relative"
        return 1
        ;;
    esac
    case "/$relative/" in
      *'/../'*|*'/./'*)
        gate_error "accepted baseline manifest path is not canonical: $relative"
        return 1
        ;;
    esac
    [[ -f "$root/$relative" && ! -L "$root/$relative" ]] || {
      gate_error "accepted baseline manifest entry is missing or symlinked: $relative"
      return 1
    }
    entry_parent="$(
      canonical_directory "$(dirname "$root/$relative")"
    )" || return 1
    entry="$entry_parent/${relative##*/}"
    if ! path_is_within "$entry" "$positive"; then
      gate_error "accepted baseline manifest entry escapes positive/: $relative"
      return 1
    fi
    if path_is_within "$entry" "$mutable"; then
      gate_error "accepted baseline manifest entry resolves under mutable Slice 1 artifacts: $relative"
      return 1
    fi
    count=$((count + 1))
  done <"$manifest"

  [[ "$count" -gt 0 ]] || {
    gate_error "accepted baseline checksum manifest is empty"
    return 1
  }
}

verify_baseline_checksums() {
  local root="$1"
  local name relative line hash listed
  validate_checksum_manifest "$root" || return 1
  for name in \
    grid-interior grid-boundary preview-commit cancel-preserves-canonical \
    five-hundred-dabs long-stroke
  do
    relative="positive/$name/$name.benchmark.json"
    listed=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      hash="${line%% *}"
      line="${line#"$hash"}"
      line="${line# }"
      line="${line# }"
      line="${line#\*}"
      if [[ "$line" == "$relative" ]]; then
        listed=1
        break
      fi
    done <"$root/SHA256SUMS"
    if [[ "$listed" -ne 1 ]]; then
      gate_error "accepted baseline manifest does not protect $relative"
      return 1
    fi
  done
  if ! (cd "$root" && shasum -a 256 -c SHA256SUMS >/dev/null); then
    gate_error "accepted Slice 1 baseline checksum verification failed: $root"
    return 1
  fi
}

baseline_manifest_digest() {
  local root="$1"
  local digest

  digest="$(
    shasum -a 256 "$root/SHA256SUMS" | awk '{ print $1 }'
  )" || return 1
  if ! printf '%s\n' "$digest" | grep -Eq '^[0-9A-Fa-f]{64}$'; then
    gate_error "unable to pin accepted baseline checksum manifest: $root"
    return 1
  fi
  printf '%s\n' "$digest"
}

verify_pinned_baseline() {
  local root="$1"
  local expected_digest="$2"
  local before after

  before="$(baseline_manifest_digest "$root")" || return 1
  if [[ "$before" != "$expected_digest" ]]; then
    gate_error "accepted baseline checksum manifest changed after it was pinned: $root"
    return 1
  fi
  verify_baseline_checksums "$root" || return 1
  after="$(baseline_manifest_digest "$root")" || return 1
  if [[ "$after" != "$expected_digest" ]]; then
    gate_error "accepted baseline checksum manifest changed during verification: $root"
    return 1
  fi
}

snapshot_baseline() {
  local source_root="$1"
  local snapshot_root="$2"
  local expected_digest="$3"
  local line hash relative

  verify_pinned_baseline "$source_root" "$expected_digest" || return 1
  rm -rf "$snapshot_root"
  mkdir -p "$snapshot_root"
  cp "$source_root/SHA256SUMS" "$snapshot_root/SHA256SUMS"
  while IFS= read -r line || [[ -n "$line" ]]; do
    hash="${line%% *}"
    relative="${line#"$hash"}"
    relative="${relative# }"
    relative="${relative# }"
    relative="${relative#\*}"
    mkdir -p "$snapshot_root/$(dirname "$relative")"
    cp "$source_root/$relative" "$snapshot_root/$relative"
  done <"$source_root/SHA256SUMS"
  verify_pinned_baseline "$source_root" "$expected_digest" || return 1
  verify_pinned_baseline "$snapshot_root" "$expected_digest"
}

scene_matrix() {
  cat <<'MATRIX'
generalized-grid|grid|0|256|256|hardRound|oracleHoleCount|coverage-basic|oracle
halfdrop-interior|halfDrop|1|288|192|hardRound|oraclePhantomCount|coverage-gridlines|oracle
halfdrop-edge|halfDrop|1|288|192|hardRound|oracleHoleCount|coverage-gridlines|oracle
halfdrop-corner|halfDrop|1|288|192|hardRound|oraclePhantomCount|coverage-gridlines|oracle
brick-transpose|brick|2|288|192|hardRound|transformMismatchCount|coverage-gridlines|oracle
mirror-x|mirrorX|3|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
mirror-y|mirrorY|4|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
mirror-xy|mirrorXY|5|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
rotational-generator|rotational|6|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
rotational-fixed-point|rotational|6|256|256|hardRound|duplicateFixedPointWriteCount|coverage-basic|oracle
rotational-orientation|rotational|6|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
large-footprint|grid|0|64|96|hardRound|oracleHoleCount|coverage-basic|oracle
asymmetric-footprint|rotational|6|256|256|asymmetricCoverage|transformMismatchCount|diagnostic|oracle
canonical-coordinate-continuity|halfDrop|1|288|192|canonicalCoordinates|coordinateContinuityMismatchCount|diagnostic|oracle
brush-local-coordinate-continuity|mirrorXY|5|256|256|brushLocalCoordinates|coordinateContinuityMismatchCount|diagnostic|oracle
rectangular-tile|grid|0|320|192|hardRound|oracleHoleCount|coverage-basic|oracle
noncentral-visible-cell-grid|grid|0|256|256|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-halfdrop|halfDrop|1|288|192|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-brick|brick|2|288|192|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-mirror-x|mirrorX|3|256|256|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-mirror-y|mirrorY|4|256|256|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-mirror-xy|mirrorXY|5|256|256|hardRound|visibleCellCanonicalByteDelta|noncentral|none
noncentral-visible-cell-rotational|rotational|6|256|256|hardRound|visibleCellCanonicalByteDelta|noncentral|none
metadata-tiling-switch|grid|0|256|256|hardRound|canonicalByteDelta|metadata|none
projected-live-commit|halfDrop|1|288|192|hardRound|previewCommitViolationCount|projected|none
projected-long-stroke|halfDrop|1|288|192|hardRound|restampedInstanceCount|projected|none
MATRIX
}

require_artifact() {
  local path="$1"
  [[ -s "$path" ]] || {
    gate_error "required Slice 2 artifact is missing or empty: $path"
    return 1
  }
}

require_artifact_family() {
  local name="$1"
  local family="$2"
  local output="$artifacts/positive/$name"
  local suffix

  require_artifact "$output/$name.benchmark.json" || return 1
  require_artifact "$output/stdout.log" || return 1

  case "$family" in
    coverage-basic|coverage-gridlines)
      for suffix in \
        live.screen.png committed.screen.png canonical.png \
        oracle.coverage.png oracle.canonical-coordinates.png \
        oracle.brush-local-coordinates.png oracle.metrics.json
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      if [[ "$family" == "coverage-gridlines" ]]; then
        require_artifact "$output/$name.grid-lines.screen.png" || return 1
      fi
      ;;
    diagnostic)
      for suffix in \
        live.screen.png canonical.png display-validation.canonical.png \
        display-validation.screen.png display-validation.grid-lines.screen.png \
        oracle.coverage.png oracle.canonical-coordinates.png \
        oracle.brush-local-coordinates.png oracle.metrics.json
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    noncentral)
      require_artifact "$output/$name.committed.screen.png" || return 1
      require_artifact "$output/$name.canonical.png" || return 1
      ;;
    metadata)
      for suffix in \
        initial-tiling.screen.png alternate-tiling.screen.png \
        restored-tiling.screen.png committed.screen.png canonical.png
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    projected)
      require_artifact "$output/$name.live.screen.png" || return 1
      require_artifact "$output/$name.committed.screen.png" || return 1
      require_artifact "$output/$name.canonical.png" || return 1
      ;;
    *)
      gate_error "unknown Slice 2 artifact family for $name: $family"
      return 1
      ;;
  esac
}

stderr_matches_exact_line() {
  local file="$1"
  local expected="$2"

  if printf '%s' "$expected" | cmp -s - "$file"; then
    return 0
  fi
  printf '%s\n' "$expected" | cmp -s - "$file"
}

run_pair() {
  local name="$1"
  local tiling="$2"
  local metric="$3"
  local family="$4"
  local negative="$name-negative-control"
  local negative_output="$artifacts/negative-control/$negative"
  local positive_output="$artifacts/positive/$name"
  local expected

  mkdir -p "$negative_output" "$positive_output"
  if "$binary" \
    --harness-scene "$scenes/$negative.json" \
    --output-directory "$negative_output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  then
    gate_error "negative control unexpectedly passed: $negative"
    return 1
  fi
  expected="HARNESS FAIL Tiling scene '$negative' tiling $tiling cell none metric $metric: expected equal 1, actual 0."
  if ! stderr_matches_exact_line \
    "$negative_output/stderr.log" "$expected"
  then
    cat "$negative_output/stderr.log" >&2
    gate_error "negative control stderr mismatch: $negative"
    return 1
  fi

  if ! "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$positive_output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$positive_output/stdout.log" \
    2>"$positive_output/stderr.log"
  then
    cat "$positive_output/stderr.log" >&2
    gate_error "positive Slice 2 scene failed: $name"
    return 1
  fi
  grep -q "^HARNESS PASS scene=$name " "$positive_output/stdout.log" || {
    gate_error "positive Slice 2 scene did not print its pass record: $name"
    return 1
  }
  require_artifact_family "$name" "$family"
}

evaluate_benchmark_json() {
  local slice2_positive="$1"
  local slice1_positive="$2"
  local expected_commit="$3"
  local baseline_positive="$4"
  local matrix_file="$repo_root/.build/slice2-scene-matrix.tsv"

  scene_matrix >"$matrix_file"
  swift - "$slice2_positive" "$slice1_positive" "$expected_commit" \
    "$baseline_positive" "$matrix_file" <<'SWIFT'
import Foundation

enum GateFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(message): message }
    }
}

struct Hardware: Decodable, Equatable {
    let gpuName: String
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
}

struct Build: Decodable {
    let configuration: String
    let gitCommit: String
}

struct Record: Decodable {
    let schemaVersion: Int
    let timestampUTC: String
    let sceneName: String
    let hardware: Hardware
    let operatingSystem: String
    let build: Build
    let frameCount: Int
    let cpuEncodeMilliseconds: [Double]
    let gpuMilliseconds: [Double]
    let peakResidentBytes: UInt64
    let brushProcessingMilliseconds: [Double]?
    let eventToSubmitMilliseconds: [Double]?
    let dabGPUMilliseconds: [Double]?
    let gridGPUMilliseconds: [Double]?
    let commitGPUMilliseconds: [Double]?
    let commitPendingMilliseconds: [Double]?
    let displayFrameBudgetMilliseconds: Double?
    let newInstanceCounts: [Int]?
    let totalStrokeInstanceCounts: [Int]?
    let missedFrameCount: Int?
    let tilingRawValue: UInt32?
    let tileWidth: Int?
    let tileHeight: Int?
    let totalProjectedFragmentCount: Int?
    let maximumFragmentsPerFootprint: Int?
    let totalInstanceBytes: Int?
    let oracleHoleCount: Int?
    let oraclePhantomCount: Int?
    let oracleMaximumDelta: Int?
    let diagnosticMode: String?
    let longStrokeEarlyCPUP95Milliseconds: Double?
    let longStrokeLateCPUP95Milliseconds: Double?
    let longStrokeEarlyDabGPUP95Milliseconds: Double?
    let longStrokeLateDabGPUP95Milliseconds: Double?
    let longStrokeCPUMillisecondsPerFrameSlope: Double?
    let longStrokeDabGPUMillisecondsPerFrameSlope: Double?
}

struct Requirement {
    let name: String
    let tilingRawValue: UInt32
    let tileWidth: Int
    let tileHeight: Int
    let diagnosticMode: String
    let requiresOracle: Bool
}

func failure(_ message: String) -> GateFailure { .message(message) }

func load(_ url: URL) throws -> Record {
    do {
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    } catch {
        throw failure("\(url.path): invalid or incomplete benchmark JSON: \(error)")
    }
}

func required<T>(_ value: T?, _ field: String, scene: String) throws -> T {
    guard let value else { throw failure("\(scene): missing \(field)") }
    return value
}

func validatePositive(_ values: [Double], field: String, scene: String, allowEmpty: Bool) throws {
    if values.isEmpty && !allowEmpty {
        throw failure("\(scene): \(field) is empty")
    }
    for value in values {
        guard value.isFinite else {
            throw failure("\(scene): \(field) contains non-finite value")
        }
        guard value > 0 else {
            throw failure("\(scene): \(field) contains non-positive value \(value)")
        }
    }
}

func percentile95(_ values: [Double]) throws -> Double {
    guard !values.isEmpty else { throw failure("cannot calculate p95 from an empty series") }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    return sorted[index]
}

func slope(_ values: [Double]) throws -> Double {
    guard values.count > 1 else { throw failure("cannot calculate slope from fewer than two samples") }
    let count = Double(values.count)
    let meanX = Double(values.count - 1) * 0.5
    let meanY = values.reduce(0, +) / count
    var numerator = 0.0
    var denominator = 0.0
    for (index, value) in values.enumerated() {
        let x = Double(index) - meanX
        numerator += x * (value - meanY)
        denominator += x * x
    }
    let result = numerator / denominator
    guard result.isFinite else { throw failure("least-squares slope is not finite") }
    return result
}

func equalMeasurement(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) <= max(1e-12, max(abs(lhs), abs(rhs)) * 1e-12)
}

func validateIdentity(_ record: Record, commit: String, scene: String) throws {
    guard record.build.gitCommit == commit else {
        throw failure("\(scene): build.gitCommit \(record.build.gitCommit) does not match \(commit)")
    }
    guard record.build.configuration == "Debug" else {
        throw failure("\(scene): build.configuration is \(record.build.configuration), expected Debug")
    }
    guard !record.hardware.gpuName.isEmpty,
          record.hardware.logicalProcessorCount > 0,
          record.hardware.physicalMemoryBytes > 0,
          !record.operatingSystem.isEmpty,
          !record.timestampUTC.isEmpty else {
        throw failure("\(scene): benchmark identity contains an empty or non-positive field")
    }
}

func validateMeasurementFields(_ record: Record) throws {
    let scene = record.sceneName
    try validatePositive(record.cpuEncodeMilliseconds, field: "cpuEncodeMilliseconds", scene: scene, allowEmpty: false)
    try validatePositive(record.gpuMilliseconds, field: "gpuMilliseconds", scene: scene, allowEmpty: false)
    let optionalSeries: [(String, [Double]?)] = [
        ("brushProcessingMilliseconds", record.brushProcessingMilliseconds),
        ("eventToSubmitMilliseconds", record.eventToSubmitMilliseconds),
        ("dabGPUMilliseconds", record.dabGPUMilliseconds),
        ("gridGPUMilliseconds", record.gridGPUMilliseconds),
        ("commitGPUMilliseconds", record.commitGPUMilliseconds),
        ("commitPendingMilliseconds", record.commitPendingMilliseconds),
    ]
    for (field, optionalValues) in optionalSeries {
        let values = try required(optionalValues, field, scene: scene)
        try validatePositive(values, field: field, scene: scene, allowEmpty: true)
    }
    let budget = try required(record.displayFrameBudgetMilliseconds, "displayFrameBudgetMilliseconds", scene: scene)
    guard budget.isFinite, budget > 0 else {
        throw failure("\(scene): displayFrameBudgetMilliseconds is non-finite or non-positive")
    }
}

func validateCounters(_ record: Record) throws {
    let scene = record.sceneName
    let newCounts = try required(record.newInstanceCounts, "newInstanceCounts", scene: scene)
    let totals = try required(record.totalStrokeInstanceCounts, "totalStrokeInstanceCounts", scene: scene)
    let missed = try required(record.missedFrameCount, "missedFrameCount", scene: scene)
    guard record.frameCount > 0,
          newCounts.count == record.frameCount,
          totals.count == record.frameCount else {
        throw failure("\(scene): frame and instance-count lengths do not match")
    }
    guard missed >= 0, missed <= record.frameCount else {
        throw failure("\(scene): missedFrameCount is outside 0...frameCount")
    }
    var previous = 0
    for index in newCounts.indices {
        guard newCounts[index] > 0, totals[index] > 0 else {
            throw failure("\(scene): instance counters contain a non-positive value")
        }
        guard totals[index] - previous == newCounts[index] else {
            throw failure("\(scene): frame \(index) encoded old or missing instances")
        }
        previous = totals[index]
    }
}

func readRequirements(_ url: URL) throws -> [Requirement] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(whereSeparator: \.isNewline)
    guard lines.count == 26 else { throw failure("Slice 2 matrix contains \(lines.count) rows instead of 26") }
    return try lines.map { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9,
              let raw = UInt32(fields[2]),
              let width = Int(fields[3]),
              let height = Int(fields[4]) else {
            throw failure("invalid Slice 2 matrix row: \(line)")
        }
        return Requirement(
            name: fields[0],
            tilingRawValue: raw,
            tileWidth: width,
            tileHeight: height,
            diagnosticMode: fields[5],
            requiresOracle: fields[8] == "oracle"
        )
    }
}

func validateLongStroke(_ record: Record) throws {
    let scene = record.sceneName
    let cpuAll = try required(record.eventToSubmitMilliseconds, "eventToSubmitMilliseconds", scene: scene)
    let gpuAll = try required(record.dabGPUMilliseconds, "dabGPUMilliseconds", scene: scene)
    let newAll = try required(record.newInstanceCounts, "newInstanceCounts", scene: scene)
    guard cpuAll.count == 401, gpuAll.count == 401, newAll.count == 401 else {
        throw failure("\(scene): long stroke requires one initial frame plus exactly 400 measured frames")
    }
    let cpu = Array(cpuAll.dropFirst())
    let gpu = Array(gpuAll.dropFirst())
    let projected = Array(newAll.dropFirst())
    guard Set(projected).count == 1, projected.first.map({ $0 > 0 }) == true else {
        throw failure("\(scene): measured frames do not have one uniform positive projected-instance count")
    }
    let earlyCPU = try percentile95(Array(cpu[40...119]))
    let lateCPU = try percentile95(Array(cpu[280...359]))
    let earlyGPU = try percentile95(Array(gpu[40...119]))
    let lateGPU = try percentile95(Array(gpu[280...359]))
    let cpuSlope = try slope(cpu)
    let gpuSlope = try slope(gpu)
    let storedEarlyCPU = try required(record.longStrokeEarlyCPUP95Milliseconds, "longStrokeEarlyCPUP95Milliseconds", scene: scene)
    let storedLateCPU = try required(record.longStrokeLateCPUP95Milliseconds, "longStrokeLateCPUP95Milliseconds", scene: scene)
    let storedEarlyGPU = try required(record.longStrokeEarlyDabGPUP95Milliseconds, "longStrokeEarlyDabGPUP95Milliseconds", scene: scene)
    let storedLateGPU = try required(record.longStrokeLateDabGPUP95Milliseconds, "longStrokeLateDabGPUP95Milliseconds", scene: scene)
    let storedCPUSlope = try required(record.longStrokeCPUMillisecondsPerFrameSlope, "longStrokeCPUMillisecondsPerFrameSlope", scene: scene)
    let storedGPUSlope = try required(record.longStrokeDabGPUMillisecondsPerFrameSlope, "longStrokeDabGPUMillisecondsPerFrameSlope", scene: scene)
    for (field, value) in [
        ("longStrokeEarlyCPUP95Milliseconds", storedEarlyCPU),
        ("longStrokeLateCPUP95Milliseconds", storedLateCPU),
        ("longStrokeEarlyDabGPUP95Milliseconds", storedEarlyGPU),
        ("longStrokeLateDabGPUP95Milliseconds", storedLateGPU),
    ] {
        guard value.isFinite, value > 0 else {
            throw failure("\(scene): \(field) is non-finite or non-positive")
        }
    }
    guard storedCPUSlope.isFinite, storedGPUSlope.isFinite else {
        throw failure("\(scene): a long-stroke slope is non-finite")
    }
    guard equalMeasurement(storedEarlyCPU, earlyCPU),
          equalMeasurement(storedLateCPU, lateCPU),
          equalMeasurement(storedEarlyGPU, earlyGPU),
          equalMeasurement(storedLateGPU, lateGPU),
          equalMeasurement(storedCPUSlope, cpuSlope),
          equalMeasurement(storedGPUSlope, gpuSlope) else {
        throw failure("\(scene): stored long-stroke summary does not match raw measurements")
    }
    let cpuLimit = max(earlyCPU * 1.15, earlyCPU + 0.10)
    let gpuLimit = max(earlyGPU * 1.15, earlyGPU + 0.10)
    guard lateCPU <= cpuLimit else {
        throw failure("\(scene): late CPU p95 \(lateCPU) exceeds \(cpuLimit)")
    }
    guard lateGPU <= gpuLimit else {
        throw failure("\(scene): late dab-GPU p95 \(lateGPU) exceeds \(gpuLimit)")
    }
    guard cpuSlope <= 0.001 else {
        throw failure("\(scene): CPU slope \(cpuSlope) exceeds 0.001 ms/frame")
    }
    guard gpuSlope <= 0.001 else {
        throw failure("\(scene): dab-GPU slope \(gpuSlope) exceeds 0.001 ms/frame")
    }
}

func slice1Record(root: URL, name: String) throws -> Record {
    try load(root.appendingPathComponent(name).appendingPathComponent("\(name).benchmark.json"))
}

func compareBaseline(currentRoot: URL, baselineRoot: URL, identity: Record) throws {
    let names = ["grid-interior", "grid-boundary", "preview-commit", "cancel-preserves-canonical", "five-hundred-dabs", "long-stroke"]
    let metrics: [(String, (Record) -> [Double]?)] = [
        ("cpuEncodeMilliseconds", { $0.cpuEncodeMilliseconds }),
        ("gpuMilliseconds", { $0.gpuMilliseconds }),
        ("brushProcessingMilliseconds", { $0.brushProcessingMilliseconds }),
        ("eventToSubmitMilliseconds", { $0.eventToSubmitMilliseconds }),
        ("dabGPUMilliseconds", { $0.dabGPUMilliseconds }),
        ("gridGPUMilliseconds", { $0.gridGPUMilliseconds }),
        ("commitGPUMilliseconds", { $0.commitGPUMilliseconds }),
        ("commitPendingMilliseconds", { $0.commitPendingMilliseconds }),
    ]
    var baselineIdentity: Record?
    for name in names {
        let current = try slice1Record(root: currentRoot, name: name)
        let baseline = try slice1Record(root: baselineRoot, name: name)
        try validateMeasurementFields(current)
        try validateMeasurementFields(baseline)
        if current.hardware != baseline.hardware {
            throw failure("baseline mismatch for \(name): hardware differs")
        }
        if current.operatingSystem != baseline.operatingSystem {
            throw failure("baseline mismatch for \(name): operating system differs")
        }
        if current.build.configuration != baseline.build.configuration {
            throw failure("baseline mismatch for \(name): configuration differs")
        }
        if current.hardware != identity.hardware || current.operatingSystem != identity.operatingSystem || current.build.configuration != "Debug" {
            throw failure("current Slice 1 and Slice 2 benchmark identities differ")
        }
        if let prior = baselineIdentity,
           prior.hardware != baseline.hardware || prior.operatingSystem != baseline.operatingSystem || prior.build.configuration != baseline.build.configuration {
            throw failure("accepted Slice 1 baseline contains mixed identities")
        }
        baselineIdentity = baseline
        for (metric, getter) in metrics {
            let currentValues = getter(current) ?? []
            let baselineValues = getter(baseline) ?? []
            if currentValues.isEmpty && baselineValues.isEmpty { continue }
            guard !currentValues.isEmpty, !baselineValues.isEmpty else {
                throw failure("baseline mismatch for \(name).\(metric): one series is empty")
            }
            try validatePositive(currentValues, field: metric, scene: name, allowEmpty: false)
            try validatePositive(baselineValues, field: metric, scene: "baseline \(name)", allowEmpty: false)
            let currentP95 = try percentile95(currentValues)
            let baselineP95 = try percentile95(baselineValues)
            guard currentP95 <= baselineP95 * 1.15 else {
                throw failure("Slice 1 comparison failed for \(name).\(metric): current p95 \(currentP95) exceeds baseline p95 \(baselineP95) by more than 15%")
            }
        }
    }
}

func run() throws {
    let slice2Root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let slice1Root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let expectedCommit = CommandLine.arguments[3]
    let baselineArgument = CommandLine.arguments[4]
    let requirements = try readRequirements(URL(fileURLWithPath: CommandLine.arguments[5]))
    var identity: Record?
    var records: [String: Record] = [:]
    var allBrush: [Double] = []
    var allTilingGPU: [Double] = []

    for requirement in requirements {
        let url = slice2Root.appendingPathComponent(requirement.name).appendingPathComponent("\(requirement.name).benchmark.json")
        let record = try load(url)
        guard record.schemaVersion == 3, record.sceneName == requirement.name else {
            throw failure("\(requirement.name): schemaVersion or sceneName mismatch")
        }
        try validateIdentity(record, commit: expectedCommit, scene: requirement.name)
        try validateMeasurementFields(record)
        try validateCounters(record)
        guard record.peakResidentBytes > 0 else { throw failure("\(requirement.name): peakResidentBytes is non-positive") }
        guard try required(record.tilingRawValue, "tilingRawValue", scene: requirement.name) == requirement.tilingRawValue,
              try required(record.tileWidth, "tileWidth", scene: requirement.name) == requirement.tileWidth,
              try required(record.tileHeight, "tileHeight", scene: requirement.name) == requirement.tileHeight,
              try required(record.diagnosticMode, "diagnosticMode", scene: requirement.name) == requirement.diagnosticMode else {
            throw failure("\(requirement.name): tiling, tile size, or diagnostic mode mismatch")
        }
        let fragments = try required(record.totalProjectedFragmentCount, "totalProjectedFragmentCount", scene: requirement.name)
        let maximum = try required(record.maximumFragmentsPerFootprint, "maximumFragmentsPerFootprint", scene: requirement.name)
        let bytes = try required(record.totalInstanceBytes, "totalInstanceBytes", scene: requirement.name)
        guard fragments > 0, maximum > 0, maximum <= fragments, bytes == fragments * 128 else {
            throw failure("\(requirement.name): projected fragment or 128-byte instance accounting is invalid")
        }
        if requirement.requiresOracle {
            let holes = try required(record.oracleHoleCount, "oracleHoleCount", scene: requirement.name)
            let phantoms = try required(record.oraclePhantomCount, "oraclePhantomCount", scene: requirement.name)
            let delta = try required(record.oracleMaximumDelta, "oracleMaximumDelta", scene: requirement.name)
            guard holes == 0, phantoms == 0, delta >= 0, delta <= 1 else {
                throw failure("\(requirement.name): oracle correctness fields are outside zero-hole/zero-phantom/delta<=1")
            }
        }
        if let prior = identity,
           prior.hardware != record.hardware || prior.operatingSystem != record.operatingSystem || prior.build.configuration != record.build.configuration {
            throw failure("Slice 2 benchmark records contain mixed hardware, OS, or configuration")
        }
        identity = identity ?? record
        records[record.sceneName] = record
        allBrush.append(contentsOf: record.brushProcessingMilliseconds ?? [])
        allTilingGPU.append(contentsOf: record.gridGPUMilliseconds ?? [])
    }

    guard records.count == 26 else { throw failure("Slice 2 benchmark set does not contain 26 unique scenes") }
    try validatePositive(allBrush, field: "Slice 2 brushProcessingMilliseconds", scene: "aggregate", allowEmpty: false)
    try validatePositive(allTilingGPU, field: "Slice 2 gridGPUMilliseconds", scene: "aggregate", allowEmpty: false)
    let brushP95 = try percentile95(allBrush)
    let tilingP95 = try percentile95(allTilingGPU)
    guard brushP95 < 2 else { throw failure("brush processing p95 \(brushP95) ms is not below 2 ms") }
    guard tilingP95 < 2 else { throw failure("tiling display p95 \(tilingP95) ms is not below 2 ms") }

    let fiveHundred = try slice1Record(root: slice1Root, name: "five-hundred-dabs")
    try validateIdentity(fiveHundred, commit: expectedCommit, scene: "five-hundred-dabs")
    try validateMeasurementFields(fiveHundred)
    guard let currentIdentity = identity,
          fiveHundred.hardware == currentIdentity.hardware,
          fiveHundred.operatingSystem == currentIdentity.operatingSystem else {
        throw failure("current Slice 1 500-dab and Slice 2 benchmark identities differ")
    }
    let fiveHundredDab = try required(fiveHundred.dabGPUMilliseconds, "dabGPUMilliseconds", scene: "five-hundred-dabs")
    try validatePositive(fiveHundredDab, field: "dabGPUMilliseconds", scene: "five-hundred-dabs", allowEmpty: false)
    guard let maximum500Dab = fiveHundredDab.max(), maximum500Dab < 3 else {
        throw failure("500-new-dab GPU maximum is not below 3 ms")
    }

    guard let long = records["projected-long-stroke"] else { throw failure("projected-long-stroke benchmark is missing") }
    try validateLongStroke(long)
    let missed = try required(long.missedFrameCount, "missedFrameCount", scene: long.sceneName)
    guard Double(missed) / Double(long.frameCount) < 0.01 else {
        throw failure("projected-long-stroke missed-frame fraction is not below 0.01")
    }

    if baselineArgument != "-" {
        try compareBaseline(
            currentRoot: slice1Root,
            baselineRoot: URL(fileURLWithPath: baselineArgument, isDirectory: true),
            identity: currentIdentity
        )
    }
}

do {
    try run()
} catch {
    fputs("SLICE2 BENCHMARK ERROR: \(error)\n", stderr)
    exit(1)
}
SWIFT
}

prove_generated_artifacts_ignored() {
  local tracked_project artifact_status

  if tracked_project="$(git ls-files --error-unmatch App/PatternSpike.xcodeproj 2>&1)"; then
    gate_error "generated Xcode project is tracked: $tracked_project"
    return 1
  else
    local status=$?
    if [[ "$status" -ne 1 ]]; then
      gate_error "unable to inspect generated-project tracking: $tracked_project"
      return 1
    fi
  fi
  git check-ignore -q .build/slice2-artifacts || {
    gate_error ".build/slice2-artifacts is not ignored"
    return 1
  }
  git check-ignore -q App/PatternSpike.xcodeproj/project.pbxproj || {
    gate_error "generated Xcode project content is not ignored"
    return 1
  }
  artifact_status="$(git status --short -- .build App/PatternSpike.xcodeproj)" || {
    gate_error "unable to inspect generated build artifacts"
    return 1
  }
  [[ -z "$artifact_status" ]] || {
    gate_error "generated build artifacts escaped ignore rules: $artifact_status"
    return 1
  }
}

run_gate() {
  local baseline_info baseline_root baseline_positive baseline_manifest_hash
  local baseline_snapshot_root matrix_file
  local slice1_log="$repo_root/.build/slice2-slice1-functional.log"
  local test_log="$repo_root/.build/slice2-swift-test.log"
  local xcodegen_log="$repo_root/.build/slice2-xcodegen.log"
  local mac_log="$repo_root/.build/slice2-macos-build.log"
  local pad_log="$repo_root/.build/slice2-ipados-build.log"
  local evaluator_log="$repo_root/.build/slice2-benchmark-evaluation.log"

  cd "$repo_root"
  mkdir -p "$repo_root/.build" "$mutable_slice1_artifacts"

  baseline_info="$(resolve_accepted_baseline)" || return 1
  baseline_root=""
  baseline_positive="-"
  baseline_manifest_hash=""
  baseline_snapshot_root="$repo_root/.build/slice2-baseline-snapshot"
  if [[ -n "$baseline_info" ]]; then
    baseline_root="${baseline_info%%|*}"
    baseline_positive="${baseline_info#*|}"
    verify_baseline_checksums "$baseline_root" || return 1
    baseline_manifest_hash="$(
      baseline_manifest_digest "$baseline_root"
    )" || return 1
    snapshot_baseline \
      "$baseline_root" \
      "$baseline_snapshot_root" \
      "$baseline_manifest_hash" || return 1
    baseline_positive="$baseline_snapshot_root/positive"
  fi

  if ! PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh >"$slice1_log" 2>&1; then
    cat "$slice1_log" >&2
    gate_error "Slice 1 functional regression failed"
    return 1
  fi

  if [[ -n "$baseline_root" ]]; then
    verify_pinned_baseline \
      "$baseline_root" "$baseline_manifest_hash" || return 1
    verify_pinned_baseline \
      "$baseline_snapshot_root" "$baseline_manifest_hash" || return 1
  fi

  if ! swift test >"$test_log" 2>&1; then
    cat "$test_log" >&2
    gate_error "Swift package tests failed"
    return 1
  fi
  if ! (cd App && xcodegen generate) >"$xcodegen_log" 2>&1; then
    cat "$xcodegen_log" >&2
    gate_error "Xcode project generation failed"
    return 1
  fi
  if ! xcodebuild \
    -project App/PatternSpike.xcodeproj \
    -scheme PatternSpikeMac \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    >"$mac_log" 2>&1
  then
    cat "$mac_log" >&2
    gate_error "macOS Debug build failed"
    return 1
  fi
  if ! xcodebuild \
    -project App/PatternSpike.xcodeproj \
    -scheme PatternSpikePad \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$pad_derived_data" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    >"$pad_log" 2>&1
  then
    cat "$pad_log" >&2
    gate_error "generic iPadOS Simulator Debug build failed"
    return 1
  fi

  rm -rf "$artifacts"
  mkdir -p "$artifacts/negative-control" "$artifacts/positive"
  git_commit="$(git rev-parse HEAD)"
  matrix_file="$repo_root/.build/slice2-scene-matrix.tsv"
  scene_matrix >"$matrix_file"
  while IFS='|' read -r name tiling raw width height diagnostic metric family oracle; do
    run_pair "$name" "$tiling" "$metric" "$family" || return 1
  done <"$matrix_file"

  if [[ -n "$baseline_root" ]]; then
    verify_pinned_baseline \
      "$baseline_root" "$baseline_manifest_hash" || return 1
    verify_pinned_baseline \
      "$baseline_snapshot_root" "$baseline_manifest_hash" || return 1
  fi
  if ! evaluate_benchmark_json \
    "$artifacts/positive" \
    "$mutable_slice1_artifacts/positive" \
    "$git_commit" \
    "$baseline_positive" \
    >"$evaluator_log" 2>&1
  then
    cat "$evaluator_log" >&2
    gate_error "Slice 2 benchmark evaluation failed"
    return 1
  fi
  if [[ -n "$baseline_root" ]]; then
    verify_pinned_baseline \
      "$baseline_root" "$baseline_manifest_hash" || return 1
    verify_pinned_baseline \
      "$baseline_snapshot_root" "$baseline_manifest_hash" || return 1
  fi

  prove_generated_artifacts_ignored || return 1
  if [[ -n "$baseline_root" ]]; then
    verify_pinned_baseline \
      "$baseline_root" "$baseline_manifest_hash" || return 1
    verify_pinned_baseline \
      "$baseline_snapshot_root" "$baseline_manifest_hash" || return 1
  fi

  printf '%s\n' 'slice0-regression=passed'
  printf '%s\n' 'slice1-regression=passed'
  printf '%s\n' 'slice2-negative-controls=passed'
  printf '%s\n' 'slice2-positive-scenes=passed'
  printf '%s\n' 'SLICE2 AUTOMATED GATE PASS'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_gate
fi
