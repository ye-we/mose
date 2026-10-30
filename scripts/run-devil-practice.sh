#!/usr/bin/env bash
# Builds the devil mode practice window (scripts/devil-practice/main.swift) with
# plain swiftc and runs it, passing every argument through. The binary goes in
# a temp folder (or DEVIL_PRACTICE_BUILD_DIR), never the repo or Xcode's
# DerivedData, so it can't disturb the app's build or its macOS permissions.
# It is only rebuilt when main.swift is newer than the last build.
# Usage: scripts/run-devil-practice.sh [--log PATH] [--quit-after SECONDS]
#        scripts/run-devil-practice.sh --render PATH.png   (offscreen, no window)
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
practice_source_path="$repository_root/scripts/devil-practice/main.swift"
build_folder="${DEVIL_PRACTICE_BUILD_DIR:-${TMPDIR:-/tmp}/devil-practice-build}"
practice_binary_path="$build_folder/devil-practice"
mkdir -p "$build_folder"

if [[ ! -x "$practice_binary_path" || "$practice_source_path" -nt "$practice_binary_path" ]]; then
  swiftc -O -o "$practice_binary_path" "$practice_source_path"
fi

# exec so a test's SIGTERM reaches the app itself, which quits cleanly on it.
exec "$practice_binary_path" "$@"
