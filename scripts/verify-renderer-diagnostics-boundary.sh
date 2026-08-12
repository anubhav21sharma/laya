#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived="$repo_root/.build/RendererDiagnosticsBoundaryDerivedData"
logs="$repo_root/.build/renderer-diagnostics-boundary-logs"

fail() {
  printf 'RENDERER DIAGNOSTICS BOUNDARY ERROR: %s\n' "$*" >&2
  exit 1
}

run_logged() {
  local name="$1"
  shift
  if "$@" >"$logs/$name.log" 2>&1; then
    return
  fi
  tail -100 "$logs/$name.log" >&2
  fail "$name failed"
}

assert_diagnostics_absent() {
  local binary="$1"
  [[ -x "$binary" ]] || fail "production binary is missing: $binary"
  if nm "$binary" 2>/dev/null \
    | grep -E 'MetalRendererDiagnostics|HarnessScene|DepositionHarnessRunner' \
      >/dev/null
  then
    fail "production binary links diagnostics: $binary"
  fi
}

cd "$repo_root"
mkdir -p "$logs"

run_logged package-renderer-build \
  swift build --target MetalRenderer
run_logged package-diagnostics-build \
  swift build --target MetalRendererDiagnostics
run_logged xcodegen \
  xcodegen generate --spec "$repo_root/App/project.yml"
run_logged production-debug-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -configuration Debug \
    -destination platform=macOS \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO
run_logged production-release-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMac \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO
run_logged harness-debug-build \
  xcodebuild build \
    -project "$repo_root/App/PatternSpike.xcodeproj" \
    -scheme PatternSpikeMacHarness \
    -configuration Debug \
    -destination platform=macOS \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO

debug_product="$derived/Build/Products/Debug/PatternSpike.app/Contents/MacOS"
debug_binary="$debug_product/PatternSpike.debug.dylib"
[[ -x "$debug_binary" ]] || debug_binary="$debug_product/PatternSpike"
release_binary="$derived/Build/Products/Release/PatternSpike.app/Contents/MacOS/PatternSpike"
harness_binary="$derived/Build/Products/Debug/PatternSpikeHarness.app/Contents/MacOS/PatternSpikeHarness.debug.dylib"
[[ -x "$harness_binary" ]] \
  || harness_binary="$derived/Build/Products/Debug/PatternSpikeHarness.app/Contents/MacOS/PatternSpikeHarness"

assert_diagnostics_absent "$debug_binary"
assert_diagnostics_absent "$release_binary"
if ! nm "$harness_binary" 2>/dev/null \
  | grep -E 'MetalRendererDiagnostics|HarnessScene|DepositionHarnessRunner' \
    >/dev/null
then
  fail "harness binary does not link diagnostics: $harness_binary"
fi

if grep -Fq "in target 'MetalRendererDiagnostics'" \
  "$logs/production-debug-build.log" \
  "$logs/production-release-build.log"
then
  fail "a production app build graph includes diagnostics"
fi

printf 'RENDERER DIAGNOSTICS BOUNDARY PASS\n'
