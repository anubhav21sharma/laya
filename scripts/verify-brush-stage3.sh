#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$repo_root/.build/brush-stage3-artifacts"
logs="$artifacts/logs"
derived_mac="$repo_root/.build/BrushStage3DerivedDataMac"
derived_pad="$repo_root/.build/BrushStage3DerivedDataPad"

fail() {
  printf 'BRUSH STAGE 3 ERROR: %s\n' "$*" >&2
  exit 1
}

verify_clean_build_inputs() {
  git diff --quiet \
    || fail "tracked working tree differs from committed HEAD"
  git diff --cached --quiet \
    || fail "index differs from committed HEAD"
  if git ls-files --others --exclude-standard -- \
    Sources Tests App/PatternSpike Package.swift Package.resolved \
    scripts Config Configuration .github docs/superpowers \
    | grep -q .; then
    fail "untracked build input exists; evidence requires committed source"
  fi
}

run_logged() {
  local name="$1"
  local status
  shift
  if "$@" >"$logs/$name.stdout.log" 2>"$logs/$name.stderr.log"; then
    return
  else
    status=$?
  fi
  cat "$logs/$name.stderr.log" >&2
  fail "$name failed with exit $status"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required tool is unavailable: $1"
}

require_report_field() {
  local path="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plutil -extract "$key" raw -o - "$path")" \
    || fail "missing fuzz report field $key: $path"
  [[ "$actual" == "$expected" ]] \
    || fail "unexpected fuzz report field $key=$actual: $path"
}

require_positive_report_integer() {
  local path="$1"
  local key="$2"
  local actual
  actual="$(plutil -extract "$key" raw -o - "$path")" \
    || fail "missing fuzz report field $key: $path"
  [[ "$actual" =~ ^[0-9]+$ ]] \
    || fail "non-integer fuzz report field $key=$actual: $path"
  (( actual > 0 )) \
    || fail "non-positive fuzz report field $key=$actual: $path"
}

require_report_sha256() {
  local path="$1"
  local key="$2"
  local actual
  actual="$(plutil -extract "$key" raw -o - "$path")" \
    || fail "missing fuzz report field $key: $path"
  [[ "$actual" =~ ^[0-9a-f]{64}$ ]] \
    || fail "invalid fuzz report SHA-256 field $key=$actual: $path"
}

cd "$repo_root"
for tool in git rg swift xcodebuild xcodegen plutil shasum otool nm; do
  require_tool "$tool"
done
verify_clean_build_inputs

commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  || fail "HEAD is not a full commit identity"

rm -rf "$artifacts" "$derived_mac" "$derived_pad"
mkdir -p "$artifacts/fuzz" "$logs"

git ls-tree -r --full-tree "$commit" >"$artifacts/source-tree.txt"
source_tree_hash="$(
  shasum -a 256 "$artifacts/source-tree.txt" | awk '{print $1}'
)"
printf '%s\n' "$commit" >"$artifacts/commit.txt"
swift --version >"$artifacts/swift-toolchain.txt" 2>&1
xcodebuild -version >"$artifacts/xcode-toolchain.txt"
xcodegen version >"$artifacts/xcodegen-toolchain.txt"
sw_vers >"$artifacts/operating-system.txt"
uname -a >"$artifacts/kernel.txt"
sysctl -n hw.model >"$artifacts/hardware-model.txt"

if rg -n \
  'import (MetalRenderer|SwiftUI|AppKit|UIKit)|MetalRenderer|PatternSpike' \
  Sources/BrushConverterFuzz Sources/BrushConverterFuzzSupport \
  >"$logs/fuzzer-source-boundary.stdout.log" \
  2>"$logs/fuzzer-source-boundary.stderr.log"; then
  fail "converter fuzzer source boundary imports app or Metal code"
else
  status=$?
  [[ "$status" -eq 1 ]] \
    || fail "converter fuzzer source boundary audit failed"
fi

run_logged package-description swift package describe --type json
run_logged cli-build swift build --product layabrush-convert
run_logged fuzzer-build swift build --product brush-converter-fuzz

