#!/usr/bin/env node
/**
 * Clicky Local Bridge
 *
 * A drop-in local replacement for the Cloudflare Worker in `worker/`.
 * Instead of calling api.anthropic.com with an API key, `/chat` runs the
 * Claude Code CLI (`claude -p`), so requests use whatever account you're
 * logged into Claude Code with (Pro / Max / Team / Enterprise).
 *
 * Routes (same contract as the worker, so the Swift app doesn't change):
 *   GET  /                  → health check (also answers the app's TLS warmup HEAD)
 *   POST /chat              → Anthropic Messages API request → `claude -p` → Anthropic SSE events
 *   POST /tts               → ElevenLabs if ELEVENLABS_API_KEY is set, otherwise macOS `say` (WAV)
 *   POST /transcribe-token  → AssemblyAI temp token if ASSEMBLYAI_API_KEY is set, otherwise 501
 *
 * Zero npm dependencies. Configuration comes from environment variables or
 * an optional `.env` file next to this script (see `.env.example`).
 */

import http from "node:http";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const bridgeDirectory = path.dirname(fileURLToPath(import.meta.url));

loadDotEnvFileIfPresent(path.join(bridgeDirectory, ".env"));

const bridgeHost = "127.0.0.1";
const bridgePort = Number(process.env.CLICKY_BRIDGE_PORT || 8787);
const claudeBinaryPath = resolveClaudeBinaryPath();

// Optional overrides. By default the model the app picks (Sonnet / Opus) is
// mapped to the Claude Code alias for that family, which always points at the
// newest model your plan has access to.
const claudeModelOverride = process.env.CLICKY_CLAUDE_MODEL || "";
const claudeEffortLevel = process.env.CLICKY_CLAUDE_EFFORT || "";
// Claude Code turns extended thinking on by default, and on screenshots of real
// apps the model uses it: up to ~18s of silence before the first spoken word.
// Voice turns skip it unless CLICKY_CLAUDE_THINKING=1.
const isClaudeThinkingEnabled = process.env.CLICKY_CLAUDE_THINKING === "1";

const macOSSayVoiceName = process.env.CLICKY_SAY_VOICE || "";
const macOSSayWordsPerMinute = process.env.CLICKY_SAY_RATE || "";

// claude -p runs inside an empty scratch folder so it never picks up a
// project CLAUDE.md from wherever the bridge happened to be launched.
const claudeWorkingDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-local-bridge-"));

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = http.createServer(async (request, response) => {
  const requestURL = new URL(request.url, `http://${bridgeHost}:${bridgePort}`);

  // Browsers always attach an Origin header; the Clicky app never does.
  // Rejecting these stops random web pages from spending your Claude usage
  // through a fire-and-forget cross-origin POST to localhost.
  if (request.headers.origin) {
    return sendJSON(response, 403, { error: "Browser requests are not allowed." });
  }

  if (request.method === "GET" || request.method === "HEAD") {
    if (requestURL.pathname === "/") {
      response.writeHead(200, { "content-type": "text/plain" });
      return response.end(request.method === "HEAD" ? undefined : "clicky local bridge ok\n");
    }
    // Lets the app pick its voice: ElevenLabs through the bridge, or the Mac's own
    if (requestURL.pathname === "/config") {
      return sendJSON(response, 200, { tts: isElevenLabsConfigured() ? "elevenlabs" : "macos" });
    }
    if (requestURL.pathname === "/agent/jobs") {
      return sendJSON(response, 200, { jobs: listAgentJobs() });
    }
    return sendJSON(response, 404, { error: "Not found" });
  }

  if (request.method !== "POST") {
    return sendJSON(response, 405, { error: "Method not allowed" });
  }

  try {
    if (requestURL.pathname === "/chat") {
      return await handleChat(request, response);
    }
    if (requestURL.pathname === "/tts") {
      return await handleTextToSpeech(request, response);
    }
    if (requestURL.pathname === "/transcribe-token") {
      return await handleTranscribeToken(response);
    }
    if (requestURL.pathname === "/agent/jobs") {
      return await handleStartAgentJob(request, response);
    }
    const stopAgentJobMatch = requestURL.pathname.match(/^\/agent\/jobs\/([\w-]+)\/stop$/);
    if (stopAgentJobMatch) {
      return handleStopAgentJob(stopAgentJobMatch[1], response);
    }
  } catch (error) {
    console.error(`[${requestURL.pathname}] Unhandled error:`, error);
    if (!response.headersSent) {
      return sendJSON(response, 500, { error: String(error?.message || error) });
    }
    return response.end();
  }

  return sendJSON(response, 404, { error: "Not found" });
});

