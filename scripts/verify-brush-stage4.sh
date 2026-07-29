#!/usr/bin/env bash
set -eEuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/brush-deposition-artifacts"
scratch="$repo_root/.build/brush-deposition-swiftpm"
card_package="$repo_root/.build/brush-deposition-card-exporter"
work="$repo_root/.build/brush-deposition-work"
derived_mac="$repo_root/.build/BrushDepositionDerivedDataMac"
derived_pad="$repo_root/.build/BrushDepositionDerivedDataPad"
scene_source="$repo_root/App/PatternSpike/Harness/Scenes"
logs="$artifacts/logs"
validator_result="$repo_root/.build/brush-deposition-validator-result.txt"
result_emitted=0

unexpected_error() {
  local code=$?
  if [[ "$result_emitted" -eq 0 ]]; then
    result_emitted=1
    printf 'BRUSH STAGE 4 FAIL: unexpected command exit %s\n' "$code" >&2
  fi
  exit 1
}
trap unexpected_error ERR

fail() {
  result_emitted=1
  trap - ERR
  printf 'BRUSH STAGE 4 FAIL: %s\n' "$*" >&2
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
    fail "positive scene failed: $name"
  fi
  [[ ! -s "$logs/$name-positive.stderr.log" ]] \
    || fail "positive scene wrote stderr: $name"
  grep -q "^HARNESS PASS scene=$name " \
    "$logs/$name-positive.stdout.log" \
    || fail "positive scene lacks its exact pass marker: $name"

  cp "$output/$name.live.png" "$destination/live.png"
  cp "$output/$name.committed.png" "$destination/committed.png"
  cp "$output/$name.canonical.png" "$destination/canonical.png"
  cp "$output/$name.deposition-evidence.json" \
    "$destination/deposition-evidence.json"
  cp "$output/$name.benchmark.json" "$destination/benchmark.json"
  if [[ "$name" == "deposition-ink" ]]; then
    cp "$output/$name.cpu-reference.png" \
      "$destination/cpu-reference.png"
  elif [[ -e "$output/$name.cpu-reference.png" ]]; then
    fail "unexpected CPU reference artifact: $name"
  fi
}

run_negative_scene() {
  local name="$1"
  local scene="$name-negative-control"
  local output="$work/negative/$name"
  local destination="$artifacts/negative-control/$name"
  local code
  mkdir -p "$output" "$destination"

  if "$app_binary" \
    --harness-scene "$scene_source/$scene.json" \
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
    || fail "negative control exit was not exactly 1: $name"
  [[ ! -s "$destination/stdout.log" ]] \
    || fail "negative control wrote stdout: $name"
  [[ "$(wc -l <"$destination/stderr.log" | tr -d ' ')" -eq 1 ]] \
    || fail "negative control did not write exactly one stderr line: $name"
  grep -q '^HARNESS FAIL .\+$' "$destination/stderr.log" \
    || fail "negative control lacks its fail-closed marker: $name"
}

run_performance_scene() {
  local name="$1"
  local output="$work/performance/$name"
  mkdir -p "$output"
  if ! "$app_binary" \
    --harness-scene "$scene_source/$name.json" \
    --output-directory "$output" \
    --git-commit "$commit" \
    --configuration Debug \
    >"$logs/$name.stdout.log" \
    2>"$logs/$name.stderr.log"; then
    fail "performance evidence scene failed: $name"
  fi
  [[ ! -s "$logs/$name.stderr.log" ]] \
    || fail "performance evidence scene wrote stderr: $name"
  cp "$output/$name.benchmark.json" \
    "$logs/$name.benchmark.json"
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
    name: "BrushDepositionCardExporter",
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
try BrushLabManualCatalog.pending().encoded().write(
    to: output,
    options: .atomic
)
SWIFT
}

write_performance_status() {
  local output="$artifacts/performance-status.txt"

  plutil -create xml1 "$output"
  plutil -insert schemaVersion -integer 2 "$output"
  plutil -insert correctnessPassed -bool true "$output"
  plutil -insert gpuName -string "$gpu_name" "$output"
  plutil -insert gpuClassification -string "$gpu_classification" "$output"
  plutil -insert cpuPreparationP95Milliseconds \
    -float "$cpu_p95" "$output"
  plutil -insert cpuPreparationBudgetMilliseconds -float 2 "$output"
  plutil -insert gpu500DabMilliseconds -float "$gpu_500" "$output"
  plutil -insert gpu500DabBudgetMilliseconds -float 3 "$output"
  plutil -insert completedStrokeLengthIndependent -bool true "$output"
  plutil -insert hotPathCompilerResourceCountersZero -bool true "$output"
  plutil -convert json "$output"
}

