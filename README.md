# Clicky (working name)

A Mac companion that lives next to your cursor. Hold Control and Option, ask about anything on your screen, and it answers out loud and draws on the screen to show you: it circles things, points with arrows, and walks you through tasks one click at a time. It runs on your own Claude Code sign-in, so there are no API keys and nothing else to set up.

This is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza, which is MIT licensed. Farza's newer version is the separate commercial app [HeyClicky](https://www.heyclicky.com/); this project isn't affiliated with it.

![The original Clicky, pointing at things on screen](clicky-demo.gif)

## What it does

- **Answers about your screen, out loud.** Short answers, one or two sentences, in your Mac's own voice. It starts talking as soon as the first sentence is ready.
- **Draws on your screen.** Circles, boxes, arrows, underlines, highlights and short handwritten notes, drawn with its cursor as the pen while it talks.
- **Guided steps.** Ask how to do something and it marks the one thing to click next. Click it and it looks again and shows the next step. Each step also stays pinned as a small card in a corner, and gets a check when you've done it.
- **Background tasks.** Ask it to research something or make a file ("make me a one page PDF comparing…") and a separate Claude Code session does it while you carry on. It tells you when it's done. Its shell commands are sandboxed to its own folder.
- **Dictation anywhere.** Hold fn and Control, talk, let go, and the text is typed wherever your cursor is.
- **Show it what you mean.** While holding Control and Option, drag the mouse to circle something; it sees what you marked.

## Install

You need macOS 14.2 or later and a Claude plan (Pro, Max, Team or Enterprise) for [Claude Code](https://claude.com/claude-code). If Claude Code isn't installed yet, Clicky's setup installs it for you.

1. Open the DMG and drag **Clicky** into **Applications**.
2. Open Clicky. macOS says it can't verify the app, because it isn't notarized by Apple. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to the message about Clicky, click **Open Anyway** and confirm. You only do this once; updates open normally.
4. The setup window walks you through signing in to Claude Code, the permissions it needs, and saying hi once.

Rather use Terminal for step 3? `xattr -dr com.apple.quarantine /Applications/Clicky.app` does the same thing.

Clicky lives in the menu bar, not the Dock. If your menu bar is too full to show its icon (common on Macs with a notch), open Clicky again from Spotlight and its panel appears.

### Conversations, and what's kept

Everything you say and every answer is saved in conversations on your Mac, in `~/Library/Application Support/com.yewe.clicky/Conversations/`, one file each. Screenshots are never saved. A conversation only leaves your Mac as context for the next answer, sent to Claude through your own Claude Code sign-in; long ones are sent as the recent exchanges plus a short summary of the start.

- Say **"new chat"**, **"start a new session"** or **"start over"** to begin fresh (add a question after it and it's answered in the new one). After 30 minutes of quiet, your next question starts a new conversation by itself.
- Say **"go back to the chat about…"** or **"continue my last conversation"** to pick an older one up again, or open **History** from the menu bar panel to read, search, continue or delete conversations.

### The permissions, and why

- **Microphone**: to hear you while you hold the keys.
- **Accessibility**: for the hotkeys, and to type what you dictate.
- **Screen Recording**: to see your screen when you ask. It only takes a screenshot when you use the hotkey.
- **Screen capture**: macOS confirms once more before an app can capture the screen.

## Using it

| | |
|---|---|
| Hold **Control + Option** | Talk about your screen. Let go to send. |
| Hold **fn + Control** | Type with your voice in any text field. |
| Drag while holding **Control + Option** | Circle something to show what you mean. |

The menu bar panel shows what Clicky is doing and any background tasks, and has the settings: the model (Haiku is fastest, Sonnet is the default, Opus is the most capable), "Think before answering" (off by default, since it can add many seconds before Clicky starts talking), and open at login.

## Build it yourself

1. Install and sign in to Claude Code (`claude auth status` should say you're logged in).
2. Open `leanring-buddy.xcodeproj` in Xcode, pick your own team under Signing & Capabilities, and hit **Cmd + R**. The scheme is `leanring-buddy`; the typo is legacy and stays.

To make a DMG for other people, run `scripts/build-shareable-dmg.sh`. It signs with your free Apple Development certificate (any Apple ID added to Xcode has one), so people see the one-time "Open Anyway" step above but keep their permissions across updates. The shared copy has its own bundle id (`com.yewe.clicky`), separate from the one you run from Xcode. Removing the warning needs a paid Apple Developer ID and notarization.

Tests and checks, none of which need Xcode:

```bash
scripts/run-sketch-tests.sh          # parser, drawing geometry, OCR snapping, engine and step-card logic
scripts/render-ui-gallery.sh OUT     # setup window, panel and step cards in several states, as PNGs
scripts/check-claude-code-engine.sh  # the Claude Code engine outside the app (uses a little Claude usage)
scripts/check-answer-length.sh       # how long answers are with the current prompt (uses a little usage)
```

## How it works

A menu bar app with two kinds of windows: the dropdown panel, and a full-screen transparent overlay per display where the blue cursor flies and draws. Holding the hotkey records your voice with Apple Speech; letting go sends the transcript and a screenshot to Claude by running the Claude Code CLI (`claude -p`) on your sign-in, with tools, plugins and extended thinking turned off so it answers fast. The answer streams back, each sentence is spoken with macOS `say` as soon as it's complete, and tags in the answer (`[POINT:…]`, `[DRAW:…]`, `[AGENT:…]`) become cursor flights, drawings and background tasks, each timed to its sentence. `AGENTS.md` has the full breakdown.

```
leanring-buddy/                  Swift source
  CompanionManager.swift           the central state machine
  ClaudeCodeCLI.swift              finding, checking and talking to Claude Code
  ClaudeCodeChatClient.swift       voice answers through claude -p
  BackgroundAgentJobRunner.swift   background tasks
  ScreenSketch*.swift              drawing on the screen
  GuidedStepCard*.swift            pinned step cards
  SetupWindow.swift                first-run setup
  CompanionPanelView.swift         the menu bar panel
  OverlayWindow.swift              the cursor overlay
local-bridge/                    optional HTTP bridge for tests and ElevenLabs voices
worker/                          optional Cloudflare Worker for API keys
scripts/                         tests, checks, the icon and the DMG build
AGENTS.md                        the full architecture doc (CLAUDE.md links to it)
```

## Using API keys instead

The original setup still works: a Cloudflare Worker in `worker/` holds your Anthropic and ElevenLabs keys (and AssemblyAI's, if you switch `VoiceTranscriptionProvider` in `Info.plist` to it), and the app answers and speaks through it when launched with `CLICKY_BRIDGE_URL` set to its URL.

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler deploy
```

`local-bridge/server.mjs` serves the same routes on your own Mac with your Claude Code sign-in, which is handy for testing (`CLICKY_BRIDGE_PORT=8790 node local-bridge/server.mjs`, then launch the app with `CLICKY_BRIDGE_URL=http://127.0.0.1:8790`) and for ElevenLabs voices.

## Credits

Built on [Clicky](https://github.com/farzaa/clicky) by [Farza](https://x.com/farzatv), MIT licensed. See `LICENSE`.
