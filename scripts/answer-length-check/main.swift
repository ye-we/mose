// Asks Claude Code a fixed set of voice questions with Clicky's real system
// prompt (read from CompanionManager.swift) and reports how long each spoken
// answer is. Run by scripts/check-answer-length.sh.

import Foundation

struct VoiceQuestion {
    let question: String
    let screenshotFileName: String?
    /// Questions that ask for depth may run long; everything else should be short.
    let mayRunLong: Bool
}

let voiceQuestions: [VoiceQuestion] = [
    VoiceQuestion(question: "what do you see here?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "how do i start a new thread?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "what is this app for?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "how do i allow screen recording here?", screenshotFileName: "setup-window-permissions.jpg", mayRunLong: false),
    VoiceQuestion(question: "how can i make a smooth transition between two songs when i dj?", screenshotFileName: "codex-app-screenshot.jpg", mayRunLong: false),
    VoiceQuestion(question: "what's a context window?", screenshotFileName: nil, mayRunLong: false),
    VoiceQuestion(question: "explain in depth how this setup screen works", screenshotFileName: "setup-window-permissions.jpg", mayRunLong: true),
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
                print("[\(wordCount) words, \(sentenceCount) sentences\(voiceQuestion.mayRunLong ? ", may run long" : "")] \(voiceQuestion.question)\n    → \(answerText.replacingOccurrences(of: "\n", with: " "))\n")
            } catch {
                print("ERROR \(voiceQuestion.question): \(error)")
            }
        }
        chatClient.shutDown()
        let sortedCounts = shortAnswerWordCounts.sorted()
        if !sortedCounts.isEmpty {
            print("short questions: median \(sortedCounts[sortedCounts.count / 2]) words, longest \(sortedCounts.last!) words")
        }
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