copy_physical_profile_evidence() {
  local input="${BRUSH_STAGE4_PHYSICAL_EVIDENCE:-}"
  local profile

  [[ -z "${BRUSH_STAGE4_PHYSICAL_PROFILES:-}" ]] \
    || fail "raw BRUSH_STAGE4_PHYSICAL_PROFILES status strings are unsupported"
  [[ -n "$input" ]] || return 0
  [[ "$input" = /* && -d "$input" && ! -L "$input" ]] \
    || fail "BRUSH_STAGE4_PHYSICAL_EVIDENCE must name an absolute regular directory"

  local candidate candidate_name known
  for candidate in "$input"/*; do
    [[ -e "$candidate" ]] || continue
    candidate_name="${candidate##*/}"
    known=0
    for profile in "${physical_profiles[@]}"; do
      if [[ "$candidate_name" == "$profile" ]]; then
        known=1
        break
      fi
    done
    [[ "$known" -eq 1 ]] \
      || fail "physical evidence contains an unknown profile: $candidate_name"
  done

  for profile in "${physical_profiles[@]}"; do
    if [[ -e "$input/$profile" ]]; then
      [[ -d "$input/$profile" && ! -L "$input/$profile" ]] \
        || fail "physical evidence profile is not a regular directory: $profile"
      cp -R "$input/$profile" "$artifacts/physical-profiles/$profile"
    fi
  done
}

write_provenance() {
  local output="$artifacts/provenance.json"
  plutil -create xml1 "$output"
  plutil -insert schemaVersion -integer 1 "$output"
  plutil -insert commit -string "$commit" "$output"
  plutil -insert sourceTreeSHA256 -string "$source_tree_hash" "$output"
  plutil -insert configuration -string Debug "$output"
  plutil -insert swiftVersion -string "$swift_version" "$output"
  plutil -insert xcodeVersion -string "$xcode_version" "$output"
  plutil -insert xcodegenVersion -string "$xcodegen_version" "$output"
  plutil -insert operatingSystem -string "$operating_system" "$output"
  plutil -insert kernel -string "$kernel" "$output"
  plutil -insert hardwareMachine -string "$hardware_machine" "$output"
  plutil -insert hardwareModel -string "$hardware_model" "$output"
  plutil -insert gpuName -string "$gpu_name" "$output"
  plutil -insert gpuClassification \
    -string "$gpu_classification" "$output"
  plutil -insert artifactRoot -string "$artifacts" "$output"
  plutil -insert brushLabCatalogSHA256 \
    -string "$card_catalog_hash" "$output"
  plutil -convert json "$output"
}

cd "$repo_root"
for tool in \
  awk bash cp find git grep nm otool plutil rg sed shasum sort \
  swift sw_vers sysctl system_profiler tr wc xargs xcodebuild xcodegen \
  xcrun
do
  require_tool "$tool"
done
verify_clean_source

commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || fail "HEAD is not a full commit identity"

rm -rf \
  "$artifacts" "$scratch" "$card_package" "$work" \
  "$derived_mac" "$derived_pad"
mkdir -p \
  "$artifacts/positive" \
  "$artifacts/negative-control" \
  "$artifacts/brush-lab-cards" \
  "$artifacts/physical-profiles" \
  "$logs" \
  "$work"

git ls-tree -r --full-tree "$commit" >"$artifacts/source-tree.txt"
source_tree_hash="$(
  shasum -a 256 "$artifacts/source-tree.txt" | awk '{print $1}'
)"
[[ "$source_tree_hash" =~ ^[0-9a-f]{64}$ ]] \
  || fail "source-tree SHA-256 is invalid"

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
    --product BrushDepositionEvidenceGate
validator="$scratch/debug/BrushDepositionEvidenceGate"
[[ -x "$validator" ]] \
  || fail "BrushDepositionEvidenceGate executable is unavailable"

run_logged full-tests \
  swift test --scratch-path "$scratch" --no-parallel
run_logged input-path-storage-diagnostic \
  swift test --scratch-path "$scratch" --no-parallel \
    --filter \
    nativeInputAndReplayPathsAllocateNothingAfterWarmup
