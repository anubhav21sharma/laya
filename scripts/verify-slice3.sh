#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/slice3-artifacts"
scenes="$repo_root/App/PatternSpike/Harness/Scenes"
derived_data="$repo_root/.build/DerivedData"
pad_derived_data="$repo_root/.build/DerivedDataPad"
binary="$derived_data/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
git_commit=""
strict_evidence_log="$repo_root/.build/slice3-strict-evidence.log"

gate_error() {
  printf 'SLICE3 GATE ERROR: %s\n' "$*" >&2
  return 1
}

verify_tracked_source_state() {
  local line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path="${line:3}"
    case "$path" in
      scripts/verify-slice3.sh|docs/superpowers/milestones/03-transactions-region-undo-color-eraser.md)
        ;;
      *)
        gate_error "dirty tracked source is outside the permitted gate/milestone files: $path"
        return 1
        ;;
    esac
  done < <(git status --porcelain --untracked-files=no)
}

verify_untracked_build_inputs() {
  local path
  while IFS= read -r -d '' path; do
    gate_error "untracked build input is outside committed HEAD: $path"
    return 1
  done < <(git ls-files --others --exclude-standard -z -- \
    Sources \
    Tests \
    App/PatternSpike \
    Package.swift \
    Package.resolved \
    project.yml \
    App/project.yml \
    scripts \
    .swiftpm \
    .swift-version \
    .xcode-version \
    .swiftformat \
    .swift-format \
    .swiftlint.yml \
    .github/workflows \
    Config \
    Configuration)
}

verify_source_provenance() {
  verify_tracked_source_state || return 1
  verify_untracked_build_inputs
}

slice2_matrix() {
  cat <<'MATRIX'
generalized-grid|coverage-basic
halfdrop-interior|coverage-gridlines
halfdrop-edge|coverage-gridlines
halfdrop-corner|coverage-gridlines
brick-transpose|coverage-gridlines
mirror-x|diagnostic
mirror-y|diagnostic
mirror-xy|diagnostic
rotational-generator|diagnostic
rotational-fixed-point|coverage-basic
rotational-orientation|diagnostic
large-footprint|coverage-basic
asymmetric-footprint|diagnostic
canonical-coordinate-continuity|diagnostic
brush-local-coordinate-continuity|diagnostic
rectangular-tile|coverage-basic
noncentral-visible-cell-grid|noncentral
noncentral-visible-cell-halfdrop|noncentral
noncentral-visible-cell-brick|noncentral
noncentral-visible-cell-mirror-x|noncentral
noncentral-visible-cell-mirror-y|noncentral
noncentral-visible-cell-mirror-xy|noncentral
noncentral-visible-cell-rotational|noncentral
metadata-tiling-switch|metadata
projected-live-commit|projected
projected-long-stroke|projected
MATRIX
}

slice3_matrix() {
  cat <<'MATRIX'
colored-draw|coloredOutputMismatchCount|stroke
eraser-live-commit|previewCommitViolationCount|stroke
region-undo-seam|undoCanonicalByteDelta|stroke
clear-undo|redoCanonicalByteDelta|clear
tiling-undo|metadataCanonicalByteDelta|tiling
resize-crop-fill|redoCanonicalByteDelta|resize
MATRIX
}

require_artifact() {
  local path="$1"
  [[ -s "$path" ]] || {
    gate_error "required artifact is missing or empty: $path"
    return 1
  }
}

require_slice2_family() {
  local name="$1"
  local family="$2"
  local output="$artifacts/slice2/$name"
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
      for suffix in live.screen.png committed.screen.png canonical.png; do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    *)
      gate_error "unknown Slice 2 artifact family for $name: $family"
      return 1
      ;;
  esac
}

