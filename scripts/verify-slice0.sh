#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
pad_derived_data="$repo_root/.build/DerivedDataPad"
artifacts="$repo_root/.build/slice0-artifacts"
mac_log="$repo_root/.build/slice0-macos-build.log"
pad_log="$repo_root/.build/slice0-ipados-build.log"
test_log="$repo_root/.build/slice0-swift-test.log"

cd "$repo_root"
mkdir -p "$artifacts/positive" "$artifacts/negative-control"

./scripts/bootstrap.sh

swift test >"$test_log"

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikeMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$mac_log"

xcodebuild \
  -project App/PatternSpike.xcodeproj \
  -scheme PatternSpikePad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$pad_derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$pad_log"

binary="$derived_data/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
git_commit="$(git rev-parse HEAD)"

if "$binary" \
  --harness-scene "$repo_root/App/PatternSpike/Harness/Scenes/blank-canvas-negative-control.json" \
  --output-directory "$artifacts/negative-control" \
  --git-commit "$git_commit" \
  --configuration Debug \
  >"$artifacts/negative-control/stdout.log" \
  2>"$artifacts/negative-control/stderr.log"
then
  printf '%s\n' "Negative control unexpectedly passed."
  exit 1
fi

grep -q "HARNESS FAIL" "$artifacts/negative-control/stderr.log"
printf '%s\n' "negative-control=failed-as-expected"

"$binary" \
  --harness-scene "$repo_root/App/PatternSpike/Harness/Scenes/blank-canvas.json" \
  --output-directory "$artifacts/positive" \
  --git-commit "$git_commit" \
  --configuration Debug \
  | tee "$artifacts/positive/stdout.log"

test -s "$artifacts/positive/blank-canvas.screen.png"
test -s "$artifacts/positive/blank-canvas.benchmark.json"
grep -q '"sceneName" : "blank-canvas"' "$artifacts/positive/blank-canvas.benchmark.json"
grep -q '"frameCount" : 1' "$artifacts/positive/blank-canvas.benchmark.json"

printf '%s\n' "swift-tests=passed"
printf '%s\n' "macos-build=passed"
printf '%s\n' "ipados-simulator-build=passed"
printf '%s\n' "offscreen-harness=passed"
printf '%s\n' "SLICE0 AUTOMATED GATE PASS"
