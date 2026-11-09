# Mose - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Mose is a fork of Clicky (github.com/farzaa/clicky, MIT). The product name lives in one constant, `AppIdentity.displayName`, plus `PRODUCT_NAME` and the Info.plist strings; internal names (types like `ClickyAnalytics`, `CLICKY_*` environment variables, `com.clicky.debug.*` notifications, settings keys, the dev bundle id `com.yewe.clicky-local`) still say Clicky on purpose, so settings and permissions carry over.

macOS companion app with a Dock icon and a small menu bar icon, and no main window. Clicking either one (or ⌘, in its app menu) opens a custom floating panel with status, shortcuts, background tasks and settings; a setup window walks new users through connecting Claude Code and the permissions. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it with Apple Speech, and sends the transcript + a screenshot of the user's screen to Claude through the user's own Claude Code CLI (no API keys, no server). Claude's answer streams back and is spoken sentence by sentence in the Mac's system voice. A blue cursor overlay can fly to, point at and draw on UI elements Claude references on the screen the mouse is on.

The original API-key path (a Cloudflare Worker proxy) still works by pointing `CLICKY_BRIDGE_URL` at it.

## Architecture

- **App Type**: A regular Dock app (no `LSUIElement`) plus a menu bar status item, no main window. It used to be menu bar only, but on notch Macs the tiny icon was easy to lose; the Dock icon is always there, opens the panel on click (`applicationShouldHandleReopen`) and quits from its right-click menu. The empty SwiftUI `Settings` scene's menu item is replaced so ⌘, opens the panel.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: the Claude Code CLI, run by the app (`ClaudeCodeChatClient`: `claude -p` with stream-json in and out, the user's sign-in, tools/MCP/settings off, extended thinking off unless the user turns it on). Model picker: Haiku, Sonnet (default) or Opus, mapped to Claude Code's aliases. With `CLICKY_BRIDGE_URL` set, `ClaudeAPI` sends Messages API requests to that bridge or Worker instead (`CompanionChatBackend` covers both).
- **Speech-to-Text**: Apple Speech (`VoiceTranscriptionProvider` = `apple`); AssemblyAI and OpenAI providers remain for the Worker path
- **Text-to-Speech**: macOS `say` with the system voice (often a Siri voice), rendered per sentence and played back to back (`MacSystemVoiceSpeechAudioSource` + `PrefetchedAudioSentenceSpeaker`); ElevenLabs only through a bridge
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), only the display the mouse is on (other monitors are left out so Mose sees as little as it can; the overlay still works on every display)
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap, which only listens to modifier changes for modifier-only shortcuts like ctrl + option (key presses only for the space-bar options), so it never sees what's typed.
- **Privacy**: see as little as possible. Screenshots stay in memory (voice answers run with `--no-session-persistence`; a background task's copy is deleted when it ends); what's kept is text (conversations, memory, job records). Devil mode reads the front window's title only when pressing a key, to tell whether return would send.
- **Element Pointing & Screen Sketching**: Claude embeds `[POINT:x,y:label:screenN]` and `[DRAW:kind numbers label="..." color=... screen=N]` tags inline, right after the sentence each one goes with (kinds: circle, box, arrow, underline, highlight, cross, check, path, text). `ClaudeVisualTagParser` turns them into ordered "visual beats"; `CompanionManager` shows beat 1 immediately and the rest timed to the TTS audio; the overlay plays beats one at a time from a queue, flying straight from one to the next, with the cursor acting as the pen for drawings. See "Screen Sketching" below.
- **Guided Steps**: For how-tos, Claude gives one step at a time and marks the next click with `[DRAW:target ...]` (an orange numbered ring). The user's next left click (on target, or anywhere in the same app) makes Clicky wait 0.8s for the UI to settle, re-screenshot, and ask Claude for the next step with a "(guided step) i clicked …" turn, up to 10 automatic steps per question. Clicks in other apps are ignored; a right-click counts too ("i right-clicked …"). One click per answer: an answer that says a click without marking it, like "open system settings from the apple menu" (`GuidedStepAnswerCheck`), doesn't end the walkthrough. Once it's been said, Claude gets a fresh screenshot and is asked once to mark only that first click, or to reply with a silent `[POINT:none]` when it isn't on screen. Each step also becomes a pinned step card (`GuidedStepCardDeck` + `GuidedStepCardsView`) in a screen corner away from the target: it goes up with its ring, gets a green check the moment the target is clicked, and the walkthrough's last answer stays as a closing note for 8s. Asking something new clears the cards.
- **Devil Mode** (1.1): with the panel's "Devil mode" switch on (off by default, `isDevilModeEnabled`), "do it for me" requests are done by Mose instead of shown. Claude writes action tags like DRAW tags (screenshot pixels; a `screen=N` for a display that wasn't captured is refused): `[CLICK:x1,y1,x2,y2 label="..."]`, `[DOUBLECLICK:...]`, `[RIGHTCLICK:...]` (a tight box, clicked in the middle after `ScreenSketchTargetSnapper` snaps it onto the text its label names), `[DRAG:x1,y1,x2,y2 label="..."]`, `[SCROLL:x,y,lines]` (positive is down), `[TYPE:text]` and `[KEY:cmd+s]`. `DevilMode.swift` is the pure part (parser, shortcut parser, `DevilModeActionPlan`, `DevilModeSafetyCheck`, `DevilModeConfirmationReply`, `DevilModeStepBudget`, follow-up wording, AppKit-to-Quartz coordinates); `DevilModeActionPerformer.swift` posts the CGEvents. One step at a time: one click, drag or scroll per answer, and only as its first action (typing and keys may follow, up to four actions); before a pointer action the blue cursor flies there with a bubble ("clicking export"); then 0.8s to settle, a fresh screenshot and a "(devil step) you clicked export. what's next?" turn, up to 15 per request. An answer without actions, or one that ends with a question, ends the run. While it runs, a note at the bottom of the screen says "Mose is driving, press esc to stop" with the current action (`DevilModeDrivingNoteView`). Every posted event carries `DevilModeEventMark` (`.eventSourceUserData` = "Mose"), so the guided-step click monitor, the sketch-clearing monitor and the push-to-talk tap ignore Mose's own input. Safety is in code, not only the prompt: a listen-only tap (`DevilModeTakeoverMonitor`) stops everything on Esc or on the user's own (unmarked) mouse move, click or scroll and says "stopped"; the talk keys stop it silently. Before an action whose label, typed text or on-screen text under the click has a risky word (send, post, buy, pay, delete, submit, publish, share, invite…), or return in a chat or mail app (by bundle id, app name or window title), or cmd+delete, Mose asks "Should I…?" and waits; the user's next push-to-talk "yes" has Claude look again and do it without asking twice, "no" drops it, anything else is a new request. A yes to Claude's own question about a risky step ("should i send it?") approves the next answer the same way. Mose never acts in its own windows (checked with CGWindowList, skipping the overlay) or types while macOS secure input is on (a password field). With devil mode off, a CLICK Claude writes anyway is shown as a guided-step target. Whether it's on goes in the user message (`DevilModeFollowUp.noteForClaude`), since the system prompt must stay fixed. Debug hook: `com.clicky.debug.devil` (`enabled` "1"/"0").
- **Conversations**: every exchange (transcript, answer with tags, time, frontmost app, whether it was a guided-step or devil-step follow-up) is saved in the current conversation, one JSON file per conversation in `~/Library/Application Support/<bundle id>/Conversations/` (`ConversationSessionStore`). Context for each answer is the last 12 exchanges word for word, within ~9,000 characters; once a conversation is longer, Haiku folds the older exchanges into a ≤120-word summary in the background (`ConversationContext`), which goes in the user message (never the system prompt, which must stay fixed for the pre-started process). Exchanges the summary doesn't cover yet stay word for word, capped at two windows. "Start a new session", "new chat", "start over", "forget everything" (optionally followed by a question) and "go back to the chat about X" / "continue my last conversation" are recognized on the Mac (`ConversationVoiceCommand`, `ConversationSearch`); other phrasings get Claude's `[SESSION:new]` tag. After 30 minutes of quiet the next question starts a new conversation; a relaunch within 30 minutes continues the last one. The panel shows the current conversation with New and History; `ConversationHistoryWindow` lists, searches, continues and deletes them.
- **Memory**: lasting facts about the user carry over between conversations (`UserMemory.swift`), saved in `~/Library/Application Support/<bundle id>/Memory.json`, at most 40. "Remember that …" gets Claude's `[REMEMBER:fact about "they"]`; "forget that …" gets `[FORGET:fact]` or `[FORGET:everything]`, applied once the answer is in, and "everything" is ignored in an answer that also says `[SESSION:new]`, since starting over only clears the conversation. When a conversation is over (not current, or quiet past 30 minutes; also checked 20s after launch), Haiku looks through it once for new facts (`+ …`) and ones it shows are out of date (`- …`, dropped only on a close match); `memoryReviewedExchangeCount` on the conversation records how far it got. The facts go first in the user message (`userMemoryNote`, never the system prompt); with memory off, Claude is told it's off instead. The History window's Memory page lists the facts as "you", says where each came from, deletes one or all, and turns memory off.
- **Short answers**: the voice prompt caps answers at one or two sentences (about thirty words) unless the user asks for depth; `scripts/check-answer-length.sh` measures this against fixed questions (median went from 59 to 32 words when the "thorough explanation / plant a seed" rules were removed).
- **Streaming Speech**: `StreamingAnswerSegmenter` cuts Claude's streamed answer into sentences and tags; each sentence is spoken as soon as it completes (`CompanionSentenceSpeaker`: `say` audio by default, since AVSpeechSynthesizer can't use Siri voices and sounds robotic with the compact ones; `SystemVoiceSentenceSpeaker` only while an HTTP bridge's voice is unknown), and each tag's beat is shown when its sentence starts speaking.
- **Background Agents**: `[AGENT:title|brief]` hands real work (research, files) to a separate sandboxed Claude Code session that the app runs itself (`BackgroundAgentJobRunner`); the panel lists jobs, and finished ones are announced aloud. Agents can also use the user's connected apps (their Claude Code MCP servers and claude.ai connectors) that are turned on one by one in the Connected Apps window (`AgentConnectedApps`, `ConnectedAppsWindow`, opened from the panel's "Apps for background tasks" row; the list comes from `claude mcp list`). None are on at first, and then MCP isn't loaded at all (`--strict-mcp-config`). With some on, each gets `mcp__<server>` in `--allowedTools` (Claude Code's naming: "claude.ai Google Calendar" → `mcp__claude_ai_Google_Calendar`), and every other server's tools are refused by `dontAsk`. Not sending, sharing, deleting or paying inside an allowed app is an instruction to the agent, not a lock, and the window says so. The voice answers are told which apps tasks can use, in the same note as memory (`notesAboutUser`).
- **Setup**: `SetupWindow.swift` is the first-run checklist (connect Claude Code, four permissions, say hi once), opened on first launch, when a permission is off, or when Claude Code is missing or signed out, and from the panel. Claude Code's installer and sign-in are interactive, so they run in Terminal via a `.command` file; setup polls `claude auth status --json` until it's done. Finished steps get a hand-drawn check and the current one a hand-drawn ring (`InkMarkView`, built on the sketch engine).
- **Dictation**: hold fn+control to type with your voice into any focused field (`DictationTextInserter`: local cleanup, paste, clipboard restored).
- **User Ink**: while ctrl+option is held the overlay accepts the mouse, so dragging draws red ink; the ink is composited into the screenshot (`UserInkCompositor`) and Claude is told the user drew it. A timer checks four times a second that the keys are really still down (`BuddyPushToTalkShortcut.isPushToTalkShortcutHeldDown`) and gives the mouse back if the release was missed, so a failed push-to-talk can never leave every click drawing ink.
- **Microphone changes**: when the input device changes (headphones connecting), `AVAudioEngine` keeps the old format and `installTap` raises an Objective-C exception, which Swift can't catch and which once wedged the app. `BuddyDictationManager` rebuilds the engine after `AVAudioEngineConfigurationChange` or a format mismatch, and runs the tap setup inside `ObjectiveCExceptionCatcher` (the project's only Objective-C, via `leanring-buddy-Bridging-Header.h`), so any exception becomes an ordinary "couldn't start voice input" error.
- **Updates** (1.2): Sparkle 2.9 (SPM), only in the release copy (`com.yewe.mose`, `AppUpdatePolicy`). The Xcode copy (`com.yewe.clicky-local`) never starts the updater, and its feed is empty anyway: Info.plist's `SUFeedURL` is `$(MOSE_UPDATE_FEED_URL)`, which only the app target's Release configuration sets (https://raw.githubusercontent.com/ye-we/mose/main/appcast.xml). `AppUpdater` starts `SPUStandardUpdaterController` at launch; Sparkle checks about once a day (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400), offers a new version in its own window with the release notes, and installing is one click. A check only fetches the feed: no system profile (`SUEnableSystemProfiling` and `SUSendProfileInfo` false). Updates must carry an EdDSA signature matching `SUPublicEDKey`; the private key is in the releaser's login keychain (`generate_keys --account mose`). "Check for Updates…" sits next to Settings… in the app menu, and "Check for updates" in the panel's footer (it posts `.clickyCheckForUpdates`, so the panel needs no Sparkle). The app isn't sandboxed, so Sparkle's XPC services aren't used; its helpers are ad-hoc signed, so Sparkle replaces the app without its atomic swap, and it copies them into its cache without quarantine, so updates work after a quarantined manual install. An installed update isn't quarantined and opens without "Open Anyway". See "Releasing".
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`, switched off: setup is commented out, and it only runs with a `PostHogAPIKey` in Info.plist (the upstream key that used to be hardcoded is gone).

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
| `ClaudeCodeCLI` | Finds `claude` (common install paths, then the login shell), builds its environment (API key variables removed so the Claude sign-in is used, the shell's PATH so agents find the user's tools), reads `claude auth status --json`, builds the stream-json user message (the memory note first, then earlier turns folded into a transcript), parses output lines, and turns failures into `notSignedIn` / `usageLimitReached` / `failed`. |
| `ClaudeCodeChatClient` | Voice answers. One `claude -p` per turn in an empty temp folder, streamed text passed to the caller. A started process waits per model + system prompt + thinking setting (at most two, replaced after ten minutes), and one is started when the hotkey goes down, so turns skip ~0.5s of startup. Cancelling the task terminates the process. |
| `BackgroundAgentJobRunner` | Background tasks: `claude -p` in `~/Library/Application Support/<bundle id>/agent-jobs/<job>/` with `--permission-mode dontAsk`, Bash sandboxed (writes only in the job folder), Write/Edit limited to `./**`, web search/fetch allowed, credential paths unreadable, MCP only for the apps turned on for background tasks, and `--no-session-persistence` so Claude Code keeps no copy of the session. The screenshot (`tmp/screen.jpg`) is deleted when the job ends, and at launch for older jobs. The brief goes in over stdin so it can't be read as a flag. Progress, result and output files are tracked; `job.json` uses the same keys as the old bridge, and jobs that were running when Clicky quit come back as "interrupted". |
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
| `leanring_buddyApp.swift` | ~145 | App entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager`, starts `CompanionManager` and the updater. No main window: the Dock icon, the menu bar icon and ⌘, open the panel. The app menu has Settings… and, in the release copy, Check for Updates…. |
| `AppUpdatePolicy.swift` | ~70 | Which copy may update itself (the release bundle id with an https feed, or http on 127.0.0.1 for local tests) and the `.clickyCheckForUpdates` notification. No Sparkle, so the standalone tests and the UI gallery use it. |
| `AppUpdater.swift` | ~70 | Sparkle for the release copy: starts `SPUStandardUpdaterController`, publishes `canCheckForUpdates`, and the app menu's `CheckForUpdatesMenuButton`. |
| `CompanionManager.swift` | ~2875 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the chat backend, speech, background tasks, devil mode runs and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model and thinking settings, open at login, Claude Code setup state, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → speech → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~270 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon (the bearded cursor in colour, `CompanionCursorMark` rendered to an image, not a template, so it stands out), manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. When the icon is hidden behind the notch (a full menu bar), the panel opens at the top right of the screen; clicking the Dock icon or opening Clicky again from Spotlight or the Finder shows it (`applicationShouldHandleReopen`). |
| `CompanionPanelView.swift` | ~420 | SwiftUI panel content for the menu bar dropdown: status, the two shortcuts as keycaps, background tasks, settings (model, think before answering, apps for background tasks, open at login), Setup, Check for updates (release copy only) and Quit. When something blocks Clicky (Claude Code missing or signed out, a permission off, setup unfinished), one card says what and opens setup. |
| `SetupWindow.swift` | ~575 | `SetupWindowController` (the window) and `SetupView`, the first-run checklist: connect Claude Code (install or sign in through Terminal), allow access (each permission with its reason), say hi (live keycaps and status), then example questions. Also `ClaudeCodeTerminalCommands`. |
| `ConversationSessions.swift` | ~520 | Saved conversations: models, the JSON store, the context policy (word-for-word window, summary bookkeeping, summarizer prompt), titles, voice commands for starting over and resuming, and search. No UI, so the standalone tests cover it. |
| `ConversationHistoryWindow.swift` | ~670 | The History window (list by day, search, transcript with what Clicky remembers, Continue, Delete), its Memory page (facts, where each came from, delete, on/off), and the panel's current-conversation row. |
| `UserMemory.swift` | ~375 | Memory across conversations: `RememberedFact`, `UserMemoryStore` (Memory.json, on/off, remember, forget, limit), `UserMemoryText` (matching facts, "everything", wording for the user) and `UserMemoryContext` (the note for Claude, Haiku's learning prompt and reply, which conversations to look through). No UI, so the standalone tests cover it. |
| `GuidedStepCardDeck.swift` | ~235 | Step card state (show, tick off, replace a step that was never done, closing note, clear), card text from an answer, which screen corner keeps clear of the target, and `GuidedStepAnswerCheck` (an answer that says a click without a target, and the follow-up that asks for one). No UI, so the standalone tests cover it. |
| `GuidedStepCardsView.swift` | ~160 | Draws the step cards in the cursor overlay on the walkthrough's screen. |
| `DevilMode.swift` | ~685 | Devil mode's pure logic: action tags (`DevilModeAction`, `DevilModeActionTagParser`), key shortcuts (`DevilModeKeyShortcutParser`), which actions of an answer get done (`DevilModeActionPlan`), risky actions and chat apps (`DevilModeSafetyCheck`), the user's yes or no (`DevilModeConfirmationReply`), the 15-step budget, follow-up wording and the note for Claude, coordinates and typing. No UI, so the standalone tests cover it. |
| `DevilModeActionPerformer.swift` | ~330 | Devil mode on the real Mac: `DevilModeEventPoster` (marked CGEvent clicks, double- and right-clicks, drags that always let go, scrolls, keys, typing by key or by paste), `DevilModeScreenInspector` (own windows, frontmost app and window title, secure input) and `DevilModeTakeoverMonitor` (Esc or the user's mouse stops a run). |
| `DevilModeDrivingNoteView.swift` | ~95 | The "Mose is driving, press esc to stop" note in the cursor overlay, with the current action. |
| `InkAndKeycapViews.swift` | ~470 | `AppIdentity.displayName` (the product name in one place), `InkMarkView` (hand-drawn check/ring from the sketch engine, drawn with the pen), `CompanionCursorMark` (the app's mark at any size: the bearded cursor, `UprightCursorTriangleShape` + `BeardedCursorFaceView`, turned -35°; used in the panel header, setup, History, the step cards and the menu bar icon), `BeardedCursorFaceView` (Mose's chin-curtain beard and eyes over the cursor triangle, laid out like the app icon, in a warm brown that still reads on dark backgrounds; brows only when it's 28pt or bigger), `KeycapView`/`ShortcutKeycaps`, and the panel's buttons, switch and segmented choice. |
| `OverlayWindow.swift` | ~1160 | Full-screen transparent overlay hosting the blue cursor (with Mose's face, `BeardedCursorFaceView`, over the same 16pt triangle so the pen tip is unchanged), response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. Each overlay is a non-activating `NSPanel`: since Mose is a regular Dock app, a plain window can't sit over another app's full-screen space. `CompanionManager` rebuilds the overlays when displays change (`didChangeScreenParametersNotification`). |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~115 | Screenshot of the display the mouse is on (ScreenCaptureKit, Mose's own windows excluded, 1280px JPEG). Returned as a one-item array so the pipeline stays the same. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `ObjectiveCExceptionCatcher.h/.m` | ~50 | Runs a block and turns an Objective-C exception into a Swift error (Swift can't catch them). Exposed through `leanring-buddy-Bridging-Header.h` (`SWIFT_OBJC_BRIDGING_HEADER` on the app target). |
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
| `BackgroundAgentJobRunner.swift` | ~430 | Runs background tasks in the app (see "Claude Code engine"). |
| `AgentConnectedApps.swift` | ~110 | Which connected apps background tasks may use: reading `claude mcp list`, Claude Code's tool permission names, the agent's extra instructions and the note for voice answers. No UI, so the standalone tests cover it. |
| `ConnectedAppsWindow.swift` | ~215 | The Connected Apps window: each connected app with a switch for background tasks (all off at first), apps that need signing in on claude.ai, and the warning that limits inside an app are instructions, not locks. |
| `DictationTextInserter.swift` | ~115 | fn+control dictation: `DictationTextCleaner` (filler words, spacing, capitalization) and `FocusedFieldTextInserter` (paste + clipboard restore, also used by devil mode's typing; its ⌘V carries Mose's event mark). |
| `scripts/sketch-tests/main.swift` | ~1310 | Standalone tests for the tag parser, geometry, label placement, snapping, OCR (on `fixtures/codex-app-screenshot.jpg`), change detection, streaming segmenter, agent tags, dictation cleanup, user ink, the Claude Code engine's pure logic, guided-step cards and checks, conversations, memory, devil mode (action tags, shortcuts, one step per answer, risky actions, yes/no, budget, follow-ups, coordinates, typing, never spoken), and updates (which copy updates itself, the appcast item, version rules, and that the repository's `appcast.xml` is a valid feed). Run `scripts/run-sketch-tests.sh`. |
| `scripts/render-ui-gallery.sh` | | Renders the setup window and panel in several states to PNGs with a stand-in manager (`scripts/ui-gallery/`). |
| `scripts/check-claude-code-engine.sh` | | Exercises the engine outside the app with a Finder-like environment: sign-in check, two answers, cancellation, voice. Uses a little Claude usage. |
| `scripts/check-memory.sh` | | Asks Claude Code memory questions with the real prompt (remember, forget, use what's remembered, start over, memory off) and has Haiku learn from two made-up conversations (`scripts/memory-check/`). Uses a little Claude usage. |
| `scripts/check-devil-mode.sh` | | Asks Claude Code "do it for me" questions with the real prompt and the devil mode note on fixture screenshots (`finder-menu-bar.jpg`, and `devil-practice.png` / `devil-practice-message-ready.png` rendered from the practice window) and checks the action tags: the right kind on the right thing, asking before sending, guided steps for "how do i" and with devil mode off. Nothing is clicked. `CLICKY_DEVIL_CHECK_ONLY=text` asks only matching questions. Uses a little Claude usage. |
| `scripts/devil-practice/main.swift` | | A practice window (title "Devil Practice"; buttons, a name field and notes, double-click, right-click and drag targets, a scroll list) that logs every event it gets, with `marked=yes|no` for Mose's mark. The only place live devil mode tests may click or type. `scripts/run-devil-practice.sh [--log PATH] [--quit-after SECONDS]`, or `--render PATH.png [--prefill]` to draw it offscreen as a fixture. |
| `scripts/check-answer-length.sh` | | Asks Claude Code fixed voice questions (fixture screenshots in `scripts/sketch-tests/fixtures/`, including a made-up Finder desktop drawn by `scripts/answer-length-check/render-menu-bar-fixture.swift`) with the real prompt and reports answer lengths, whether how-tos mark the next click, and whether the missing-target follow-up works. Uses a little Claude usage. |
| `install.sh` | | The README's one-line install (`curl -fsSL https://raw.githubusercontent.com/ye-we/mose/main/install.sh \| bash`): reads the newest DMG from `appcast.xml`, downloads it with curl (so it isn't quarantined and macOS asks nothing), checks the app's signature, team ZBYTA87RP2 and bundle id, quits a running Mose, copies it into /Applications (or ~/Applications) and opens it. `MOSE_INSTALL_FOLDER` and `MOSE_INSTALL_DONT_OPEN=1` are for tests. |
| `scripts/build-shareable-dmg.sh` | | Builds a universal Release copy as `com.yewe.mose`, signed with the free Apple Development certificate (no provisioning profile, so it opens on other Macs after a one-time "Open Anyway"), and wraps it in `releases/Mose-<version>.dmg`. The DMG itself is unsigned on purpose: Gatekeeper rejects a quarantined DMG signed with a development certificate before it opens, but opens an unsigned one (checked on macOS 26); Sparkle's EdDSA signature covers the DMG. For local update tests, `VERSION_OVERRIDE`, `BUILD_NUMBER_OVERRIDE`, `UPDATE_FEED_URL` and `DMG_OUTPUT_FOLDER` build an older copy pointed at a local feed without touching the project. |
| `scripts/publish-release.sh` | | A release in two steps (see "Releasing"): `build VERSION BUILD` (bump, DMG, checks, EdDSA signature) and `publish VERSION NOTES.md` (commit, push, GitHub release, download-back check, then the appcast item). |
| `scripts/appcast/` | | `Appcast.swift` (pure: an appcast item's text, adding it newest first, refusing a build number that didn't go up or a version already listed, reading sign_update's output) and `main.swift`, the `appcast add/list/empty` command the release script runs. |
| `appcast.xml` | | Mose's Sparkle feed, served from the main branch on raw.githubusercontent.com. Only `scripts/publish-release.sh` edits it. |
| `scripts/render-app-icon.sh` | | Draws the app icon (`scripts/app-icon/main.swift`: Mose's blue cursor, tilted, with stern brows and a chin-curtain beard, on a light background) into the asset catalog. |
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
scripts/check-answer-length.sh       # answer lengths and guided-step targets with the current prompt (uses a little usage)
scripts/check-memory.sh              # remembering, forgetting and learning with the current prompts (uses a little usage)
scripts/check-devil-mode.sh          # devil mode's action tags on fixture screenshots, asking before sending (uses a little usage)
```

Debug builds launched with `CLICKY_DEBUG_AUTOMATION=1` (e.g. `open --env CLICKY_DEBUG_AUTOMATION=1 --env NSUnbufferedIO=YES --stdout /tmp/clicky.log Mose.app`) listen for distributed notifications so a terminal can drive the whole pipeline: `com.clicky.debug.ask` (userInfo `text`: ask Claude as if spoken), `com.clicky.debug.present` (`text`: show and speak a canned answer with tags, no Claude), `com.clicky.debug.snapshot` (`name`: save the main display *including* the overlay to `~/Library/Caches/<bundle id>/debug-snapshots/`), `com.clicky.debug.click` (`x`,`y`: a click at a global point, for guided steps), `com.clicky.debug.dictate` (`text`: type it into the focused field), `com.clicky.debug.ink` (`points`: "x,y x,y …", the user's ink as if drawn), `com.clicky.debug.clear`, `com.clicky.debug.devil` (`enabled`: "1" or "0", devil mode on or off). Devil mode moves the real mouse, so live tests only ever target the practice window (`scripts/run-devil-practice.sh`). `CLICKY_BRIDGE_URL` points the app at an HTTP bridge instead of running Claude Code itself. They're off by default because the snapshot hook would otherwise let any local process capture the screen through Clicky's permission.

## Releasing

A release is two commands; the second asks nothing more, so try the DMG in between.

```bash
scripts/publish-release.sh build 1.3 5              # versions → DMG → checks → EdDSA signature
scripts/publish-release.sh publish 1.3 notes.md     # commit, push, GitHub release, then the feed
```

- **Versions**: `MARKETING_VERSION` is what people see; `CURRENT_PROJECT_VERSION` is the build number Sparkle compares (`sparkle:version`), so it must go up every release (1.1.2 was build 3, 1.2 build 4). `build` refuses a build number that isn't higher than every one in `appcast.xml`.
- **build** sets both versions in `project.pbxproj`, runs `build-shareable-dmg.sh`, mounts the DMG and checks it (versions, bundle id, the GitHub feed, the public key matching the keychain, profiling off, code signature, no `/Users/` paths, no `com.clicky.debug` hooks, `hdiutil verify`), checks the DMG itself isn't code-signed, then signs it with `sign_update --account mose` (written to `releases/Mose-<version>.dmg.sparkle-signature`) and verifies the signature.
- **publish** commits the version bump ("Release X", when that's the only change; anything else must be committed first), fast-forwards main, pushes both branches as ye-we (retrying GitHub's occasional "Internal Server Error"), runs `gh release create vX --target <full sha> --latest` with the notes, downloads the DMG back and compares SHA-256, and only then adds the appcast item and pushes it, so the feed never offers a DMG that isn't up yet. raw.githubusercontent.com caches for a few minutes.
- **Notes** are markdown: they go on the GitHub release and, inside the appcast item (`<description sparkle:format="markdown">`), in Sparkle's update window.
- **The key**: the EdDSA private key lives only in the login keychain (account `mose`); macOS asks for the login password the first time `sign_update` reads it ("Always Allow"). Never print, log or commit it. A backup: `generate_keys --account mose -x FILE` (the tools are in DerivedData's `SourcePackages/artifacts/sparkle/Sparkle/bin`). Without it no update can be signed again, and every installed copy is stuck on its version.
- **Testing an update locally**: build an older copy with `VERSION_OVERRIDE=1.1.9 BUILD_NUMBER_OVERRIDE=3 UPDATE_FEED_URL=http://127.0.0.1:8765/appcast.xml DMG_OUTPUT_FOLDER=… scripts/build-shareable-dmg.sh`, write a feed with `scripts/appcast` (`empty`, then `add` with the real DMG's sign_update output), serve it with `python3 -m http.server 8765 --bind 127.0.0.1`, quit every other Mose, and run the copy from a writable folder. Check for Updates should install and relaunch; a feed pointing at a different DMG with the same signature must give "The update is improperly signed". The test copy has the release bundle id, so it uses the release copy's settings: remove what it adds afterwards (`SULastCheckTime`, `SUHasLaunchedBefore`, `SUUpdateGroupIdentifier`, `NSWindow Frame SUUpdateAlert2`, `~/Library/Caches/com.yewe.mose`).
- **People on 1.1–1.1.2** have no updater: 1.2 is their last manual update.

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

### Privacy

- Surveil as little as possible. A feature captures, reads and keeps only what it needs, for only as long as it needs it: screenshots stay in memory, listeners watch only the events they act on, and anything saved is text the user can see and delete. Ask before adding anything that watches or stores more.

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
