//
//  ScreenTextRecognizer.swift
//  leanring-buddy
//
//  Reads the text on a screenshot with Apple's Vision framework (on device)
//  so Clicky's drawings can be lined up with what's really on screen:
//  rings that miss a labelled button snap onto it, and handwritten labels
//  avoid covering text. Runs while Claude is still answering, so it adds no
//  waiting time.
//

import CoreGraphics
import Foundation
import Vision

/// One word Vision found, in screenshot pixels (top-left origin).
struct RecognizedScreenWord {
    let text: String
    let screenshotRect: CGRect
}

/// One line of text Vision found, with its words.
struct RecognizedScreenTextLine {
    let text: String
    let screenshotRect: CGRect
    let words: [RecognizedScreenWord]
}

enum ScreenTextRecognizer {
    /// Recognizes the text in `screenshotImage`. Synchronous and takes a few
    /// hundred milliseconds, so call it off the main thread.
    static func recognizeTextLines(in screenshotImage: CGImage) -> [RecognizedScreenTextLine] {
        let textRecognitionRequest = VNRecognizeTextRequest()
        textRecognitionRequest.recognitionLevel = .accurate
        // UI labels aren't sentences; correcting "SYNC" into a dictionary word hurts
        textRecognitionRequest.usesLanguageCorrection = false

        let imageRequestHandler = VNImageRequestHandler(cgImage: screenshotImage, options: [:])
        do {
            try imageRequestHandler.perform([textRecognitionRequest])
        } catch {
            print("⚠️ Screen text recognition failed: \(error)")
            return []
        }

        let imageWidth = CGFloat(screenshotImage.width)
        let imageHeight = CGFloat(screenshotImage.height)

        // Vision boxes are normalized with a bottom-left origin
        func screenshotRect(fromNormalizedBox normalizedBox: CGRect) -> CGRect {
            CGRect(
                x: normalizedBox.minX * imageWidth,
                y: (1 - normalizedBox.maxY) * imageHeight,
                width: normalizedBox.width * imageWidth,
                height: normalizedBox.height * imageHeight
            )
        }

        return (textRecognitionRequest.results ?? []).compactMap { textObservation in
            guard let topCandidate = textObservation.topCandidates(1).first else { return nil }
            let lineText = topCandidate.string

            var recognizedWords: [RecognizedScreenWord] = []
            lineText.enumerateSubstrings(in: lineText.startIndex..., options: .byWords) { wordText, wordRange, _, _ in
                guard let wordText,
                      let wordBoxObservation = try? topCandidate.boundingBox(for: wordRange) else { return }
                recognizedWords.append(RecognizedScreenWord(
                    text: wordText,
                    screenshotRect: screenshotRect(fromNormalizedBox: wordBoxObservation.boundingBox)
                ))
            }

            return RecognizedScreenTextLine(
                text: lineText,
                screenshotRect: screenshotRect(fromNormalizedBox: textObservation.boundingBox),
                words: recognizedWords
            )
        }
    }
}

/// Corrects marks that miss the thing Claude named. Claude's coordinates are
/// usually close but can land a row or a few dozen pixels off on dense UIs.
/// When the mark's label names text that's on screen nearby (a "save changes"
/// ring near a "Save Changes" button), the mark moves onto that text.
enum ScreenSketchTargetSnapper {
    /// Words that describe the kind of element rather than its name:
    /// "sync button" should match the text "SYNC".
    static let genericElementWords: Set<String> = [
        "button", "btn", "bar", "field", "menu", "icon", "tab", "link", "box",
        "dropdown", "toggle", "option", "item", "the", "a", "an", "this", "that",
        "here", "knob", "slider", "checkbox", "switch", "label", "click", "tap"
    ]

