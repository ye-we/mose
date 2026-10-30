//
//  BackgroundAgentJobRunner.swift
//  leanring-buddy
//
//  Runs background tasks inside Clicky. When the user asks for real work
//  ("research X and make me a PDF"), a separate `claude` session does it in
//  its own folder while they carry on. Each job gets output/ for what it makes
//  and tmp/ for scratch work, and its state is saved to job.json so past jobs
//  show up again after a restart.
//
//  What a job may do:
//    - shell commands run in Claude Code's sandbox, so they can only write
//      inside the job folder (and the temp folder);
//    - Write and Edit only inside the job folder;
//    - search the web and read pages;
//    - read files, except credentials (SSH, cloud keys, keychains, .env);
//    - use the connected apps the user turned on for background tasks
//      (AgentConnectedApps), and no others;
//    - anything else (other MCP servers, other tools) is refused without asking.
//

import Foundation

/// One job as saved in its job.json. The keys match what the old Node bridge
/// wrote, so jobs it ran still load.
struct BackgroundAgentJobRecord: Codable {
    struct ProgressEntry: Codable {
        let at: String
        let text: String
    }

    let id: String
    let title: String
    let brief: String
    let folder: String
    var status: String
    let startedAt: String
    var finishedAt: String?
    var progress: [ProgressEntry]
    var result: String?
    var outputFiles: [String]
    var wasStopRequested: Bool?
}

@MainActor
final class BackgroundAgentJobRunner: BackgroundAgentJobService {
    /// ~/Library/Application Support/<bundle id>/agent-jobs, next to the
    /// conversations and memory.
    static let jobsDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Mose", isDirectory: true)
        .appendingPathComponent("agent-jobs", isDirectory: true)
    private static let maximumRunningJobCount = 3
    private static let jobTimeLimitSeconds: TimeInterval = 30 * 60
    private nonisolated static let agentModelAlias = "sonnet"
    private static let shownJobCount = 20

    nonisolated static let allowedTools = "Bash Read Glob Grep WebSearch WebFetch Write(./**) Edit(./**)"
    nonisolated static let disallowedTools = [
        "Read(~/.ssh/**)", "Read(~/.aws/**)", "Read(~/.gnupg/**)", "Read(~/.config/gcloud/**)",
        "Read(~/.kube/**)", "Read(~/Library/Keychains/**)", "Read(**/.env)", "Read(**/.env.*)",
    ].joined(separator: " ")
    nonisolated static let sandboxSettingsJSON = #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}"#

    nonisolated static let agentInstructions = """
    You're a helper Mose started on this person's Mac to do one piece of work in the background. They asked out loud and Mose wrote you the brief. They aren't watching: work it through end to end on your own.

    Your current folder is this job's home. Put what they asked for in output/ and keep scratch work in tmp/. If tmp/screen.jpg exists, it's a screenshot of their screen from when they asked.

    - Do the work, don't describe it. If something only they know is missing (an account, their own details), do every part that doesn't depend on it and list the open questions at the end. Never invent their facts or put placeholder data where theirs belongs.
    - Use the web for outside facts and cite where numbers come from. Never invent a fact, a price, a file or a source.
    - Don't send anything to anyone, delete their files, or spend money.
    - Make deliverables polished and in the format they asked for (a PDF means a PDF). Check them before you finish: open, render or recompute.

    Your final message is shown to them and its first sentence is read aloud. Lead with the result in plain words (what you made or found, and that it's in the output folder), then only what helps. No filler.
    """

    /// The connected apps (MCP server names) the user lets background tasks
    /// use. Set by CompanionManager from the Connected Apps window.
    var connectedAppServerNames: [String] = []

    private var jobRecordsByID: [String: BackgroundAgentJobRecord] = [:]
    private var runningProcessesByJobID: [String: Process] = [:]

    init() {
        loadSavedJobs()
    }