server.on("error", (serverError) => {
  if (serverError.code === "EADDRINUSE") {
    console.error(`❌ Port ${bridgePort} is already in use. Another bridge is probably running already (check: curl http://${bridgeHost}:${bridgePort}/).`);
    console.error(`   Find it with: lsof -nP -iTCP:${bridgePort} -sTCP:LISTEN`);
    process.exit(1);
  }
  throw serverError;
});

server.listen(bridgePort, bridgeHost, () => {
  console.log(`🟢 Clicky local bridge listening on http://${bridgeHost}:${bridgePort}`);
  console.log(`   claude binary: ${claudeBinaryPath}`);
  console.log(`   chat model:    ${claudeModelOverride || "follows the app's Sonnet/Opus picker"}`);
  console.log(`   thinking:      ${isClaudeThinkingEnabled ? "on (CLICKY_CLAUDE_THINKING=1)" : "off, for faster answers"}`);
  console.log(`   tts:           ${isElevenLabsConfigured() ? "ElevenLabs" : `macOS say${macOSSayVoiceName ? ` (${macOSSayVoiceName})` : ""}`}`);
  console.log(`   transcription: ${process.env.ASSEMBLYAI_API_KEY ? "AssemblyAI tokens available" : "not proxied (app uses Apple Speech)"}`);
  console.log(`   agent jobs:    ${agentJobsDirectory}`);
});

// ---------------------------------------------------------------------------
// /chat → claude -p
// ---------------------------------------------------------------------------

