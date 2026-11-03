# Mose

A Mac companion that lives next to your cursor. Hold Control and Option, ask about anything on your screen, and it answers out loud and draws on the screen to show you: it circles things, points with arrows, and walks you through tasks one click at a time. It runs on your own Claude Code sign-in, so there are no API keys and nothing else to set up.

**[Download Mose for Mac](https://github.com/ye-we/mose/releases/latest)**

Mose grew out of [Clicky](https://github.com/farzaa/clicky) by Farza, which is MIT licensed. Farza's newer version is the separate commercial app [HeyClicky](https://www.heyclicky.com/); Mose isn't affiliated with it.

![The original Clicky, which Mose grew out of, pointing at things on screen](clicky-demo.gif)

## What it does

- **Answers about your screen, out loud.** Short answers, one or two sentences, in your Mac's own voice. It starts talking as soon as the first sentence is ready.
- **Draws on your screen.** Circles, boxes, arrows, underlines, highlights and short handwritten notes, drawn with its cursor as the pen while it talks.
- **Guided steps.** Ask how to do something and it marks the one thing to click next. Click it and it looks again and shows the next step, one click at a time. Each step also stays pinned as a small card in a corner, and gets a check when you've done it.
- **Devil mode.** Turn it on in Mose's panel and say "do it for me": Mose clicks, double-clicks, right-clicks, drags, scrolls, types and presses shortcuts for you, one step at a time, flying its cursor to each spot first. Press Esc or move your mouse and it stops at once. Before anything that sends, posts, buys, pays, deletes, submits, publishes, shares or invites, it asks and waits for your "yes". It never types into password fields or touches its own windows. Off by default; when you only ask how, it still shows you instead.
- **Conversations and memory.** It follows the conversation you're having, and remembers lasting things about you between conversations (the apps you use, what you're working on, anything you ask it to remember). You can read, search and delete all of it.
- **Background tasks.** Ask it to research something or make a file ("make me a one page PDF comparing…") and a separate Claude Code session does it while you carry on. It tells you when it's done. Its shell commands are sandboxed to its own folder, and it can use the apps you've connected to Claude Code (Gmail, Google Drive, Notion…) only if you turn them on one by one.
- **Dictation anywhere.** Hold fn and Control, talk, let go, and the text is typed wherever your cursor is.
- **Show it what you mean.** While holding Control and Option, drag the mouse to circle something; it sees what you marked.

## Install

You need macOS 14.2 or later and a Claude plan (Pro, Max, Team or Enterprise) for [Claude Code](https://claude.com/claude-code). If Claude Code isn't installed yet, Mose's setup installs it for you.

1. [Download the DMG](https://github.com/ye-we/mose/releases/latest), open it and drag **Mose** into **Applications**.
2. Open Mose. macOS says it can't verify the app, because it isn't notarized by Apple. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to the message about Mose, click **Open Anyway** and confirm. You only do this once; updates open normally.
4. The setup window walks you through signing in to Claude Code, the permissions it needs, and saying hi once.

Rather use Terminal for step 3? `xattr -dr com.apple.quarantine /Applications/Mose.app` does the same thing.

Mose sits in the Dock: click its icon for the panel, or right-click it to quit. There's also a small triangle in the menu bar that opens the same panel.

### Conversations, and what's kept

Everything you say and every answer is saved in conversations on your Mac, in `~/Library/Application Support/com.yewe.mose/Conversations/`, one file each, as text: screenshots aren't kept (see Privacy). A conversation only leaves your Mac as context for the next answer, sent to Claude through your own Claude Code sign-in; long ones are sent as the recent exchanges plus a short summary of the start.

- Say **"new chat"**, **"start a new session"** or **"start over"** to begin fresh (add a question after it and it's answered in the new one). After 30 minutes of quiet, your next question starts a new conversation by itself.
- Say **"go back to the chat about…"** or **"continue my last conversation"** to pick an older one up again, or open **History** from Mose's panel to read, search, continue or delete conversations.

### Memory

Mose keeps a short list of lasting facts about you, so you don't have to repeat yourself in every conversation. Say **"remember that…"** to add one, or **"forget that…"** / **"forget everything you know about me"** to remove them. When a conversation ends, it also looks through it once for anything lasting, like the apps you use or what you're working on; passing questions, errors and anything sensitive are left out. The list is saved on your Mac (`Memory.json` next to the conversations) and sent with each question. **History → Memory** shows every fact and where it came from, deletes any of them, and turns memory off.

### Apps for background tasks

Background tasks can use the apps you've connected to Claude Code, such as Gmail, Google Calendar, Google Drive or your own MCP servers, but only the ones you turn on under **Apps for background tasks** in Mose's panel. All of them start off. A task reads what it needs and creates things (a draft, a document) only when you ask; it's told never to send, share, delete or pay, but that's an instruction to the model, not a lock, so only turn on apps you'd trust it with.

### Privacy

Mose has no server, and it looks at as little as it can.

- **Screenshots** are taken only when you let go of Control + Option, and for the next step of a walkthrough or of devil mode. Each one shows only the display your mouse is on (without Mose's own windows), shrunk to 1280 pixels, and goes to Claude only through your own Claude Code sign-in. They're never kept: voice answers hold them in memory and tell Claude Code not to save the session, and a background task gets a copy in its folder only while it runs, deleted when it ends.
- **Keys:** the hotkey listener only sees Control, Option and fn going down and up, never what you type. While devil mode is driving, it also watches for Esc and for your mouse, so it can stop.
- **What's kept** is text: your conversations and memory, in files on your Mac, which you can read and delete in History.

Analytics and auto-updates are off.

### The permissions, and why

- **Microphone**: to hear you while you hold the keys.
- **Accessibility**: for the hotkeys, to type what you dictate, and for devil mode's clicks and keys.
- **Screen Recording**: to see your screen when you ask. It only takes a screenshot when you use the hotkey.
- **Screen capture**: macOS confirms once more before an app can capture the screen.

## Using it

| | |
|---|---|
| Hold **Control + Option** | Talk about your screen. Let go to send. |
| Hold **fn + Control** | Type with your voice in any text field. |
| Drag while holding **Control + Option** | Circle something to show what you mean. |
| **Esc**, or move the mouse | Stop devil mode while Mose is clicking and typing. |

The panel (click Mose in the Dock) shows what Mose is doing and any background tasks, and has the settings: the model (Haiku is fastest, Sonnet is the default, Opus is the most capable), "Think before answering" (off by default, since it can add many seconds before Mose starts talking), devil mode (off by default), the apps background tasks may use, and open at login.

## Build it yourself

1. Install and sign in to Claude Code (`claude auth status` should say you're logged in).
2. Open `leanring-buddy.xcodeproj` in Xcode, pick your own team under Signing & Capabilities, and hit **Cmd + R**. The scheme is `leanring-buddy`; the typo is legacy and stays.

To make a DMG for other people, run `scripts/build-shareable-dmg.sh`. It signs with your free Apple Development certificate (any Apple ID added to Xcode has one), so people see the one-time "Open Anyway" step above but keep their permissions across updates. The shared copy has its own bundle id (`com.yewe.mose`), separate from the one you run from Xcode. Removing the warning needs a paid Apple Developer ID and notarization.

Tests and checks, none of which need Xcode:

```bash
scripts/run-sketch-tests.sh          # parser, drawing geometry, OCR snapping, engine and step-card logic
scripts/render-ui-gallery.sh OUT     # setup window, panel and step cards in several states, as PNGs
scripts/check-claude-code-engine.sh  # the Claude Code engine outside the app (uses a little Claude usage)
scripts/check-answer-length.sh       # answer lengths and guided-step targets with the current prompt (uses a little usage)
scripts/check-memory.sh              # remembering, forgetting and learning with the current prompts (uses a little usage)
scripts/check-devil-mode.sh          # devil mode's actions on fixture screenshots, asking before sending (uses a little usage)
```

## How it works

A Dock app with two kinds of windows: the panel, and a full-screen transparent overlay per display where the blue cursor flies and draws. Holding the hotkey records your voice with Apple Speech; letting go sends the transcript and a screenshot to Claude by running the Claude Code CLI (`claude -p`) on your sign-in, with tools, plugins and extended thinking turned off so it answers fast. The answer streams back, each sentence is spoken with macOS `say` as soon as it's complete, and tags in the answer (`[POINT:…]`, `[DRAW:…]`, `[AGENT:…]`, `[REMEMBER:…]`) become cursor flights, drawings, background tasks and memories, each timed to its sentence. In devil mode, action tags (`[CLICK:…]`, `[TYPE:…]`, `[KEY:…]` and the rest) become real clicks and keys, posted as marked CGEvents one step at a time. `AGENTS.md` has the full breakdown.

```
leanring-buddy/                  Swift source
  CompanionManager.swift           the central state machine
  ClaudeCodeCLI.swift              finding, checking and talking to Claude Code
  ClaudeCodeChatClient.swift       voice answers through claude -p
  BackgroundAgentJobRunner.swift   background tasks
  AgentConnectedApps.swift         which connected apps background tasks may use
  ConversationSessions.swift       saved conversations
  UserMemory.swift                 memory across conversations
  ScreenSketch*.swift              drawing on the screen
  GuidedStepCard*.swift            pinned step cards
  DevilMode*.swift                 devil mode: action tags, safety checks, posting clicks and keys
  SetupWindow.swift                first-run setup
  CompanionPanelView.swift         the panel
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

Built on [Clicky](https://github.com/farzaa/clicky) by [Farza](https://x.com/farzatv), MIT licensed. Mose is MIT licensed too; see `LICENSE`.
