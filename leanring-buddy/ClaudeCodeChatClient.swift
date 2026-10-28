//
//  ClaudeCodeChatClient.swift
//  leanring-buddy
//
//  Voice answers straight from Claude Code: each turn runs `claude -p` with
//  the screenshot and the question and streams the answer back as it's
//  written, so Clicky can start speaking after the first sentence. It uses
//  the user's own Claude Code sign-in, with no server in between.
//
//  Starting `claude` takes about half a second before it can answer, so a
//  started process is kept waiting for the next turn, and one is started as
//  soon as the user presses the hotkey.
//

import Foundation

/// Something that answers a voice turn about the screen, streaming as it goes.
/// `ClaudeCodeChatClient` is the default; `ClaudeAPI` talks to an HTTP bridge.
protocol CompanionChatBackend: AnyObject {
    var model: String { get set }

    /// `notesAboutUser` is what Clicky remembers about the user from earlier
    /// conversations (UserMemoryContext) and which of their apps background
    /// tasks may use (AgentConnectedApps); `earlierConversationSummary` stands
    /// in for exchanges too old to send word for word; `conversationHistory`
    /// is the recent ones, oldest first.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        notesAboutUser: String?,
        earlierConversationSummary: String?,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)

    /// A request with this system prompt is about to come (the hotkey went
    /// down), so get ready for it.
    func prepareForUpcomingRequest(systemPrompt: String)

    /// Clicky is quitting: stop anything still running.
    func shutDown()
}

extension CompanionChatBackend {
    func prepareForUpcomingRequest(systemPrompt: String) {}
    func shutDown() {}

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        earlierConversationSummary: String?,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            notesAboutUser: nil,
            earlierConversationSummary: earlierConversationSummary,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            earlierConversationSummary: nil,
            conversationHistory: [],
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            earlierConversationSummary: nil,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }
}

final class ClaudeCodeChatClient: CompanionChatBackend {
    var model: String
    /// Claude Code thinks before answering by default, which on screenshots of
    /// real apps meant up to ~18s of silence before the first word. Off unless
    /// the user turns it on.
    var isExtendedThinkingEnabled: Bool

    /// Answers time out if nothing finishes in this long.
    private static let answerTimeLimitSeconds: TimeInterval = 180

