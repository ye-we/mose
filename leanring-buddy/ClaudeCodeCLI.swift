//
//  ClaudeCodeCLI.swift
//  leanring-buddy
//
//  Clicky answers with the Claude Code command line tool (`claude`) that the
//  user already has installed and signed into, so it runs on their Claude
//  subscription with no API keys and no separate server to start. This file
//  finds the tool, builds the environment it runs in, checks the sign-in, and
//  has the pieces shared by voice answers (ClaudeCodeChatClient) and background
//  tasks (BackgroundAgentJobRunner): the message format and the output parser.
//  Foundation only, so the standalone tests can use it.
//

import Foundation

/// Where `claude` is and how to run it.
struct ClaudeCodeInstallation: Equatable {
    let binaryURL: URL
    let processEnvironment: [String: String]
}

/// Whether Clicky can answer, as shown in setup and the menu bar panel.
enum ClaudeCodeSetupState: Equatable {
    case checking
    case notInstalled
    case notSignedIn
    case ready(ClaudeCodeAccount)
    case problem(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Who Claude Code is signed in as, from `claude auth status`.
struct ClaudeCodeAccount: Equatable {
    let email: String?
    let subscriptionType: String?
    let organizationName: String?

    /// "Team plan", "Max plan" and so on, or nil if Claude Code didn't say.
    var planDescription: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return "\(subscriptionType.prefix(1).uppercased())\(subscriptionType.dropFirst()) plan"
    }
}

enum ClaudeCodeCLIError: LocalizedError {
    case notInstalled
    case notSignedIn
    case usageLimitReached
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Claude Code isn't installed."
        case .notSignedIn: return "Claude Code isn't signed in."
        case .usageLimitReached: return "You've reached your Claude usage limit for now."
        case .failed(let failureMessage): return failureMessage
        }
    }

    /// What Clicky says out loud when an answer fails this way.
    var spokenExplanation: String {
        switch self {
        case .notInstalled:
            return "I need Claude Code to answer, and it isn't installed. Open setup from the menu bar and I'll walk you through it."
        case .notSignedIn:
            return "Claude Code isn't signed in. Open setup from the menu bar to sign in."
        case .usageLimitReached:
            return "You've hit your Claude usage limit for now. Try again a bit later."
        case .failed:
            return "Something went wrong talking to Claude. Try again in a moment."
        }
    }
}

enum ClaudeCodeCLI {
    // MARK: - Finding the tool

    /// Where installers put `claude`, most common first. Apps opened from the
    /// Finder don't get the shell's PATH, so these are checked directly.
    static func commonInstallLocations(homeDirectoryPath: String) -> [String] {
        [
            "\(homeDirectoryPath)/.local/bin/claude",    // the native installer
            "\(homeDirectoryPath)/.claude/local/claude", // older local installs
            "/opt/homebrew/bin/claude",                  // Homebrew on Apple silicon
            "/usr/local/bin/claude",                     // Homebrew on Intel, npm -g
        ]
    }

    private static let cacheLock = NSLock()
    private static var cachedInstallation: ClaudeCodeInstallation?

    /// Finds `claude` and the PATH its tools should see. Looking through the
    /// user's login shell can take a moment, so the result is cached; pass
    /// `forceRefresh` after the user installs it.
    static func installation(forceRefresh: Bool = false) async throws -> ClaudeCodeInstallation {
        if !forceRefresh, let alreadyFoundInstallation = cacheLock.withLock({ cachedInstallation }) {
            return alreadyFoundInstallation
        }

        let loginShellSearchPath = await loginShellOutput(forCommand: #"printf '%s' "$PATH""#)
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path

        var binaryPath = commonInstallLocations(homeDirectoryPath: homeDirectoryPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if binaryPath == nil,
           let pathFromShell = await loginShellOutput(forCommand: "command -v claude"),
           FileManager.default.isExecutableFile(atPath: pathFromShell) {
            binaryPath = pathFromShell
        }
        guard let binaryPath else { throw ClaudeCodeCLIError.notInstalled }

        let foundInstallation = ClaudeCodeInstallation(
            binaryURL: URL(fileURLWithPath: binaryPath),
            processEnvironment: processEnvironment(
                inheritedEnvironment: ProcessInfo.processInfo.environment,
                loginShellSearchPath: loginShellSearchPath,
                claudeBinaryDirectoryPath: (binaryPath as NSString).deletingLastPathComponent,
                homeDirectoryPath: homeDirectoryPath
            )
        )
        cacheLock.withLock { cachedInstallation = foundInstallation }
        return foundInstallation
    }

    /// The environment `claude` runs with. API key variables are removed so it
    /// signs in with the user's Claude account instead of billing an API key,
    /// and PATH is the one from their shell, so background tasks can find the
    /// tools they installed (python, node and so on).
    static func processEnvironment(
        inheritedEnvironment: [String: String],
        loginShellSearchPath: String?,
        claudeBinaryDirectoryPath: String,
        homeDirectoryPath: String
    ) -> [String: String] {
        var environment = inheritedEnvironment
        for variableName in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: variableName)
        }

        var searchPathDirectories: [String] = []
        let candidateDirectories = (loginShellSearchPath ?? "").split(separator: ":").map(String.init) + [
            claudeBinaryDirectoryPath,
            "\(homeDirectoryPath)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        for candidateDirectory in candidateDirectories where !candidateDirectory.isEmpty && !searchPathDirectories.contains(candidateDirectory) {
            searchPathDirectories.append(candidateDirectory)
        }
        environment["PATH"] = searchPathDirectories.joined(separator: ":")
        return environment
    }

