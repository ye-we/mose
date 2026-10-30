//
//  ConversationSessions.swift
//  leanring-buddy
//
//  Clicky's conversations: each one is saved as a JSON file on this Mac, so it
//  survives a restart and can be picked up again later. This file has
//
//  - the saved conversation and exchange models and the store that reads and
//    writes them (one file per conversation in Application Support);
//  - the context policy: which exchanges go to Claude word for word, and
//    which older ones are folded into a short summary instead;
//  - the voice commands for starting over and going back to an older
//    conversation, recognized on the Mac without asking Claude;
//  - search, for "go back to the chat about ..." and the history window.
//
//  Nothing here leaves the Mac except when a conversation is sent to Claude
//  as context for the next answer. Foundation only, so the standalone tests
//  can use it.
//

import Combine
import Foundation

// MARK: - Models

/// One thing the user said and what Clicky answered.
struct ConversationExchange: Codable, Equatable, Identifiable {
    let id: UUID
    let askedAt: Date
    let userTranscript: String
    /// Clicky's answer with its tags, so later turns keep seeing how it pointed and drew.
    let assistantResponse: String
    /// "(guided step) i clicked ..." turns Clicky sent itself after a click.
    let isGuidedStepFollowUp: Bool
    /// The app that was in front when they asked, if known.
    let frontmostAppName: String?
}

/// One conversation, saved as its own file.
struct ConversationSession: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    let startedAt: Date
    var lastActivityAt: Date
    var exchanges: [ConversationExchange]
    /// A short summary of `exchanges[0..<summarizedExchangeCount]`, written by
    /// Claude once the conversation is too long to send whole.
    var earlierSummary: String?
    var summarizedExchangeCount: Int
    /// How many exchanges had been said when it was last looked through for
    /// lasting facts to remember (UserMemory). Nil until then, and in
    /// conversations saved before memory existed.
    var memoryReviewedExchangeCount: Int? = nil

    /// Exchanges the user started, without Clicky's own guided-step turns.
    var questionCount: Int { exchanges.filter { !$0.isGuidedStepFollowUp }.count }
}

// MARK: - Store

@MainActor
final class ConversationSessionStore: ObservableObject {
    /// Every saved conversation, newest activity first.
    @Published private(set) var sessions: [ConversationSession] = []
    /// The conversation new exchanges go into. Nil means the next question
    /// starts a fresh one (it's only saved once something is said in it).
    @Published private(set) var currentSessionID: UUID?

    let conversationsDirectoryURL: URL
    /// When the user last picked a conversation to continue, so an older one
    /// they just resumed isn't immediately treated as stale.
    private var currentSessionChosenAt: Date?

    /// ~/Library/Application Support/<bundle id>/Conversations
    nonisolated static var defaultDirectoryURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolderName = Bundle.main.bundleIdentifier ?? "Mose"
        return applicationSupportURL.appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    init(conversationsDirectoryURL: URL = ConversationSessionStore.defaultDirectoryURL) {
        self.conversationsDirectoryURL = conversationsDirectoryURL
        loadSavedSessions()
    }

    var currentSession: ConversationSession? {
        guard let currentSessionID else { return nil }
        return sessions.first { $0.id == currentSessionID }
    }

    func session(withID sessionID: UUID) -> ConversationSession? {
        sessions.first { $0.id == sessionID }
    }

    // MARK: Switching conversations

    /// The next question starts a new conversation. The old one stays saved.
    func startNewSession() {
        currentSessionID = nil
        currentSessionChosenAt = Date()
    }

    func resumeSession(withID sessionID: UUID) {
        guard session(withID: sessionID) != nil else { return }
        currentSessionID = sessionID
        currentSessionChosenAt = Date()
    }

    /// Whether the current conversation has been quiet long enough that the
    /// next question should start a new one.
    func isCurrentSessionIdle(at now: Date, idleLimitSeconds: TimeInterval) -> Bool {
        guard let currentSession else { return false }
        let lastTouchedAt = max(currentSession.lastActivityAt, currentSessionChosenAt ?? .distantPast)
        return now.timeIntervalSince(lastTouchedAt) > idleLimitSeconds
    }

    // MARK: Recording exchanges

