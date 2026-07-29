#!/usr/bin/env bash
set -eEuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/professional-brush-artifacts"
stage_four_artifacts="$repo_root/.build/brush-deposition-artifacts"
scratch="$repo_root/.build/professional-brush-swiftpm"
work="$repo_root/.build/professional-brush-work"
logs="$repo_root/.build/professional-brush-logs"
card_package="$repo_root/.build/professional-brush-card-exporter"
derived_mac="$repo_root/.build/ProfessionalBrushDerivedDataMac"
derived_pad="$repo_root/.build/ProfessionalBrushDerivedDataPad"
scene_source="$repo_root/App/PatternSpike/Harness/Scenes"
result_emitted=0

unexpected_error() {
  local code=$?
  if [[ "$result_emitted" -eq 0 ]]; then
    result_emitted=1
    printf 'BRUSH STAGE 5 FAIL: unexpected command exit %s\n' "$code" >&2
  fi
  exit 1
}
trap unexpected_error ERR

fail() {
  result_emitted=1
  trap - ERR
  printf 'BRUSH STAGE 5 FAIL: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required tool is unavailable: $1"
}

verify_clean_source() {
  git diff --quiet \
    || fail "tracked working tree differs from committed HEAD"
  git diff --cached --quiet \
    || fail "index differs from committed HEAD"
  local path
  while IFS= read -r -d '' path; do
    case "$path" in
      .vscode|.vscode/*) ;;
      *) fail "untracked source is not the allowed .vscode directory: $path" ;;
    esac
  done < <(git ls-files --others --exclude-standard -z)
}

run_logged() {
  local name="$1"
  local code
  shift
  if "$@" >"$logs/$name.stdout.log" 2>"$logs/$name.stderr.log"; then
    return
  else
    code=$?
  fi
  fail "$name failed with exit $code"
}

run_stage_four_prerequisite() {
  local code
  if ./scripts/verify-brush-stage4.sh \
      >"$logs/stage-four.stdout.log" \
      2>"$logs/stage-four.stderr.log"; then
    code=0
  else
    code=$?
  fi
  [[ "$code" -eq 0 || "$code" -eq 2 ]] \
    || fail "Stage 4 prerequisite failed with exit $code"
  [[ -d "$stage_four_artifacts" ]] \
    || fail "Stage 4 prerequisite artifact root is missing"
  stage_four_exit="$code"
  stage_four_terminal="$(
    tail -n 1 "$logs/stage-four.stdout.log"
  )"
  case "$code" in
    0)
      [[ "$stage_four_terminal" == \
        "BRUSH STAGE 4 PASS artifacts=$stage_four_artifacts commit=$commit" ]] \
        || fail "Stage 4 pass terminal line is not exact"
      ;;
    2)
      [[ "$stage_four_terminal" == \
        "BRUSH STAGE 4 PERFORMANCE PENDING artifacts=$stage_four_artifacts commit=$commit gpu="* ]] \
        || fail "Stage 4 pending terminal line is not exact"
      ;;
  esac
  stage_four_manifest_hash="$(
    shasum -a 256 "$stage_four_artifacts/artifact-sha256.txt" \
      | awk '{print $1}'
  )"
  [[ "$stage_four_manifest_hash" =~ ^[0-9a-f]{64}$ ]] \
    || fail "Stage 4 artifact manifest hash is invalid"
}

run_positive_scene() {
  local name="$1"
  local output="$work/positive/$name"
  local destination="$artifacts/positive/$name"
  mkdir -p "$output" "$destination"
  if ! "$app_binary" \
    --harness-scene "$scene_source/$name.json" \
    --output-directory "$output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$logs/$name-positive.stdout.log" \
    2>"$logs/$name-positive.stderr.log"; then
    fail "positive professional scene failed: $name"
  fi
  [[ ! -s "$logs/$name-positive.stderr.log" ]] \
    || fail "positive professional scene wrote stderr: $name"
  grep -q "^HARNESS PASS scene=$name " \
    "$logs/$name-positive.stdout.log" \
    || fail "positive professional scene lacks its pass marker: $name"

  cp "$output/$name.live.png" "$destination/live.png"
  cp "$output/$name.committed.png" "$destination/committed.png"
  cp "$output/$name.canonical.png" "$destination/canonical.png"
  cp "$output/$name.characterization.json" \
    "$destination/characterization.json"
  cp "$output/$name.professional-evidence.json" \
    "$destination/evidence.json"
  cp "$output/$name.benchmark.json" "$destination/benchmark.json"
  [[ "$(find "$output" -type f | wc -l | tr -d ' ')" -eq 6 ]] \
    || fail "positive professional scene emitted an unexpected file: $name"
}

run_negative_scene() {
  local name="$1"
  local negative="$name-negative-control"
  local output="$work/negative/$name"
  local destination="$artifacts/negative-control/$name"
  local code
  mkdir -p "$output" "$destination"
  if "$app_binary" \
    --harness-scene "$scene_source/$negative.json" \
    --output-directory "$output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$destination/stdout.log" \
    2>"$destination/stderr.log"; then
    code=0
  else
    code=$?
  fi
  printf '%s\n' "$code" >"$destination/exit-status.txt"
  [[ "$code" -eq 1 ]] \
    || fail "negative professional scene exit was not exactly 1: $name"
  [[ ! -s "$destination/stdout.log" ]] \
    || fail "negative professional scene wrote stdout: $name"
  expected="HARNESS FAIL $negative expectation 'professionalDefinitionIdentityExact' did not match"
  [[ "$(cat "$destination/stderr.log")" == "$expected" ]] \
    || fail "negative professional scene stderr is not exact: $name"
}

write_scene_matrix() {
  local index
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "positive": [\n'
    for index in "${!scene_names[@]}"; do
      printf '    "%s"' "${scene_names[$index]}"
      if [[ "$index" -lt $((${#scene_names[@]} - 1)) ]]; then
        printf ','
      fi
      printf '\n'
    done
    printf '  ],\n'
    printf '  "negativeControls": [\n'
    for index in "${!scene_names[@]}"; do
      printf '    "%s-negative-control"' "${scene_names[$index]}"
      if [[ "$index" -lt $((${#scene_names[@]} - 1)) ]]; then
        printf ','
      fi
      printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } >"$artifacts/scene-matrix.json"
}

write_card_exporter_package() {
  mkdir -p "$card_package/Sources/CardExporter"
  cp "$repo_root/App/PatternSpike/BrushLab/BrushLabManualCard.swift" \
    "$card_package/Sources/CardExporter/BrushLabManualCard.swift"
  cat >"$card_package/Package.swift" <<PACKAGE
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProfessionalBrushCardExporter",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "PatternModules", path: "$repo_root"),
    ],
    targets: [
        .executableTarget(
            name: "CardExporter",
            dependencies: [
                .product(name: "PatternEngine", package: "PatternModules"),
                .product(name: "EditorCore", package: "PatternModules"),
            ]
        ),
    ]
)
PACKAGE
  cat >"$card_package/Sources/CardExporter/main.swift" <<'SWIFT'
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: CardExporter OUTPUT")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try BrushLabProfessionalManualCatalog.pending().encoded().write(
    to: output,
    options: .atomic
)
SWIFT
}

copy_physical_profiles() {
  local input="${PROFESSIONAL_BRUSH_PHYSICAL_EVIDENCE_DIR:-}"
  [[ -n "$input" ]] || return 0
  [[ -d "$input" && ! -L "$input" ]] \
    || fail "physical evidence input must be a regular directory"
  local profile
  for profile in \
    a14Floor60Hz inputToPhoton memoryWarning pencil \
    referenceMSeriesProMotion120Hz suspendResume sustainedThermal wacom
  do
    if [[ -e "$input/$profile" ]]; then
      [[ -d "$input/$profile" && ! -L "$input/$profile" ]] \
        || fail "physical evidence profile is not a regular directory: $profile"
      cp -R "$input/$profile" "$artifacts/physical-profiles/$profile"
    fi
  done
}

write_json_status_and_provenance() {
  local performance="$artifacts/performance-status.json"
  plutil -create xml1 "$performance"
  plutil -insert schemaVersion -integer 1 "$performance"
  plutil -insert correctnessPassed -bool true "$performance"
  plutil -insert gpuName -string "$gpu_name" "$performance"
  plutil -insert gpuClassification -string "$gpu_classification" \
    "$performance"
  plutil -insert cpuPreparationP95Milliseconds -float "$cpu_p95" \
    "$performance"
  plutil -insert cpuPreparationBudgetMilliseconds -float 2 "$performance"
  plutil -insert gpu500DabMilliseconds -float "$gpu_500" "$performance"
  plutil -insert gpu500DabBudgetMilliseconds -float 3 "$performance"
  plutil -insert completedStrokeLengthIndependent -bool true "$performance"
  plutil -insert hotPathCompilerResourceCountersZero -bool true "$performance"
  plutil -convert json "$performance"

  local provenance="$artifacts/provenance.json"
  plutil -create xml1 "$provenance"
  plutil -insert schemaVersion -integer 1 "$provenance"
  plutil -insert commit -string "$commit" "$provenance"
  plutil -insert sourceTreeSHA256 -string "$source_tree_hash" "$provenance"
  plutil -insert configuration -string Debug "$provenance"
  plutil -insert swiftVersion -string "$swift_version" "$provenance"
  plutil -insert xcodeVersion -string "$xcode_version" "$provenance"
  plutil -insert xcodegenVersion -string "$xcodegen_version" "$provenance"
  plutil -insert operatingSystem -string "$operating_system" "$provenance"
  plutil -insert kernel -string "$kernel" "$provenance"
  plutil -insert hardwareMachine -string "$hardware_machine" "$provenance"
  plutil -insert hardwareModel -string "$hardware_model" "$provenance"
  plutil -insert gpuName -string "$gpu_name" "$provenance"
  plutil -insert gpuClassification -string "$gpu_classification" \
    "$provenance"
  plutil -insert artifactRoot -string "$artifacts" "$provenance"
  plutil -insert stageFourExitStatus -integer "$stage_four_exit" "$provenance"
  plutil -insert stageFourArtifactManifestSHA256 \
    -string "$stage_four_manifest_hash" "$provenance"
  plutil -convert json "$provenance"

  local regression="$artifacts/stage-four-regression.json"
  plutil -create xml1 "$regression"
  plutil -insert schemaVersion -integer 1 "$regression"
  plutil -insert exitStatus -integer "$stage_four_exit" "$regression"
  plutil -insert artifactRoot -string "$stage_four_artifacts" "$regression"
  plutil -insert commit -string "$commit" "$regression"
  plutil -insert sourceTreeSHA256 -string "$source_tree_hash" "$regression"
  plutil -insert artifactManifestSHA256 \
    -string "$stage_four_manifest_hash" "$regression"
  plutil -insert terminalLine -string "$stage_four_terminal" "$regression"
  plutil -convert json "$regression"
}

cd "$repo_root"
for tool in \
  awk bash cat cp find git grep nm otool plutil rg sed shasum sort \
  swift sw_vers sysctl system_profiler tail tr wc xargs xcodebuild \
  xcodegen xcrun
do
  require_tool "$tool"
done
verify_clean_source

commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || fail "HEAD is not a full commit identity"

rm -rf \
  "$artifacts" "$scratch" "$work" "$logs" "$card_package" \
  "$derived_mac" "$derived_pad"
mkdir -p \
  "$artifacts/positive" \
  "$artifacts/negative-control" \
  "$artifacts/manual-cards" \
  "$artifacts/physical-profiles" \
  "$artifacts/scene-inputs" \
  "$work" "$logs"

git ls-tree -r --full-tree "$commit" >"$artifacts/source-tree.txt"
source_tree_hash="$(
  shasum -a 256 "$artifacts/source-tree.txt" | awk '{print $1}'
)"
[[ "$source_tree_hash" =~ ^[0-9a-f]{64}$ ]] \
  || fail "source-tree SHA-256 is invalid"

run_stage_four_prerequisite

swift --version >"$logs/swift-toolchain.txt" 2>&1
xcodebuild -version >"$logs/xcode-toolchain.txt"
xcodegen version >"$logs/xcodegen-toolchain.txt"
sw_vers >"$logs/operating-system.txt"
uname -a >"$logs/kernel.txt"
sysctl -n hw.model >"$logs/hardware-model.txt"
system_profiler SPDisplaysDataType >"$logs/hardware.txt"
swift_version="$(
  tr '\n' ' ' <"$logs/swift-toolchain.txt" \
    | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
)"
xcode_version="$(
  tr '\n' ' ' <"$logs/xcode-toolchain.txt" \
    | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
)"
xcodegen_version="$(
  tr '\n' ' ' <"$logs/xcodegen-toolchain.txt" \
    | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
)"
kernel="$(tr '\n' ' ' <"$logs/kernel.txt" | sed -E 's/[[:space:]]+$//')"
hardware_machine="$(uname -m)"
hardware_model="$(tr -d '\n' <"$logs/hardware-model.txt")"

run_logged gate-build \
  swift build --scratch-path "$scratch" \
    --product ProfessionalBrushEvidenceGate
validator="$scratch/debug/ProfessionalBrushEvidenceGate"
[[ -x "$validator" ]] \
  || fail "ProfessionalBrushEvidenceGate executable is unavailable"

run_logged full-tests \
  swift test --scratch-path "$scratch" --disable-sandbox --no-parallel
run_logged focused-professional-tests \
  swift test --scratch-path "$scratch" --disable-sandbox --no-parallel \
    --filter \
    'ProfessionalBrushCatalogTests|ProfessionalBrushCharacterizationTests|ProfessionalBrushDynamicsTests|ProfessionalBrushHarnessRunnerTests|ProfessionalBrushEvidenceValidatorTests|EditorBrushCatalogTests|BrushLabSessionTests'
run_logged bootstrap ./scripts/bootstrap.sh

run_logged mac-build xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath "$derived_mac" \
  build CODE_SIGNING_ALLOWED=NO
run_logged mac-analyze xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath "$derived_mac" \
  analyze CODE_SIGNING_ALLOWED=NO
run_logged ipad-build xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_pad" \
  build CODE_SIGNING_ALLOWED=NO
run_logged ipad-analyze xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_pad" \
  analyze CODE_SIGNING_ALLOWED=NO

app_binary="$derived_mac/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
[[ -x "$app_binary" ]] \
  || fail "Mac professional harness binary is unavailable"

scene_names=(
  professional-chisel-marker
  professional-graphite-pencil
  professional-natural-charcoal
  professional-technical-ink
)
for name in "${scene_names[@]}"; do
  cp "$scene_source/$name.json" "$artifacts/scene-inputs/$name.json"
  cp "$scene_source/$name-negative-control.json" \
    "$artifacts/scene-inputs/$name-negative-control.json"
  run_negative_scene "$name"
  run_positive_scene "$name"
done
write_scene_matrix

run_logged characterization-export \
  swift run --scratch-path "$scratch" --disable-sandbox \
    BrushCharacterizationTool professional
cp "$logs/characterization-export.stdout.log" \
  "$artifacts/characterization-baseline.json"

write_card_exporter_package
run_logged manual-card-export \
  swift run --package-path "$card_package" \
    --configuration debug CardExporter \
    "$artifacts/manual-cards/catalog.json"
copy_physical_profiles

gpu_name="$(
  plutil -extract hardware.gpuName raw -o - \
    "$artifacts/positive/${scene_names[0]}/benchmark.json"
)"
operating_system="$(
  plutil -extract operatingSystem raw -o - \
    "$artifacts/positive/${scene_names[0]}/benchmark.json"
)"
lower_gpu="$(printf '%s' "$gpu_name" | tr '[:upper:]' '[:lower:]')"
case "$lower_gpu" in
  *paravirtual*) gpu_classification="paravirtual" ;;
  *virtual*|*simulator*) gpu_classification="virtual" ;;
  *) gpu_classification="physical" ;;
esac

metrics="$(
  xcrun swift - "$artifacts" "$stage_four_artifacts" <<'SWIFT'
import Foundation

func object(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        as! [String: Any]
}
func p95(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let stageFour = URL(fileURLWithPath: CommandLine.arguments[2])
let names = [
    "professional-chisel-marker",
    "professional-graphite-pencil",
    "professional-natural-charcoal",
    "professional-technical-ink",
]
let cpu = try names.map {
    let benchmark = try object(
        root.appendingPathComponent("positive/\($0)/benchmark.json")
    )
    return p95(benchmark["cpuEncodeMilliseconds"] as! [Double])
}.max()!
let five = try object(
    stageFour.appendingPathComponent(
        "logs/five-hundred-dabs.benchmark.json"
    )
)
let gpu = (five["dabGPUMilliseconds"] as! [Double]).max()!
print(String(format: "%.17g %.17g", cpu, gpu))
SWIFT
)"
read -r cpu_p95 gpu_500 <<<"$metrics"
[[ -n "$cpu_p95" && -n "$gpu_500" ]] \
  || fail "professional performance metrics are unavailable"
write_json_status_and_provenance

run_logged git-diff-check git diff --check
[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while Stage 5 evidence was running"
verify_clean_source
git ls-tree -r --full-tree "$commit" \
  >"$artifacts/source-tree-terminal.txt"
cmp -s "$artifacts/source-tree.txt" \
  "$artifacts/source-tree-terminal.txt" \
  || fail "committed source tree changed while Stage 5 evidence was running"

rm -rf "$work"
(
  cd "$artifacts"
  find . -type f \
    ! -name artifact-sha256.txt \
    -print0 \
    | sort -z \
    | xargs -0 shasum -a 256
) >"$artifacts/artifact-sha256.txt"

if "$validator" \
  --artifacts "$artifacts" \
  --commit "$commit" \
  --source-tree-sha256 "$source_tree_hash" \
  --stage-four-artifacts "$stage_four_artifacts" \
  >"$logs/validator.stdout.log" \
  2>"$logs/validator.stderr.log"; then
  validator_status=0
else
  validator_status=$?
fi
case "$validator_status" in
  0)
    result_emitted=1
    trap - ERR
    printf 'BRUSH STAGE 5 PASS artifacts=%s commit=%s\n' \
      "$artifacts" "$commit"
    exit 0
    ;;
  2)
    result_emitted=1
    trap - ERR
    printf 'BRUSH STAGE 5 MANUAL/PHYSICAL PENDING artifacts=%s commit=%s gpu=%s\n' \
      "$artifacts" "$commit" "$gpu_name"
    exit 2
    ;;
  *)
    message="$(
      tr '\n' ' ' <"$logs/validator.stderr.log" \
        | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
    )"
    fail "artifact validator exit $validator_status: $message"
    ;;
esac