run_logged input-path-allocator-runtime \
  ./scripts/run-brush-input-allocation-probe.sh "$scratch" release
grep -Eq \
  '^ALLOCATOR PROBE SELF-TEST PASS allocations=[1-9][0-9]*$' \
  "$logs/input-path-allocator-runtime.stdout.log" \
  || fail "allocator probe self-test did not detect its Array allocation"
grep -q \
  '^ALLOCATOR PROBE PRODUCTION PASS allocations=0$' \
  "$logs/input-path-allocator-runtime.stdout.log" \
  || fail "allocator probe did not prove zero production-route allocations"
run_logged brush-lab-headless-contract \
  swift test --scratch-path "$scratch" --no-parallel \
    --filter \
    'fixedManualCardMatrixCoversEveryAnchorAndRequiredDimension|freshSessionsProduceByteIdenticalManualCardJSON|loadsCompilesTracesAndExportsWithoutUIInteraction|manualEvidenceArchiveWritesJSONPNGsAndTelemetryAtomically'
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
  || fail "Mac harness binary is unavailable: $app_binary"

if rg -n \
  'Data\(contentsOf:|FileHandle|URLSession|BrushAssetDecoder|BrushTextureUploader|makeRenderPipelineState|waitUntilCompleted|compileAndActivate|makeTexture\(' \
  Sources/MetalRenderer/Deposition/DepositionEncoder.swift \
  Sources/MetalRenderer/Deposition/FrameScheduler.swift \
  Sources/MetalRenderer/LiveStroke.swift \
  Sources/PatternEngine/BrushDynamicsEngine.swift \
  Sources/PatternEngine/CentripetalCatmullRomStrokeInterpolator.swift \
  Sources/PatternEngine/TilingProjection.swift \
  Sources/PatternEngine/TilingStrategy.swift \
  >"$logs/hot-path-source.stdout.log" \
  2>"$logs/hot-path-source.stderr.log"; then
  fail "hot-path source references compiler, resource, file, allocation, pipeline, or wait APIs"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "hot-path source audit failed with exit $code"
fi

if rg -n \
  'Set\([[:space:]]*records\.map|preparedChunkRanges\.flatMap|dabs\.map\(\\\.attributes\)|let suffix = \[sample\]|Array\(dabs\)|var snapshot: \[LogicalDab\]|var updatedBuffer = transientStrokeBuffer|guard var buffer = transientStrokeBuffer|candidate\.nextFrame\(' \
  Sources/MetalRenderer/GridRenderer.swift \
  >"$logs/hot-path-owning-wrapper.stdout.log" \
  2>"$logs/hot-path-owning-wrapper.stderr.log"; then
  fail "renderer hot path references an allocating compatibility wrapper or COW buffer copy"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "renderer hot-path ownership boundary audit failed with exit $code"
fi

if rg -n \
  'definition\.coverage\.shapes\.map|shapeFrames\.flatMap|unitCorners\.map|corners\.map' \
  Sources/PatternEngine/BrushDynamicsEngine.swift \
  >"$logs/hot-path-dynamics-ownership.stdout.log" \
  2>"$logs/hot-path-dynamics-ownership.stderr.log"; then
  fail "brush dynamics hot path constructs an owning per-dab temporary"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "brush dynamics ownership boundary audit failed with exit $code"
fi

if rg -n \
  'final class ReservationTransaction' \
  Sources/PatternEngine/TransientStrokeBuffer.swift \
  >"$logs/hot-path-arena-transaction.stdout.log" \
  2>"$logs/hot-path-arena-transaction.stderr.log"; then
  fail "transient dab arena transaction allocates a heap object"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "arena transaction ownership boundary audit failed with exit $code"
fi
rg -q \
  'public struct ReservationTransaction' \
  Sources/PatternEngine/TransientStrokeBuffer.swift \
  || fail "transient dab arena lacks its value transaction API boundary"

if sed -n \
  '/private func prepareGeneratedDabs(/,/func appendProjectedFragments(/p' \
  Sources/MetalRenderer/GridRenderer.swift \
  | rg -n \
    'TilingProjection\.(fragments|fragmentsWithStorageDiagnostics|projection)\('; then
  fail "interactive projection path references an allocating compatibility wrapper"
fi

input_path_instrumentation_log="$logs/input-path-instrumentation.stdout.log"
: >"$input_path_instrumentation_log"
while IFS='|' read -r marker source; do
  if ! rg -n -F "$marker" "$source" \
    >>"$input_path_instrumentation_log"; then
    fail "input-path storage instrumentation is missing: $marker"
  fi
