//
//  StreamingAnswerSegmenter.swift
//  leanring-buddy
//
//  Cuts Claude's answer into sentences while it's still streaming in, so
//  Clicky can start speaking the first sentence instead of waiting for the
//  whole answer. POINT, DRAW, AGENT and SESSION tags are pulled out as they complete
//  and attached to the sentence they follow, so each mark can appear exactly
//  when that sentence starts being spoken.
//

import Foundation

enum StreamingAnswerPiece: Equatable {
    /// A sentence ready to speak, with its tags removed.
    case sentence(index: Int, text: String)
    /// A complete "[POINT:...]", "[DRAW:...]" or "[AGENT:...]" tag. It belongs
    /// to the sentence it follows (the sentence that describes it); tags that
    /// come before any sentence belong to the first one.
    case tag(tagText: String, sentenceIndex: Int)
}

struct StreamingAnswerSegmenter {
    /// How much of the accumulated answer has been turned into pieces.
    private var consumedCharacterCount = 0
    private var unfinishedSentenceText = ""
    private var emittedSentenceCount = 0

    /// Turns whatever is new in `accumulatedAnswerText` into pieces. Call it with
    /// the whole answer so far each time more arrives, and once more with
    /// `isAnswerComplete` when the stream ends, so the last sentence is released.
    mutating func consume(accumulatedAnswerText: String, isAnswerComplete: Bool) -> [StreamingAnswerPiece] {
        let newCharacters = Array(accumulatedAnswerText.dropFirst(consumedCharacterCount))
        var pieces: [StreamingAnswerPiece] = []
        var characterIndex = 0

        while characterIndex < newCharacters.count {
            let character = newCharacters[characterIndex]

            if character == "[" {
                guard let closingBracketIndex = newCharacters[characterIndex...].firstIndex(of: "]") else {
                    // The tag (or bracketed text) isn't complete yet: wait for more
                    if isAnswerComplete {
                        unfinishedSentenceText += String(newCharacters[characterIndex...])
                        characterIndex = newCharacters.count
                    }
                    break
                }
                let bracketedText = String(newCharacters[characterIndex...closingBracketIndex])
                if Self.isClickyTag(bracketedText) {
                    // The text before a tag is the sentence it goes with, even
                    // if Claude didn't end it with punctuation
                    pieces += flushUnfinishedSentence()
                    pieces.append(.tag(tagText: bracketedText, sentenceIndex: max(emittedSentenceCount - 1, 0)))
                } else {
                    unfinishedSentenceText += bracketedText
                }
                characterIndex = closingBracketIndex + 1
                continue
            }

            if character == "\n" {
                pieces += flushUnfinishedSentence()
                characterIndex += 1
                continue
            }

            unfinishedSentenceText.append(character)

            if character == "." || character == "!" || character == "?" {
                let nextCharacterIndex = characterIndex + 1
                if nextCharacterIndex < newCharacters.count {
                    // "3.5" or "file.pdf" aren't sentence ends; ". " is
                    if newCharacters[nextCharacterIndex].isWhitespace {
                        pieces += flushUnfinishedSentence()
                    }
                } else if isAnswerComplete {
                    pieces += flushUnfinishedSentence()
                } else {
                    // Can't tell yet whether this ends the sentence: leave it
                    // unconsumed and look at it again once more text arrives
                    unfinishedSentenceText.removeLast()
                    break
                }
            }
            characterIndex += 1
        }

        consumedCharacterCount += characterIndex

        if isAnswerComplete {
            pieces += flushUnfinishedSentence()
        }
        return pieces
    }

    private mutating func flushUnfinishedSentence() -> [StreamingAnswerPiece] {
        let sentenceText = unfinishedSentenceText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        unfinishedSentenceText = ""
        // Nothing to say, or only punctuation left behind by a removed tag
        guard sentenceText.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        let sentenceIndex = emittedSentenceCount
        emittedSentenceCount += 1
        return [.sentence(index: sentenceIndex, text: sentenceText)]
    }

    static func isClickyTag(_ bracketedText: String) -> Bool {
        bracketedText.range(of: #"^\[\s*(POINT|DRAW|AGENT|SESSION)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "[SESSION:new]": the user asked to start a new conversation.
    static func isSessionTag(_ tagText: String) -> Bool {
        tagText.range(of: #"^\[\s*SESSION\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isAgentTag(_ tagText: String) -> Bool {
        tagText.range(of: #"^\[\s*AGENT\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
