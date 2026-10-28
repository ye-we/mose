#!/usr/bin/env bash
# Asks Claude Code a fixed set of voice questions with Clicky's real system
# prompt and reports how long each answer is, so prompt changes can be judged
# by numbers. Uses a little of your Claude usage (about seven short answers).
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
work_folder="$(mktemp -d)"

swiftc -parse-as-library -O -o "$work_folder/answer-length-check" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeChatClient.swift" \
  "$repository_root/scripts/answer-length-check/main.swift"

"$work_folder/answer-length-check" "$repository_root"