require_slice3_family() {
  local name="$1"
  local family="$2"
  local output="$artifacts/positive/$name"
  local suffix

  require_artifact "$output/$name.benchmark.json" || return 1
  require_artifact "$output/stdout.log" || return 1
  case "$family" in
    stroke)
      for suffix in \
        live.screen.png committed.screen.png undone.canonical.png \
        redone.canonical.png canonical.png
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    clear)
      for suffix in \
        committed.screen.png before-clear.canonical.png cleared.canonical.png \
        undone.canonical.png redone.canonical.png canonical.png
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    tiling)
      for suffix in \
        initial-tiling.screen.png alternate-tiling.screen.png \
        restored-tiling.screen.png redone-tiling.screen.png canonical.png
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    resize)
      for suffix in \
        committed.screen.png original.canonical.png shrunk.canonical.png \
        grown.canonical.png undone.canonical.png redone.canonical.png \
        canonical.png
      do
        require_artifact "$output/$name.$suffix" || return 1
      done
      ;;
    *)
      gate_error "unknown Slice 3 artifact family for $name: $family"
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

run_slice2_positive() {
  local name="$1"
  local family="$2"
  local output="$artifacts/slice2/$name"
  mkdir -p "$output"
  if ! "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$output/stdout.log" \
    2>"$output/stderr.log"
  then
    cat "$output/stderr.log" >&2
    gate_error "Slice 2 correctness scene failed: $name"
    return 1
  fi
  [[ ! -s "$output/stderr.log" ]] || {
    cat "$output/stderr.log" >&2
    gate_error "Slice 2 correctness scene wrote stderr: $name"
    return 1
  }
  grep -q "^HARNESS PASS scene=$name " "$output/stdout.log" || {
    gate_error "Slice 2 correctness scene did not print its pass record: $name"
    return 1
  }
  require_slice2_family "$name" "$family"
}

run_slice3_pair() {
  local name="$1"
  local metric="$2"
  local family="$3"
  local negative="$name-negative-control"
  local negative_output="$artifacts/negative-control/$negative"
  local positive_output="$artifacts/positive/$name"
  local expected status

  mkdir -p "$negative_output" "$positive_output"
  set +e
  "$binary" \
    --harness-scene "$scenes/$negative.json" \
    --output-directory "$negative_output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$negative_output/stdout.log" \
    2>"$negative_output/stderr.log"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || {
    gate_error "negative control exited $status instead of 1: $negative"
    return 1
  }
  [[ ! -s "$negative_output/stdout.log" ]] || {
    gate_error "negative control wrote stdout: $negative"
    return 1
  }
  expected="HARNESS FAIL Slice 3 scene '$negative' metric $metric: expected equal 1, actual 0."
  if ! stderr_matches_exact_line "$negative_output/stderr.log" "$expected"; then
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
    gate_error "positive Slice 3 scene failed: $name"
    return 1
  fi
  [[ ! -s "$positive_output/stderr.log" ]] || {
    cat "$positive_output/stderr.log" >&2
    gate_error "positive Slice 3 scene wrote stderr: $name"
    return 1
  }
  grep -q "^HARNESS PASS scene=$name " "$positive_output/stdout.log" || {
    gate_error "positive Slice 3 scene did not print its pass record: $name"
    return 1
  }
  require_slice3_family "$name" "$family"
}

validate_strict_evidence() {
  local build_log="$repo_root/.build/slice3-evidence-validator-build.log"
  local status validator

  if ! swift build --product SliceThreeEvidenceGate >"$build_log" 2>&1; then
    cat "$build_log" >&2
    gate_error "strict Slice 3 evidence validator failed to build"
    return 1
  fi
  validator="$repo_root/.build/debug/SliceThreeEvidenceGate"
  [[ -x "$validator" ]] || {
    gate_error "strict Slice 3 evidence validator executable is missing"
    return 1
  }

  set +e
  "$validator" \
    "$artifacts/slice2" \
    "$artifacts/positive" \
    "$repo_root/.build/slice1-artifacts/positive" \
    "$git_commit" \
    >"$strict_evidence_log" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    return 2
  fi
  if [[ "$status" -ne 0 ]]; then
    cat "$strict_evidence_log" >&2
    gate_error "strict Slice 3 evidence validation failed"
    return 1
  fi
}

