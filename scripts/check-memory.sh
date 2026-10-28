#!/usr/bin/env bash
# Asks Claude Code a few memory questions with Clicky's real system prompt
# (remember, forget, use what's remembered, start over) and has Haiku pick
# facts out of two made-up conversations, then reports which went as
# expected. Uses a little of your Claude usage (about nine short answers).
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
work_folder="$(mktemp -d)"

swiftc -parse-as-library -O -o "$work_folder/memory-check" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeChatClient.swift" \
  "$repository_root/leanring-buddy/ConversationSessions.swift" \
  "$repository_root/leanring-buddy/UserMemory.swift" \
  "$repository_root/scripts/memory-check/main.swift"

"$work_folder/memory-check" "$repository_root"
