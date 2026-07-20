#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
binary="$derived_data/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike"

cd "$repo_root"
./scripts/bootstrap.sh

xcodebuild \
  -project "$repo_root/App/PatternSpike.xcodeproj" \
  -scheme PatternSpikeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -x "$binary" ]]; then
  printf 'macOS app executable not found: %s\n' "$binary" >&2
  exit 1
fi

printf 'Launching %s\n' "$binary"
exec "$binary" "$@"
