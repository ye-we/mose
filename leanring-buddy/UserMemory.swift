//
//  UserMemory.swift
//  leanring-buddy
//
//  What Clicky remembers about the user from one conversation to the next: a
//  short list of lasting facts, like "they edit their youtube videos in final
//  cut pro" or "they'd rather use keyboard shortcuts than menus". Facts come
//  from two places:
//
//  - the user asks ("remember that my invoices are in dropbox"): Claude
//    answers with [REMEMBER:...], and "forget that ..." gets [FORGET:...];
//  - once a conversation is over, Haiku looks through it in the background
//    for anything worth keeping, and for facts it shows are out of date.
//
//  The facts are saved in one JSON file on this Mac and go to Claude in the
//  user message of each answer, never the system prompt, which must stay
//  fixed for the pre-started process. Memory can be turned off, and the
//  History window lists every fact so any of them can be deleted.
//  Foundation only, so the standalone tests can use it.
//

import Combine
import Foundation

// MARK: - Model

struct RememberedFact: Codable, Equatable, Identifiable {
    enum Origin: String, Codable {
        /// The user asked Clicky to remember it.
        case askedToRemember
        /// Picked up from a finished conversation.
        case learnedFromConversation
    }

    let id: UUID
    var text: String
    /// When it was remembered, or last said again.
    var rememberedAt: Date
    let origin: Origin
    /// The conversation it came from, so the History window can say where.
    let conversationID: UUID?
}

/// What's saved in Memory.json.
private struct SavedUserMemory: Codable {
    var isMemoryEnabled: Bool
    var facts: [RememberedFact]
}

// MARK: - Store

@MainActor
final class UserMemoryStore: ObservableObject {
    /// Enough for what matters about someone, and small enough to send with
    /// every answer (forty short lines are well under a thousand words).
    static let maximumFactCount = 40

    /// Newest first.
    @Published private(set) var facts: [RememberedFact] = []
    /// Off: nothing is sent to Claude, learned or remembered, and Claude is
    /// told memory is off so it doesn't promise to remember.
    @Published private(set) var isMemoryEnabled = true

    let memoryFileURL: URL