done <<'INSTRUMENTATION'
recordGeneratedDabs|Sources/MetalRenderer/GridRenderer.swift
recordTiling|Sources/MetalRenderer/GridRenderer.swift
recordRecordStorage|Sources/MetalRenderer/GridRenderer.swift
DepositionInputScratch|Sources/MetalRenderer/GridRenderer.swift
TilingProjectionScratch|Sources/PatternEngine/TilingProjection.swift
authoritativeScratch|Sources/MetalRenderer/Deposition/FrameScheduler.swift
preparedFrame|Sources/MetalRenderer/Deposition/FrameScheduler.swift
consume(_ frame|Sources/MetalRenderer/Deposition/FrameScheduler.swift
storageDiagnostics|Sources/PatternEngine/TilingProjection.swift
allocationEventCountAfterWarmup|Sources/MetalRenderer/InputPathStorageAudit.swift
recordCollectionStorageAllocation|Sources/MetalRenderer/InputPathStorageAudit.swift
authoritativeBacklogRemaining|Sources/MetalRenderer/GridRenderer.swift
auditLiveFlushIdentity|Sources/MetalRenderer/Capture/HarnessRunner.swift
INSTRUMENTATION

run_logged validator-linked-libraries otool -L "$validator"
run_logged validator-undefined-symbols nm -u "$validator"
if rg -n \
  'AppKit|SwiftUI|UIKit|MetalKit|Metal\.framework|CFNetwork|Network\.framework' \
  "$logs/validator-linked-libraries.stdout.log" \
  "$logs/validator-undefined-symbols.stdout.log" \
  >"$logs/validator-binary-boundary.stdout.log"; then
  fail "artifact-only validator links UI, Metal, or network code"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "validator binary boundary audit failed with exit $code"
fi

run_logged app-linked-libraries otool -L "$app_binary"
app_symbol_binary="$app_binary"
debug_dylib="$(dirname "$app_binary")/PatternSpike.debug.dylib"
if rg -q '@rpath/PatternSpike\.debug\.dylib' \
  "$logs/app-linked-libraries.stdout.log"; then
  [[ -f "$debug_dylib" ]] \
    || fail "app launcher references a missing debug dylib"
  app_symbol_binary="$debug_dylib"
fi
printf '%s\n' "$app_symbol_binary" \
  >"$logs/app-symbol-image.txt"
run_logged app-symbols \
  bash -c 'nm "$1" | xcrun swift-demangle' _ "$app_symbol_binary"
run_logged app-native-deposition-symbols \
  rg -n \
    'DepositionEncoder|FrameScheduler|InputPathStorageAudit|TilingProjectionStorageDiagnostics' \
    "$logs/app-symbols.stdout.log"
if rg -n 'BoundedWashSurface|ProjectedStampInstance' \
  "$logs/app-symbols.stdout.log" \
  >"$logs/app-legacy-symbols.stdout.log"; then
  fail "app binary retains removed generic deposition or bounded-wash symbols"
else
  code=$?
  [[ "$code" -eq 1 ]] \
    || fail "app legacy-symbol audit failed with exit $code"
fi

scene_names=(
  deposition-airbrush
  deposition-cache-pinning
  deposition-custom-asymmetric
  deposition-dry
  deposition-erase
  deposition-failure-matrix
  deposition-glaze
  deposition-ink
  deposition-kinematics
  deposition-layer-matrix
  deposition-marker
  deposition-periodic-seams
  deposition-prediction
  deposition-preview-commit
  deposition-radial-reflection
  deposition-stamp-size-mips
)
for name in "${scene_names[@]}"; do
  [[ -f "$scene_source/$name.json" ]] \
    || fail "positive deposition scene is missing: $name"
  [[ -f "$scene_source/$name-negative-control.json" ]] \
    || fail "negative deposition scene is missing: $name"
  run_negative_scene "$name"
  run_positive_scene "$name"
done
write_scene_matrix

run_performance_scene five-hundred-dabs
run_performance_scene projected-long-stroke

write_card_exporter_package
run_logged brush-lab-card-export \
  swift run --package-path "$card_package" \
    --configuration debug \
    CardExporter \
    "$artifacts/brush-lab-cards/catalog.json"
card_catalog_hash="$(
  shasum -a 256 "$artifacts/brush-lab-cards/catalog.json" \
    | awk '{print $1}'
)"
[[ "$card_catalog_hash" \
    == "6490bcf5d3d452e523b0eba7293b1bf8050ae8445a41941592bbb60c91bf7a32" ]] \
  || fail "headless Brush Lab catalog is not the committed 312-card contract"

