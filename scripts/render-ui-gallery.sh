#!/usr/bin/env bash
# Renders the setup window and the menu bar panel in several states to PNGs,
# with a stand-in CompanionManager (scripts/ui-gallery/Stubs.swift), so the
# design can be checked without launching the app or touching the screen.
# Usage: scripts/render-ui-gallery.sh [output folder] [one scenario name]
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_folder="${1:-$(mktemp -d)}"
gallery_binary_path="$(mktemp -d)/ui-gallery"
mkdir -p "$output_folder"

swiftc -o "$gallery_binary_path" \
  "$repository_root/leanring-buddy/DesignSystem.swift" \
  "$repository_root/leanring-buddy/InkAndKeycapViews.swift" \
  "$repository_root/leanring-buddy/ScreenSketch.swift" \
  "$repository_root/leanring-buddy/DevilMode.swift" \
  "$repository_root/leanring-buddy/DevilModeDrivingNoteView.swift" \
  "$repository_root/leanring-buddy/ScreenSketchLayer.swift" \
  "$repository_root/leanring-buddy/SetupWindow.swift" \
  "$repository_root/leanring-buddy/CompanionPanelView.swift" \
  "$repository_root/leanring-buddy/BackgroundAgentJobs.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/GuidedStepCardDeck.swift" \
  "$repository_root/leanring-buddy/GuidedStepCardsView.swift" \
  "$repository_root/leanring-buddy/ConversationSessions.swift" \
  "$repository_root/leanring-buddy/UserMemory.swift" \
  "$repository_root/leanring-buddy/AgentConnectedApps.swift" \
  "$repository_root/leanring-buddy/ConnectedAppsWindow.swift" \
  "$repository_root/leanring-buddy/ConversationHistoryWindow.swift" \
  "$repository_root/scripts/ui-gallery/Stubs.swift" \
  "$repository_root/scripts/ui-gallery/main.swift"

"$gallery_binary_path" "$output_folder" ${2:+"$2"}
echo "PNGs in $output_folder"
