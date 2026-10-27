#!/usr/bin/env bash
# Checks the in-app Claude Code engine outside the app: finds and checks the
# sign-in, asks two short questions (the second one through a pre-started
# process, with history), cancels a long answer, and renders a sentence with
# the Mac's system voice. It runs with an almost empty environment, like an
# app opened from the Finder. This uses a little of your Claude usage.
# Usage: scripts/check-claude-code-engine.sh [image.jpg]
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
work_folder="$(mktemp -d)"

# The voice source lives in CompanionSentenceSpeaker.swift next to AppKit
# speakers the check doesn't need, so only that part is compiled in.
{
  echo "import Foundation"
  sed -n '/^\/\/ MARK: - Sentence audio played back to back/,/^\/\/\/ Fetches each sentence/p' \
    "$repository_root/leanring-buddy/CompanionSentenceSpeaker.swift" | sed '$d' | grep -v "extension ElevenLabsTTSClient"
} > "$work_folder/VoiceSource.swift"

swiftc -parse-as-library -O -o "$work_folder/engine-check" \
  "$repository_root/leanring-buddy/ChildProcessSupport.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeCLI.swift" \
  "$repository_root/leanring-buddy/ClaudeCodeChatClient.swift" \
  "$work_folder/VoiceSource.swift" \
  "$repository_root/scripts/engine-check/main.swift"

cd "$work_folder"
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL="${SHELL:-/bin/zsh}" TMPDIR="${TMPDIR:-/tmp}" \
  "$work_folder/engine-check" all "${1:-}"