evaluate_benchmarks() {
  local evaluator_log="$repo_root/.build/slice3-benchmark-evaluation.log"
  local status

  set +e
  swift - \
    "$artifacts/slice2" \
    "$artifacts/positive" \
    "$repo_root/.build/slice1-artifacts/positive" \
    "$git_commit" \
    >"$evaluator_log" 2>&1 <<'SWIFT'
import Darwin
import Foundation

struct Hardware: Codable, Equatable {
    let gpuName: String
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
}

struct Build: Codable {
    let configuration: String
    let gitCommit: String
}

struct Record: Codable {
    let schemaVersion: Int
    let sceneName: String
    let hardware: Hardware
    let operatingSystem: String
    let build: Build
    let frameCount: Int
    let cpuEncodeMilliseconds: [Double]
    let gpuMilliseconds: [Double]
    let peakResidentBytes: UInt64
    let brushProcessingMilliseconds: [Double]?
    let dabGPUMilliseconds: [Double]?
    let gridGPUMilliseconds: [Double]?
    let missedFrameCount: Int?
    let totalProjectedFragmentCount: Int?
    let totalInstanceBytes: Int?
    let revisionCaptureMilliseconds: [Double]?
    let revisionRestoreMilliseconds: [Double]?
    let historyResidentBytes: Int?
    let historyCommandCount: Int?
    let changedRegionCount: Int?
}

enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(value): value }
    }
}

func failure(_ message: String) -> ValidationFailure {
    .message(message)
}

func load(_ url: URL) throws -> Record {
    try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
}

func require<T>(_ value: T?, _ field: String, scene: String) throws -> T {
    guard let value else { throw failure("\(scene): missing \(field)") }
    return value
}

func validateNonnegative(
    _ values: [Double],
    field: String,
    scene: String
) throws {
    guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
        throw failure("\(scene): \(field) contains a nonfinite or negative value")
    }
}

