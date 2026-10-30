//
//  GuidedStepCardDeck.swift
//  leanring-buddy
//
//  The cards a guided walkthrough leaves on screen. Each step Clicky gives
//  ("click share in the top right") becomes a small pinned card, so the
//  instruction is still there after it's been said. Clicking the target ticks
//  the step off right away; the next answer adds the next step. When the
//  walkthrough ends, Clicky's last line stays for a moment as a closing note.
//  This file is the state and the layout math, with no UI, so the standalone
//  tests can check it; GuidedStepCardsView draws it.
//

import CoreGraphics
import Foundation

struct GuidedStepCard: Identifiable, Equatable {
    enum CardKind: Equatable {
        /// "2. Click Share in the top right."
        case step(number: Int)
        /// What Clicky said when the walkthrough ended ("Done, it's exporting.")
        case closingNote
    }

    let id: UUID
    let kind: CardKind
    let instructionText: String
    var isDone: Bool
}

struct GuidedStepCardDeck: Equatable {
    /// Older steps scroll away; a walkthrough only needs its recent context.
    static let maximumShownCardCount = 4
    static let maximumInstructionLength = 160

    private(set) var cards: [GuidedStepCard] = []
    /// The screen the walkthrough is on, in global AppKit coordinates.
    private(set) var displayFrame: CGRect?
    /// The thing to click next, in global AppKit coordinates. The cards are
    /// placed so they never cover it.
    private(set) var targetGlobalRect: CGRect?

    var isEmpty: Bool { cards.isEmpty }
    var shownCards: [GuidedStepCard] { Array(cards.suffix(Self.maximumShownCardCount)) }

    /// Adds the next step. A step that was never done (the user clicked
    /// somewhere else and got a corrected instruction) is replaced, not kept.
    mutating func showStep(number stepNumber: Int, instructionText: String, targetGlobalRect: CGRect, displayFrame: CGRect) {
        removeUnfinishedSteps()
        cards.append(GuidedStepCard(id: UUID(), kind: .step(number: stepNumber), instructionText: instructionText, isDone: false))
        self.targetGlobalRect = targetGlobalRect
        self.displayFrame = displayFrame
    }

    /// The whole answer is in: the current step's card gets its full text.
    mutating func updateCurrentStepText(_ instructionText: String) {
        guard !instructionText.isEmpty,
              let currentStepIndex = cards.lastIndex(where: { !$0.isDone && $0.kind != .closingNote }) else { return }
        let currentStepCard = cards[currentStepIndex]
        cards[currentStepIndex] = GuidedStepCard(id: currentStepCard.id, kind: currentStepCard.kind, instructionText: instructionText, isDone: false)
    }

    /// The user clicked the target: tick the step off while Clicky looks again.
    mutating func markCurrentStepDone() {
        guard let currentStepIndex = cards.lastIndex(where: { !$0.isDone && $0.kind != .closingNote }) else { return }
        cards[currentStepIndex].isDone = true
        targetGlobalRect = nil
    }

    /// The walkthrough ended: an answer without a next click, either because
    /// it's done or because the next step is typing or a shortcut. Steps nobody
    /// did are dropped and Clicky's last words stay as a closing note.
    mutating func finish(closingText: String) {
        removeUnfinishedSteps()
        targetGlobalRect = nil
        guard !closingText.isEmpty else { return }
        cards.append(GuidedStepCard(id: UUID(), kind: .closingNote, instructionText: closingText, isDone: true))
    }

    mutating func clear() {
        cards.removeAll()
        displayFrame = nil
        targetGlobalRect = nil
    }

    private mutating func removeUnfinishedSteps() {
        cards.removeAll { card in
            if case .step = card.kind { return !card.isDone }
            return false
        }
    }

    // MARK: - Card text