fuzzer="$repo_root/.build/debug/brush-converter-fuzz"
[[ -x "$fuzzer" ]] || fail "converter fuzz executable is unavailable"
run_logged fuzzer-linked-libraries otool -L "$fuzzer"
run_logged fuzzer-undefined-symbols nm -u "$fuzzer"
if rg -n 'MetalRenderer|SwiftUI|AppKit|UIKit|Metal.framework' \
  "$logs/fuzzer-linked-libraries.stdout.log" \
  "$logs/fuzzer-undefined-symbols.stdout.log" \
  >"$logs/fuzzer-binary-boundary.stdout.log"; then
  fail "converter fuzz executable links app, UI, or Metal code"
else
  status=$?
  [[ "$status" -eq 1 ]] \
    || fail "converter fuzzer binary boundary audit failed"
fi

run_logged full-tests swift test --no-parallel
run_logged defensive-converter-corpus \
  swift test --no-parallel --filter BrushConverterTests
run_logged fuzz-contract-tests \
  swift test --no-parallel --filter BrushConverterFuzzHarnessTests
run_logged package-v1-v2-compatibility \
  swift test --no-parallel \
    --filter \
    'conversionReportRoundTripsInsideVersionTwoPackage|frozenStageTwoVersionOneArchiveRemainsReadable'
run_logged cli-atomicity \
  swift test --no-parallel --filter LayabrushConvertSubprocessTests
run_logged compiler-dry-wet-activation \
  swift test --no-parallel \
    --filter SyntheticBrushCompilerIntegrationTests
run_logged headless-brush-lab \
  swift test --no-parallel --filter BrushLabSessionTests

toolchain="$(
  tr '\n' ' ' <"$artifacts/swift-toolchain.txt" \
    | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
)"
fuzz_seeds=(0 1 41 0x123456789abcdef0)
for index in "${!fuzz_seeds[@]}"; do
  seed="${fuzz_seeds[$index]}"
  output="$artifacts/fuzz/seed-$index.json"
  crash_directory="$artifacts/fuzz/seed-$index-crash"
  run_logged "fuzz-seed-$index" \
    "$fuzzer" \
      --seed "$seed" \
      --iterations 1024 \
      --output "$output" \
      --artifacts "$crash_directory" \
      --commit "$commit" \
      --toolchain "$toolchain"
  plutil -p "$output" >/dev/null \
    || fail "invalid fuzz campaign report: $output"
  require_report_field "$output" commit "$commit"
  require_report_field "$output" crashArtifactPresent false
  require_report_field "$output" summary.iterations 1024
  require_report_field \
    "$output" \
    crashArtifactPath \
    "$crash_directory/current-case.json"
  require_positive_report_integer \
    "$output" summary.acceptedDocumentCount
  require_positive_report_integer \
    "$output" summary.rejectedParserOperationCount
  require_positive_report_integer "$output" summary.totalInputBytes
  require_report_sha256 "$output" summary.generatedInputSHA256
  require_report_sha256 "$output" summary.observationSHA256
  [[ ! -e "$crash_directory/current-case.json" ]] \
    || fail "successful fuzz campaign retained a crash artifact: $seed"
done
printf '%s\n' "${fuzz_seeds[@]}" >"$artifacts/fuzz-smoke-seeds.txt"

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

[[ "$(git rev-parse HEAD)" == "$commit" ]] \
  || fail "HEAD changed while Stage 3 evidence was running"
verify_clean_build_inputs
git ls-tree -r --full-tree "$commit" \
  >"$artifacts/source-tree-terminal.txt"
cmp -s \
  "$artifacts/source-tree.txt" \
  "$artifacts/source-tree-terminal.txt" \
  || fail "committed source tree changed while evidence was running"

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "commit": "%s",\n' "$commit"
  printf '  "sourceTreeSHA256": "%s",\n' "$source_tree_hash"
  printf '  "configuration": "Debug",\n'
  printf '  "fuzzSeedCount": %s,\n' "${#fuzz_seeds[@]}"
  printf '  "fuzzIterationsPerSeed": 1024,\n'
  printf '  "artifactRoot": "%s"\n' "$artifacts"
  printf '}\n'
} >"$artifacts/provenance.json"
plutil -p "$artifacts/provenance.json" >/dev/null \
  || fail "generated provenance JSON is invalid"

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

printf 'BRUSH STAGE 3 PASS artifacts=%s commit=%s\n' \
  "$artifacts" "$commit"
