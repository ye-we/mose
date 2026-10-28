# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with status, shortcuts, background tasks and settings; a setup window walks new users through connecting Claude Code and the permissions. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it with Apple Speech, and sends the transcript + a screenshot of the user's screen to Claude through the user's own Claude Code CLI (no API keys, no server). Claude's answer streams back and is spoken sentence by sentence in the Mac's system voice. A blue cursor overlay can fly to, point at and draw on UI elements Claude references on any connected monitor.

The original API-key path (a Cloudflare Worker proxy) still works by pointing `CLICKY_BRIDGE_URL` at it.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: the Claude Code CLI, run by the app (`ClaudeCodeChatClient`: `claude -p` with stream-json in and out, the user's sign-in, tools/MCP/settings off, extended thinking off unless the user turns it on). Model picker: Haiku, Sonnet (default) or Opus, mapped to Claude Code's aliases. With `CLICKY_BRIDGE_URL` set, `ClaudeAPI` sends Messages API requests to that bridge or Worker instead (`CompanionChatBackend` covers both).
- **Speech-to-Text**: Apple Speech (`VoiceTranscriptionProvider` = `apple`); AssemblyAI and OpenAI providers remain for the Worker path
- **Text-to-Speech**: macOS `say` with the system voice (often a Siri voice), rendered per sentence and played back to back (`MacSystemVoiceSpeechAudioSource` + `PrefetchedAudioSentenceSpeaker`); ElevenLabs only through a bridge
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing & Screen Sketching**: Claude embeds `[POINT:x,y:label:screenN]` and `[DRAW:kind numbers label="..." color=... screen=N]` tags inline, right after the sentence each one goes with (kinds: circle, box, arrow, underline, highlight, cross, check, path, text). `ClaudeVisualTagParser` turns them into ordered "visual beats"; `CompanionManager` shows beat 1 immediately and the rest timed to the TTS audio; the overlay plays beats one at a time from a queue, flying straight from one to the next, with the cursor acting as the pen for drawings. See "Screen Sketching" below.
- **Guided Steps**: For how-tos, Claude gives one step at a time and marks the next click with `[DRAW:target ...]` (an orange numbered ring). The user's next left click (on target, or anywhere in the same app) makes Clicky wait 0.8s for the UI to settle, re-screenshot, and ask Claude for the next step with a "(guided step) i clicked …" turn, up to 10 automatic steps per question. Clicks in other apps are ignored. Each step also becomes a pinned step card (`GuidedStepCardDeck` + `GuidedStepCardsView`) in a screen corner away from the target: it goes up with its ring, gets a green check the moment the target is clicked, and the walkthrough's last answer stays as a closing note for 8s. Asking something new clears the cards.
- **Short answers**: the voice prompt caps answers at one or two sentences (about thirty words) unless the user asks for depth; `scripts/check-answer-length.sh` measures this against fixed questions (median went from 59 to 32 words when the "thorough explanation / plant a seed" rules were removed).
- **Streaming Speech**: `StreamingAnswerSegmenter` cuts Claude's streamed answer into sentences and tags; each sentence is spoken as soon as it completes (`CompanionSentenceSpeaker`: `say` audio by default, since AVSpeechSynthesizer can't use Siri voices and sounds robotic with the compact ones; `SystemVoiceSentenceSpeaker` only while an HTTP bridge's voice is unknown), and each tag's beat is shown when its sentence starts speaking.
- **Background Agents**: `[AGENT:title|brief]` hands real work (research, files) to a separate sandboxed Claude Code session that the app runs itself (`BackgroundAgentJobRunner`); the panel lists jobs, and finished ones are announced aloud.
- **Setup**: `SetupWindow.swift` is the first-run checklist (connect Claude Code, four permissions, say hi once), opened on first launch, when a permission is off, or when Claude Code is missing or signed out, and from the panel. Claude Code's installer and sign-in are interactive, so they run in Terminal via a `.command` file; setup polls `claude auth status --json` until it's done. Finished steps get a hand-drawn check and the current one a hand-drawn ring (`InkMarkView`, built on the sketch engine).
- **Dictation**: hold fn+control to type with your voice into any focused field (`DictationTextInserter`: local cleanup, paste, clipboard restored).
- **User Ink**: while ctrl+option is held the overlay accepts the mouse, so dragging draws red ink; the ink is composited into the screenshot (`UserInkCompositor`) and Claude is told the user drew it.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`, switched off (its setup is commented out; the upstream key would send transcripts to the original author)

### API Proxy (Cloudflare Worker, optional)

For running on API keys instead of a Claude Code sign-in: a Cloudflare Worker (`worker/src/index.ts`) holds the keys as secrets, and the app talks to it when `CLICKY_BRIDGE_URL` points at it.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Claude Code engine (default)

The app runs everything itself; nothing else needs to be started.

| Piece | What it does |
|-------|--------------|
| `ClaudeCodeCLI` | Finds `claude` (common install paths, then the login shell), builds its environment (API key variables removed so the Claude sign-in is used, the shell's PATH so agents find the user's tools), reads `claude auth status --json`, builds the stream-json user message (earlier turns folded into a transcript), parses output lines, and turns failures into `notSignedIn` / `usageLimitReached` / `failed`. |
| `ClaudeCodeChatClient` | Voice answers. One `claude -p` per turn in an empty temp folder, streamed text passed to the caller. A started process waits per model + system prompt + thinking setting (at most two, replaced after ten minutes), and one is started when the hotkey goes down, so turns skip ~0.5s of startup. Cancelling the task terminates the process. |
| `BackgroundAgentJobRunner` | Background tasks: `claude -p` in `~/Library/Application Support/ClickyLocal/agent-jobs/<job>/` with `--permission-mode dontAsk`, Bash sandboxed (writes only in the job folder), Write/Edit limited to `./**`, web search/fetch allowed, credential paths unreadable, no MCP. The brief goes in over stdin so it can't be read as a flag. Progress, result and output files are tracked; `job.json` uses the same keys as the old bridge, and jobs that were running when Clicky quit come back as "interrupted". |
| `MacSystemVoiceSpeechAudioSource` | `say -o file.wav` per sentence (~1–2s, so sentences render while earlier ones play). |
| `ChildProcessRunner` | Runs a program to completion (stdin text, time limit, cancellation) or streams its output lines. Pipe writes never raise SIGPIPE. |

### Local Bridge (optional)

`local-bridge/server.mjs` (Node, no dependencies) serves the same jobs over HTTP: `/chat`, `/tts` (ElevenLabs if configured, else `say`), `/agent/jobs`, `/config`, `/transcribe-token`. The app only uses it when launched with `CLICKY_BRIDGE_URL` (for example `CLICKY_BRIDGE_PORT=8790 node local-bridge/server.mjs`, then `open --env CLICKY_BRIDGE_URL=http://127.0.0.1:8790 …`), which is handy for tests and for ElevenLabs voices. It rejects requests with an `Origin` header (browsers) or that aren't `application/json`, and has extended thinking off unless `CLICKY_CLAUDE_THINKING=1`.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Screen Sketching**: Drawings are rendered natively in the cursor overlay (`ScreenSketchLayer`, a SwiftUI `Canvas`) — no web view. `ScreenSketchGeometry` turns each mark into dense polylines with a slow, seeded "hand wobble" (rings overshoot their start, arrows bow, boxes overrun the corner) plus a pen timeline, so the drawing can be revealed by progress and the triangle's tip can trace it. Labels are handwritten (Noteworthy) on small paper tags. The overlay is a separate window composited with plain alpha, so blend modes can't reach other apps: highlights over dark backgrounds get a faint wash plus a solid underline instead (`ScreenshotBrightnessSampler` decides). `ScreenTextRecognizer` (Apple Vision OCR) runs on the screenshot while Claude is thinking and is used two ways: `ScreenSketchTargetSnapper` moves a ring/highlight/cross/point onto the on-screen text its label names when Claude clearly missed it (never region-sized boxes), and label placement avoids covering recognized text. Drawings stay until the user clicks or scrolls after the walkthrough ends, talks again, or 90s pass; if the user clicks or scrolls between the screenshot and the answer, marks are skipped (they'd land on a moved screen).

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1980 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the chat backend, speech, background tasks and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model and thinking settings, open at login, Claude Code setup state, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → speech → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~270 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. When the icon is hidden behind the notch (a full menu bar), the panel opens at the top right of the screen; opening Clicky again from Spotlight or the Finder shows it (`applicationShouldHandleReopen`). |
| `CompanionPanelView.swift` | ~380 | SwiftUI panel content for the menu bar dropdown: status, the two shortcuts as keycaps, background tasks, settings (model, think before answering, open at login), Setup and Quit. When something blocks Clicky (Claude Code missing or signed out, a permission off, setup unfinished), one card says what and opens setup. |
| `SetupWindow.swift` | ~575 | `SetupWindowController` (the window) and `SetupView`, the first-run checklist: connect Claude Code (install or sign in through Terminal), allow access (each permission with its reason), say hi (live keycaps and status), then example questions. Also `ClaudeCodeTerminalCommands`. |
| `GuidedStepCardDeck.swift` | ~165 | Step card state (show, tick off, replace a step that was never done, closing note, clear), card text from an answer, and which screen corner keeps clear of the target. No UI, so the standalone tests cover it. |
| `GuidedStepCardsView.swift` | ~160 | Draws the step cards in the cursor overlay on the walkthrough's screen. |
| `InkAndKeycapViews.swift` | ~390 | `AppIdentity.displayName` (the product name in one place), `InkMarkView` (hand-drawn check/ring from the sketch engine, drawn with the pen), `CompanionCursorMark`, `KeycapView`/`ShortcutKeycaps`, and the panel's buttons, switch and segmented choice. |
| `OverlayWindow.swift` | ~1230 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~295 | Messages API client (SSE streaming) for an HTTP bridge or Worker, used when `CLICKY_BRIDGE_URL` is set. Conforms to `CompanionChatBackend`. |
| `ClaudeCodeCLI.swift` | ~370 | Finding, configuring and checking the Claude Code CLI, the stream-json message format, output parsing and failure classification (see "Claude Code engine"). |
| `ClaudeCodeChatClient.swift` | ~340 | `CompanionChatBackend` protocol, the Claude Code voice-answer client, `StartedClaudeProcess` and `WaitingClaudeProcessPool`. |
| `ChildProcessSupport.swift` | ~180 | `ChildProcessRunner` (run to completion, stream lines, safe stdin writes), `OutputLineSplitter`, `LockedTextBuffer`. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `ScreenSketch.swift` | ~1400 | Screen sketching core: `ClaudeVisualTagParser` (POINT + DRAW tags → ordered visual beats and clean spoken text), `ScreenSketchGeometry` (hand-drawn strokes, pen timeline, label placement), `ScreenshotBrightnessSampler`. Pure Foundation/AppKit so it's testable without the app. |
| `ScreenSketchLayer.swift` | ~130 | SwiftUI `Canvas` that renders drawings at their current pen progress, including paper-tag labels. |
| `ScreenTextRecognizer.swift` | ~215 | Vision OCR of screenshots plus `ScreenSketchTargetSnapper`, which corrects marks that missed the text they name. |
| `StreamingAnswerSegmenter.swift` | ~115 | Splits a streaming answer into sentences to speak and POINT/DRAW/AGENT tags, each tag attached to the sentence it follows. |
| `CompanionSentenceSpeaker.swift` | ~240 | Sentence-by-sentence speech with per-sentence start callbacks: `PrefetchedAudioSentenceSpeaker` over a `SentenceSpeechAudioSource` (`MacSystemVoiceSpeechAudioSource`, the default, or `ElevenLabsTTSClient` through a bridge) and `SystemVoiceSentenceSpeaker` (AVSpeechSynthesizer). |
| `BackgroundAgentJobs.swift` | ~120 | Background agent job model, `[AGENT:title\|brief]` parser, the `BackgroundAgentJobService` protocol, and the HTTP bridge client. |
| `BackgroundAgentJobRunner.swift` | ~395 | Runs background tasks in the app (see "Claude Code engine"). |
| `DictationTextInserter.swift` | ~110 | fn+control dictation: `DictationTextCleaner` (filler words, spacing, capitalization) and `FocusedFieldTextInserter` (paste + clipboard restore). |
| `scripts/sketch-tests/main.swift` | ~580 | Standalone tests for the tag parser, geometry, label placement, snapping, OCR (on `fixtures/codex-app-screenshot.jpg`), change detection, streaming segmenter, agent tags, dictation cleanup, user ink, and the Claude Code engine's pure logic. Run `scripts/run-sketch-tests.sh`. |
| `scripts/render-ui-gallery.sh` | | Renders the setup window and panel in several states to PNGs with a stand-in manager (`scripts/ui-gallery/`). |
| `scripts/check-claude-code-engine.sh` | | Exercises the engine outside the app with a Finder-like environment: sign-in check, two answers, cancellation, voice. Uses a little Claude usage. |
| `scripts/check-answer-length.sh` | | Asks Claude Code fixed voice questions (fixture screenshots in `scripts/sketch-tests/fixtures/`) with the real prompt and reports answer lengths. Uses a little Claude usage. |
| `scripts/render-app-icon.sh` | | Draws the app icon (`scripts/app-icon/main.swift`) into the asset catalog. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |
| `local-bridge/server.mjs` | ~850 | Optional HTTP bridge with the same jobs as the in-app engine (see "Local Bridge (optional)"). Config via `local-bridge/.env`. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc. (An unsigned compile-only check into a throwaway `-derivedDataPath` that is never launched is harmless.)

### Testing screen sketching

```bash
scripts/run-sketch-tests.sh          # parser, geometry, snapping, OCR, engine logic — no Xcode needed
scripts/render-ui-gallery.sh OUT     # setup window and panel in several states, as PNGs
scripts/check-claude-code-engine.sh  # the real Claude Code engine outside the app (uses a little usage)
scripts/check-answer-length.sh       # how long answers are with the current prompt (uses a little usage)
```

Debug builds launched with `CLICKY_DEBUG_AUTOMATION=1` (e.g. `open --env CLICKY_DEBUG_AUTOMATION=1 --env NSUnbufferedIO=YES --stdout /tmp/clicky.log Clicky.app`) listen for distributed notifications so a terminal can drive the whole pipeline: `com.clicky.debug.ask` (userInfo `text`: ask Claude as if spoken), `com.clicky.debug.present` (`text`: show and speak a canned answer with tags, no Claude), `com.clicky.debug.snapshot` (`name`: save the main display *including* the overlay to `~/Library/Caches/<bundle id>/debug-snapshots/`), `com.clicky.debug.click` (`x`,`y`: a click at a global point, for guided steps), `com.clicky.debug.dictate` (`text`: type it into the focused field), `com.clicky.debug.ink` (`points`: "x,y x,y …", the user's ink as if drawn), `com.clicky.debug.clear`. `CLICKY_BRIDGE_URL` points the app at an HTTP bridge instead of running Claude Code itself. They're off by default because the snapshot hook would otherwise let any local process capture the screen through Clicky's permission.

## Local Bridge (optional)

```bash
CLICKY_BRIDGE_PORT=8790 node local-bridge/server.mjs   # only for tests or ElevenLabs; the app doesn't need it
```

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