    /// What goes on a card: the spoken answer without its tags, as a sentence,
    /// cut at a word boundary if it's long.
    static func cardText(fromAnswerText answerText: String) -> String {
        let tagFreeText = answerText.replacingOccurrences(of: #"\[\s*(POINT|DRAW|AGENT|SESSION|REMEMBER|FORGET|CLICK|DOUBLE[-_ ]?CLICK|RIGHT[-_ ]?CLICK|DRAG|SCROLL|TYPE|KEY)\s*:[^\]]*\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        let singleSpacedText = tagFreeText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
        guard let firstCharacter = singleSpacedText.first else { return "" }
        var cardText = firstCharacter.uppercased() + singleSpacedText.dropFirst()

        if cardText.count > maximumInstructionLength {
            let shortenedText = String(cardText.prefix(maximumInstructionLength))
            let lastWordBoundary = shortenedText.lastIndex(of: " ") ?? shortenedText.endIndex
            cardText = String(shortenedText[..<lastWordBoundary]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
        }
        return cardText
    }

    // MARK: - Placement

    enum ScreenCorner: CaseIterable {
        case topTrailing
        case bottomTrailing
        case topLeading
        case bottomLeading
    }

    /// The corner for the cards: top right unless that would cover the thing
    /// to click, then the next free corner. `targetLocalRect` and the result's
    /// rect are in the screen's own top-left-origin coordinates.
    static func cardCorner(
        screenSize: CGSize,
        topInset: CGFloat,
        cardSize: CGSize,
        margin: CGFloat,
        avoiding targetLocalRect: CGRect?
    ) -> ScreenCorner {
        guard let targetLocalRect else { return .topTrailing }
        let keepClearRect = targetLocalRect.insetBy(dx: -30, dy: -30)
        return ScreenCorner.allCases.first { screenCorner in
            !cardRect(in: screenCorner, screenSize: screenSize, topInset: topInset, cardSize: cardSize, margin: margin)
                .intersects(keepClearRect)
        } ?? .topTrailing
    }

    static func cardRect(in screenCorner: ScreenCorner, screenSize: CGSize, topInset: CGFloat, cardSize: CGSize, margin: CGFloat) -> CGRect {
        let leadingX = margin
        let trailingX = screenSize.width - margin - cardSize.width
        let topY = topInset + margin
        let bottomY = screenSize.height - margin - cardSize.height
        switch screenCorner {
        case .topTrailing: return CGRect(x: trailingX, y: topY, width: cardSize.width, height: cardSize.height)
        case .bottomTrailing: return CGRect(x: trailingX, y: bottomY, width: cardSize.width, height: cardSize.height)
        case .topLeading: return CGRect(x: leadingX, y: topY, width: cardSize.width, height: cardSize.height)
        case .bottomLeading: return CGRect(x: leadingX, y: bottomY, width: cardSize.width, height: cardSize.height)
        }
    }
}

// MARK: - Answers that skip the mark

/// Catches an answer that tells the user what to click but marks nothing,
/// like "open system settings from the apple menu": two clicks in one
/// sentence, the second one not on screen yet. Without a target the
/// walkthrough would stop there, so Clicky asks Claude once more for a mark
/// on the first click.
enum GuidedStepAnswerCheck {
    /// Sent back to Claude after such an answer. An answer of only [POINT:none]
    /// isn't spoken, so when there's nothing to mark the user hears nothing more.
    static let missingTargetFollowUpTranscript = "(guided step) you told me what to click but didn't mark it. mark only the very next click with a target and say it in a few words. if that click isn't on screen right now, or it's a keyboard shortcut, write no words at all: your whole reply is [POINT:none]."

    /// Words that can come before the instruction itself ("first, click…",
    /// "now you'll want to open…", "start by opening…").
    private static let leadingWordsBeforeAnInstruction = [
        "first", "now", "then", "next", "so", "okay", "ok", "alright", "and", "just",
        "you'll want to", "you will want to", "you need to", "you'll need to", "you have to",
        "start by", "begin by", "try",
    ]

    /// Openings that always mean a click, after any leading words.
    private static let clickOpenings = [
        "click", "double-click", "double click", "right-click", "right click", "tap",
        "clicking", "double-clicking", "right-clicking", "tapping",
    ]

    /// Openings that mean a click only when the clause names a place on
    /// screen: "pick show sidebar" is a step, "pick a sauce" is advice.
    private static let clickOpeningsThatNeedAScreenPlace = [
        "select", "choose", "pick", "open", "hit", "go to", "go into", "head to",
        "head over to", "navigate to",
        "selecting", "choosing", "picking", "opening", "hitting", "going to", "heading to",
    ]

    private static let screenPlaceWords = [
        "menu", "button", "tab", "settings", "preferences", "icon", "bar", "sidebar", "toolbar",
        "panel", "pane", "window", "option", "link", "field", "box", "list", "item", "dropdown",
        "checkbox", "toggle", "switch", "dock", "file", "folder", "top", "bottom", "left",
        "right", "corner", "here", "there", "screen", "apple",
    ]

    /// Words that make "hit …" or "tap …" a key press, not a click.
    private static let keyboardWords = [
        "command", "cmd", "shift", "ctrl", "escape", "esc", "return", "enter",
        "spacebar", "space bar", "key", "keys", "shortcut", "keyboard",
    ]

    static func answerHasTarget(_ answerText: String) -> Bool {
        answerText.range(of: #"\[\s*DRAW\s*:\s*target\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when the answer has no target and one of its sentences or clauses
    /// is an instruction to click something. Keyboard steps ("press command
    /// comma") and typing don't count: those are said without a target.
    static func isClickInstructionWithoutTarget(_ answerText: String) -> Bool {
        guard !answerHasTarget(answerText) else { return false }
        let spokenText = answerText
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let clauses = spokenText
            .replacingOccurrences(of: #"\bthen\b"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ".!?;:,\n"))
        return clauses.contains { clause in
            isClickInstruction(clause.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func isClickInstruction(_ clause: String) -> Bool {
        var remainingClause = clause
        var didRemoveLeadingWords = true
        while didRemoveLeadingWords {
            didRemoveLeadingWords = false
            for leadingWords in leadingWordsBeforeAnInstruction where startsWithWords(remainingClause, leadingWords) {
                remainingClause = String(remainingClause.dropFirst(leadingWords.count)).trimmingCharacters(in: .whitespaces)
                didRemoveLeadingWords = true
            }
        }
        let clauseWords = " " + remainingClause.replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression) + " "
        let isAboutTheKeyboard = keyboardWords.contains { clauseWords.contains(" \($0) ") }
        guard !isAboutTheKeyboard else { return false }
        if clickOpenings.contains(where: { startsWithWords(remainingClause, $0) }) {
            return true
        }
        guard clickOpeningsThatNeedAScreenPlace.contains(where: { startsWithWords(remainingClause, $0) }) else { return false }
        return screenPlaceWords.contains { clauseWords.contains(" \($0) ") }
    }

    /// Whether the text starts with these whole words ("open" matches "open
    /// the menu" but not "opens" or "openly").
    private static func startsWithWords(_ text: String, _ words: String) -> Bool {
        guard text.hasPrefix(words) else { return false }
        guard let characterAfterWords = text.dropFirst(words.count).first else { return true }
        return !(characterAfterWords.isLetter || characterAfterWords == "-" || characterAfterWords == "'")
    }
}