gpu_name="$(
  plutil -extract hardware.gpuName raw -o - \
    "$artifacts/positive/deposition-airbrush/benchmark.json"
)"
operating_system="$(
  plutil -extract operatingSystem raw -o - \
    "$artifacts/positive/deposition-airbrush/benchmark.json"
)"
[[ -n "$gpu_name" && -n "$operating_system" ]] \
  || fail "benchmark GPU or operating-system provenance is empty"
lower_gpu="$(printf '%s' "$gpu_name" | tr '[:upper:]' '[:lower:]')"
case "$lower_gpu" in
  *paravirtual*) gpu_classification="paravirtual" ;;
  *virtual*|*simulator*) gpu_classification="virtual" ;;
  *) gpu_classification="physical" ;;
esac

metrics="$(
  xcrun swift - "$artifacts" \
    2>"$logs/performance-metrics.stderr.log" <<'SWIFT'
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
let positive = root.appendingPathComponent("positive")
let names = [
    "deposition-airbrush", "deposition-cache-pinning",
    "deposition-custom-asymmetric", "deposition-dry",
    "deposition-erase", "deposition-failure-matrix",
    "deposition-glaze", "deposition-ink", "deposition-kinematics",
    "deposition-layer-matrix", "deposition-marker",
    "deposition-periodic-seams", "deposition-prediction",
    "deposition-preview-commit", "deposition-radial-reflection",
    "deposition-stamp-size-mips",
]
let cpu = try names.map {
    let record = try object(
        positive.appendingPathComponent($0)
            .appendingPathComponent("benchmark.json")
    )
    return p95(record["cpuEncodeMilliseconds"] as! [Double])
}.max()!
let five = try object(
    root.appendingPathComponent("logs")
        .appendingPathComponent("five-hundred-dabs.benchmark.json")
)
let gpu = (five["dabGPUMilliseconds"] as! [Double]).max()!
print(String(format: "%.17g %.17g", cpu, gpu))
SWIFT
)"
read -r cpu_p95 gpu_500 <<<"$metrics"
[[ -n "$cpu_p95" && -n "$gpu_500" ]] \
  || fail "software performance measurements are unavailable"

physical_profiles=(
  a14Floor60Hz
  inputToPhoton
  memoryWarning
  pencil
  referenceMSeriesProMotion120Hz
  suspendResume
  sustainedThermal
  wacom
)
copy_physical_profile_evidence
write_performance_status
write_provenance
run_logged git-diff-check git diff --check

[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while Stage 4 evidence was running"
verify_clean_source
git ls-tree -r --full-tree "$commit" \
  >"$artifacts/source-tree-terminal.txt"
cmp -s \
  "$artifacts/source-tree.txt" \
  "$artifacts/source-tree-terminal.txt" \
  || fail "committed source tree changed while evidence was running"

rm -rf "$work"
(
  cd "$artifacts"
  find . -type f \
    ! -name artifact-sha256.txt \
    -print0 \
    | sort -z \
    | xargs -0 shasum -a 256
) >"$artifacts/artifact-sha256.txt"
[[ -s "$artifacts/artifact-sha256.txt" ]] \
  || fail "artifact digest manifest is empty"

if "$validator" \
  --artifacts "$artifacts" \
  --commit "$commit" \
  --source-tree-sha256 "$source_tree_hash" \
  >"$validator_result" 2>&1; then
  validator_status=0
else
  validator_status=$?
fi

case "$validator_status" in
  0)
    result_emitted=1
    trap - ERR
    printf 'BRUSH STAGE 4 PASS artifacts=%s commit=%s\n' \
      "$artifacts" "$commit"
    exit 0
    ;;
  2)
    result_emitted=1
    trap - ERR
    printf 'BRUSH STAGE 4 PERFORMANCE PENDING artifacts=%s commit=%s gpu=%s\n' \
      "$artifacts" "$commit" "$gpu_name"
    exit 2
    ;;
  *)
    validator_message="$(
      tr '\n' ' ' <"$validator_result" \
        | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
    )"
    fail "artifact validator exit $validator_status: $validator_message"
    ;;
esac