    /// Saves an exchange into the current conversation, starting one if needed.
    @discardableResult
    func recordExchange(_ conversationExchange: ConversationExchange) -> ConversationSession {
        var updatedSession: ConversationSession
        if let currentSession {
            updatedSession = currentSession
        } else {
            updatedSession = ConversationSession(
                id: UUID(),
                title: "",
                startedAt: conversationExchange.askedAt,
                lastActivityAt: conversationExchange.askedAt,
                exchanges: [],
                earlierSummary: nil,
                summarizedExchangeCount: 0
            )
            currentSessionID = updatedSession.id
        }
        updatedSession.exchanges.append(conversationExchange)
        updatedSession.lastActivityAt = conversationExchange.askedAt
        if updatedSession.title.isEmpty && !conversationExchange.isGuidedStepFollowUp {
            updatedSession.title = ConversationTitle.title(fromFirstQuestion: conversationExchange.userTranscript)
        }
        saveAndPublish(updatedSession)
        return updatedSession
    }

    func updateEarlierSummary(ofSessionWithID sessionID: UUID, summary: String, summarizedExchangeCount: Int) {
        guard var summarizedSession = session(withID: sessionID),
              summarizedExchangeCount > summarizedSession.summarizedExchangeCount,
              summarizedExchangeCount <= summarizedSession.exchanges.count else { return }
        summarizedSession.earlierSummary = summary
        summarizedSession.summarizedExchangeCount = summarizedExchangeCount
        saveAndPublish(summarizedSession)
    }

    func markReviewedForMemory(sessionWithID sessionID: UUID, exchangeCount: Int) {
        guard var reviewedSession = session(withID: sessionID) else { return }
        reviewedSession.memoryReviewedExchangeCount = exchangeCount
        saveAndPublish(reviewedSession)
    }

    func renameSession(withID sessionID: UUID, to newTitle: String) {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var renamedSession = session(withID: sessionID), !trimmedTitle.isEmpty else { return }
        renamedSession.title = trimmedTitle
        saveAndPublish(renamedSession)
    }

    // MARK: Deleting

