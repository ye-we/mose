//
//  AgentConnectedApps.swift
//  leanring-buddy
//
//  The user's connected apps (their Claude Code MCP servers, including the
//  claude.ai connectors like Gmail or Google Drive) that background tasks may
//  use. None are allowed until the user turns them on one by one in the
//  Connected Apps window. For a turned-on app, the agent's `claude` gets
//  every tool of that server allowed (`mcp__<server>`); every other app's
//  tools are still refused without asking. What it may do inside an allowed
//  app (read, and create only what the brief asks; never send, delete or
//  pay) is an instruction to the agent, not a lock, and the window says so.
//
//  Foundation only, so the standalone tests can use it.
//

import Foundation

/// One app from `claude mcp list`.
struct ClaudeCodeConnectedApp: Equatable, Identifiable {
    enum ConnectionStatus: Equatable {
        case connected
        /// A claude.ai connector that hasn't been signed in to yet.
        case needsSignIn
        case failed
    }

    /// The server's name as Claude Code has it ("claude.ai Gmail", "aytalent").
    let serverName: String
    let connectionStatus: ConnectionStatus

    var id: String { serverName }

    /// "Gmail" for "claude.ai Gmail".
    var displayName: String { AgentConnectedApps.displayName(forServerName: serverName) }
}

enum AgentConnectedApps {
    /// Reads `claude mcp list`: one line per server, "name: url-or-command -
    /// ✔ Connected" (or "! Needs authentication", "✘ Failed to connect").
    static func parseServerList(_ serverListOutput: String) -> [ClaudeCodeConnectedApp] {
        serverListOutput.components(separatedBy: .newlines).compactMap { serverLine in
            let trimmedLine = serverLine.trimmingCharacters(in: .whitespaces)
            guard let nameSeparatorRange = trimmedLine.range(of: ": "),
                  let statusSeparatorRange = trimmedLine.range(of: " - ", options: .backwards),
                  nameSeparatorRange.lowerBound < statusSeparatorRange.lowerBound else { return nil }
            let serverName = String(trimmedLine[..<nameSeparatorRange.lowerBound])
            let statusText = String(trimmedLine[statusSeparatorRange.upperBound...]).lowercased()
            let connectionStatus: ClaudeCodeConnectedApp.ConnectionStatus
            if statusText.contains("auth") {
                connectionStatus = .needsSignIn
            } else if statusText.range(of: #"(^|[^a-z])connected$"#, options: .regularExpression) != nil {
                connectionStatus = .connected
            } else {
                connectionStatus = .failed
            }
            return ClaudeCodeConnectedApp(serverName: serverName, connectionStatus: connectionStatus)
        }
    }

    static func displayName(forServerName serverName: String) -> String {
        serverName.hasPrefix("claude.ai ") ? String(serverName.dropFirst("claude.ai ".count)) : serverName
    }

    /// The permission rule that allows every tool of one server, the way
    /// Claude Code names them: "claude.ai Google Calendar" →
    /// "mcp__claude_ai_Google_Calendar".
    static func toolPermissionRule(forServerName serverName: String) -> String {
        let normalizedServerName = serverName
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "mcp__\(normalizedServerName)"
    }

    /// Added to the agent's instructions when it may use some apps.
    static func agentInstructions(forAppDisplayNames appDisplayNames: [String]) -> String {
        """

        They've also let you use these apps of theirs: \(appDisplayNames.joined(separator: ", ")). Use them when the brief needs what's in them. Read whatever helps, and create something in them (a draft, a document, an event) only when the brief asks for it. Never send, post, share, invite, delete or pay through them, even if the brief seems to ask: make it ready and tell them what's left for them to do.
        """
    }

    /// Asks Claude Code which apps are connected. Takes ~15 seconds, since it
    /// checks each one. Run from an empty folder, like the agents, so no
    /// project's own servers show up.
    static func loadConnectedApps() async throws -> [ClaudeCodeConnectedApp] {
        let foundInstallation = try await ClaudeCodeCLI.installation()
        let emptyFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-connected-apps", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolderURL, withIntermediateDirectories: true)
        let serverListResult = try await ChildProcessRunner.runToCompletion(
            executableURL: foundInstallation.binaryURL,
            arguments: ["mcp", "list"],
            environment: foundInstallation.processEnvironment,
            currentDirectoryURL: emptyFolderURL,
            timeLimitSeconds: 90
        )
        return parseServerList(serverListResult.standardOutputText)
    }

    /// Told to the voice assistant with each question, so it knows what a
    /// background task can do.
    static func noteForVoiceAnswers(appDisplayNames: [String]) -> String? {
        guard !appDisplayNames.isEmpty else { return nil }
        return "background tasks can also use these apps of theirs: \(appDisplayNames.joined(separator: ", ")). they can read and create things there, but never send anything."
    }
}