    /// ~/Library/Application Support/<bundle id>/Memory.json
    nonisolated static var defaultFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolderName = Bundle.main.bundleIdentifier ?? "ClickyLocal"
        return applicationSupportURL.appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("Memory.json")
    }

    init(memoryFileURL: URL = UserMemoryStore.defaultFileURL) {
        self.memoryFileURL = memoryFileURL
        loadSavedMemory()
    }

    func setMemoryEnabled(_ isEnabled: Bool) {
        isMemoryEnabled = isEnabled
        save()
    }

    /// Adds a fact, or freshens the one it repeats (keeping the newer
    /// wording). Returns the saved fact, or nil if there was nothing to save.
    @discardableResult
    func remember(
        _ factText: String,
        origin: RememberedFact.Origin,
        conversationID: UUID?,
        at rememberedAt: Date = Date()
    ) -> RememberedFact? {
        let cleanedFactText = UserMemoryText.cleanedFact(factText)
        guard !cleanedFactText.isEmpty else { return nil }

        if let repeatedFactIndex = facts.firstIndex(where: { UserMemoryText.isSameFact($0.text, cleanedFactText) }) {
            var freshenedFact = facts.remove(at: repeatedFactIndex)
            freshenedFact.text = cleanedFactText
            freshenedFact.rememberedAt = rememberedAt
            facts.insert(freshenedFact, at: 0)
            save()
            return freshenedFact
        }

        let newFact = RememberedFact(
            id: UUID(),
            text: cleanedFactText,
            rememberedAt: rememberedAt,
            origin: origin,
            conversationID: conversationID
        )
        facts.insert(newFact, at: 0)
        dropOldestFactsOverTheLimit()
        save()
        return newFact
    }

    /// Removes what the user asked to forget: the fact it names (Claude
    /// quotes it as it knows it), or all of them for "everything". Returns
    /// what was removed.
    @discardableResult
    func forget(matching forgetRequest: String) -> [RememberedFact] {
        let factsToForget = UserMemoryText.factsMatching(forgetRequest: forgetRequest, in: facts)
        guard !factsToForget.isEmpty else { return [] }
        let forgottenFactIDs = Set(factsToForget.map(\.id))
        facts.removeAll { forgottenFactIDs.contains($0.id) }
        save()
        return factsToForget
    }

    /// Drops the facts a finished conversation showed are wrong or out of
    /// date. Only the same fact counts, never a loose match or "everything",
    /// since this comes from Haiku, not the user.
    func dropFacts(sameAs outdatedFactText: String) {
        let factCountBefore = facts.count
        facts.removeAll { UserMemoryText.isSameFact($0.text, outdatedFactText) }
        if facts.count != factCountBefore { save() }
    }

    func deleteFact(withID factID: UUID) {
        facts.removeAll { $0.id == factID }
        save()
    }

    func deleteAllFacts() {
        facts.removeAll()
        save()
    }

    /// Facts learned from conversations go first; ones the user asked for
    /// are only dropped when nothing else is left to drop.
    private func dropOldestFactsOverTheLimit() {
        while facts.count > Self.maximumFactCount {
            if let oldestLearnedFactIndex = facts.lastIndex(where: { $0.origin == .learnedFromConversation }) {
                facts.remove(at: oldestLearnedFactIndex)
            } else {
                facts.removeLast()
            }
        }
    }

    // MARK: Files

    private func save() {
        do {
            try FileManager.default.createDirectory(at: memoryFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let memoryEncoder = JSONEncoder()
            memoryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            memoryEncoder.dateEncodingStrategy = .iso8601
            let memoryData = try memoryEncoder.encode(SavedUserMemory(isMemoryEnabled: isMemoryEnabled, facts: facts))
            try memoryData.write(to: memoryFileURL, options: .atomic)
        } catch {
            print("⚠️ Couldn't save memory: \(error)")
        }
    }

    private func loadSavedMemory() {
        guard let memoryData = try? Data(contentsOf: memoryFileURL) else { return }
        let memoryDecoder = JSONDecoder()
        memoryDecoder.dateDecodingStrategy = .iso8601
        guard let savedUserMemory = try? memoryDecoder.decode(SavedUserMemory.self, from: memoryData) else {
            print("⚠️ Couldn't read memory at \(memoryFileURL.path)")
            return
        }
        isMemoryEnabled = savedUserMemory.isMemoryEnabled
        facts = savedUserMemory.facts.sorted { $0.rememberedAt > $1.rememberedAt }
    }
}

// MARK: - Fact text

enum UserMemoryText {
    static let maximumFactLength = 160

    /// One line, no list marker or quotes around it, cut at a word if long.
    static func cleanedFact(_ factText: String) -> String {
        var cleanedText = factText
            .replacingOccurrences(of: #"[\[\]]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -•*+\"'“”"))
        if cleanedText.count > maximumFactLength {
            let shortenedText = String(cleanedText.prefix(maximumFactLength))
            let lastWordBoundary = shortenedText.lastIndex(of: " ") ?? shortenedText.endIndex
            cleanedText = String(shortenedText[..<lastWordBoundary])
        }
        return cleanedText.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }

    private static let ignoredWords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "they", "their", "them",
        "is", "are", "was", "that", "this", "it", "its", "user", "user's", "theirs", "i", "my", "me",
    ]

    /// The words that carry a fact's meaning.
    static func meaningfulWords(in text: String) -> Set<String> {
        Set(text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}'\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !ignoredWords.contains($0) })
    }

