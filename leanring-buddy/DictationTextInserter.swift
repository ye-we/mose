//
//  DictationTextInserter.swift
//  leanring-buddy
//
//  Dictation into any app: hold fn + control, talk, let go, and the words are
//  typed wherever the text cursor is. The transcript is tidied up locally
//  (no round trip, so it's instant) and pasted into the focused field, with
//  the user's clipboard put back afterwards.
//

import AppKit
import Foundation

enum DictationTextCleaner {
    /// Hesitation sounds that never belong in typed text. Words like "like" or
    /// "you know" are left alone: they're often meant.
    private static let fillerWordPattern = #"(?i)(?<![\p{L}'-])(?:u+m+|u+h+|u+h+m+|e+r+m+|e+r+|a+h+|h+m+)(?![\p{L}'-])[,.]?\s*"#

    /// Tidies raw speech-to-text for typing: drops filler sounds, fixes spacing
    /// around punctuation, and capitalizes the start of each sentence.
    static func cleanedDictation(_ rawTranscript: String) -> String {
        var cleanedText = rawTranscript.replacingOccurrences(of: fillerWordPattern, with: "", options: .regularExpression)
        cleanedText = cleanedText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leftover comma or period at the very start, from a removed filler
        while let firstCharacter = cleanedText.first, ",.;:".contains(firstCharacter) {
            cleanedText = String(cleanedText.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return capitalizingSentenceStarts(cleanedText)
    }

    private static func capitalizingSentenceStarts(_ text: String) -> String {
        let characters = Array(text)
        var capitalizedText = ""
        var isAtSentenceStart = true
        for (characterIndex, character) in characters.enumerated() {
            if isAtSentenceStart && character.isLetter {
                capitalizedText += character.uppercased()
                isAtSentenceStart = false
                continue
            }
            capitalizedText.append(character)
            if character.isLetter || character.isNumber {
                isAtSentenceStart = false
            }
            // A sentence ends at . ! or ? followed by a space, so "example.com",
            // "file.pdf" and "3.5" are left alone
            let isFollowedBySpace = characterIndex + 1 < characters.count && characters[characterIndex + 1].isWhitespace
            if ".!?".contains(character) && isFollowedBySpace {
                isAtSentenceStart = true
            }
        }
        return capitalizedText
    }
}

@MainActor
enum FocusedFieldTextInserter {
    /// Types `text` into whatever has keyboard focus, in any app, by pasting it.
    /// Pasting works in practically every text field (native, web, Electron),
    /// unlike Accessibility text insertion. The clipboard is restored right after,
    /// and the temporary contents are marked transient so clipboard managers skip them.
    static func typeIntoFocusedField(_ text: String) {
        guard !text.isEmpty else { return }
        let generalPasteboard = NSPasteboard.general
        let savedPasteboardItems = copyOfPasteboardItems(generalPasteboard)

        generalPasteboard.clearContents()
        generalPasteboard.setString(text, forType: .string)
        generalPasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let dictationChangeCount = generalPasteboard.changeCount

        postCommandV()

        // Give the target app time to read the clipboard before restoring it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // If something else replaced the clipboard meanwhile, leave theirs alone
            guard generalPasteboard.changeCount == dictationChangeCount else { return }
            generalPasteboard.clearContents()
            if !savedPasteboardItems.isEmpty {
                generalPasteboard.writeObjects(savedPasteboardItems)
            }
        }
    }

    private static func copyOfPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { originalItem in
            let copiedItem = NSPasteboardItem()
            for pasteboardType in originalItem.types {
                if let typeData = originalItem.data(forType: pasteboardType) {
                    copiedItem.setData(typeData, forType: pasteboardType)
                }
            }
            return copiedItem
        }
    }

    /// Presses ⌘V. Needs the Accessibility permission Clicky already uses for its hotkeys.
    private static func postCommandV() {
        let keyboardEventSource = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        let commandVKeyDown = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: vKeyCode, keyDown: true)
        let commandVKeyUp = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: vKeyCode, keyDown: false)
        // Set the flags explicitly so a still-held control or fn doesn't turn this into another shortcut
        commandVKeyDown?.flags = .maskCommand
        commandVKeyUp?.flags = .maskCommand
        // Mose's own keys, so devil mode's takeover watch never takes them for the user's
        commandVKeyDown?.setIntegerValueField(.eventSourceUserData, value: DevilModeEventMark.eventSourceUserData)
        commandVKeyUp?.setIntegerValueField(.eventSourceUserData, value: DevilModeEventMark.eventSourceUserData)
        commandVKeyDown?.post(tap: .cghidEventTap)
        commandVKeyUp?.post(tap: .cghidEventTap)
    }
}
