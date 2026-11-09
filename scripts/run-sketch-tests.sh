#!/usr/bin/env bash
# Builds and runs the screen sketching tests (scripts/sketch-tests) against the
# app's own source files. Plain swiftc, so it doesn't touch Xcode builds or the
# app's macOS permissions.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
test_binary_path="$(mktemp -d)/sketch-tests"

swiftc -O -o "$test_binary_path" \
  "$repository_root/leanring-buddy/ScreenSketch.swift" \
  "$repository_root/leanring-buddy/DevilMode.swift" \
  "$repository_root/leanring-buddy/ScreenTextRecognizer.swift" \
  "$repository_root/leanring-buddy/StreamingAnswerSegmenter.swift" \
  "$repository_root/leanring-buddy/BackgroundAgentJobs.swift" \
  "$repository_root/leanring-buddy/DictationTextInserter.swift" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeChatClient.swift" \
  "$repository_root/leanring-buddy/BackgroundAgentJobRunner.swift" \
  "$repository_root/leanring-buddy/GuidedStepCardDeck.swift" \
  "$repository_root/leanring-buddy/ConversationSessions.swift" \
  "$repository_root/leanring-buddy/UserMemory.swift" \
  "$repository_root/leanring-buddy/AgentConnectedApps.swift" \
  "$repository_root/leanring-buddy/AppUpdatePolicy.swift" \
  "$repository_root/scripts/appcast/Appcast.swift" \
  "$repository_root/scripts/sketch-tests/main.swift"

"$test_binary_path" "$repository_root/appcast.xml"