    /// Two wordings of the same fact: (nearly) the same meaningful words.
    static func isSameFact(_ firstFactText: String, _ secondFactText: String) -> Bool {
        let firstWords = meaningfulWords(in: firstFactText)
        let secondWords = meaningfulWords(in: secondFactText)
        guard !firstWords.isEmpty, !secondWords.isEmpty else {
            return firstFactText.lowercased() == secondFactText.lowercased()
        }
        let sharedWordCount = firstWords.intersection(secondWords).count
        let allWordCount = firstWords.union(secondWords).count
        return Double(sharedWordCount) / Double(allWordCount) >= 0.8
    }

    /// "they edit videos in final cut pro" → "You edit videos in final cut
    /// pro": facts are written about "they" for Claude, but read better
    /// addressed to the user. "them" is left alone: it's as often about
    /// things ("send them as pdfs") as about the user.
    static func factAddressedToUser(_ factText: String) -> String {
        var displayedText = " " + factText + " "
        let pronounReplacements = [
            (" they're ", " you're "), (" they've ", " you've "), (" they'd ", " you'd "), (" they'll ", " you'll "),
            (" they are ", " you are "), (" they were ", " you were "), (" they ", " you "), (" their ", " your "),
            (" theirs ", " yours "), (" themselves ", " yourself "),
        ]
        for (thirdPersonWords, secondPersonWords) in pronounReplacements {
            displayedText = displayedText.replacingOccurrences(of: thirdPersonWords, with: secondPersonWords, options: .caseInsensitive)
        }
        // "they uses" never happens, but "they has" from a sloppy fact reads oddly as "you has"
        displayedText = displayedText.replacingOccurrences(of: " you has ", with: " you have ")
        displayedText = displayedText.trimmingCharacters(in: .whitespaces)
        guard let firstCharacter = displayedText.first else { return factText }
        return firstCharacter.uppercased() + displayedText.dropFirst()
    }

    /// "[FORGET:everything]" and the like.
    static func isForgetEverythingRequest(_ forgetRequest: String) -> Bool {
        let normalizedRequest = forgetRequest.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return ["everything", "all", "all of it", "everything about them", "everything about me", "all facts", "all memories"]
            .contains(normalizedRequest)
    }

    /// The answer's forget requests that should be carried out. Starting over
    /// only clears the conversation, so "everything" is dropped from an
    /// answer that also asked for a new conversation ([SESSION:new]).
    static func forgetRequestsToApply(_ forgetRequests: [String], answerAskedForNewConversation: Bool) -> [String] {
        guard answerAskedForNewConversation else { return forgetRequests }
        return forgetRequests.filter { !isForgetEverythingRequest($0) }
    }

    /// The facts a forget request means: all of them for "everything", the
    /// same fact if it's there, or else the one sharing most of its words.
    static func factsMatching(forgetRequest: String, in facts: [RememberedFact]) -> [RememberedFact] {
        if isForgetEverythingRequest(forgetRequest) { return facts }
        let sameFacts = facts.filter { isSameFact($0.text, forgetRequest) }
        if !sameFacts.isEmpty { return sameFacts }

        let requestWords = meaningfulWords(in: forgetRequest)
        guard !requestWords.isEmpty else { return [] }
        let scoredFacts = facts.map { rememberedFact in
            (rememberedFact: rememberedFact, sharedWordCount: meaningfulWords(in: rememberedFact.text).intersection(requestWords).count)
        }
        guard let bestMatch = scoredFacts.max(by: { $0.sharedWordCount < $1.sharedWordCount }),
              Double(bestMatch.sharedWordCount) >= Double(requestWords.count) * 0.5 else { return [] }
        return [bestMatch.rememberedFact]
    }
}

// MARK: - Memory and Claude

enum UserMemoryContext {
    /// What goes at the start of each request: the facts, oldest first so the
    /// newest read as the latest word, or a note that memory is off. Nil when
    /// there's nothing to say.
    static func noteForClaude(facts: [RememberedFact], isMemoryEnabled: Bool) -> String? {
        guard isMemoryEnabled else {
            return "memory is turned off, so nothing carries over between conversations. if they ask you to remember something, say they can turn memory on in the history window, from the menu bar."
        }
        guard !facts.isEmpty else { return nil }
        let factLines = facts
            .sorted { $0.rememberedAt < $1.rememberedAt }
            .map { "- \($0.text)" }
            .joined(separator: "\n")
        return "what you remember about them from earlier conversations (use it when it helps, don't recite it):\n\(factLines)"
    }