func positiveP95(_ values: [Double], field: String, scene: String) throws -> Double {
    guard !values.isEmpty,
          values.allSatisfy({ $0.isFinite && $0 > 0 })
    else { throw failure("\(scene): \(field) lacks positive measured values") }
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

func recordURL(root: URL, name: String) -> URL {
    root.appendingPathComponent(name)
        .appendingPathComponent("\(name).benchmark.json")
}

func validateIdentity(_ record: Record, commit: String) throws {
    guard record.build.configuration == "Debug",
          record.build.gitCommit == commit,
          record.frameCount >= 0,
          record.peakResidentBytes > 0
    else { throw failure("\(record.sceneName): invalid build or core numeric identity") }
    try validateNonnegative(
        record.cpuEncodeMilliseconds,
        field: "cpuEncodeMilliseconds",
        scene: record.sceneName
    )
    try validateNonnegative(
        record.gpuMilliseconds,
        field: "gpuMilliseconds",
        scene: record.sceneName
    )
}

let slice2Names = [
    "generalized-grid", "halfdrop-interior", "halfdrop-edge",
    "halfdrop-corner", "brick-transpose", "mirror-x", "mirror-y",
    "mirror-xy", "rotational-generator", "rotational-fixed-point",
    "rotational-orientation", "large-footprint", "asymmetric-footprint",
    "canonical-coordinate-continuity", "brush-local-coordinate-continuity",
    "rectangular-tile", "noncentral-visible-cell-grid",
    "noncentral-visible-cell-halfdrop", "noncentral-visible-cell-brick",
    "noncentral-visible-cell-mirror-x", "noncentral-visible-cell-mirror-y",
    "noncentral-visible-cell-mirror-xy",
    "noncentral-visible-cell-rotational", "metadata-tiling-switch",
    "projected-live-commit", "projected-long-stroke",
]
let slice3Names = [
    "colored-draw", "eraser-live-commit", "region-undo-seam",
    "clear-undo", "tiling-undo", "resize-crop-fill",
]

do {
    let slice2Root = URL(fileURLWithPath: CommandLine.arguments[1])
    let slice3Root = URL(fileURLWithPath: CommandLine.arguments[2])
    let slice1Root = URL(fileURLWithPath: CommandLine.arguments[3])
    let expectedCommit = CommandLine.arguments[4]
    var identity: (Hardware, String)?
    var slice2Records: [String: Record] = [:]
    var slice3Records: [String: Record] = [:]

    for name in slice2Names {
        let record = try load(recordURL(root: slice2Root, name: name))
        guard record.schemaVersion == 3, record.sceneName == name else {
            throw failure("\(name): wrong Slice 2 schema or scene identity")
        }
        try validateIdentity(record, commit: expectedCommit)
        let fragments = try require(
            record.totalProjectedFragmentCount,
            "totalProjectedFragmentCount",
            scene: name
        )
        let bytes = try require(
            record.totalInstanceBytes,
            "totalInstanceBytes",
            scene: name
        )
        guard fragments > 0, bytes == fragments * 128 else {
            throw failure("\(name): projected fragment or 128-byte instance accounting is invalid")
        }
        if name == "generalized-grid" {
            guard fragments == 4, record.totalInstanceBytes == 512 else {
                throw failure("generalized-grid: four fragments must retain 512 instance bytes")
            }
        }
        if let prior = identity,
           prior.0 != record.hardware || prior.1 != record.operatingSystem {
            throw failure("Slice 2 benchmark records have mixed environments")
        }
        identity = identity ?? (record.hardware, record.operatingSystem)
        slice2Records[name] = record
    }

    for name in slice3Names {
        let record = try load(recordURL(root: slice3Root, name: name))
        guard record.schemaVersion == 4, record.sceneName == name else {
            throw failure("\(name): wrong Slice 3 schema or scene identity")
        }
        try validateIdentity(record, commit: expectedCommit)
        let capture = try require(
            record.revisionCaptureMilliseconds,
            "revisionCaptureMilliseconds",
            scene: name
        )
        let restore = try require(
            record.revisionRestoreMilliseconds,
            "revisionRestoreMilliseconds",
            scene: name
        )
        let resident = try require(
            record.historyResidentBytes,
            "historyResidentBytes",
            scene: name
        )
        let commands = try require(
            record.historyCommandCount,
            "historyCommandCount",
            scene: name
        )
        let regions = try require(
            record.changedRegionCount,
            "changedRegionCount",
            scene: name
        )
        try validateNonnegative(
            capture,
            field: "revisionCaptureMilliseconds",
            scene: name
        )
        try validateNonnegative(
            restore,
            field: "revisionRestoreMilliseconds",
            scene: name
        )
        guard resident >= 0, resident <= 200 * 1_024 * 1_024,
              commands >= 0, commands <= 100, regions >= 0
        else { throw failure("\(name): history or region metric is outside its absolute bound") }
        guard let currentIdentity = identity,
              currentIdentity.0 == record.hardware,
              currentIdentity.1 == record.operatingSystem
        else { throw failure("Slice 2 and Slice 3 benchmark environments differ") }
        slice3Records[name] = record
    }

    guard let currentIdentity = identity else {
        throw failure("benchmark identity is unavailable")
    }
    if currentIdentity.0.gpuName.lowercased().contains("paravirtual") {
        fputs(
            "SLICE3 PERFORMANCE PENDING: unstable real-Metal timing environment '\(currentIdentity.0.gpuName)'.\n",
            stderr
        )
        exit(2)
    }

    for record in Array(slice2Records.values) + Array(slice3Records.values) {
        if let brush = record.brushProcessingMilliseconds, !brush.isEmpty {
            let value = try positiveP95(
                brush,
                field: "brushProcessingMilliseconds",
                scene: record.sceneName
            )
            guard value < 2 else {
                throw failure("\(record.sceneName): brush p95 \(value) ms is not below 2 ms")
            }
        }
        if let tiling = record.gridGPUMilliseconds, !tiling.isEmpty {
            let value = try positiveP95(
                tiling,
                field: "gridGPUMilliseconds",
                scene: record.sceneName
            )
            guard value < 2 else {
                throw failure("\(record.sceneName): tiling p95 \(value) ms is not below 2 ms")
            }
        }
        if let missed = record.missedFrameCount, record.frameCount > 0 {
            guard Double(missed) / Double(record.frameCount) < 0.01 else {
                throw failure("\(record.sceneName): missed-frame fraction is not below 0.01")
            }
        }
    }

    let fiveHundred = try load(
        recordURL(root: slice1Root, name: "five-hundred-dabs")
    )
    try validateIdentity(fiveHundred, commit: expectedCommit)
    let dab = try require(
        fiveHundred.dabGPUMilliseconds,
        "dabGPUMilliseconds",
        scene: fiveHundred.sceneName
    )
    guard let maximumDab = dab.max(), maximumDab.isFinite,
          maximumDab > 0, maximumDab < 3
    else { throw failure("five-hundred-dabs: GPU maximum is not below 3 ms") }
} catch {
    fputs("SLICE3 BENCHMARK ERROR: \(error)\n", stderr)
    exit(1)
}
SWIFT
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    cat "$evaluator_log" >&2
    if [[ "$status" -eq 2 ]]; then
      gate_error "stable real-Metal performance acceptance remains pending"
    else
      gate_error "Slice 3 benchmark validation failed"
    fi
    return 1
  fi
}

