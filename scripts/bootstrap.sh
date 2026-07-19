#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' "xcodegen is required. Install XcodeGen 2.46.0 or newer."
  exit 1
fi

printf 'Using %s\n' "$(xcodegen version)"
cd "$repo_root/App"
xcodegen generate --spec project.yml
