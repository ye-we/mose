#!/usr/bin/env bash
# Asks Claude Code "do it for me" questions with Mose's real system prompt and
# devil mode on (and once off), on the fixture screenshots, and checks the
# action tags it answers with: the right action on the right thing, asking
# before sending, and showing instead of doing when they ask how. Nothing is
# clicked. Uses a little of your Claude usage (about a dozen short answers).
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
work_folder="$(mktemp -d)"

swiftc -parse-as-library -O -o "$work_folder/devil-mode-check" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeChatClient.swift" \
  "$repository_root/leanring-buddy/GuidedStepCardDeck.swift" \
  "$repository_root/leanring-buddy/ConversationSessions.swift" \
  "$repository_root/leanring-buddy/ScreenSketch.swift" \
  "$repository_root/leanring-buddy/DevilMode.swift" \
  "$repository_root/scripts/devil-mode-check/main.swift"

"$work_folder/devil-mode-check" "$repository_root"
