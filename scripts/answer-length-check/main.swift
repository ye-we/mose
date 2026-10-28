// Asks Claude Code a fixed set of voice questions with Clicky's real system
// prompt (read from CompanionManager.swift) and reports how long each spoken
// answer is, and for how-tos whether the next click got a target or was only
// said (GuidedStepAnswerCheck). Run by scripts/check-answer-length.sh.

import Foundation

struct VoiceQuestion {
    let question: String
    let screenshotFileName: String?
    /// Questions that ask for depth may run long; everything else should be short.
    let mayRunLong: Bool
    /// How-tos whose first step is a click on something in the screenshot,
    /// so the answer should mark it with a target.
    var expectsTarget = false
}

let voiceQuestions: [VoiceQuestion] = [
    VoiceQuestion(question: "what do you see here?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "how do i start a new thread?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false, expectsTarget: true),
    VoiceQuestion(question: "what is this app for?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "how do i allow screen recording here?", screenshotFileName: "setup-window-permissions.jpg", mayRunLong: false, expectsTarget: true),
    VoiceQuestion(question: "how do i open system settings?", screenshotFileName: "finder-menu-bar.jpg", mayRunLong: false, expectsTarget: true),
    VoiceQuestion(question: "how do i show the path bar in finder?", screenshotFileName: "finder-menu-bar.jpg", mayRunLong: false, expectsTarget: true),
    VoiceQuestion(question: "how do i make a new folder here?", screenshotFileName: "finder-menu-bar.jpg", mayRunLong: false, expectsTarget: true),
    VoiceQuestion(question: "how can i make a smooth transition between two songs when i dj?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "what's a context window?", screenshotFileName: nil, mayRunLong: false),
    VoiceQuestion(question: "explain in depth how this setup screen works", screenshotFileName: "setup-window-permissions.jpg", mayRunLong: true),
]

/// An answer that said a click without marking it, and whether the app's
/// follow-up should get a target (the click is on screen) or only [POINT:none].
struct MissingTargetFollowUpCase {
    let question: String
    let screenshotFileName: String
    let answerWithoutTarget: String
    let clickIsOnScreen: Bool
}

let missingTargetFollowUpCases: [MissingTargetFollowUpCase] = [
    MissingTargetFollowUpCase(question: "how do i open system settings?", screenshotFileName: "finder-menu-bar.jpg",
                              answerWithoutTarget: "open system settings from the apple menu. [POINT:none]", clickIsOnScreen: true),
    MissingTargetFollowUpCase(question: "how do i finish setting this up?", screenshotFileName: "setup-window-permissions.jpg",
                              answerWithoutTarget: "click allow next to accessibility, then allow screen recording too.", clickIsOnScreen: true),
    MissingTargetFollowUpCase(question: "how do i open system settings?", screenshotFileName: "codex-app-screenshot.jpg",
                              answerWithoutTarget: "open system settings from the apple menu. [POINT:none]", clickIsOnScreen: false),
]

@main
struct AnswerLengthCheck {
    static func main() async {
        let repositoryRoot = URL(fileURLWithPath: CommandLine.arguments[1])
        let companionManagerSource = try! String(contentsOf: repositoryRoot.appendingPathComponent("leanring-buddy/CompanionManager.swift"), encoding: .utf8)
        let promptStart = companionManagerSource.range(of: "companionVoiceResponseSystemPrompt = \"\"\"\n")!.upperBound
        let promptEnd = companionManagerSource.range(of: "\n    \"\"\"", range: promptStart..<companionManagerSource.endIndex)!.lowerBound
        let systemPrompt = companionManagerSource[promptStart..<promptEnd]
            .components(separatedBy: "\n")
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : $0 }
            .joined(separator: "\n")

        let chatClient = ClaudeCodeChatClient(model: "claude-sonnet-4-6", isExtendedThinkingEnabled: false)
        var shortAnswerWordCounts: [Int] = []
        var howToCount = 0
        var howTosWithTarget = 0
        var howTosWithClickSaidButNotMarked = 0
        var howTosMarkedAfterTheFollowUp = 0
        for voiceQuestion in voiceQuestions {
            var images: [(data: Data, label: String)] = []
            if let screenshotFileName = voiceQuestion.screenshotFileName {
                let screenshotURL = repositoryRoot.appendingPathComponent("scripts/sketch-tests/fixtures/\(screenshotFileName)")
                let screenshotData = try! Data(contentsOf: screenshotURL)
                let screenshotSize = imagePixelSize(of: screenshotURL)
                images = [(screenshotData, "screen 1 of 1 (primary focus) (image dimensions: \(screenshotSize) pixels)")]
            }
            do {
                let (answerText, _) = try await chatClient.analyzeImageStreaming(
                    images: images, systemPrompt: systemPrompt, conversationHistory: [],
                    userPrompt: voiceQuestion.question, onTextChunk: { _ in })
                let spokenText = answerText.replacingOccurrences(of: #"\[[A-Z]+:[^\]]*\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let wordCount = spokenText.split(whereSeparator: \.isWhitespace).count
                let sentenceCount = spokenText.components(separatedBy: CharacterSet(charactersIn: ".?!")).filter { $0.trimmingCharacters(in: .whitespaces).count > 2 }.count
                if !voiceQuestion.mayRunLong { shortAnswerWordCounts.append(wordCount) }
                var targetNote = ""
                if voiceQuestion.expectsTarget {
                    howToCount += 1
                    if GuidedStepAnswerCheck.answerHasTarget(answerText) {
                        howTosWithTarget += 1
                        targetNote = ", target"
                    } else if GuidedStepAnswerCheck.isClickInstructionWithoutTarget(answerText) {
                        howTosWithClickSaidButNotMarked += 1
                        targetNote = ", CLICK SAID BUT NOT MARKED"
                        // What the app does next: ask once more for the mark
                        let (followUpAnswerText, _) = try await chatClient.analyzeImageStreaming(
                            images: images, systemPrompt: systemPrompt,
                            conversationHistory: [(userPlaceholder: voiceQuestion.question, assistantResponse: answerText)],
                            userPrompt: GuidedStepAnswerCheck.missingTargetFollowUpTranscript, onTextChunk: { _ in })
                        let isMarkedAfterTheFollowUp = GuidedStepAnswerCheck.answerHasTarget(followUpAnswerText)
                        if isMarkedAfterTheFollowUp { howTosMarkedAfterTheFollowUp += 1 }
                        targetNote += "; follow-up \(isMarkedAfterTheFollowUp ? "marked it" : "DIDN'T MARK IT"): \(followUpAnswerText.replacingOccurrences(of: "\n", with: " "))"
                    } else {
                        targetNote = ", NO TARGET"
                    }
                }
                print("[\(wordCount) words, \(sentenceCount) sentences\(voiceQuestion.mayRunLong ? ", may run long" : "")\(targetNote)] \(voiceQuestion.question)\n    → \(answerText.replacingOccurrences(of: "\n", with: " "))\n")
            } catch {
                print("ERROR \(voiceQuestion.question): \(error)")
            }
        }
        var followUpsAsExpected = 0
        for followUpCase in missingTargetFollowUpCases {
            let screenshotURL = repositoryRoot.appendingPathComponent("scripts/sketch-tests/fixtures/\(followUpCase.screenshotFileName)")
            let images = [(data: try! Data(contentsOf: screenshotURL), label: "screen 1 of 1 (primary focus) (image dimensions: \(imagePixelSize(of: screenshotURL)) pixels)")]
            do {
                let (followUpAnswerText, _) = try await chatClient.analyzeImageStreaming(
                    images: images, systemPrompt: systemPrompt,
                    conversationHistory: [(userPlaceholder: followUpCase.question, assistantResponse: followUpCase.answerWithoutTarget)],
                    userPrompt: GuidedStepAnswerCheck.missingTargetFollowUpTranscript, onTextChunk: { _ in })
                let spokenText = followUpAnswerText.replacingOccurrences(of: #"\[[A-Z]+:[^\]]*\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isAsExpected = followUpCase.clickIsOnScreen
                    ? GuidedStepAnswerCheck.answerHasTarget(followUpAnswerText)
                    : !GuidedStepAnswerCheck.answerHasTarget(followUpAnswerText) && spokenText.isEmpty
                if isAsExpected { followUpsAsExpected += 1 }
                print("[follow-up \(isAsExpected ? "ok" : "NOT AS EXPECTED"), expected \(followUpCase.clickIsOnScreen ? "a target" : "silence")] \(followUpCase.answerWithoutTarget) (\(followUpCase.screenshotFileName))\n    → \(followUpAnswerText.replacingOccurrences(of: "\n", with: " "))\n")
            } catch {
                print("ERROR follow-up \(followUpCase.question): \(error)")
            }
        }
        chatClient.shutDown()
        let sortedCounts = shortAnswerWordCounts.sorted()
        if !sortedCounts.isEmpty {
            print("short questions: median \(sortedCounts[sortedCounts.count / 2]) words, longest \(sortedCounts.last!) words")
        }
        if howToCount > 0 {
            print("how-tos: \(howTosWithTarget)/\(howToCount) marked the next click, \(howTosWithClickSaidButNotMarked) said a click without marking it (\(howTosMarkedAfterTheFollowUp) marked after the follow-up)")
        }
        print("follow-ups for a click said without a mark: \(followUpsAsExpected)/\(missingTargetFollowUpCases.count) as expected")
    }

    static func imagePixelSize(of imageURL: URL) -> String {
        let sipsProcess = Process()
        sipsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sipsProcess.arguments = ["-g", "pixelWidth", "-g", "pixelHeight", imageURL.path]
        let outputPipe = Pipe(); sipsProcess.standardOutput = outputPipe
        try? sipsProcess.run(); sipsProcess.waitUntilExit()
        let numbers = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .components(separatedBy: .whitespacesAndNewlines).compactMap { Int($0) }
        return numbers.count >= 2 ? "\(numbers[0])x\(numbers[1])" : "unknown"
    }
}