    func deleteSession(withID sessionID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(forSessionWithID: sessionID))
        sessions.removeAll { $0.id == sessionID }
        if currentSessionID == sessionID { currentSessionID = nil }
    }

    func deleteAllSessions() {
        for savedSession in sessions {
            try? FileManager.default.removeItem(at: fileURL(forSessionWithID: savedSession.id))
        }
        sessions.removeAll()
        currentSessionID = nil
    }

    // MARK: Files

    private func fileURL(forSessionWithID sessionID: UUID) -> URL {
        conversationsDirectoryURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static let sessionEncoder: JSONEncoder = {
        let sessionEncoder = JSONEncoder()
        sessionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        sessionEncoder.dateEncodingStrategy = .iso8601
        return sessionEncoder
    }()

    private static let sessionDecoder: JSONDecoder = {
        let sessionDecoder = JSONDecoder()
        sessionDecoder.dateDecodingStrategy = .iso8601
        return sessionDecoder
    }()

    private func saveAndPublish(_ updatedSession: ConversationSession) {
        sessions.removeAll { $0.id == updatedSession.id }
        sessions.insert(updatedSession, at: 0)
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        do {
            try FileManager.default.createDirectory(at: conversationsDirectoryURL, withIntermediateDirectories: true)
            let sessionData = try Self.sessionEncoder.encode(updatedSession)
            try sessionData.write(to: fileURL(forSessionWithID: updatedSession.id), options: .atomic)
        } catch {
            print("⚠️ Couldn't save conversation \(updatedSession.id): \(error)")
        }
    }

    private func loadSavedSessions() {
        guard let sessionFileURLs = try? FileManager.default.contentsOfDirectory(
            at: conversationsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        sessions = sessionFileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { sessionFileURL in
                guard let sessionData = try? Data(contentsOf: sessionFileURL) else { return nil }
                return try? Self.sessionDecoder.decode(ConversationSession.self, from: sessionData)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}

// MARK: - Context sent to Claude

enum ConversationContext {
    /// Recent exchanges go to Claude word for word, up to this many...
    static let maximumVerbatimExchangeCount = 12
    /// ...and this many characters of transcript and answer together.
    static let verbatimCharacterBudget = 9_000

    /// Where the word-for-word part of the conversation starts: the newest
    /// exchanges that fit the limits, but never past what the summary covers,
    /// so nothing falls between the summary and the recent exchanges.
    static func verbatimStartIndex(for conversationSession: ConversationSession) -> Int {
        let exchanges = conversationSession.exchanges
        var windowStartIndex = exchanges.count
        var usedCharacterCount = 0
        while windowStartIndex > 0 {
            let candidateExchange = exchanges[windowStartIndex - 1]
            let candidateCharacterCount = candidateExchange.userTranscript.count + candidateExchange.assistantResponse.count
            let windowExchangeCount = exchanges.count - windowStartIndex
            guard windowExchangeCount < maximumVerbatimExchangeCount,
                  windowExchangeCount == 0 || usedCharacterCount + candidateCharacterCount <= verbatimCharacterBudget else { break }
            usedCharacterCount += candidateCharacterCount
            windowStartIndex -= 1
        }
        // Exchanges the summary doesn't cover yet stay word for word, up to a
        // second window's worth, so a summary that's behind never loses them
        // but a summary that keeps failing can't make the context grow forever.
        let earliestAllowedStartIndex = max(windowStartIndex - maximumVerbatimExchangeCount, 0)
        return max(min(windowStartIndex, conversationSession.summarizedExchangeCount), earliestAllowedStartIndex)
    }

    /// What goes to Claude for the next answer.
    static func context(for conversationSession: ConversationSession?) -> (earlierSummary: String?, recentExchanges: [ConversationExchange]) {
        guard let conversationSession else { return (nil, []) }
        let windowStartIndex = verbatimStartIndex(for: conversationSession)
        let summaryCoversSomething = conversationSession.earlierSummary != nil
            && conversationSession.summarizedExchangeCount > 0
            && windowStartIndex > 0
        return (
            summaryCoversSomething ? conversationSession.earlierSummary : nil,
            Array(conversationSession.exchanges[windowStartIndex...])
        )
    }

    /// The exchanges that fell out of the word-for-word window and aren't in
    /// the summary yet, or nil if the summary is up to date.
    static func exchangesToSummarize(in conversationSession: ConversationSession) -> (exchanges: [ConversationExchange], summarizedExchangeCountAfterwards: Int)? {
        var windowOnlyByLimits = conversationSession
        windowOnlyByLimits.summarizedExchangeCount = conversationSession.exchanges.count
        let windowStartIndex = max(verbatimStartIndex(for: windowOnlyByLimits), 0)
        guard windowStartIndex > conversationSession.summarizedExchangeCount else { return nil }
        return (Array(conversationSession.exchanges[conversationSession.summarizedExchangeCount..<windowStartIndex]), windowStartIndex)
    }

    static let summarizerSystemPrompt = """
    you keep the running summary of a conversation between a person and mose, a voice assistant that sees their screen. write at most 120 words, plain text, no lists. keep what later questions might need: what they were working on and in which apps, decisions, facts and names they mentioned, what clicky told them to do, and anything left open. leave out greetings, filler and screen coordinates. refer to the person as "they".
    """

    /// The request for an updated summary: the previous summary plus the
    /// exchanges to fold into it.
    static func summaryRequest(previousSummary: String?, exchangesToFold: [ConversationExchange]) -> String {
        let foldedTranscript = exchangesToFold.map { conversationExchange in
            "they said: \(conversationExchange.userTranscript)\nmose said: \(spokenText(of: conversationExchange.assistantResponse))"
        }.joined(separator: "\n")
        let previousSummaryText = previousSummary.map { "the summary so far:\n\($0)\n\n" } ?? ""
        return "\(previousSummaryText)fold these later exchanges into the summary and reply with only the new summary:\n\(foldedTranscript)"
    }

    /// An answer without its POINT, DRAW, AGENT, SESSION, REMEMBER and FORGET tags.
    static func spokenText(of assistantResponse: String) -> String {
        assistantResponse
            .replacingOccurrences(of: #"\[(POINT|DRAW|AGENT|SESSION|REMEMBER|FORGET):[^\]]*\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
    }
}

// MARK: - Titles

enum ConversationTitle {
    /// A short title from the first thing the user asked: its first few words,
    /// without fillers like "hey" or "um", starting with a capital.
    static func title(fromFirstQuestion firstQuestion: String) -> String {
        let fillerWords: Set<String> = ["hey", "hi", "hello", "mose", "clicky", "um", "uh", "so", "okay", "ok", "yo", "please"]
        var titleWords = firstQuestion
            .replacingOccurrences(of: #"[^\p{L}\p{N}'\s-]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        while let firstWord = titleWords.first, fillerWords.contains(firstWord.lowercased()) {
            titleWords.removeFirst()
        }
        // Speech recognition sometimes leaves "i" lowercase
        titleWords = titleWords.map { titleWord in
            titleWord == "i" || titleWord.hasPrefix("i'") ? "I" + titleWord.dropFirst() : titleWord
        }
        let shortenedTitle = titleWords.prefix(7).joined(separator: " ")
        guard let firstCharacter = shortenedTitle.first else { return "New conversation" }
        return firstCharacter.uppercased() + shortenedTitle.dropFirst() + (titleWords.count > 7 ? "…" : "")
    }
}

// MARK: - Voice commands

enum ConversationVoiceCommand: Equatable {
    /// "start a new session", optionally followed by a question to ask in it.
    case startNewSession(followingQuestion: String?)
    /// "go back to the chat about X"; nil topic means the previous conversation.
    case resumeSession(topic: String?)

    /// Recognizes the commands when they're what the user said, or the first
    /// part of it ("new chat. how do i export a pdf?"). A request about some
    /// app ("start a new chat in slack") isn't a command, and neither is a
    /// question ("how do i start a new chat").
    static func parse(_ transcript: String) -> ConversationVoiceCommand? {
        // "Hey Clicky, start over": the wake word is its own clause, so it goes first
        let transcriptWithoutWakeWord = transcript.replacingOccurrences(
            of: #"^\s*(?:(?:hey|okay|ok|hi)\s+)?(?:mose|clicky)\s*[,.!:]?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let (commandClause, followingText) = splitFirstClause(of: transcriptWithoutWakeWord)
        let normalizedClause = normalizedCommandText(commandClause)
        guard !normalizedClause.isEmpty else { return nil }

        // "thread" is left out on purpose: "start a new thread" is a real
        // action in apps like Slack and Codex that users ask for help with
        let conversationWords = #"(?:session|chat|conversation|topic)"#
        let newSessionPatterns = [
            #"^(?:let'?s |can we |could we |can you |please )?(?:start |begin |open |make )?(?:a )?(?:new|fresh|brand new) \#(conversationWords)(?: please)?$"#,
            #"^(?:let'?s |can we |please )?(?:start|begin) (?:over|fresh|again|from scratch)(?: please)?$"#,
            #"^(?:a )?fresh start$"#,
            #"^(?:clear|reset|wipe) (?:the |this |our |your )?(?:\#(conversationWords)|context|history|memory)$"#,
            #"^forget (?:everything|all that|all of that|about that|that|this conversation|what we talked about|our conversation)$"#,
        ]
        if newSessionPatterns.contains(where: { normalizedClause.range(of: $0, options: .regularExpression) != nil }) {
            let followingQuestion = followingText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .startNewSession(followingQuestion: followingQuestion.split(separator: " ").count >= 2 ? followingQuestion : nil)
        }

        let resumePattern = #"^(?:can we |let'?s |please )?(?:go back to|back to|continue|resume|pick up|reopen|return to) (?:the |my |our |that )?(?:(last|previous|earlier|older|old|other) )?\#(conversationWords)(?: (?:about|on|from|where we talked about|we had about|with) (.+))?$"#
        if let resumeMatch = normalizedClause.range(of: resumePattern, options: .regularExpression) {
            let matchedText = String(normalizedClause[resumeMatch])
            let topic = resumeTopic(in: matchedText)
            return .resumeSession(topic: topic)
        }
        return nil
    }

    /// The first sentence or clause, and whatever follows it.
    private static func splitFirstClause(of transcript: String) -> (clause: String, rest: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separatorRange = trimmedTranscript.range(of: #"[.,!?;:]\s*"#, options: .regularExpression) {
            let firstClause = String(trimmedTranscript[..<separatorRange.lowerBound])
            let remainingText = String(trimmedTranscript[separatorRange.upperBound...])
            // "go back to the chat about invoices, please" keeps the topic whole
            if remainingText.isEmpty || normalizedCommandText(remainingText) == "please" {
                return (firstClause, "")
            }
            return (firstClause, remainingText)
        }
        return (trimmedTranscript, "")
    }

    /// Lowercased, without punctuation, wake words or fillers at the start.
    private static func normalizedCommandText(_ commandText: String) -> String {
        var normalizedText = commandText.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}'\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let leadingFillers = ["hey mose ", "okay mose ", "ok mose ", "mose ", "hey clicky ", "okay clicky ", "ok clicky ", "clicky ", "hey ", "okay ", "ok ", "um ", "uh ", "so ", "alright ", "all right "]
        var didRemoveFiller = true
        while didRemoveFiller {
            didRemoveFiller = false
            for leadingFiller in leadingFillers where normalizedText.hasPrefix(leadingFiller) {
                normalizedText.removeFirst(leadingFiller.count)
                didRemoveFiller = true
            }
        }
        return normalizedText
    }

    private static func resumeTopic(in matchedCommandText: String) -> String? {
        let topicMarkers = [" where we talked about ", " we had about ", " about ", " on ", " from ", " with "]
        for topicMarker in topicMarkers {
            if let markerRange = matchedCommandText.range(of: topicMarker) {
                let topic = String(matchedCommandText[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                return topic.isEmpty ? nil : topic
            }
        }
        return nil
    }
}

// MARK: - Search

enum ConversationSearch {
    private static let ignoredWords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "about", "my", "our", "your", "i", "we",
        "you", "it", "is", "was", "that", "this", "what", "how", "do", "did", "can", "me", "chat", "conversation", "session",
    ]

    static func searchWords(in searchText: String) -> [String] {
        searchText.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !ignoredWords.contains($0) }
    }

    /// Two words match when they're the same or one starts the other, so
    /// "mixing" finds "mix" and "export" finds "exporting".
    static func wordsMatch(_ firstWord: String, _ secondWord: String) -> Bool {
        if firstWord == secondWord { return true }
        guard min(firstWord.count, secondWord.count) >= 3 else { return false }
        return firstWord.hasPrefix(secondWord) || secondWord.hasPrefix(firstWord)
    }

    /// How well a conversation matches the words: title words count more than
    /// words somewhere in what was said.
    static func matchScore(of conversationSession: ConversationSession, for searchWordList: [String]) -> Int {
        guard !searchWordList.isEmpty else { return 0 }
        let titleWords = Set(searchWords(in: conversationSession.title))
        let spokenText = conversationSession.exchanges
            .map { "\($0.userTranscript) \(ConversationContext.spokenText(of: $0.assistantResponse))" }
            .joined(separator: " ")
        let spokenWords = Set(searchWords(in: spokenText))
        var totalScore = 0
        for searchWord in searchWordList {
            if titleWords.contains(where: { wordsMatch($0, searchWord) }) {
                totalScore += 3
            } else if spokenWords.contains(where: { wordsMatch($0, searchWord) }) {
                totalScore += 1
            }
        }
        return totalScore
    }

    /// The conversation a spoken topic most likely means, or nil if nothing
    /// matches. With no topic, the most recent one other than the current.
    static func bestMatchingSession(forTopic topic: String?, in conversationSessions: [ConversationSession], excludingSessionID: UUID?) -> ConversationSession? {
        let candidateSessions = conversationSessions
            .filter { $0.id != excludingSessionID }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        guard let topic else { return candidateSessions.first }
        let topicWords = searchWords(in: topic)
        let scoredSessions = candidateSessions
            .map { (conversationSession: $0, score: matchScore(of: $0, for: topicWords)) }
            .filter { $0.score > 0 }
        // Highest score wins; on a tie, the more recent one (the list is newest first)
        return scoredSessions.max { firstCandidate, secondCandidate in
            firstCandidate.score < secondCandidate.score
                || (firstCandidate.score == secondCandidate.score && firstCandidate.conversationSession.lastActivityAt < secondCandidate.conversationSession.lastActivityAt)
        }?.conversationSession
    }

    /// Conversations whose title or text contain every searched word, for the history window.
    static func sessions(_ conversationSessions: [ConversationSession], matching searchText: String) -> [ConversationSession] {
        let searchWordList = searchWords(in: searchText)
        guard !searchWordList.isEmpty else { return conversationSessions }
        return conversationSessions.filter { conversationSession in
            searchWordList.allSatisfy { matchScore(of: conversationSession, for: [$0]) > 0 }
        }
    }
}
