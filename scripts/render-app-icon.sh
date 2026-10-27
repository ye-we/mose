#!/usr/bin/env bash
# Renders the app icon (scripts/app-icon/main.swift) at every size macOS needs
# and writes the PNGs into the asset catalog. Plain swiftc, no Xcode needed.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
renderer_path="$(mktemp -d)/render-app-icon"

swiftc -o "$renderer_path" \
  "$repository_root/leanring-buddy/DesignSystem.swift" \
  "$repository_root/leanring-buddy/InkAndKeycapViews.swift" \
  "$repository_root/leanring-buddy/ScreenSketch.swift" \
  "$repository_root/leanring-buddy/ScreenSketchLayer.swift" \
  "$repository_root/scripts/app-icon/main.swift"

"$renderer_path" "$repository_root/leanring-buddy/Assets.xcassets/AppIcon.appiconset"