    /// With no connected apps, MCP servers aren't even loaded. With some,
    /// Claude Code loads the user's servers as usual, and only the turned-on
    /// ones are allowed; tools of the rest are refused without asking.
    nonisolated static func claudeArguments(connectedAppServerNames: [String] = []) -> [String] {
        var allowedToolRules = allowedTools
        var instructions = agentInstructions
        if !connectedAppServerNames.isEmpty {
            let connectedAppRules = connectedAppServerNames.map(AgentConnectedApps.toolPermissionRule(forServerName:))
            allowedToolRules += " " + connectedAppRules.joined(separator: " ")
            instructions += AgentConnectedApps.agentInstructions(
                forAppDisplayNames: connectedAppServerNames.map(AgentConnectedApps.displayName(forServerName:))
            )
        }
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--model", agentModelAlias,
            "--append-system-prompt", instructions,
            "--permission-mode", "dontAsk",
            "--allowedTools", allowedToolRules,
            "--disallowedTools", disallowedTools,
            "--settings", sandboxSettingsJSON,
            // Claude Code would otherwise keep the whole session (including the
            // screenshot, if the agent opened it) in ~/.claude/projects
            "--no-session-persistence",
        ]
        if connectedAppServerNames.isEmpty {
            arguments.append("--strict-mcp-config")
        }
        return arguments
    }

    // MARK: - BackgroundAgentJobService

    func startJob(title: String, brief: String, screenshotJPEGData: Data?) async throws -> BackgroundAgentJob {
        let runningJobCount = jobRecordsByID.values.filter { $0.status == "running" }.count
        guard runningJobCount < Self.maximumRunningJobCount else {
            throw NSError(domain: "BackgroundAgentJobs", code: 429,
                          userInfo: [NSLocalizedDescriptionKey: "Already running \(runningJobCount) background tasks"])
        }
        let foundInstallation = try await ClaudeCodeCLI.installation()

        let jobID = String(UUID().uuidString.lowercased().prefix(8))
        let jobTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.titleFromBrief(brief)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobFolderURL = Self.jobsDirectoryURL.appendingPathComponent(
            "\(Self.dateStamp())-\(Self.folderSlug(forTitle: jobTitle))-\(jobID)",
            isDirectory: true
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: jobFolderURL.appendingPathComponent("output"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: jobFolderURL.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try "# \(jobTitle)\n\n\(brief)\n".write(to: jobFolderURL.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
        if let screenshotJPEGData {
            try screenshotJPEGData.write(to: jobFolderURL.appendingPathComponent("tmp/screen.jpg"))
        }

        let jobRecord = BackgroundAgentJobRecord(
            id: jobID,
            title: jobTitle,
            brief: brief,
            folder: jobFolderURL.path,
            status: "running",
            startedAt: Self.timestamp(),
            finishedAt: nil,
            progress: [],
            result: nil,
            outputFiles: [],
            wasStopRequested: false
        )
        jobRecordsByID[jobID] = jobRecord

        let agentProcess = Process()
        agentProcess.executableURL = foundInstallation.binaryURL
        agentProcess.arguments = Self.claudeArguments(connectedAppServerNames: connectedAppServerNames)
        if !connectedAppServerNames.isEmpty {
            print("🤖 Background agent \(jobID) may use: \(connectedAppServerNames.joined(separator: ", "))")
        }
        agentProcess.environment = foundInstallation.processEnvironment
        agentProcess.currentDirectoryURL = jobFolderURL
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        agentProcess.standardInput = standardInputPipe
        agentProcess.standardOutput = standardOutputPipe
        agentProcess.standardError = standardErrorPipe

        do {
            try agentProcess.run()
        } catch {
            jobRecordsByID[jobID]?.status = "failed"
            jobRecordsByID[jobID]?.result = "Couldn't start Claude Code: \(error.localizedDescription)"
            jobRecordsByID[jobID]?.finishedAt = Self.timestamp()
            saveJob(withID: jobID)
            throw error
        }
        runningProcessesByJobID[jobID] = agentProcess
        print("🤖 Background agent \(jobID) started \"\(jobTitle)\" in \(jobFolderURL.path)")

        // The brief goes in over stdin so nothing in it can be read as a flag
        ChildProcessRunner.writeAndCloseOnBackgroundThread(Data(brief.utf8), to: standardInputPipe.fileHandleForWriting)

        let standardErrorBuffer = LockedTextBuffer()
        standardErrorPipe.fileHandleForReading.readabilityHandler = { readableFileHandle in
            let newlyReadData = readableFileHandle.availableData
            if newlyReadData.isEmpty {
                readableFileHandle.readabilityHandler = nil
            } else {
                standardErrorBuffer.append(String(decoding: newlyReadData, as: UTF8.self))
            }
        }

        let timeLimitWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, agentProcess.isRunning else { return }
                self.addProgress("stopped: took longer than 30 minutes", toJobWithID: jobID)
                agentProcess.terminate()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.jobTimeLimitSeconds, execute: timeLimitWorkItem)

        Task { [weak self] in
            for await outputLine in ChildProcessRunner.outputLines(from: standardOutputPipe.fileHandleForReading) {
                guard let outputEvent = ClaudeCodeCLI.parseOutputLine(outputLine) else { continue }
                self?.handleAgentOutputEvent(outputEvent, forJobWithID: jobID)
            }
            await ChildProcessRunner.waitForExitOnBackgroundThread(agentProcess)
            timeLimitWorkItem.cancel()
            self?.finishJob(withID: jobID, exitCode: agentProcess.terminationStatus, standardErrorText: standardErrorBuffer.text)
        }

        saveJob(withID: jobID)
        return publicJob(from: jobRecord)
    }

    func listJobs() async throws -> [BackgroundAgentJob] {
        jobRecordsByID.values
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.shownJobCount)
            .map(publicJob(from:))
    }

    func stopJob(withID jobID: String) async throws {
        guard let agentProcess = runningProcessesByJobID[jobID], agentProcess.isRunning else { return }
        jobRecordsByID[jobID]?.wasStopRequested = true
        agentProcess.terminate()
    }

    /// Clicky is quitting. The jobs are stopped; next launch shows them as interrupted.
    func stopAllRunningJobs() {
        for agentProcess in runningProcessesByJobID.values where agentProcess.isRunning {
            agentProcess.terminate()
        }
    }

    // MARK: - Running a job

    private func handleAgentOutputEvent(_ outputEvent: ClaudeCodeCLI.OutputEvent, forJobWithID jobID: String) {
        switch outputEvent {
        case .assistantMessage(let contentBlocks):
            for contentBlock in contentBlocks {
                switch contentBlock {
                case .toolUse(let toolName, let toolInput):
                    addProgress(Self.describeToolUse(toolName: toolName, toolInput: toolInput), toJobWithID: jobID)
                case .text(let messageText):
                    let firstLine = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").first ?? ""
                    if !firstLine.isEmpty { addProgress(firstLine, toJobWithID: jobID) }
                }
            }
        case .result(let isError, let resultText):
            if let resultText { jobRecordsByID[jobID]?.result = resultText }
            jobRecordsByID[jobID]?.status = isError ? "failed" : "done"
        case .textDelta:
            break
        }
    }

    private func finishJob(withID jobID: String, exitCode: Int32, standardErrorText: String) {
        runningProcessesByJobID[jobID] = nil
        guard var jobRecord = jobRecordsByID[jobID] else { return }
        jobRecord.finishedAt = Self.timestamp()

        if jobRecord.wasStopRequested == true {
            jobRecord.status = "stopped"
        } else if jobRecord.status == "running" {
            if exitCode == 0 && jobRecord.result != nil {
                jobRecord.status = "done"
            } else {
                jobRecord.status = "failed"
                let lastErrorLines = standardErrorText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\n").suffix(3).joined(separator: " ")
                jobRecord.result = jobRecord.result
                    ?? (lastErrorLines.isEmpty ? "claude exited with code \(exitCode)" : lastErrorLines)
            }
        }
        jobRecord.outputFiles = Self.outputFiles(inJobFolderPath: jobRecord.folder)
        jobRecordsByID[jobID] = jobRecord
        saveJob(withID: jobID)
        Self.removeScreenshot(fromJobFolderPath: jobRecord.folder)
        print("🤖 Background agent \(jobID) \(jobRecord.status): \((jobRecord.result ?? "").prefix(120))")
    }

    private func addProgress(_ progressLine: String, toJobWithID jobID: String) {
        let shortenedProgressLine = progressLine.count > 140 ? "\(progressLine.prefix(139))…" : progressLine
        jobRecordsByID[jobID]?.progress.append(.init(at: Self.timestamp(), text: shortenedProgressLine))
        if let progressCount = jobRecordsByID[jobID]?.progress.count, progressCount > 40 {
            jobRecordsByID[jobID]?.progress.removeFirst()
        }
    }

    /// A job only needs the screenshot of the user's screen while it runs,
    /// so it's deleted as soon as the job ends (or at the next launch).
    nonisolated static func removeScreenshot(fromJobFolderPath jobFolderPath: String) {
        let screenshotURL = URL(fileURLWithPath: jobFolderPath).appendingPathComponent("tmp/screen.jpg")
        try? FileManager.default.removeItem(at: screenshotURL)
    }

    // MARK: - Saving and loading

    private func saveJob(withID jobID: String) {
        guard let jobRecord = jobRecordsByID[jobID] else { return }
        let jobEncoder = JSONEncoder()
        jobEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jobData = try? jobEncoder.encode(jobRecord) else { return }
        try? jobData.write(to: URL(fileURLWithPath: jobRecord.folder).appendingPathComponent("job.json"))
    }

    /// Past jobs come back after a restart; ones that were mid-run are marked as interrupted.
    private func loadSavedJobs() {
        guard let jobFolderURLs = try? FileManager.default.contentsOfDirectory(
            at: Self.jobsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for jobFolderURL in jobFolderURLs {
            guard let jobData = try? Data(contentsOf: jobFolderURL.appendingPathComponent("job.json")),
                  var jobRecord = try? JSONDecoder().decode(BackgroundAgentJobRecord.self, from: jobData) else {
                continue // Not a job folder, or a half-written one
            }
            if jobRecord.status == "running" {
                jobRecord.status = "interrupted"
                jobRecordsByID[jobRecord.id] = jobRecord
                saveJob(withID: jobRecord.id)
            } else {
                jobRecordsByID[jobRecord.id] = jobRecord
            }
            // Nothing runs at launch, so no job needs its screenshot any more
            Self.removeScreenshot(fromJobFolderPath: jobRecord.folder)
        }
    }

    private func publicJob(from jobRecord: BackgroundAgentJobRecord) -> BackgroundAgentJob {
        BackgroundAgentJob(
            id: jobRecord.id,
            title: jobRecord.title,
            status: jobRecord.status,
            startedAt: jobRecord.startedAt,
            finishedAt: jobRecord.finishedAt,
            latestProgress: jobRecord.progress.last?.text,
            result: jobRecord.result,
            folder: jobRecord.folder,
            // Listed live until the process exits: the result can arrive a
            // moment before the job is finished and its file list saved.
            outputFiles: jobRecord.status == "running" || runningProcessesByJobID[jobRecord.id] != nil
                ? Self.outputFiles(inJobFolderPath: jobRecord.folder)
                : jobRecord.outputFiles
        )
    }

    // MARK: - Small helpers

    /// One short, human line for what the agent is doing right now.
    nonisolated static func describeToolUse(toolName: String, toolInput: [String: Any]) -> String {
        func fileName(_ filePath: Any?) -> String {
            ((filePath as? String ?? "") as NSString).lastPathComponent
        }
        switch toolName {
        case "WebSearch":
            return "searching the web for \"\(toolInput["query"] as? String ?? "")\""
        case "WebFetch":
            if let pageURLString = toolInput["url"] as? String, let pageHost = URL(string: pageURLString)?.host {
                return "reading \(pageHost)"
            }
            return "reading a web page"
        case "Bash":
            if let commandDescription = toolInput["description"] as? String, !commandDescription.isEmpty {
                return "running \(commandDescription)"
            }
            return "running \(String((toolInput["command"] as? String ?? "").prefix(60)))"
        case "Write":
            return "writing \(fileName(toolInput["file_path"]))"
        case "Edit":
            return "editing \(fileName(toolInput["file_path"]))"
        case "Read":
            return "reading \(fileName(toolInput["file_path"]))"
        case "Glob", "Grep":
            return "looking through files"
        default:
            // "mcp__claude_ai_Gmail__search_threads" → "using Gmail: search threads"
            if toolName.hasPrefix("mcp__") {
                let toolNameParts = toolName.dropFirst("mcp__".count).components(separatedBy: "__")
                let appName = (toolNameParts.first ?? "")
                    .replacingOccurrences(of: "claude_ai_", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                let actionName = toolNameParts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                return actionName.isEmpty ? "using \(appName)" : "using \(appName): \(actionName)"
            }
            return "using \(toolName)"
        }
    }

    /// "Standing desk comparison" → "standing-desk-comparison", for the job's folder name.
    nonisolated static func folderSlug(forTitle jobTitle: String) -> String {
        let lowercasedTitle = jobTitle.lowercased()
        var folderSlug = ""
        var lastCharacterWasSeparator = false
        for character in lowercasedTitle {
            if character.isASCII && (character.isLetter || character.isNumber) {
                folderSlug.append(character)
                lastCharacterWasSeparator = false
            } else if !lastCharacterWasSeparator && !folderSlug.isEmpty {
                folderSlug.append("-")
                lastCharacterWasSeparator = true
            }
        }
        while folderSlug.hasSuffix("-") { folderSlug.removeLast() }
        let shortenedFolderSlug = String(folderSlug.prefix(40))
        let trimmedFolderSlug = shortenedFolderSlug.hasSuffix("-") ? String(shortenedFolderSlug.dropLast()) : shortenedFolderSlug
        return trimmedFolderSlug.isEmpty ? "task" : trimmedFolderSlug
    }

    /// The first six words of the brief, when Claude didn't give the job a title.
    nonisolated static func titleFromBrief(_ brief: String) -> String {
        let firstWords = brief.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return firstWords.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
    }

    nonisolated static func outputFiles(inJobFolderPath jobFolderPath: String) -> [String] {
        let outputFolderPath = (jobFolderPath as NSString).appendingPathComponent("output")
        let outputFileNames = (try? FileManager.default.contentsOfDirectory(atPath: outputFolderPath)) ?? []
        return outputFileNames.filter { !$0.hasPrefix(".") }.sorted()
    }

    private nonisolated static func timestamp() -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return timestampFormatter.string(from: Date())
    }

    private nonisolated static func dateStamp() -> String {
        String(timestamp().prefix(10))
    }
}
