#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fixture_repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
log="$fixture_root/commands.log"
stdout_log="$fixture_root/stdout.log"
stderr_log="$fixture_root/stderr.log"

mkdir -p "$fixture_repo/App" "$fixture_repo/scripts" "$fake_bin"
cp "$repo_root/scripts/bootstrap.sh" "$fixture_repo/scripts/bootstrap.sh"
cp "$repo_root/scripts/run-macos.sh" "$fixture_repo/scripts/run-macos.sh"
touch "$fixture_repo/App/project.yml"
chmod +x \
  "$fixture_repo/scripts/bootstrap.sh" \
  "$fixture_repo/scripts/run-macos.sh"

cat >"$fake_bin/xcodegen" <<'FAKE_XCODEGEN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "version" ]]; then
  printf '%s\n' "Version: 2.46.0"
  exit 0
fi

printf 'xcodegen' >>"$LAUNCH_TEST_LOG"
printf ' <%s>' "$@" >>"$LAUNCH_TEST_LOG"
printf '\n' >>"$LAUNCH_TEST_LOG"
exit "${XCODEGEN_EXIT:-0}"
FAKE_XCODEGEN

cat >"$fake_bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/usr/bin/env bash
set -euo pipefail

printf 'xcodebuild' >>"$LAUNCH_TEST_LOG"
printf ' <%s>' "$@" >>"$LAUNCH_TEST_LOG"
printf '\n' >>"$LAUNCH_TEST_LOG"

if [[ "${XCODEBUILD_EXIT:-0}" -ne 0 ]]; then
  exit "$XCODEBUILD_EXIT"
fi
if [[ "${SKIP_APP_CREATE:-0}" == "1" ]]; then
  exit 0
fi

app="$LAUNCH_TEST_REPO/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
mkdir -p "$(dirname "$app")"
cp "$LAUNCH_TEST_FAKE_APP" "$app"
chmod +x "$app"
FAKE_XCODEBUILD

cat >"$fixture_root/fake-app" <<'FAKE_APP'
#!/usr/bin/env bash
set -euo pipefail

printf 'app' >>"$LAUNCH_TEST_LOG"
printf ' <%s>' "$@" >>"$LAUNCH_TEST_LOG"
printf '\n' >>"$LAUNCH_TEST_LOG"
exit "${APP_EXIT:-0}"
FAKE_APP

chmod +x "$fake_bin/xcodegen" "$fake_bin/xcodebuild" "$fixture_root/fake-app"

run_launcher() {
  env \
    PATH="$fake_bin:$PATH" \
    LAUNCH_TEST_LOG="$log" \
    LAUNCH_TEST_REPO="$fixture_repo" \
    LAUNCH_TEST_FAKE_APP="$fixture_root/fake-app" \
    "$@"
}

: >"$log"
set +e
run_launcher \
  APP_EXIT=23 \
  "$fixture_repo/scripts/run-macos.sh" \
  "argument with spaces" "*.json" \
  >"$stdout_log" 2>"$stderr_log"
status=$?
set -e
[[ "$status" -eq 23 ]]

expected_build="xcodebuild <-project> <$fixture_repo/App/PatternSpike.xcodeproj> <-scheme> <PatternSpikeMac> <-configuration> <Debug> <-destination> <platform=macOS> <-derivedDataPath> <$fixture_repo/.build/DerivedData> <build> <CODE_SIGNING_ALLOWED=NO>"
[[ "$(wc -l <"$log" | tr -d ' ')" -eq 3 ]]
[[ "$(sed -n '1p' "$log")" == "xcodegen <generate> <--spec> <project.yml>" ]]
[[ "$(sed -n '2p' "$log")" == "$expected_build" ]]
[[ "$(sed -n '3p' "$log")" == "app <argument with spaces> <*.json>" ]]
grep -Fqx \
  "Launching $fixture_repo/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike" \
  "$stdout_log"

: >"$log"
set +e
run_launcher \
  XCODEGEN_EXIT=41 \
  "$fixture_repo/scripts/run-macos.sh" \
  >"$stdout_log" 2>"$stderr_log"
status=$?
set -e
[[ "$status" -eq 41 ]]
[[ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]]
grep -Fqx "xcodegen <generate> <--spec> <project.yml>" "$log"

: >"$log"
set +e
run_launcher \
  XCODEBUILD_EXIT=42 \
  "$fixture_repo/scripts/run-macos.sh" \
  >"$stdout_log" 2>"$stderr_log"
status=$?
set -e
[[ "$status" -eq 42 ]]
[[ "$(wc -l <"$log" | tr -d ' ')" -eq 2 ]]
if grep -Fq "app " "$log"; then
  exit 1
fi

rm -f \
  "$fixture_repo/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"
: >"$log"
set +e
run_launcher \
  SKIP_APP_CREATE=1 \
  "$fixture_repo/scripts/run-macos.sh" \
  >"$stdout_log" 2>"$stderr_log"
status=$?
set -e
[[ "$status" -eq 1 ]]
grep -Fqx \
  "macOS app executable not found: $fixture_repo/.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike" \
  "$stderr_log"
if grep -Fq "app " "$log"; then
  exit 1
fi

printf '%s\n' "run-macos-tests=passed"