    /// Runs a command in the user's login shell (which loads their PATH) and
    /// returns what it printed. Shell startup files sometimes print their own
    /// text, so the answer is wrapped in markers and cut out.
    private static func loginShellOutput(forCommand shellCommand: String) async -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let outputMarker = "__CLICKY_OUTPUT__"
        let markedCommand = "printf '\(outputMarker)'; \(shellCommand); printf '\(outputMarker)'"
        guard let shellResult = try? await ChildProcessRunner.runToCompletion(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: ["-l", "-i", "-c", markedCommand],
            timeLimitSeconds: 5
        ) else { return nil }
        let markedParts = shellResult.standardOutputText.components(separatedBy: outputMarker)
        guard markedParts.count >= 3 else { return nil }
        let markedOutput = markedParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return markedOutput.isEmpty ? nil : markedOutput
    }

    // MARK: - Sign-in

    /// Checks whether Claude Code is installed and signed in.
    static func checkSetupState(forceRefresh: Bool = false) async -> ClaudeCodeSetupState {
        let foundInstallation: ClaudeCodeInstallation
        do {
            foundInstallation = try await installation(forceRefresh: forceRefresh)
        } catch {
            return .notInstalled
        }

        guard let statusResult = try? await ChildProcessRunner.runToCompletion(
            executableURL: foundInstallation.binaryURL,
            arguments: ["auth", "status", "--json"],
            environment: foundInstallation.processEnvironment,
            timeLimitSeconds: 20
        ) else {
            return .problem("Claude Code didn't respond.")
        }
        return setupState(fromAuthStatusOutput: statusResult.standardOutputText)
    }

    /// Reads `claude auth status --json`.
    static func setupState(fromAuthStatusOutput authStatusOutput: String) -> ClaudeCodeSetupState {
        guard let jsonStartIndex = authStatusOutput.firstIndex(of: "{"),
              let statusData = String(authStatusOutput[jsonStartIndex...]).data(using: .utf8),
              let statusFields = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
            return .problem("Claude Code's sign-in status couldn't be read.")
        }
        guard statusFields["loggedIn"] as? Bool == true else { return .notSignedIn }
        return .ready(ClaudeCodeAccount(
            email: statusFields["email"] as? String,
            subscriptionType: statusFields["subscriptionType"] as? String,
            organizationName: statusFields["orgName"] as? String
        ))
    }

    // MARK: - Talking to it

    /// Claude Code's own model names. They always point at the newest model of
    /// that family the user's plan includes.
    static func modelAlias(forRequestedModel requestedModel: String) -> String {
        let lowercasedRequestedModel = requestedModel.lowercased()
        if lowercasedRequestedModel.contains("opus") { return "opus" }
        if lowercasedRequestedModel.contains("haiku") { return "haiku" }
        return "sonnet"
    }

    /// The one line `claude -p --input-format stream-json` reads for a turn.
    /// It takes a single user message, so notes about the user (what Clicky
    /// remembers, which apps background tasks may use) and earlier exchanges
    /// (as a short text transcript) go at the start, and this turn keeps its
    /// images.
    static func userMessageLine(
        images: [(data: Data, label: String)],
        notesAboutUser: String? = nil,
        earlierConversationSummary: String? = nil,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> String {
        var contentBlocks: [[String: Any]] = []

        if let notesAboutUser {
            contentBlocks.append(["type": "text", "text": notesAboutUser])
        }

        if earlierConversationSummary != nil || !conversationHistory.isEmpty {
            var earlierConversationParts: [String] = []
            if let earlierConversationSummary {
                earlierConversationParts.append("how this conversation started, in short: \(earlierConversationSummary)")
            }
            if !conversationHistory.isEmpty {
                let earlierConversationTranscript = conversationHistory
                    .map { exchange in "user: \(exchange.userPlaceholder)\nyou: \(exchange.assistantResponse)" }
                    .joined(separator: "\n")
                earlierConversationParts.append(earlierConversationSummary == nil
                    ? earlierConversationTranscript
                    : "the most recent exchanges:\n\(earlierConversationTranscript)")
            }
            contentBlocks.append([
                "type": "text",
                "text": "earlier in this conversation (for context only, don't repeat it):\n\(earlierConversationParts.joined(separator: "\n\n"))",
            ])
        }

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageMediaType(for: image.data),
                    "data": image.data.base64EncodedString(),
                ],
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }
        contentBlocks.append(["type": "text", "text": userPrompt])

        let userMessage: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks],
        ]
        let userMessageData = try JSONSerialization.data(withJSONObject: userMessage)
        return String(decoding: userMessageData, as: UTF8.self) + "\n"
    }

    /// Screenshots are JPEG; pasted images can be PNG. The declared type must match.
    static func imageMediaType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        return Array(imageData.prefix(4)) == pngSignature ? "image/png" : "image/jpeg"
    }

    // MARK: - Reading its output

    /// One piece of an assistant message, as background tasks report progress.
    enum AssistantContentBlock {
        case text(String)
        case toolUse(name: String, input: [String: Any])
    }

    /// The parts of Claude Code's stream-json output that Clicky uses.
    enum OutputEvent {
        /// A piece of the answer as it streams (with --include-partial-messages).
        case textDelta(String)
        /// A finished assistant message: what it said and which tools it used.
        case assistantMessage([AssistantContentBlock])
        /// The end of the turn.
        case result(isError: Bool, resultText: String?)
    }

    /// Parses one line of stream-json output. Lines Clicky doesn't need
    /// (system events, thinking, tool results) return nil.
    static func parseOutputLine(_ outputLine: String) -> OutputEvent? {
        guard let lineData = outputLine.data(using: .utf8),
              let outputFields = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let eventType = outputFields["type"] as? String else { return nil }

        switch eventType {
        case "stream_event":
            guard let streamEvent = outputFields["event"] as? [String: Any],
                  streamEvent["type"] as? String == "content_block_delta",
                  let delta = streamEvent["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let textChunk = delta["text"] as? String else { return nil }
            return .textDelta(textChunk)

        case "assistant":
            let message = outputFields["message"] as? [String: Any]
            let rawContentBlocks = message?["content"] as? [[String: Any]] ?? []
            let contentBlocks: [AssistantContentBlock] = rawContentBlocks.compactMap { rawContentBlock in
                switch rawContentBlock["type"] as? String {
                case "text":
                    return (rawContentBlock["text"] as? String).map { .text($0) }
                case "tool_use":
                    return .toolUse(
                        name: rawContentBlock["name"] as? String ?? "a tool",
                        input: rawContentBlock["input"] as? [String: Any] ?? [:]
                    )
                default:
                    return nil
                }
            }
            return .assistantMessage(contentBlocks)

        case "result":
            return .result(
                isError: outputFields["is_error"] as? Bool ?? false,
                resultText: outputFields["result"] as? String
            )

        default:
            return nil
        }
    }

    /// Turns a failed run into an error, or nil if it didn't fail.
    static func failure(
        exitCode: Int32,
        resultEvent: (isError: Bool, resultText: String?)?,
        standardErrorText: String
    ) -> ClaudeCodeCLIError? {
        let failureMessage: String
        if let resultEvent, resultEvent.isError {
            failureMessage = resultEvent.resultText ?? "Claude Code returned an error."
        } else if exitCode != 0 {
            let trimmedStandardError = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            failureMessage = trimmedStandardError.isEmpty ? "claude exited with code \(exitCode)" : trimmedStandardError
        } else {
            return nil
        }

        let lowercasedFailureMessage = failureMessage.lowercased()
        if lowercasedFailureMessage.contains("/login")
            || lowercasedFailureMessage.contains("not logged in")
            || lowercasedFailureMessage.contains("invalid api key")
            || lowercasedFailureMessage.contains("please log in")
            || lowercasedFailureMessage.contains("oauth token") {
            return .notSignedIn
        }
        if lowercasedFailureMessage.contains("usage limit")
            || lowercasedFailureMessage.contains("limit reached")
            || lowercasedFailureMessage.contains("rate limit") {
            return .usageLimitReached
        }
        return .failed(failureMessage)
    }
}