    /// The box of on-screen text that `label` names, nearest to `proposedRect`,
    /// or nil if nothing nearby matches. All rects are in screenshot pixels.
    static func matchingTextRect(
        forLabel label: String,
        near proposedRect: CGRect,
        in recognizedTextLines: [RecognizedScreenTextLine]
    ) -> CGRect? {
        let allLabelWords = normalizedWords(in: label)
        let distinctiveLabelWords = allLabelWords.filter { !genericElementWords.contains($0) }
        let labelWords = distinctiveLabelWords.isEmpty ? allLabelWords : distinctiveLabelWords
        let joinedLabel = labelWords.joined(separator: " ")
        guard joinedLabel.count >= 2 else { return nil }

        var candidateRects: [CGRect] = []

        for recognizedLine in recognizedTextLines {
            let lineWords = recognizedLine.words.map { normalizedWords(in: $0.text).joined(separator: " ") }

            // The label's words appear as a run inside this line
            if labelWords.count <= lineWords.count {
                for runStartIndex in 0...(lineWords.count - labelWords.count) {
                    let runWords = Array(lineWords[runStartIndex..<(runStartIndex + labelWords.count)])
                    if zip(runWords, labelWords).allSatisfy({ screenWordMatches($0, labelWord: $1) }) {
                        let runRects = recognizedLine.words[runStartIndex..<(runStartIndex + labelWords.count)].map(\.screenshotRect)
                        candidateRects.append(runRects.dropFirst().reduce(runRects[0]) { $0.union($1) })
                    }
                }
            }

            // The whole line is a shorter part of the label, like the text
            // "Light" for the label "theme: light"
            let joinedLineWords = lineWords.filter { !$0.isEmpty }.joined(separator: " ")
            if joinedLineWords.count >= 3,
               joinedLineWords != joinedLabel,
               " \(joinedLabel) ".contains(" \(joinedLineWords) "),
               Double(joinedLineWords.count) >= Double(joinedLabel.count) * 0.4 {
                candidateRects.append(recognizedLine.screenshotRect)
            }
        }

        let maximumSnapDistance = min(max(48, hypot(proposedRect.width, proposedRect.height) * 1.2), 140)
        return candidateRects
            .map { (rect: $0, distance: distanceBetween($0, proposedRect)) }
            .filter { $0.distance <= maximumSnapDistance }
            .min { $0.distance < $1.distance }?
            .rect
    }

    /// Where the mark should go instead, or nil to leave Claude's mark alone.
    /// Only clear misses of a single element are corrected:
    /// - if the named text's center is already inside Claude's box, Claude found
    ///   the right element (the box may be the whole control around the text);
    /// - if Claude's box is much bigger than the text, it's marking a region
    ///   (a card, a panel) and a matching heading nearby isn't the target.
    static func correctedTargetRect(
        forLabel label: String?,
        proposedRect: CGRect,
        recognizedTextLines: [RecognizedScreenTextLine]
    ) -> CGRect? {
        guard let label,
              let matchedTextRect = matchingTextRect(forLabel: label, near: proposedRect, in: recognizedTextLines) else {
            return nil
        }
        let matchedTextCenter = CGPoint(x: matchedTextRect.midX, y: matchedTextRect.midY)
        guard !proposedRect.insetBy(dx: -2, dy: -2).contains(matchedTextCenter) else { return nil }
        let isProposedRectElementSized = proposedRect.width <= max(matchedTextRect.width * 3, 140)
            && proposedRect.height <= max(matchedTextRect.height * 4, 70)
        guard isProposedRectElementSized else { return nil }
        return matchedTextRect.insetBy(dx: -6, dy: -4)
    }

    /// Whether a word read off the screen is the label's word, allowing for the
    /// usual text recognition noise on small UI text: an icon read as a stray
    /// letter or two in front ("unew" for "new" after a compose icon) and a
    /// single misread letter in longer words ("autornations").
    static func screenWordMatches(_ screenWord: String, labelWord: String) -> Bool {
        if screenWord == labelWord { return true }
        guard labelWord.count >= 3 else { return false }
        if screenWord.hasSuffix(labelWord) && screenWord.count - labelWord.count <= 2 { return true }
        if labelWord.count >= 4 && abs(screenWord.count - labelWord.count) <= 1 {
            return editDistance(screenWord, labelWord) <= 1
        }
        return false
    }

    /// Levenshtein distance: how many single-letter edits turn one word into the other.
    static func editDistance(_ firstWord: String, _ secondWord: String) -> Int {
        let firstCharacters = Array(firstWord)
        let secondCharacters = Array(secondWord)
        var previousRowDistances = Array(0...secondCharacters.count)
        for (firstIndex, firstCharacter) in firstCharacters.enumerated() {
            var currentRowDistances = [firstIndex + 1]
            for (secondIndex, secondCharacter) in secondCharacters.enumerated() {
                let substitutionCost = firstCharacter == secondCharacter ? 0 : 1
                currentRowDistances.append(min(
                    previousRowDistances[secondIndex + 1] + 1,
                    currentRowDistances[secondIndex] + 1,
                    previousRowDistances[secondIndex] + substitutionCost
                ))
            }
            previousRowDistances = currentRowDistances
        }
        return previousRowDistances[secondCharacters.count]
    }

    /// Lowercased runs of letters and digits: "Save Changes!" -> ["save", "changes"].
    static func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Gap between two rects (0 when they overlap).
    static func distanceBetween(_ firstRect: CGRect, _ secondRect: CGRect) -> CGFloat {
        let horizontalGap = max(0, max(firstRect.minX - secondRect.maxX, secondRect.minX - firstRect.maxX))
        let verticalGap = max(0, max(firstRect.minY - secondRect.maxY, secondRect.minY - firstRect.maxY))
        return hypot(horizontalGap, verticalGap)
    }
}
