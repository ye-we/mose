// Checks how Claude Code handles memory with Clicky's real prompts: asking to
// remember and forget, using what it remembers, telling forgetting a fact
// apart from starting over, and Haiku picking facts out of a finished
// conversation. Run by scripts/check-memory.sh.

import Foundation

struct MemoryVoiceCase {
    let question: String
    let knownFacts: [String]
    let isMemoryEnabled: Bool
    /// What the answer must contain (a tag, or a word from a known fact).
    let expectedText: String
    /// What it must not contain.
    let unexpectedText: String?
}

let memoryVoiceCases: [MemoryVoiceCase] = [
    MemoryVoiceCase(question: "remember that i keep my invoices in dropbox", knownFacts: [], isMemoryEnabled: true, expectedText: "[REMEMBER:", unexpectedText: nil),
    MemoryVoiceCase(question: "which app do i use to dj again?", knownFacts: ["they dj with mixxx on a controller"], isMemoryEnabled: true, expectedText: "mixxx", unexpectedText: nil),
    MemoryVoiceCase(question: "forget that i keep my invoices in dropbox", knownFacts: ["they keep their invoices in dropbox", "they dj with mixxx"], isMemoryEnabled: true, expectedText: "[FORGET:", unexpectedText: "[SESSION:"),
    MemoryVoiceCase(question: "forget everything you know about me", knownFacts: ["they keep their invoices in dropbox"], isMemoryEnabled: true, expectedText: "[FORGET:everything]", unexpectedText: nil),
    MemoryVoiceCase(question: "let's forget what we talked about and start fresh", knownFacts: ["they dj with mixxx"], isMemoryEnabled: true, expectedText: "[SESSION:new]", unexpectedText: "[FORGET:"),
    MemoryVoiceCase(question: "what do you remember about me?", knownFacts: ["they dj with mixxx", "they edit videos in final cut pro"], isMemoryEnabled: true, expectedText: "final cut", unexpectedText: nil),
    MemoryVoiceCase(question: "remember that my sister's name is ana", knownFacts: [], isMemoryEnabled: false, expectedText: "history", unexpectedText: "[REMEMBER:"),
]

@main
struct MemoryCheck {
    @MainActor
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
        var passedCaseCount = 0
        for memoryVoiceCase in memoryVoiceCases {
            let knownFacts = memoryVoiceCase.knownFacts.enumerated().map { factIndex, factText in
                RememberedFact(id: UUID(), text: factText, rememberedAt: Date().addingTimeInterval(Double(factIndex)), origin: .learnedFromConversation, conversationID: nil)
            }
            let notesAboutUser = UserMemoryContext.noteForClaude(facts: knownFacts, isMemoryEnabled: memoryVoiceCase.isMemoryEnabled)
            do {
                let (answerText, _) = try await chatClient.analyzeImageStreaming(
                    images: [], systemPrompt: systemPrompt, notesAboutUser: notesAboutUser,
                    earlierConversationSummary: nil, conversationHistory: [],
                    userPrompt: memoryVoiceCase.question, onTextChunk: { _ in })
                let lowercasedAnswer = answerText.lowercased()
                let isAsExpected = lowercasedAnswer.contains(memoryVoiceCase.expectedText.lowercased())
                    && !(memoryVoiceCase.unexpectedText.map { lowercasedAnswer.contains($0.lowercased()) } ?? false)
                if isAsExpected { passedCaseCount += 1 }
                print("[\(isAsExpected ? "ok" : "NOT AS EXPECTED"), wanted \(memoryVoiceCase.expectedText)\(memoryVoiceCase.isMemoryEnabled ? "" : ", memory off")] \(memoryVoiceCase.question)\n    → \(answerText.replacingOccurrences(of: "\n", with: " "))\n")
            } catch {
                print("ERROR \(memoryVoiceCase.question): \(error)")
            }
        }
        chatClient.shutDown()

        // Learning from a finished conversation, with Haiku like the app
        let learningClient = ClaudeCodeChatClient(model: "claude-haiku-4-5", isExtendedThinkingEnabled: false, keepsProcessWaitingForNextRequest: false)
        let finishedConversation = ConversationSession(
            id: UUID(), title: "How do I export my video", startedAt: Date(), lastActivityAt: Date(),
            exchanges: [
                ConversationExchange(id: UUID(), askedAt: Date(), userTranscript: "how do i export this for youtube? it's for my cooking channel", assistantResponse: "click file up in the menu bar. [DRAW:target 62,4,92,22 label=\"file\"]", isGuidedStepFollowUp: false, frontmostAppName: "Final Cut Pro"),
                ConversationExchange(id: UUID(), askedAt: Date(), userTranscript: "(guided step) i clicked file. what's next?", assistantResponse: "now pick share. [DRAW:target 70,200,190,220 label=\"share\"]", isGuidedStepFollowUp: true, frontmostAppName: "Final Cut Pro"),
                ConversationExchange(id: UUID(), askedAt: Date(), userTranscript: "i always forget, i only used imovie before this", assistantResponse: "no worries, share works like imovie's export. [POINT:none]", isGuidedStepFollowUp: false, frontmostAppName: "Final Cut Pro"),
                ConversationExchange(id: UUID(), askedAt: Date(), userTranscript: "it keeps saying the export failed with an error", assistantResponse: "try freeing some disk space, then share again. [POINT:none]", isGuidedStepFollowUp: false, frontmostAppName: "Final Cut Pro"),
            ],
            earlierSummary: nil, summarizedExchangeCount: 0)
        let knownFacts = [RememberedFact(id: UUID(), text: "they edit videos in imovie", rememberedAt: Date(), origin: .learnedFromConversation, conversationID: nil)]
        let quietConversation = ConversationSession(
            id: UUID(), title: "What time is it in Tokyo", startedAt: Date(), lastActivityAt: Date(),
            exchanges: [ConversationExchange(id: UUID(), askedAt: Date(), userTranscript: "what time is it in tokyo right now?", assistantResponse: "it's about eleven at night there. [POINT:none]", isGuidedStepFollowUp: false, frontmostAppName: "Safari")],
            earlierSummary: nil, summarizedExchangeCount: 0)
        for (conversationSession, expectsFacts) in [(finishedConversation, true), (quietConversation, false)] {
            do {
                let (learningReply, _) = try await learningClient.analyzeImageStreaming(
                    images: [], systemPrompt: UserMemoryContext.learningSystemPrompt,
                    userPrompt: UserMemoryContext.learningRequest(conversationSession: conversationSession, knownFacts: knownFacts),
                    onTextChunk: { _ in })
                let (factsToAdd, factsToDrop) = UserMemoryContext.parseLearningReply(learningReply)
                let keptAOneOffProblem = factsToAdd.contains { $0.lowercased().contains("error") || $0.lowercased().contains("fail") }
                let isAsExpected = (expectsFacts ? !factsToAdd.isEmpty : factsToAdd.isEmpty) && !keptAOneOffProblem
                if isAsExpected { passedCaseCount += 1 }
                print("[learning \(isAsExpected ? "ok" : "NOT AS EXPECTED"), expected \(expectsFacts ? "facts" : "none")] \(conversationSession.title)\n    + \(factsToAdd)\n    - \(factsToDrop)\n    raw: \(learningReply.replacingOccurrences(of: "\n", with: " | "))\n")
            } catch {
                print("ERROR learning from \(conversationSession.title): \(error)")
            }
        }
        learningClient.shutDown()
        print("memory checks: \(passedCaseCount)/\(memoryVoiceCases.count + 2) as expected")
    }
}
