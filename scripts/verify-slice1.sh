#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/slice1-artifacts"
scenes="$repo_root/App/PatternSpike/Harness/Scenes"
binary="$repo_root/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"

cd "$repo_root"
rm -rf "$artifacts"
mkdir -p "$artifacts/negative-control" "$artifacts/positive"

./scripts/verify-slice0.sh

git_commit="$(git rev-parse HEAD)"

negative_scenes=(
  grid-interior-negative-control
  grid-boundary-negative-control
  preview-commit-negative-control
  cancel-preserves-canonical-negative-control
  five-hundred-dabs-negative-control
  long-stroke-negative-control
)

negative_failures=(
  "HARNESS FAIL Grid scene 'grid-interior-negative-control' channel liveScreen pixel mismatch at (200, 256): expected [241, 244, 242, 255], actual [0, 0, 0, 255], tolerance 1."
  "HARNESS FAIL Grid scene 'grid-boundary-negative-control' channel canonical pixel mismatch at (0, 0): expected [241, 244, 242, 255], actual [0, 0, 0, 255], tolerance 1."
  "HARNESS FAIL Grid scene 'preview-commit-negative-control' channel liveScreen pixel mismatch at (180, 220): expected [241, 244, 242, 255], actual [0, 0, 0, 255], tolerance 1."
  "HARNESS FAIL Grid scene 'cancel-preserves-canonical-negative-control' structural mismatch canonicalRevisionDelta: expected equal 1, actual 0."
  "HARNESS FAIL Grid scene 'five-hundred-dabs-negative-control' structural mismatch encodedInstanceCount: expected equal 499, actual 500."
  "HARNESS FAIL Grid scene 'long-stroke-negative-control' structural mismatch restampedInstanceCount: expected equal 1, actual 0."
)

for index in "${!negative_scenes[@]}"; do
  name="${negative_scenes[$index]}"
  output="$artifacts/negative-control/$name"
  mkdir -p "$output"
  if "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    >"$output/stdout.log" \
    2>"$output/stderr.log"
  then
    printf 'Negative control unexpectedly passed: %s\n' "$name"
    exit 1
  fi
  grep -Fqx "${negative_failures[$index]}" "$output/stderr.log"
  printf 'negative-control=%s failed-as-expected\n' "$name"
done

positive_scenes=(
  grid-interior
  grid-boundary
  preview-commit
  cancel-preserves-canonical
  five-hundred-dabs
  long-stroke
)

for name in "${positive_scenes[@]}"; do
  output="$artifacts/positive/$name"
  mkdir -p "$output"
  "$binary" \
    --harness-scene "$scenes/$name.json" \
    --output-directory "$output" \
    --git-commit "$git_commit" \
    --configuration Debug \
    | tee "$output/stdout.log"
  grep -q "^HARNESS PASS scene=$name " "$output/stdout.log"
  test -s "$output/$name.benchmark.json"
done

three_image_scenes=(
  grid-interior
  grid-boundary
  preview-commit
  cancel-preserves-canonical
  long-stroke
)

for name in "${three_image_scenes[@]}"; do
  output="$artifacts/positive/$name"
  test -s "$output/$name.live.screen.png"
  test -s "$output/$name.committed.screen.png"
  test -s "$output/$name.canonical.png"
done

test -s "$artifacts/positive/five-hundred-dabs/five-hundred-dabs.live.screen.png"

swift - "$artifacts/positive" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let names = [
    "grid-interior",
    "grid-boundary",
    "preview-commit",
    "cancel-preserves-canonical",
    "five-hundred-dabs",
    "long-stroke",
]

func p95(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    return sorted[index]
}

var records: [[String: Any]] = []
for name in names {
    let url = root
        .appendingPathComponent(name)
        .appendingPathComponent("\(name).benchmark.json")
    let data = try Data(contentsOf: url)
    records.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
}

let allBrush = records.flatMap { $0["brushProcessingMilliseconds"] as! [Double] }
let allGrid = records.flatMap { $0["gridGPUMilliseconds"] as! [Double] }
let fiveHundred = records.first { $0["sceneName"] as? String == "five-hundred-dabs" }!
let dab = (fiveHundred["dabGPUMilliseconds"] as! [Double]).max() ?? 0
let long = records.first { $0["sceneName"] as? String == "long-stroke" }!
let frameCount = long["frameCount"] as! Int
let missed = long["missedFrameCount"] as! Int
let newCounts = long["newInstanceCounts"] as! [Int]
let totals = long["totalStrokeInstanceCounts"] as! [Int]
let commitPending = records.flatMap {
    $0["commitPendingMilliseconds"] as! [Double]
}
let frameBudget = records.compactMap {
    $0["displayFrameBudgetMilliseconds"] as? Double
}.min()!

guard p95(allBrush) < 2 else { fatalError("brush p95 budget failed") }
guard p95(allGrid) < 2 else { fatalError("grid p95 budget failed") }
guard dab < 3 else { fatalError("500-dab GPU budget failed") }
guard Double(missed) / Double(frameCount) < 0.01 else {
    fatalError("missed-frame budget failed")
}
guard zip(newCounts, totals).allSatisfy({ $0 <= $1 }) else {
    fatalError("instance counter ordering failed")
}
guard (commitPending.max() ?? 0) < frameBudget else {
    fatalError("commit-pending frame budget failed")
}
SWIFT

if tracked_project="$(
  git ls-files --error-unmatch App/PatternSpike.xcodeproj 2>&1
)"; then
  printf '%s\n' "Generated Xcode project is tracked."
  exit 1
else
  status=$?
  if [[ "$status" -ne 1 ]]; then
    printf 'Unable to inspect generated-project tracking: %s\n' \
      "$tracked_project"
    exit 1
  fi
fi

if ! artifact_status="$(
  git status --short -- .build App/PatternSpike.xcodeproj
)"; then
  printf '%s\n' "Unable to inspect generated build artifacts."
  exit 1
fi

if [[ -n "$artifact_status" ]]; then
  printf '%s\n' "Generated build artifacts escaped ignore rules."
  exit 1
fi

printf '%s\n' "slice0-regression=passed"
printf '%s\n' "swift-tests=passed"
printf '%s\n' "macos-build=passed"
printf '%s\n' "ipados-simulator-build=passed"
printf '%s\n' "grid-negative-controls=passed"
printf '%s\n' "grid-positive-scenes=passed"
printf '%s\n' "SLICE1 AUTOMATED GATE PASS"