    static let learningSystemPrompt = """
    you read a finished conversation between a person and clicky, a voice assistant that sees their screen, and pick out what's worth remembering about the person in future conversations. keep lasting things: the apps and tools they use, what they work on and their projects, people and names they work with, how experienced they are, and how they like to be helped. leave out what they asked this time, problems or errors they ran into along the way, what was on screen, passing moods, and anything sensitive like passwords, account numbers, addresses, health or money. only keep what they said or clearly showed, never guesses.

    reply with lines only, each fact short (under fifteen words) and about "they":
    + a new fact
    - a fact from the known list that this conversation shows is wrong or out of date, copied exactly
    most conversations have nothing worth keeping. then reply with only: none
    """

    /// The conversation and the facts already known.
    static func learningRequest(conversationSession: ConversationSession, knownFacts: [RememberedFact]) -> String {
        let knownFactLines = knownFacts.isEmpty
            ? "(nothing yet)"
            : knownFacts.map { "- \($0.text)" }.joined(separator: "\n")
        let conversationTranscript = conversationSession.exchanges
            .filter { !$0.isGuidedStepFollowUp }
            .map { conversationExchange in
                let appText = conversationExchange.frontmostAppName.map { " (in \($0))" } ?? ""
                return "they said\(appText): \(conversationExchange.userTranscript)\nclicky said: \(ConversationContext.spokenText(of: conversationExchange.assistantResponse))"
            }
            .joined(separator: "\n")
        return "what you already know about them:\n\(knownFactLines)\n\nthe conversation:\n\(conversationTranscript)"
    }

    /// "+ fact" lines to add and "- fact" lines to drop. Anything else
    /// (including "none") is ignored.
    static func parseLearningReply(_ learningReply: String) -> (factsToAdd: [String], factsToDrop: [String]) {
        var factsToAdd: [String] = []
        var factsToDrop: [String] = []
        for replyLine in learningReply.components(separatedBy: .newlines) {
            let trimmedLine = replyLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("+") {
                let factText = UserMemoryText.cleanedFact(String(trimmedLine.dropFirst()))
                if !factText.isEmpty { factsToAdd.append(factText) }
            } else if trimmedLine.hasPrefix("-") {
                let factText = UserMemoryText.cleanedFact(String(trimmedLine.dropFirst()))
                if !factText.isEmpty { factsToDrop.append(factText) }
            }
        }
        // A conversation rarely has more than a few lasting facts; more means
        // the reply went off track
        return (Array(factsToAdd.prefix(5)), Array(factsToDrop.prefix(5)))
    }

    /// Conversations that are over and haven't been looked through since
    /// their last exchange, newest first. Over means it's not the current one,
    /// or it's been quiet past the idle limit. Old ones (from before memory,
    /// or left for days) are skipped.
    static func conversationsToLearnFrom(
        in conversationSessions: [ConversationSession],
        currentSessionID: UUID?,
        now: Date,
        idleLimitSeconds: TimeInterval,
        maximumAgeSeconds: TimeInterval = 3 * 24 * 60 * 60
    ) -> [ConversationSession] {
        conversationSessions
            .filter { conversationSession in
                let isOver = conversationSession.id != currentSessionID
                    || now.timeIntervalSince(conversationSession.lastActivityAt) > idleLimitSeconds
                let isRecent = now.timeIntervalSince(conversationSession.lastActivityAt) < maximumAgeSeconds
                let hasUnreadExchanges = (conversationSession.memoryReviewedExchangeCount ?? 0) < conversationSession.exchanges.count
                return isOver && isRecent && hasUnreadExchanges && conversationSession.questionCount > 0
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