prove_generated_artifacts_ignored() {
  git check-ignore -q .build/slice3-artifacts || {
    gate_error ".build/slice3-artifacts is not ignored"
    return 1
  }
  git check-ignore -q App/PatternSpike.xcodeproj/project.pbxproj || {
    gate_error "generated Xcode project content is not ignored"
    return 1
  }
  [[ -z "$(git status --short -- .build App/PatternSpike.xcodeproj)" ]] || {
    gate_error "generated artifacts escaped ignore rules"
    return 1
  }
}

complete_gate_after_harness() {
  local validation_status=0
  local ignore_status=0
  local provenance_status=0

  if validate_strict_evidence; then
    validation_status=0
  else
    validation_status=$?
  fi
  if [[ "$validation_status" -ne 0 && "$validation_status" -ne 2 ]]; then
    return 1
  fi

  if prove_generated_artifacts_ignored; then
    ignore_status=0
  else
    ignore_status=$?
  fi
  if verify_source_provenance; then
    provenance_status=0
  else
    provenance_status=$?
  fi
  if [[ "$ignore_status" -ne 0 || "$provenance_status" -ne 0 ]]; then
    return 1
  fi

  if [[ "$validation_status" -eq 2 ]]; then
    cat "$strict_evidence_log" >&2
    gate_error "stable real-Metal performance acceptance remains pending"
    return 1
  fi

  evaluate_benchmarks || return 1

  printf '%s\n' 'slice0-functional=passed'
  printf '%s\n' 'slice1-functional=passed'
  printf '%s\n' 'slice2-correctness=passed'
  printf '%s\n' 'slice3-negative-controls=passed'
  printf '%s\n' 'slice3-positive-scenes=passed'
  printf '%s\n' 'SLICE3 GATE PASS'
}

run_gate() {
  local name family metric host_arch
  local slice0_log="$repo_root/.build/slice3-slice0-functional.log"
  local slice1_log="$repo_root/.build/slice3-slice1-functional.log"
  local test_log="$repo_root/.build/slice3-swift-test.log"
  local xcodegen_log="$repo_root/.build/slice3-xcodegen.log"
  local mac_log="$repo_root/.build/slice3-macos-build.log"
  local pad_log="$repo_root/.build/slice3-ipados-build.log"

  cd "$repo_root"
  mkdir -p "$repo_root/.build"
  verify_source_provenance || return 1
  git_commit="$(git rev-parse HEAD)"
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64|x86_64)
      ;;
    *)
      gate_error "unsupported macOS host architecture: $host_arch"
      return 1
      ;;
  esac

  if ! ./scripts/verify-slice0.sh >"$slice0_log" 2>&1; then
    cat "$slice0_log" >&2
    gate_error "Slice 0 functional regression failed"
    return 1
  fi
  if ! PATTERN_SKIP_PERFORMANCE=1 ./scripts/verify-slice1.sh \
    >"$slice1_log" 2>&1
  then
    cat "$slice1_log" >&2
    gate_error "Slice 1 functional regression failed"
    return 1
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
    -destination "platform=macOS,arch=$host_arch" \
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
  mkdir -p \
    "$artifacts/slice2" \
    "$artifacts/negative-control" \
    "$artifacts/positive"
  while IFS='|' read -r name family; do
    run_slice2_positive "$name" "$family" || return 1
  done < <(slice2_matrix)
  while IFS='|' read -r name metric family; do
    run_slice3_pair "$name" "$metric" "$family" || return 1
  done < <(slice3_matrix)

  complete_gate_after_harness
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_gate
fi