async function handleChat(request, response) {
  if (!isJSONRequest(request)) {
    return sendJSON(response, 415, { error: "Expected application/json" });
  }

  const messagesAPIRequestBody = JSON.parse(await readRequestBody(request));
  const isStreamingRequest = messagesAPIRequestBody.stream === true;
  const claudeModelAlias = mapRequestedModelToClaudeCodeAlias(messagesAPIRequestBody.model);
  const userMessageForClaudeCode = buildClaudeCodeUserMessage(messagesAPIRequestBody.messages || []);

  const claudeArguments = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
    "--model", claudeModelAlias,
    "--system-prompt", systemPromptAsString(messagesAPIRequestBody.system),
    // Clicky only needs a vision + text answer. Turning off tools, MCP servers,
    // user/project settings (hooks, plugins) and slash commands keeps each
    // voice turn fast and stops it from touching anything on your machine.
    "--tools", "",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--disable-slash-commands",
    "--no-session-persistence",
  ];
  if (claudeEffortLevel) {
    claudeArguments.push("--effort", claudeEffortLevel);
  }
  if (!isClaudeThinkingEnabled) {
    claudeArguments.push("--settings", JSON.stringify({ alwaysThinkingEnabled: false }));
  }

  const requestStartTime = Date.now();
  const { claudeProcess, wasAlreadyStarted } = takeStartedClaudeProcess(claudeArguments);

  // The app cancels the in-flight request when you start talking again.
  // Kill the CLI too so it stops spending usage on an answer nobody will hear.
  let didClientDisconnect = false;
  response.on("close", () => {
    if (!response.writableFinished) {
      didClientDisconnect = true;
      claudeProcess.kill("SIGTERM");
    }
  });

  claudeProcess.stdin.end(JSON.stringify(userMessageForClaudeCode) + "\n");

  let standardErrorOutput = "";
  claudeProcess.stderr.on("data", (chunk) => {
    standardErrorOutput += chunk.toString();
  });

  let accumulatedResponseText = "";
  let claudeCodeResultEvent = null;
  // Headers are held back until the first streamed token so that a CLI failure
  // (not logged in, usage limit hit) can still be reported as a real HTTP error.
  let hasStartedStreamingResponse = false;
  let partialStandardOutputLine = "";

  claudeProcess.stdout.on("data", (chunk) => {
    partialStandardOutputLine += chunk.toString();
    const completeLines = partialStandardOutputLine.split("\n");
    partialStandardOutputLine = completeLines.pop();

    for (const outputLine of completeLines) {
      if (!outputLine.trim()) continue;

      let claudeCodeEvent;
      try {
        claudeCodeEvent = JSON.parse(outputLine);
      } catch {
        continue;
      }

      if (claudeCodeEvent.type === "result") {
        claudeCodeResultEvent = claudeCodeEvent;
        continue;
      }

      if (claudeCodeEvent.type !== "stream_event") continue;

      // With --include-partial-messages the CLI forwards the raw Anthropic
      // streaming events, which is exactly what ClaudeAPI.swift parses.
      const anthropicStreamEvent = claudeCodeEvent.event;
      if (
        anthropicStreamEvent.type === "content_block_delta" &&
        anthropicStreamEvent.delta?.type === "text_delta"
      ) {
        accumulatedResponseText += anthropicStreamEvent.delta.text;
      }

      if (isStreamingRequest && !didClientDisconnect) {
        if (!hasStartedStreamingResponse) {
          response.writeHead(200, {
            "content-type": "text/event-stream",
            "cache-control": "no-cache",
          });
          hasStartedStreamingResponse = true;
        }
        response.write(`event: ${anthropicStreamEvent.type}\ndata: ${JSON.stringify(anthropicStreamEvent)}\n\n`);
      }
    }
  });

  const claudeProcessExitCode = await new Promise((resolve) => {
    claudeProcess.on("close", (exitCode) => resolve(exitCode));
    claudeProcess.on("error", (spawnError) => {
      standardErrorOutput += String(spawnError);
      resolve(-1);
    });
  });

  if (didClientDisconnect) {
    console.log(`[/chat] cancelled by app after ${Date.now() - requestStartTime}ms`);
    return;
  }

  const claudeCodeErrorMessage = describeClaudeCodeFailure(claudeProcessExitCode, claudeCodeResultEvent, standardErrorOutput);
  const elapsedMilliseconds = Date.now() - requestStartTime;

  if (claudeCodeErrorMessage) {
    console.error(`[/chat] claude failed after ${elapsedMilliseconds}ms: ${claudeCodeErrorMessage}`);
    if (hasStartedStreamingResponse) {
      // Too late for a status code; send an Anthropic-style error event instead.
      response.write(`event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "api_error", message: claudeCodeErrorMessage } })}\n\n`);
      return response.end();
    }
    return sendJSON(response, 502, { type: "error", error: { type: "api_error", message: claudeCodeErrorMessage } });
  }

  console.log(`[/chat] ${claudeModelAlias} answered in ${elapsedMilliseconds}ms (${accumulatedResponseText.length} chars${wasAlreadyStarted ? ", pre-started" : ""})`);

  if (isStreamingRequest) {
    if (!hasStartedStreamingResponse) {
      response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    }
    return response.end();
  }

  const finalResponseText = accumulatedResponseText || claudeCodeResultEvent?.result || "";
  return sendJSON(response, 200, {
    id: `msg_local_${crypto.randomUUID()}`,
    type: "message",
    role: "assistant",
    model: claudeModelAlias,
    content: [{ type: "text", text: finalResponseText }],
    stop_reason: "end_turn",
  });
}

// ---------------------------------------------------------------------------
// Pre-started claude processes
// ---------------------------------------------------------------------------

// Starting `claude` takes about half a second before it can answer. Keeping one
// started process waiting on stdin (per model + system prompt) lets the next
// voice turn skip that wait. A replacement starts right after each one is used.
const startedClaudeProcessMaximumAgeMilliseconds = 10 * 60 * 1000;
const maximumWaitingClaudeProcessCount = 2;
const waitingClaudeProcessesByArguments = new Map();