    /// `claude` runs in an empty folder so it never picks up a project's
    /// CLAUDE.md from wherever Clicky happened to be launched.
    private let emptyWorkingDirectoryURL: URL = {
        let emptyWorkingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-claude-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyWorkingDirectoryURL, withIntermediateDirectories: true)
        return emptyWorkingDirectoryURL
    }()

    private let waitingProcessPool = WaitingClaudeProcessPool()
    /// Voice answers keep a started process ready for the next turn; one-off
    /// jobs like summaries don't, so no idle process is left behind for them.
    private let keepsProcessWaitingForNextRequest: Bool

    init(model: String, isExtendedThinkingEnabled: Bool, keepsProcessWaitingForNextRequest: Bool = true) {
        self.model = model
        self.isExtendedThinkingEnabled = isExtendedThinkingEnabled
        self.keepsProcessWaitingForNextRequest = keepsProcessWaitingForNextRequest
    }

    /// The `claude` arguments for a voice turn. Tools, MCP servers, the user's
    /// settings (hooks, plugins) and slash commands are all off: a voice answer
    /// only needs to look and talk, so this keeps it fast and stops it from
    /// touching anything on the Mac.
    static func claudeArguments(
        modelAlias: String,
        systemPrompt: String,
        isExtendedThinkingEnabled: Bool
    ) -> [String] {
        var claudeArguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", modelAlias,
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if !isExtendedThinkingEnabled {
            claudeArguments += ["--settings", #"{"alwaysThinkingEnabled":false}"#]
        }
        return claudeArguments
    }

    private func currentClaudeArguments(systemPrompt: String) -> [String] {
        Self.claudeArguments(
            modelAlias: ClaudeCodeCLI.modelAlias(forRequestedModel: model),
            systemPrompt: systemPrompt,
            isExtendedThinkingEnabled: isExtendedThinkingEnabled
        )
    }

    func prepareForUpcomingRequest(systemPrompt: String) {
        let claudeArguments = currentClaudeArguments(systemPrompt: systemPrompt)
        let workingDirectoryURL = emptyWorkingDirectoryURL
        Task.detached { [waitingProcessPool] in
            guard let foundInstallation = try? await ClaudeCodeCLI.installation() else { return }
            waitingProcessPool.ensureWaitingProcess(
                claudeArguments: claudeArguments,
                installation: foundInstallation,
                workingDirectoryURL: workingDirectoryURL
            )
        }
    }

    func shutDown() {
        waitingProcessPool.stopAllWaitingProcesses()
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        notesAboutUser: String?,
        earlierConversationSummary: String?,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartDate = Date()
        let foundInstallation = try await ClaudeCodeCLI.installation()
        let claudeArguments = currentClaudeArguments(systemPrompt: systemPrompt)
        let userMessageLine = try ClaudeCodeCLI.userMessageLine(
            images: images,
            notesAboutUser: notesAboutUser,
            earlierConversationSummary: earlierConversationSummary,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let (startedProcess, wasAlreadyStarted) = try waitingProcessPool.takeProcess(
            claudeArguments: claudeArguments,
            installation: foundInstallation,
            workingDirectoryURL: emptyWorkingDirectoryURL,
            startsReplacementForNextRequest: keepsProcessWaitingForNextRequest
        )
        let payloadSizeInMegabytes = Double(userMessageLine.utf8.count) / 1_048_576.0
        print("🌐 Claude Code request: \(String(format: "%.1f", payloadSizeInMegabytes))MB, \(images.count) image(s), \(ClaudeCodeCLI.modelAlias(forRequestedModel: model))\(wasAlreadyStarted ? ", pre-started" : "")")

        let standardErrorBuffer = LockedTextBuffer()
        startedProcess.standardErrorPipe.fileHandleForReading.readabilityHandler = { readableFileHandle in
            let newlyReadData = readableFileHandle.availableData
            if newlyReadData.isEmpty {
                readableFileHandle.readabilityHandler = nil
            } else {
                standardErrorBuffer.append(String(decoding: newlyReadData, as: UTF8.self))
            }
        }

        let timeLimitWorkItem = DispatchWorkItem {
            if startedProcess.process.isRunning { startedProcess.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.answerTimeLimitSeconds, execute: timeLimitWorkItem)
        defer { timeLimitWorkItem.cancel() }

        return try await withTaskCancellationHandler {
            ChildProcessRunner.writeAndCloseOnBackgroundThread(
                Data(userMessageLine.utf8),
                to: startedProcess.standardInputPipe.fileHandleForWriting
            )

            var accumulatedResponseText = ""
            var resultEvent: (isError: Bool, resultText: String?)?
            var firstTextArrivalDate: Date?

            for await outputLine in ChildProcessRunner.outputLines(from: startedProcess.standardOutputPipe.fileHandleForReading) {
                switch ClaudeCodeCLI.parseOutputLine(outputLine) {
                case .textDelta(let textChunk):
                    if firstTextArrivalDate == nil { firstTextArrivalDate = Date() }
                    accumulatedResponseText += textChunk
                    let currentAccumulatedText = accumulatedResponseText
                    await onTextChunk(currentAccumulatedText)
                case .result(let isError, let resultText):
                    resultEvent = (isError, resultText)
                case .assistantMessage, .none:
                    break
                }
            }

            await ChildProcessRunner.waitForExitOnBackgroundThread(startedProcess.process)
            try Task.checkCancellation()

            if let claudeCodeFailure = ClaudeCodeCLI.failure(
                exitCode: startedProcess.process.terminationStatus,
                resultEvent: resultEvent,
                standardErrorText: standardErrorBuffer.text
            ) {
                print("⚠️ Claude Code failed after \(Int(Date().timeIntervalSince(requestStartDate) * 1000))ms: \(claudeCodeFailure.localizedDescription)")
                throw claudeCodeFailure
            }

            if accumulatedResponseText.isEmpty, let resultText = resultEvent?.resultText {
                accumulatedResponseText = resultText
            }
            let totalDuration = Date().timeIntervalSince(requestStartDate)
            let firstTextDelayDescription = firstTextArrivalDate.map { "first words after \(Int($0.timeIntervalSince(requestStartDate) * 1000))ms, " } ?? ""
            print("⏱️ Claude Code answered: \(firstTextDelayDescription)done after \(Int(totalDuration * 1000))ms")
            return (text: accumulatedResponseText, duration: totalDuration)
        } onCancel: {
            // The user started talking again: stop spending usage on an answer nobody will hear
            if startedProcess.process.isRunning { startedProcess.process.terminate() }
        }
    }
}

/// A `claude` process that's been started and is waiting for its message on stdin.
final class StartedClaudeProcess {
    let process: Process
    let standardInputPipe = Pipe()
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    let startedDate = Date()

    init(claudeArguments: [String], installation: ClaudeCodeInstallation, workingDirectoryURL: URL) throws {
        process = Process()
        process.executableURL = installation.binaryURL
        process.arguments = claudeArguments
        process.environment = installation.processEnvironment
        process.currentDirectoryURL = workingDirectoryURL
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

/// Keeps a started `claude` waiting per set of arguments (model, system prompt,
/// thinking) so the next turn skips startup. Waiting processes are replaced
/// after ten minutes so sign-ins and Claude Code updates never go stale.
final class WaitingClaudeProcessPool {
    private static let maximumWaitingSeconds: TimeInterval = 10 * 60
    private static let maximumWaitingProcessCount = 2

    private let lock = NSLock()
    /// Oldest first, so the longest-waiting process is the one replaced when full.
    private var waitingProcesses: [(argumentsKey: [String], startedProcess: StartedClaudeProcess)] = []

    /// A started process for these arguments: a waiting one if there is one,
    /// otherwise a new one. A replacement starts right away for the next turn.
    func takeProcess(
        claudeArguments: [String],
        installation: ClaudeCodeInstallation,
        workingDirectoryURL: URL,
        startsReplacementForNextRequest: Bool = true
    ) throws -> (startedProcess: StartedClaudeProcess, wasAlreadyStarted: Bool) {
        lock.lock()
        removeExpiredProcessesWhileLocked()
        var takenWaitingProcess: StartedClaudeProcess?
        if let waitingProcessIndex = waitingProcesses.firstIndex(where: { $0.argumentsKey == claudeArguments }) {
            takenWaitingProcess = waitingProcesses.remove(at: waitingProcessIndex).startedProcess
        }
        lock.unlock()

        let startedProcess: StartedClaudeProcess
        let wasAlreadyStarted: Bool
        if let takenWaitingProcess {
            startedProcess = takenWaitingProcess
            wasAlreadyStarted = true
        } else {
            startedProcess = try StartedClaudeProcess(
                claudeArguments: claudeArguments,
                installation: installation,
                workingDirectoryURL: workingDirectoryURL
            )
            wasAlreadyStarted = false
        }

        if startsReplacementForNextRequest {
            ensureWaitingProcess(claudeArguments: claudeArguments, installation: installation, workingDirectoryURL: workingDirectoryURL)
        }
        return (startedProcess, wasAlreadyStarted)
    }

    /// Starts a waiting process for these arguments unless one is already waiting.
    func ensureWaitingProcess(claudeArguments: [String], installation: ClaudeCodeInstallation, workingDirectoryURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredProcessesWhileLocked()
        guard !waitingProcesses.contains(where: { $0.argumentsKey == claudeArguments }) else { return }

        if waitingProcesses.count >= Self.maximumWaitingProcessCount {
            waitingProcesses.removeFirst().startedProcess.stop()
        }
        guard let newlyStartedProcess = try? StartedClaudeProcess(
            claudeArguments: claudeArguments,
            installation: installation,
            workingDirectoryURL: workingDirectoryURL
        ) else { return }
        waitingProcesses.append((claudeArguments, newlyStartedProcess))

        // Don't keep an idle process around forever if no turn comes
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.maximumWaitingSeconds + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.removeExpiredProcessesWhileLocked()
            self.lock.unlock()
        }
    }

    func stopAllWaitingProcesses() {
        lock.lock()
        let processesToStop = waitingProcesses.map(\.startedProcess)
        waitingProcesses.removeAll()
        lock.unlock()
        processesToStop.forEach { $0.stop() }
    }

    private func removeExpiredProcessesWhileLocked() {
        let now = Date()
        waitingProcesses.removeAll { waitingProcess in
            let isExpired = now.timeIntervalSince(waitingProcess.startedProcess.startedDate) > Self.maximumWaitingSeconds
            let hasExited = !waitingProcess.startedProcess.process.isRunning
            if isExpired { waitingProcess.startedProcess.stop() }
            return isExpired || hasExited
        }
    }
}