function spawnClaudeProcess(claudeArguments) {
  // Drop any API key from the environment so Claude Code authenticates with
  // your logged-in claude.ai account instead of billing an API key.
  const claudeEnvironment = { ...process.env };
  delete claudeEnvironment.ANTHROPIC_API_KEY;
  delete claudeEnvironment.ANTHROPIC_AUTH_TOKEN;

  return spawn(claudeBinaryPath, claudeArguments, {
    cwd: claudeWorkingDirectory,
    env: claudeEnvironment,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

/** A claude process for these arguments: a waiting one if there is one, otherwise a new one. */
function takeStartedClaudeProcess(claudeArguments) {
  const argumentsKey = JSON.stringify(claudeArguments);
  const waitingProcessEntry = waitingClaudeProcessesByArguments.get(argumentsKey);
  waitingClaudeProcessesByArguments.delete(argumentsKey);

  let claudeProcess;
  let wasAlreadyStarted = false;
  if (waitingProcessEntry && !waitingProcessEntry.hasExited) {
    clearTimeout(waitingProcessEntry.expiryTimer);
    claudeProcess = waitingProcessEntry.claudeProcess;
    wasAlreadyStarted = true;
  } else {
    claudeProcess = spawnClaudeProcess(claudeArguments);
  }

  startWaitingClaudeProcess(claudeArguments, argumentsKey);
  return { claudeProcess, wasAlreadyStarted };
}

function startWaitingClaudeProcess(claudeArguments, argumentsKey) {
  if (waitingClaudeProcessesByArguments.size >= maximumWaitingClaudeProcessCount) {
    // Make room by stopping the one that has waited longest
    const [oldestArgumentsKey, oldestEntry] = waitingClaudeProcessesByArguments.entries().next().value;
    waitingClaudeProcessesByArguments.delete(oldestArgumentsKey);
    clearTimeout(oldestEntry.expiryTimer);
    oldestEntry.claudeProcess.kill("SIGTERM");
  }

  const waitingProcessEntry = {
    claudeProcess: spawnClaudeProcess(claudeArguments),
    hasExited: false,
    expiryTimer: null,
  };
  waitingProcessEntry.claudeProcess.on("exit", () => {
    waitingProcessEntry.hasExited = true;
    if (waitingClaudeProcessesByArguments.get(argumentsKey) === waitingProcessEntry) {
      waitingClaudeProcessesByArguments.delete(argumentsKey);
    }
  });
  // Replace processes that have waited too long, so logins and updates never go stale
  waitingProcessEntry.expiryTimer = setTimeout(() => {
    if (waitingClaudeProcessesByArguments.get(argumentsKey) === waitingProcessEntry) {
      waitingClaudeProcessesByArguments.delete(argumentsKey);
      waitingProcessEntry.claudeProcess.kill("SIGTERM");
    }
  }, startedClaudeProcessMaximumAgeMilliseconds);
  waitingProcessEntry.expiryTimer.unref();

  waitingClaudeProcessesByArguments.set(argumentsKey, waitingProcessEntry);
}

// Don't leave waiting processes behind when the bridge stops
for (const terminationSignal of ["SIGINT", "SIGTERM"]) {
  process.on(terminationSignal, () => {
    for (const waitingProcessEntry of waitingClaudeProcessesByArguments.values()) {
      waitingProcessEntry.claudeProcess.kill("SIGTERM");
    }
    for (const agentJob of agentJobsById.values()) {
      agentJob.claudeProcess?.kill("SIGTERM");
    }
    process.exit(0);
  });
}

/**
 * `claude -p --input-format stream-json` takes one user message per turn, so the
 * Messages API conversation is folded into a single message: earlier exchanges
 * become a short text transcript, and the latest message keeps its images.
 */
function buildClaudeCodeUserMessage(messagesAPIMessages) {
  const earlierMessages = messagesAPIMessages.slice(0, -1);
  const latestMessage = messagesAPIMessages[messagesAPIMessages.length - 1] || { role: "user", content: "" };

  const contentBlocksForClaudeCode = [];

  if (earlierMessages.length > 0) {
    const earlierConversationTranscript = earlierMessages
      .map((message) => `${message.role === "assistant" ? "you" : "user"}: ${messageContentAsPlainText(message.content)}`)
      .join("\n");
    contentBlocksForClaudeCode.push({
      type: "text",
      text: `earlier in this conversation (for context only, don't repeat it):\n${earlierConversationTranscript}`,
    });
  }

  if (typeof latestMessage.content === "string") {
    contentBlocksForClaudeCode.push({ type: "text", text: latestMessage.content });
  } else {
    for (const contentBlock of latestMessage.content || []) {
      if (contentBlock.type === "text" || contentBlock.type === "image") {
        contentBlocksForClaudeCode.push(contentBlock);
      }
    }
  }

  return {
    type: "user",
    message: { role: "user", content: contentBlocksForClaudeCode },
  };
}

function messageContentAsPlainText(messageContent) {
  if (typeof messageContent === "string") return messageContent;
  return (messageContent || [])
    .filter((contentBlock) => contentBlock.type === "text")
    .map((contentBlock) => contentBlock.text)
    .join(" ");
}

function systemPromptAsString(systemField) {
  if (!systemField) return "";
  if (typeof systemField === "string") return systemField;
  return messageContentAsPlainText(systemField);
}

function mapRequestedModelToClaudeCodeAlias(requestedModel) {
  if (claudeModelOverride) return claudeModelOverride;
  const lowercasedRequestedModel = String(requestedModel || "").toLowerCase();
  if (lowercasedRequestedModel.includes("opus")) return "opus";
  if (lowercasedRequestedModel.includes("haiku")) return "haiku";
  return "sonnet";
}

function describeClaudeCodeFailure(exitCode, resultEvent, standardErrorOutput) {
  if (resultEvent?.is_error) {
    return resultEvent.result || resultEvent.subtype || "Claude Code returned an error.";
  }
  if (exitCode !== 0) {
    return standardErrorOutput.trim() || `claude exited with code ${exitCode}`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// /tts → ElevenLabs (if configured) or macOS `say`
// ---------------------------------------------------------------------------

function isElevenLabsConfigured() {
  return Boolean(process.env.ELEVENLABS_API_KEY && process.env.ELEVENLABS_VOICE_ID);
}

async function handleTextToSpeech(request, response) {
  if (!isJSONRequest(request)) {
    return sendJSON(response, 415, { error: "Expected application/json" });
  }

  const requestBodyText = await readRequestBody(request);

  if (isElevenLabsConfigured()) {
    const elevenLabsResponse = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${process.env.ELEVENLABS_VOICE_ID}`,
      {
        method: "POST",
        headers: {
          "xi-api-key": process.env.ELEVENLABS_API_KEY,
          "content-type": "application/json",
          accept: "audio/mpeg",
        },
        body: requestBodyText,
      }
    );
    const elevenLabsAudio = Buffer.from(await elevenLabsResponse.arrayBuffer());
    response.writeHead(elevenLabsResponse.status, {
      "content-type": elevenLabsResponse.headers.get("content-type") || "audio/mpeg",
    });
    return response.end(elevenLabsAudio);
  }

  const { text: textToSpeak } = JSON.parse(requestBodyText);
  const spokenAudioWAVData = await synthesizeSpeechWithMacOSSay(String(textToSpeak || ""));
  response.writeHead(200, { "content-type": "audio/wav" });
  return response.end(spokenAudioWAVData);
}

async function synthesizeSpeechWithMacOSSay(textToSpeak) {
  const temporaryAudioFilePath = path.join(os.tmpdir(), `clicky-tts-${crypto.randomUUID()}.wav`);
  const sayArguments = ["-o", temporaryAudioFilePath, "--file-format=WAVE", "--data-format=LEI16@22050"];
  if (macOSSayVoiceName) sayArguments.push("-v", macOSSayVoiceName);
  if (macOSSayWordsPerMinute) sayArguments.push("-r", macOSSayWordsPerMinute);

  // Text goes in over stdin so nothing Claude says can be read as a `say` flag.
  await new Promise((resolve, reject) => {
    const sayProcess = spawn("/usr/bin/say", sayArguments, { stdio: ["pipe", "ignore", "pipe"] });
    let sayErrorOutput = "";
    sayProcess.stderr.on("data", (chunk) => (sayErrorOutput += chunk.toString()));
    sayProcess.on("error", reject);
    sayProcess.on("close", (exitCode) =>
      exitCode === 0 ? resolve() : reject(new Error(`say failed (${exitCode}): ${sayErrorOutput.trim()}`))
    );
    sayProcess.stdin.end(textToSpeak);
  });

  try {
    return fs.readFileSync(temporaryAudioFilePath);
  } finally {
    fs.rmSync(temporaryAudioFilePath, { force: true });
  }
}

// ---------------------------------------------------------------------------
// /transcribe-token → AssemblyAI (only if a key is configured)
// ---------------------------------------------------------------------------

async function handleTranscribeToken(response) {
  if (!process.env.ASSEMBLYAI_API_KEY) {
    return sendJSON(response, 501, {
      error: "ASSEMBLYAI_API_KEY is not set in local-bridge/.env. Set VoiceTranscriptionProvider to \"apple\" in Info.plist to transcribe locally.",
    });
  }

  const assemblyAIResponse = await fetch("https://streaming.assemblyai.com/v3/token?expires_in_seconds=480", {
    method: "GET",
    headers: { authorization: process.env.ASSEMBLYAI_API_KEY },
  });
  response.writeHead(assemblyAIResponse.status, { "content-type": "application/json" });
  return response.end(await assemblyAIResponse.text());
}


// ---------------------------------------------------------------------------
// /agent/jobs → background Claude Code agents
// ---------------------------------------------------------------------------

// When you ask Clicky for real work ("research X and make me a PDF"), it hands
// a brief to a separate `claude` session that works in its own folder while you
// carry on. Each job gets output/ for deliverables and tmp/ for scratch work.
//
// What a job may do:
//   - shell commands run in Claude Code's sandbox: they can only write inside
//     the job folder (and the temp folder);
//   - Write/Edit only inside the job folder;
//   - web search and reading pages;
//   - reading files, except credentials (SSH, cloud keys, keychains, .env);
//   - anything else (MCP servers, other tools) is refused without asking.
const agentJobsDirectory = path.join(os.homedir(), "Library", "Application Support", "ClickyLocal", "agent-jobs");
const agentModel = process.env.CLICKY_AGENT_MODEL || "sonnet";
const maximumRunningAgentJobCount = 3;
const agentJobTimeLimitMilliseconds = 30 * 60 * 1000;
const agentJobsById = new Map();

const agentAllowedTools = "Bash Read Glob Grep WebSearch WebFetch Write(./**) Edit(./**)";
const agentDisallowedTools = [
  "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.gnupg/**)", "Read(~/.config/gcloud/**)",
  "Read(~/.kube/**)", "Read(~/Library/Keychains/**)", "Read(**/.env)", "Read(**/.env.*)",
].join(" ");
const agentSandboxSettings = JSON.stringify({ sandbox: { enabled: true, autoAllowBashIfSandboxed: true } });

const agentInstructions = `You're a helper Clicky started on this person's Mac to do one piece of work in the background. They asked out loud and Clicky wrote you the brief. They aren't watching: work it through end to end on your own.

Your current folder is this job's home. Put what they asked for in output/ and keep scratch work in tmp/. If tmp/screen.jpg exists, it's a screenshot of their screen from when they asked.

- Do the work, don't describe it. If something only they know is missing (an account, their own details), do every part that doesn't depend on it and list the open questions at the end. Never invent their facts or put placeholder data where theirs belongs.
- Use the web for outside facts and cite where numbers come from. Never invent a fact, a price, a file or a source.
- Don't send anything to anyone, delete their files, or spend money.
- Make deliverables polished and in the format they asked for (a PDF means a PDF). Check them before you finish: open, render or recompute.

Your final message is shown to them and its first sentence is read aloud. Lead with the result in plain words (what you made or found, and that it's in the output folder), then only what helps. No filler.`;

loadSavedAgentJobs();

async function handleStartAgentJob(request, response) {
  if (!isJSONRequest(request)) {
    return sendJSON(response, 415, { error: "Expected application/json" });
  }
  const { title, brief, screenshotJPEGBase64 } = JSON.parse(await readRequestBody(request));
  if (!brief || typeof brief !== "string") {
    return sendJSON(response, 400, { error: "A brief is required" });
  }
  const runningJobCount = [...agentJobsById.values()].filter((job) => job.status === "running").length;
  if (runningJobCount >= maximumRunningAgentJobCount) {
    return sendJSON(response, 429, { error: `Already running ${runningJobCount} background tasks` });
  }

  const job = startAgentJob({ title: String(title || "").trim() || briefToTitle(brief), brief, screenshotJPEGBase64 });
  return sendJSON(response, 200, { job: publicAgentJob(job) });
}

function handleStopAgentJob(jobID, response) {
  const job = agentJobsById.get(jobID);
  if (!job) return sendJSON(response, 404, { error: "No such job" });
  if (job.status === "running" && job.claudeProcess) {
    job.wasStopRequested = true;
    job.claudeProcess.kill("SIGTERM");
  }
  return sendJSON(response, 200, { job: publicAgentJob(job) });
}

function startAgentJob({ title, brief, screenshotJPEGBase64 }) {
  const jobID = crypto.randomUUID().slice(0, 8);
  const dateStamp = new Date().toISOString().slice(0, 10);
  const titleSlug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "task";
  const jobFolder = path.join(agentJobsDirectory, `${dateStamp}-${titleSlug}-${jobID}`);
  fs.mkdirSync(path.join(jobFolder, "output"), { recursive: true });
  fs.mkdirSync(path.join(jobFolder, "tmp"), { recursive: true });
  fs.writeFileSync(path.join(jobFolder, "BRIEF.md"), `# ${title}\n\n${brief}\n`);
  if (screenshotJPEGBase64) {
    fs.writeFileSync(path.join(jobFolder, "tmp", "screen.jpg"), Buffer.from(screenshotJPEGBase64, "base64"));
  }

  const job = {
    id: jobID,
    title,
    brief,
    folder: jobFolder,
    status: "running",
    startedAt: new Date().toISOString(),
    finishedAt: null,
    progress: [],
    result: null,
    outputFiles: [],
    claudeProcess: null,
    wasStopRequested: false,
  };
  agentJobsById.set(jobID, job);

  const claudeEnvironment = { ...process.env };
  delete claudeEnvironment.ANTHROPIC_API_KEY;
  delete claudeEnvironment.ANTHROPIC_AUTH_TOKEN;

  const claudeArguments = [
    "-p", brief,
    "--output-format", "stream-json",
    "--verbose",
    "--model", agentModel,
    "--append-system-prompt", agentInstructions,
    "--permission-mode", "dontAsk",
    "--allowedTools", agentAllowedTools,
    "--disallowedTools", agentDisallowedTools,
    "--settings", agentSandboxSettings,
    "--strict-mcp-config",
  ];
  const claudeProcess = spawn(claudeBinaryPath, claudeArguments, { cwd: jobFolder, env: claudeEnvironment, stdio: ["ignore", "pipe", "pipe"] });
  job.claudeProcess = claudeProcess;
  console.log(`[agent ${jobID}] started "${title}" in ${jobFolder}`);

  const timeLimitTimer = setTimeout(() => {
    addAgentJobProgress(job, "stopped: took longer than 30 minutes");
    claudeProcess.kill("SIGTERM");
  }, agentJobTimeLimitMilliseconds);

  let standardErrorOutput = "";
  claudeProcess.stderr.on("data", (chunk) => (standardErrorOutput += chunk.toString()));

  let partialOutputLine = "";
  claudeProcess.stdout.on("data", (chunk) => {
    partialOutputLine += chunk.toString();
    const completeLines = partialOutputLine.split("\n");
    partialOutputLine = completeLines.pop();
    for (const outputLine of completeLines) {
      let claudeCodeEvent;
      try {
        claudeCodeEvent = JSON.parse(outputLine);
      } catch {
        continue;
      }
      handleAgentEvent(job, claudeCodeEvent);
    }
  });

  claudeProcess.on("close", (exitCode) => {
    clearTimeout(timeLimitTimer);
    job.claudeProcess = null;
    job.finishedAt = new Date().toISOString();
    if (job.status === "running") {
      if (job.wasStopRequested) {
        job.status = "stopped";
      } else if (exitCode === 0 && job.result) {
        job.status = "done";
      } else {
        job.status = "failed";
        job.result = job.result || standardErrorOutput.trim().split("\n").slice(-3).join(" ") || `claude exited with code ${exitCode}`;
      }
    }
    job.outputFiles = listOutputFiles(jobFolder);
    saveAgentJob(job);
    console.log(`[agent ${jobID}] ${job.status}: ${(job.result || "").slice(0, 120)}`);
  });

  saveAgentJob(job);
  return job;
}

function handleAgentEvent(job, claudeCodeEvent) {
  if (claudeCodeEvent.type === "assistant") {
    for (const contentBlock of claudeCodeEvent.message?.content || []) {
      if (contentBlock.type === "tool_use") {
        addAgentJobProgress(job, describeAgentToolUse(contentBlock.name, contentBlock.input || {}));
      } else if (contentBlock.type === "text" && contentBlock.text.trim()) {
        addAgentJobProgress(job, contentBlock.text.trim().split("\n")[0]);
      }
    }
  } else if (claudeCodeEvent.type === "result") {
    job.result = claudeCodeEvent.result || job.result;
    job.status = claudeCodeEvent.is_error ? "failed" : "done";
  }
}

/** One short, human line for what the agent is doing right now. */
function describeAgentToolUse(toolName, toolInput) {
  const fileName = (filePath) => path.basename(String(filePath || ""));
  switch (toolName) {
    case "WebSearch": return `searching the web for "${toolInput.query}"`;
    case "WebFetch": {
      try { return `reading ${new URL(toolInput.url).hostname}`; } catch { return "reading a web page"; }
    }
    case "Bash": return `running ${toolInput.description || String(toolInput.command || "").slice(0, 60)}`;
    case "Write": return `writing ${fileName(toolInput.file_path)}`;
    case "Edit": return `editing ${fileName(toolInput.file_path)}`;
    case "Read": return `reading ${fileName(toolInput.file_path)}`;
    case "Glob":
    case "Grep": return "looking through files";
    default: return `using ${toolName}`;
  }
}

function addAgentJobProgress(job, progressLine) {
  const trimmedProgressLine = progressLine.length > 140 ? `${progressLine.slice(0, 139)}…` : progressLine;
  job.progress.push({ at: new Date().toISOString(), text: trimmedProgressLine });
  if (job.progress.length > 40) job.progress.shift();
}

function listOutputFiles(jobFolder) {
  try {
    return fs.readdirSync(path.join(jobFolder, "output")).filter((fileName) => !fileName.startsWith("."));
  } catch {
    return [];
  }
}

function publicAgentJob(job) {
  return {
    id: job.id,
    title: job.title,
    status: job.status,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
    latestProgress: job.progress.at(-1)?.text || null,
    result: job.result,
    folder: job.folder,
    outputFiles: job.status === "running" ? listOutputFiles(job.folder) : job.outputFiles,
  };
}

function listAgentJobs() {
  return [...agentJobsById.values()]
    .sort((firstJob, secondJob) => secondJob.startedAt.localeCompare(firstJob.startedAt))
    .slice(0, 20)
    .map(publicAgentJob);
}

function saveAgentJob(job) {
  const { claudeProcess, ...savableJob } = job;
  fs.writeFileSync(path.join(job.folder, "job.json"), JSON.stringify(savableJob, null, 2));
}

/** Past jobs survive bridge restarts; ones that were mid-run are marked as interrupted. */
function loadSavedAgentJobs() {
  let jobFolderNames = [];
  try {
    jobFolderNames = fs.readdirSync(agentJobsDirectory);
  } catch {
    return;
  }
  for (const jobFolderName of jobFolderNames) {
    try {
      const savedJob = JSON.parse(fs.readFileSync(path.join(agentJobsDirectory, jobFolderName, "job.json"), "utf8"));
      if (savedJob.status === "running") {
        savedJob.status = "interrupted";
      }
      agentJobsById.set(savedJob.id, { ...savedJob, claudeProcess: null });
    } catch {
      // Not a job folder, or a half-written one
    }
  }
}

function briefToTitle(brief) {
  return brief.split(/\s+/).slice(0, 6).join(" ").replace(/[.,:;]+$/, "");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function resolveClaudeBinaryPath() {
  if (process.env.CLAUDE_BIN) return process.env.CLAUDE_BIN;

  const commonInstallLocations = [
    path.join(os.homedir(), ".local/bin/claude"),
    path.join(os.homedir(), ".claude/local/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ];
  for (const candidatePath of commonInstallLocations) {
    if (fs.existsSync(candidatePath)) return candidatePath;
  }

  try {
    return execFileSync("/bin/zsh", ["-lc", "command -v claude"], { encoding: "utf8" }).trim();
  } catch {
    console.error("❌ Could not find the `claude` CLI. Install Claude Code or set CLAUDE_BIN in local-bridge/.env.");
    process.exit(1);
  }
}

function isJSONRequest(request) {
  return String(request.headers["content-type"] || "").toLowerCase().startsWith("application/json");
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const bodyChunks = [];
    request.on("data", (chunk) => bodyChunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(bodyChunks).toString("utf8")));
    request.on("error", reject);
  });
}

function sendJSON(response, statusCode, payload) {
  response.writeHead(statusCode, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function loadDotEnvFileIfPresent(dotEnvFilePath) {
  if (!fs.existsSync(dotEnvFilePath)) return;
  for (const dotEnvLine of fs.readFileSync(dotEnvFilePath, "utf8").split("\n")) {
    const trimmedLine = dotEnvLine.trim();
    if (!trimmedLine || trimmedLine.startsWith("#")) continue;
    const separatorIndex = trimmedLine.indexOf("=");
    if (separatorIndex === -1) continue;
    const variableName = trimmedLine.slice(0, separatorIndex).trim();
    const variableValue = trimmedLine.slice(separatorIndex + 1).trim().replace(/^["']|["']$/g, "");
    if (!(variableName in process.env)) process.env[variableName] = variableValue;
  }
}
