//
//  ScreenSketch.swift
//  leanring-buddy
//
//  Hand-drawn marks Clicky sketches on top of the user's screen: rings,
//  arrows, boxes, underlines, highlights, crosses, checks, freehand paths
//  and short handwritten notes. Claude asks for them with [DRAW:...] tags
//  placed inline in its answer, next to the existing [POINT:...] tags.
//
//  This file holds the tag parser and the geometry that turns one mark into
//  slightly wobbly "marker" strokes plus a pen timeline. ScreenSketchLayer
//  renders the strokes, and BlueCursorView moves the cursor along the pen
//  timeline so it looks like Clicky is drawing them.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Mark Requests (what Claude asked for)

enum ScreenSketchMarkKind: String, CaseIterable {
    case circle
    /// The one thing to click next in a guided walkthrough. Drawn like a
    /// circle; clicking it makes Clicky look again and give the next step.
    case target
    case box
    case arrow
    case underline
    case highlight
    case cross
    case check
    case path
    case text

    /// Default ink when Claude doesn't pick a color: red for "wrong",
    /// green for "right", yellow for highlighter, blue for everything else.
    var defaultInkColor: ScreenSketchInkColor {
        switch self {
        case .target: return .orange
        case .cross: return .red
        case .check: return .green
        case .highlight: return .yellow
        default: return .blue
        }
    }
}

enum ScreenSketchInkColor: String, CaseIterable {
    case blue
    case red
    case green
    case yellow
    case orange
    case purple

    /// sRGB components. Blue matches DS.Colors.overlayCursorBlue (#3380FF) so
    /// the marks look like they came out of the cursor.
    var redGreenBlueComponents: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blue: return (0.200, 0.502, 1.000)
        case .red: return (0.957, 0.263, 0.212)
        case .green: return (0.157, 0.780, 0.353)
        case .yellow: return (1.000, 0.835, 0.039)
        case .orange: return (1.000, 0.584, 0.000)
        case .purple: return (0.749, 0.353, 0.949)
        }
    }
}

/// One [DRAW:...] tag as Claude wrote it, in screenshot pixel coordinates.
struct ScreenSketchMarkRequest: Equatable {
    let kind: ScreenSketchMarkKind
    let screenshotPoints: [CGPoint]
    let label: String?
    let inkColor: ScreenSketchInkColor
    let screenNumber: Int?
}

// MARK: - Visual Beats (POINT and DRAW tags in speaking order)

enum ParsedVisualBeatContent: Equatable {
    case point(coordinate: CGPoint, elementLabel: String?)
    case sketch(ScreenSketchMarkRequest)
}

/// One POINT or DRAW tag from Claude's response, in the order it was written.
struct ParsedVisualBeat: Equatable {
    let content: ParsedVisualBeatContent
    /// Which screen the coordinates refer to (1-based), or nil for the cursor screen.
    let screenNumber: Int?
    /// Character offset in the spoken text where the sentence this beat belongs to
    /// begins (right after the previous beat's tag). Used to time it to the speech.
    let spokenTextOffsetWhereBeatIsDescribed: Int
}

struct VisualBeatsParseResult {
    /// The response with every POINT and DRAW tag removed. This is what gets spoken.
    let spokenText: String
    let beats: [ParsedVisualBeat]
}

enum ClaudeVisualTagParser {
    /// Longest label we'll draw. Claude is asked for 1-3 words; this guards
    /// against a whole sentence ending up handwritten across the screen.
    static let maximumLabelCharacterCount = 32

    /// Most marks we'll draw for one answer, so a runaway response can't cover the screen.
    static let maximumBeatCount = 12

    /// Parses every [POINT:...] and [DRAW:...] tag anywhere in Claude's response, in
    /// order, and returns the spoken text with all tags removed.
    static func parseVisualBeats(from responseText: String) -> VisualBeatsParseResult {
        guard let tagRegex = try? NSRegularExpression(pattern: #"\[(POINT|DRAW)\s*:([^\]]*)\]"#, options: [.caseInsensitive]) else {
            return VisualBeatsParseResult(spokenText: responseText, beats: [])
        }

        let responseTextAsNSString = responseText as NSString
        let tagMatches = tagRegex.matches(in: responseText, range: NSRange(location: 0, length: responseTextAsNSString.length))

        var spokenTextWithTagsRemoved = ""
        var parsedVisualBeats: [ParsedVisualBeat] = []
        var endOfPreviousTag = 0
        // A beat's sentence starts where the previous beat's tag ended, so that's
        // when the cursor should start on it.
        var spokenTextLengthAtPreviousBeatTag = 0

        for tagMatch in tagMatches {
            spokenTextWithTagsRemoved += responseTextAsNSString.substring(
                with: NSRange(location: endOfPreviousTag, length: tagMatch.range.location - endOfPreviousTag)
            )
            endOfPreviousTag = tagMatch.range.location + tagMatch.range.length

            let tagType = responseTextAsNSString.substring(with: tagMatch.range(at: 1)).uppercased()
            let tagBody = responseTextAsNSString.substring(with: tagMatch.range(at: 2))

            let parsedBeatContentAndScreen: (content: ParsedVisualBeatContent, screenNumber: Int?)?
            if tagType == "POINT" {
                parsedBeatContentAndScreen = parsePointTagBody(tagBody).map { parsedPoint in
                    (ParsedVisualBeatContent.point(coordinate: parsedPoint.coordinate, elementLabel: parsedPoint.elementLabel), parsedPoint.screenNumber)
                }
            } else {
                parsedBeatContentAndScreen = parseDrawTagBody(tagBody).map { markRequest in
                    (ParsedVisualBeatContent.sketch(markRequest), markRequest.screenNumber)
                }
            }

            // [POINT:none] and malformed tags are still removed from the speech,
            // they just don't produce a beat.
            guard let parsedBeatContentAndScreen, parsedVisualBeats.count < maximumBeatCount else { continue }

            parsedVisualBeats.append(ParsedVisualBeat(
                content: parsedBeatContentAndScreen.content,
                screenNumber: parsedBeatContentAndScreen.screenNumber,
                spokenTextOffsetWhereBeatIsDescribed: spokenTextLengthAtPreviousBeatTag
            ))
            spokenTextLengthAtPreviousBeatTag = spokenTextWithTagsRemoved.count
        }

        spokenTextWithTagsRemoved += responseTextAsNSString.substring(from: endOfPreviousTag)

        // Removing inline tags leaves double spaces behind ("menu.  then"),
        // which some voices pause on. Collapse them so the speech flows.
        let collapsedSpokenText = spokenTextWithTagsRemoved
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([.,!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return VisualBeatsParseResult(spokenText: collapsedSpokenText, beats: parsedVisualBeats)
    }

    /// Parses the inside of a POINT tag: "x,y", "x,y:label", "x,y:label:screen2",
    /// "x,y:screen2" or "none". Returns nil for "none" or anything malformed.
    static func parsePointTagBody(_ pointTagBody: String) -> (coordinate: CGPoint, elementLabel: String?, screenNumber: Int?)? {
        let bodyParts = pointTagBody.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let coordinatePart = bodyParts.first else { return nil }

        let coordinateValues = extractNumbers(from: coordinatePart)
        guard coordinateValues.count >= 2 else { return nil }

        var elementLabel: String? = nil
        var screenNumber: Int? = nil
        for extraPart in bodyParts.dropFirst() where !extraPart.isEmpty {
            if let parsedScreenNumber = parseScreenNumber(from: extraPart) {
                screenNumber = parsedScreenNumber
            } else if elementLabel == nil {
                elementLabel = cleanedLabel(extraPart)
            }
        }

        return (CGPoint(x: coordinateValues[0], y: coordinateValues[1]), elementLabel, screenNumber)
    }

    /// Parses the inside of a DRAW tag, e.g.
    /// `circle 120,80,260,140 label="export" color=red screen=2`.
    static func parseDrawTagBody(_ drawTagBody: String) -> ScreenSketchMarkRequest? {
        var remainingBody = drawTagBody.trimmingCharacters(in: .whitespaces)

        // The kind is the first word
        let kindEndIndex = remainingBody.firstIndex(where: { !$0.isLetter }) ?? remainingBody.endIndex
        guard let markKind = ScreenSketchMarkKind(rawValue: String(remainingBody[..<kindEndIndex]).lowercased()) else {
            return nil
        }
        remainingBody = String(remainingBody[kindEndIndex...])

        // Pull out key=value settings (quoted or bare) before reading numbers,
        // so digits inside a label like "step 2" aren't taken as coordinates.
        var settingValuesByKey: [String: String] = [:]
        let settingPattern = #"([A-Za-z]+)\s*=\s*(?:"([^"]*)"|“([^”]*)”|'([^']*)'|([^\s"“”']+))"#
        if let settingRegex = try? NSRegularExpression(pattern: settingPattern) {
            let remainingBodyAsNSString = remainingBody as NSString
            let settingMatches = settingRegex.matches(in: remainingBody, range: NSRange(location: 0, length: remainingBodyAsNSString.length))
            for settingMatch in settingMatches {
                let settingKey = remainingBodyAsNSString.substring(with: settingMatch.range(at: 1)).lowercased()
                let settingValue = (2...5)
                    .map { settingMatch.range(at: $0) }
                    .first { $0.location != NSNotFound }
                    .map { remainingBodyAsNSString.substring(with: $0) } ?? ""
                settingValuesByKey[settingKey] = settingValue
            }
            remainingBody = settingRegex.stringByReplacingMatches(
                in: remainingBody,
                range: NSRange(location: 0, length: remainingBodyAsNSString.length),
                withTemplate: " "
            )
        }

        // Also accept the POINT-style ":screen2" suffix
        var screenNumber = settingValuesByKey["screen"].flatMap { parseScreenNumber(from: $0) }
        if let screenSuffixRange = remainingBody.range(of: #":?\s*screen\s*(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            screenNumber = screenNumber ?? parseScreenNumber(from: String(remainingBody[screenSuffixRange]))
            remainingBody.removeSubrange(screenSuffixRange)
        }

        let coordinateValues = extractNumbers(from: remainingBody)
        let screenshotPoints: [CGPoint]
        switch markKind {
        case .circle, .target, .box, .arrow, .underline, .highlight, .cross:
            guard coordinateValues.count >= 4 else { return nil }
            screenshotPoints = [
                CGPoint(x: coordinateValues[0], y: coordinateValues[1]),
                CGPoint(x: coordinateValues[2], y: coordinateValues[3])
            ]
        case .check, .text:
            guard coordinateValues.count >= 2 else { return nil }
            screenshotPoints = [CGPoint(x: coordinateValues[0], y: coordinateValues[1])]
        case .path:
            guard coordinateValues.count >= 4 else { return nil }
            screenshotPoints = stride(from: 0, to: coordinateValues.count - 1, by: 2).map {
                CGPoint(x: coordinateValues[$0], y: coordinateValues[$0 + 1])
            }
        }

        let label = (settingValuesByKey["label"] ?? settingValuesByKey["text"]).flatMap { cleanedLabel($0) }
        // A text mark with nothing to write isn't worth drawing
        if markKind == .text && label == nil { return nil }

        let inkColor = settingValuesByKey["color"]
            .flatMap { ScreenSketchInkColor(rawValue: $0.lowercased()) }
            ?? markKind.defaultInkColor

        return ScreenSketchMarkRequest(
            kind: markKind,
            screenshotPoints: screenshotPoints,
            label: label,
            inkColor: inkColor,
            screenNumber: screenNumber
        )
    }

    private static func extractNumbers(from text: String) -> [Double] {
        guard let numberRegex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return [] }
        let textAsNSString = text as NSString
        return numberRegex
            .matches(in: text, range: NSRange(location: 0, length: textAsNSString.length))
            .compactMap { Double(textAsNSString.substring(with: $0.range)) }
    }

    private static func parseScreenNumber(from text: String) -> Int? {
        let trimmedText = text.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
        if trimmedText.hasPrefix("screen") {
            return Int(trimmedText.dropFirst("screen".count).trimmingCharacters(in: .whitespaces))
        }
        return Int(trimmedText)
    }

    private static func cleanedLabel(_ rawLabel: String) -> String? {
        let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, trimmedLabel.lowercased() != "none" else { return nil }
        if trimmedLabel.count <= maximumLabelCharacterCount { return trimmedLabel }
        return String(trimmedLabel.prefix(maximumLabelCharacterCount - 1)) + "…"
    }
}

// MARK: - Drawings (marks turned into strokes, in overlay coordinates)

/// One continuous marker stroke, stored as a dense polyline so it can be
/// partially drawn by length and the pen can be placed anywhere along it.
struct ScreenSketchStroke {
    let points: [CGPoint]
    /// cumulativeLengths[i] is the distance along the stroke to points[i].
    let cumulativeLengths: [CGFloat]
    let lineWidth: CGFloat
    /// Wide translucent highlighter instead of an opaque marker line.
    let isHighlighter: Bool

    var totalLength: CGFloat { cumulativeLengths.last ?? 0 }

    init(points: [CGPoint], lineWidth: CGFloat, isHighlighter: Bool = false) {
        self.points = points
        self.lineWidth = lineWidth
        self.isHighlighter = isHighlighter

        var runningLength: CGFloat = 0
        var cumulativeLengths: [CGFloat] = []
        for (pointIndex, point) in points.enumerated() {
            if pointIndex > 0 {
                runningLength += hypot(point.x - points[pointIndex - 1].x, point.y - points[pointIndex - 1].y)
            }
            cumulativeLengths.append(runningLength)
        }
        self.cumulativeLengths = cumulativeLengths
    }

    /// The point `distanceAlongStroke` from the start, interpolated between samples.
    func point(atDistance distanceAlongStroke: CGFloat) -> CGPoint {
        guard let firstPoint = points.first else { return .zero }
        guard distanceAlongStroke > 0 else { return firstPoint }
        guard distanceAlongStroke < totalLength else { return points[points.count - 1] }

        let segmentEndIndex = indexOfFirstSample(atOrBeyondDistance: distanceAlongStroke)
        let segmentStartIndex = max(segmentEndIndex - 1, 0)
        let segmentStartLength = cumulativeLengths[segmentStartIndex]
        let segmentLength = cumulativeLengths[segmentEndIndex] - segmentStartLength
        guard segmentLength > 0 else { return points[segmentEndIndex] }

        let fractionThroughSegment = (distanceAlongStroke - segmentStartLength) / segmentLength
        let segmentStartPoint = points[segmentStartIndex]
        let segmentEndPoint = points[segmentEndIndex]
        return CGPoint(
            x: segmentStartPoint.x + (segmentEndPoint.x - segmentStartPoint.x) * fractionThroughSegment,
            y: segmentStartPoint.y + (segmentEndPoint.y - segmentStartPoint.y) * fractionThroughSegment
        )
    }

    /// The samples making up the first `distanceAlongStroke` of the stroke, ending
    /// exactly at that distance. Used to render a partially drawn stroke.
    func points(upToDistance distanceAlongStroke: CGFloat) -> [CGPoint] {
        guard distanceAlongStroke > 0, points.count > 1 else { return [] }
        guard distanceAlongStroke < totalLength else { return points }

        let firstSampleBeyondDistanceIndex = indexOfFirstSample(atOrBeyondDistance: distanceAlongStroke)
        var partialPoints = Array(points[..<firstSampleBeyondDistanceIndex])
        partialPoints.append(point(atDistance: distanceAlongStroke))
        return partialPoints
    }

    private func indexOfFirstSample(atOrBeyondDistance distanceAlongStroke: CGFloat) -> Int {
        // Binary search: strokes have a few hundred samples and this runs every frame
        var lowerIndex = 0
        var upperIndex = cumulativeLengths.count - 1
        while lowerIndex < upperIndex {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if cumulativeLengths[middleIndex] < distanceAlongStroke {
                lowerIndex = middleIndex + 1
            } else {
                upperIndex = middleIndex
            }
        }
        return lowerIndex
    }
}

/// A short handwritten note drawn on a small paper tag.
struct ScreenSketchTextLabel {
    let text: String
    /// Left edge, vertical middle of the text.
    let leadingCenterPoint: CGPoint
    let fontSize: CGFloat
    let textSize: CGSize
    /// Slight tilt so the tag looks stuck on by hand.
    let rotationDegrees: Double
}

/// What the pen is doing during one slice of the drawing animation.
enum ScreenSketchPenSegment {
    /// Drawing stroke `strokeIndex` from its start to its end.
    case drawingStroke(strokeIndex: Int)
    /// Pen lifted, moving from one place to another without ink.
    case movingWithoutInk(fromPoint: CGPoint, toPoint: CGPoint)
    /// Writing the text label from left to right.
    case writingLabel
}

/// A fully laid-out mark: its strokes, its optional label, and the timeline
/// the pen follows to draw them. Built once per mark; the animation only
/// changes a 0...1 progress value.
struct ScreenSketchDrawing {
    let id: UUID
    let kind: ScreenSketchMarkKind
    let inkColor: ScreenSketchInkColor
    /// Whether the screen under the mark is dark. Translucent yellow turns muddy
    /// over dark UIs, so highlights there get a faint wash plus a solid underline.
    let isOverDarkBackground: Bool
    let strokes: [ScreenSketchStroke]
    let textLabel: ScreenSketchTextLabel?
    let penSegments: [ScreenSketchPenSegment]
    let penSegmentDurations: [Double]
    let drawingDurationSeconds: Double

    /// Where the pen starts, so the cursor can fly there before drawing.
    var penStartPoint: CGPoint { penPoint(atProgress: 0) }

    /// How far (in points) stroke `strokeIndex` is drawn at `drawingProgress`.
    func inkedLength(ofStrokeAt strokeIndex: Int, atProgress drawingProgress: Double) -> CGFloat {
        let (currentSegmentIndex, fractionThroughCurrentSegment) = penSegmentPosition(atProgress: drawingProgress)
        for (segmentIndex, penSegment) in penSegments.enumerated() {
            guard case .drawingStroke(let segmentStrokeIndex) = penSegment, segmentStrokeIndex == strokeIndex else { continue }
            if segmentIndex < currentSegmentIndex { return strokes[strokeIndex].totalLength }
            if segmentIndex > currentSegmentIndex { return 0 }
            return strokes[strokeIndex].totalLength * CGFloat(fractionThroughCurrentSegment)
        }
        return 0
    }

    /// How many characters of the label are written at `drawingProgress`.
    func revealedLabelCharacterCount(atProgress drawingProgress: Double) -> Int {
        guard let textLabel else { return 0 }
        let (currentSegmentIndex, fractionThroughCurrentSegment) = penSegmentPosition(atProgress: drawingProgress)
        guard let writingSegmentIndex = penSegments.firstIndex(where: {
            if case .writingLabel = $0 { return true }
            return false
        }) else { return 0 }
        if currentSegmentIndex < writingSegmentIndex { return 0 }
        if currentSegmentIndex > writingSegmentIndex { return textLabel.text.count }
        return Int((Double(textLabel.text.count) * fractionThroughCurrentSegment).rounded(.up))
    }

    /// Whether the label's paper tag should be showing yet.
    func isLabelVisible(atProgress drawingProgress: Double) -> Bool {
        revealedLabelCharacterCount(atProgress: drawingProgress) > 0
    }

    /// Where the pen tip is at `drawingProgress`.
    func penPoint(atProgress drawingProgress: Double) -> CGPoint {
        let (currentSegmentIndex, fractionThroughCurrentSegment) = penSegmentPosition(atProgress: drawingProgress)
        guard penSegments.indices.contains(currentSegmentIndex) else { return .zero }

        switch penSegments[currentSegmentIndex] {
        case .drawingStroke(let strokeIndex):
            let stroke = strokes[strokeIndex]
            return stroke.point(atDistance: stroke.totalLength * CGFloat(fractionThroughCurrentSegment))
        case .movingWithoutInk(let fromPoint, let toPoint):
            return CGPoint(
                x: fromPoint.x + (toPoint.x - fromPoint.x) * CGFloat(fractionThroughCurrentSegment),
                y: fromPoint.y + (toPoint.y - fromPoint.y) * CGFloat(fractionThroughCurrentSegment)
            )
        case .writingLabel:
            guard let textLabel else { return .zero }
            return CGPoint(
                x: textLabel.leadingCenterPoint.x + textLabel.textSize.width * CGFloat(fractionThroughCurrentSegment),
                y: textLabel.leadingCenterPoint.y + textLabel.textSize.height * 0.25
            )
        }
    }

    /// Which pen segment is active at `drawingProgress`, and how far through it.
    private func penSegmentPosition(atProgress drawingProgress: Double) -> (segmentIndex: Int, fractionThroughSegment: Double) {
        guard !penSegments.isEmpty else { return (0, 0) }
        let clampedProgress = min(max(drawingProgress, 0), 1)
        let totalSegmentDuration = penSegmentDurations.reduce(0, +)
        guard totalSegmentDuration > 0 else { return (penSegments.count - 1, 1) }

        let elapsedSegmentDuration = clampedProgress * totalSegmentDuration
        var segmentStartDuration = 0.0
        for (segmentIndex, segmentDuration) in penSegmentDurations.enumerated() {
            let segmentEndDuration = segmentStartDuration + segmentDuration
            if elapsedSegmentDuration <= segmentEndDuration || segmentIndex == penSegmentDurations.count - 1 {
                let fractionThroughSegment = segmentDuration > 0
                    ? (elapsedSegmentDuration - segmentStartDuration) / segmentDuration
                    : 1
                return (segmentIndex, min(max(fractionThroughSegment, 0), 1))
            }
            segmentStartDuration = segmentEndDuration
        }
        return (penSegments.count - 1, 1)
    }
}

// MARK: - Geometry

/// Deterministic random numbers (SplitMix64) so a mark's wobble is decided once
/// from its seed and never jitters between frames.
struct ScreenSketchRandomNumberGenerator: RandomNumberGenerator {
    private var generatorState: UInt64

    init(seed: UInt64) {
        generatorState = seed
    }

    mutating func next() -> UInt64 {
        generatorState &+= 0x9E37_79B9_7F4A_7C15
        var mixedValue = generatorState
        mixedValue = (mixedValue ^ (mixedValue >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixedValue = (mixedValue ^ (mixedValue >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixedValue ^ (mixedValue >> 31)
    }
}

enum ScreenSketchGeometry {
    static let markerLineWidth: CGFloat = 3.4
    static let labelFontName = "Noteworthy-Bold"
    static let labelFontSize: CGFloat = 17
    /// Gap between a mark and its label.
    static let labelGap: CGFloat = 10
    /// Keep marks and labels at least this far inside the screen edges.
    static let screenEdgeInset: CGFloat = 8

    // Pen speeds. Writing is slower than drawing lines, like real handwriting.
    static let inkDrawingSpeedPointsPerSecond: Double = 720
    static let labelWritingSpeedPointsPerSecond: Double = 260
    static let penLiftDurationSeconds: Double = 0.07
    static let minimumDrawingDurationSeconds: Double = 0.3
    static let maximumDrawingDurationSeconds: Double = 2.2

    /// Builds the strokes, label and pen timeline for one mark.
    /// `localPoints` are the mark's points already converted to overlay
    /// coordinates (top-left origin, in points). `canvasSize` is the overlay's size.
    static func makeDrawing(
        kind: ScreenSketchMarkKind,
        localPoints: [CGPoint],
        label: String?,
        inkColor: ScreenSketchInkColor,
        canvasSize: CGSize,
        seed: UInt64,
        isOverDarkBackground: Bool = false,
        labelObstacleRects: [CGRect] = [],
        id: UUID = UUID()
    ) -> ScreenSketchDrawing {
        var randomNumberGenerator = ScreenSketchRandomNumberGenerator(seed: seed)
        let clampedLocalPoints = localPoints.map { clampPointToCanvas($0, canvasSize: canvasSize) }

        let strokes: [ScreenSketchStroke]
        // The area the mark covers, used to place its label beside it
        let markBounds: CGRect
        var arrowTailPointAndDirection: (tailPoint: CGPoint, direction: CGVector)? = nil

        switch kind {
        case .circle, .target:
            let ringedRect = normalizedRect(clampedLocalPoints[0], clampedLocalPoints[1])
            let ringStroke = makeRingStroke(around: ringedRect, randomNumberGenerator: &randomNumberGenerator)
            strokes = [ringStroke]
            markBounds = boundingRect(of: ringStroke.points)
        case .box:
            let boxedRect = normalizedRect(clampedLocalPoints[0], clampedLocalPoints[1]).insetBy(dx: -5, dy: -5)
            let boxStroke = makeBoxStroke(around: boxedRect, randomNumberGenerator: &randomNumberGenerator)
            strokes = [boxStroke]
            markBounds = boundingRect(of: boxStroke.points)
        case .arrow:
            let arrowStrokes = makeArrowStrokes(
                fromTailPoint: clampedLocalPoints[0],
                toTipPoint: clampedLocalPoints[1],
                randomNumberGenerator: &randomNumberGenerator
            )
            strokes = arrowStrokes.strokes
            markBounds = boundingRect(of: strokes.flatMap(\.points))
            arrowTailPointAndDirection = (arrowStrokes.tailPoint, arrowStrokes.direction)
        case .underline:
            let underlineStroke = makeUnderlineStroke(
                fromPoint: clampedLocalPoints[0],
                toPoint: clampedLocalPoints[1],
                randomNumberGenerator: &randomNumberGenerator
            )
            strokes = [underlineStroke]
            markBounds = boundingRect(of: underlineStroke.points)
        case .highlight:
            let highlightedRect = normalizedRect(clampedLocalPoints[0], clampedLocalPoints[1])
            var highlightStrokes = makeHighlightStrokes(over: highlightedRect, randomNumberGenerator: &randomNumberGenerator)
            if isOverDarkBackground {
                // The wash is kept faint on dark backgrounds (see ScreenSketchLayer),
                // so a solid marker line underneath carries the highlight.
                let underlineY = max(highlightedRect.maxY, highlightedRect.midY + 9) + 3
                highlightStrokes.append(makeUnderlineStroke(
                    fromPoint: CGPoint(x: highlightedRect.minX - 2, y: underlineY),
                    toPoint: CGPoint(x: highlightedRect.maxX + 2, y: underlineY),
                    randomNumberGenerator: &randomNumberGenerator
                ))
            }
            strokes = highlightStrokes
            markBounds = boundingRect(of: highlightStrokes.flatMap(\.points))
        case .cross:
            let crossedRect = expandedToMinimumSize(normalizedRect(clampedLocalPoints[0], clampedLocalPoints[1]), minimumSide: 24)
            strokes = makeCrossStrokes(over: crossedRect, randomNumberGenerator: &randomNumberGenerator)
            markBounds = crossedRect
        case .check:
            let checkStroke = makeCheckStroke(centeredAt: clampedLocalPoints[0], randomNumberGenerator: &randomNumberGenerator)
            strokes = [checkStroke]
            markBounds = boundingRect(of: checkStroke.points)
        case .path:
            let freehandStroke = makeFreehandStroke(through: clampedLocalPoints, randomNumberGenerator: &randomNumberGenerator)
            strokes = [freehandStroke]
            markBounds = boundingRect(of: freehandStroke.points)
        case .text:
            strokes = []
            markBounds = CGRect(origin: clampedLocalPoints[0], size: .zero)
        }

        // What the label must not cover: an arrow's actual line (its bounding box
        // is mostly empty space, often right where the label belongs), or the
        // whole area of any other mark.
        let markObstacleRects: [CGRect] = kind == .arrow
            ? strokes.flatMap { stroke in
                stride(from: 0, to: stroke.points.count, by: 4).map { pointIndex in
                    CGRect(x: stroke.points[pointIndex].x - 4, y: stroke.points[pointIndex].y - 4, width: 8, height: 8)
                }
            }
            : [markBounds.insetBy(dx: -3, dy: -3)]

        let textLabel = label.map { labelText in
            makeTextLabel(
                text: labelText,
                kind: kind,
                markBounds: markBounds,
                markObstacleRects: markObstacleRects,
                arrowTailPointAndDirection: arrowTailPointAndDirection,
                textAnchorPoint: kind == .text ? clampedLocalPoints[0] : nil,
                canvasSize: canvasSize,
                labelObstacleRects: labelObstacleRects,
                randomNumberGenerator: &randomNumberGenerator
            )
        }

        // Pen timeline: each stroke in order with quick lifts between them,
        // then the label written left to right.
        var penSegments: [ScreenSketchPenSegment] = []
        var penSegmentDurations: [Double] = []
        var previousPenEndPoint: CGPoint? = nil

        for (strokeIndex, stroke) in strokes.enumerated() where stroke.points.count > 1 {
            if let previousPenEndPoint {
                penSegments.append(.movingWithoutInk(fromPoint: previousPenEndPoint, toPoint: stroke.points[0]))
                penSegmentDurations.append(penLiftDurationSeconds)
            }
            penSegments.append(.drawingStroke(strokeIndex: strokeIndex))
            penSegmentDurations.append(Double(stroke.totalLength) / inkDrawingSpeedPointsPerSecond)
            previousPenEndPoint = stroke.points[stroke.points.count - 1]
        }

        if let textLabel {
            if let previousPenEndPoint {
                penSegments.append(.movingWithoutInk(fromPoint: previousPenEndPoint, toPoint: textLabel.leadingCenterPoint))
                penSegmentDurations.append(penLiftDurationSeconds * 2)
            }
            penSegments.append(.writingLabel)
            penSegmentDurations.append(Double(textLabel.textSize.width) / labelWritingSpeedPointsPerSecond)
        }

        let naturalDrawingDuration = penSegmentDurations.reduce(0, +)
        let drawingDurationSeconds = min(max(naturalDrawingDuration, minimumDrawingDurationSeconds), maximumDrawingDurationSeconds)

        return ScreenSketchDrawing(
            id: id,
            kind: kind,
            inkColor: inkColor,
            isOverDarkBackground: isOverDarkBackground,
            strokes: strokes,
            textLabel: textLabel,
            penSegments: penSegments,
            penSegmentDurations: penSegmentDurations,
            drawingDurationSeconds: drawingDurationSeconds
        )
    }

    // MARK: Shapes

    /// A hand-drawn ring around `ringedRect`: starts upper-left, goes all the way
    /// around and overshoots past the start, with the end drifting slightly
    /// outward so it doesn't close perfectly, the way people circle things.
    private static func makeRingStroke(around ringedRect: CGRect, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> ScreenSketchStroke {
        let ringRadii = enclosingRingRadii(for: ringedRect)
        let horizontalRadius = ringRadii.horizontalRadius
        let verticalRadius = ringRadii.verticalRadius
        let ringCenter = CGPoint(x: ringedRect.midX, y: ringedRect.midY)

        let startAngle = Double.random(in: -2.6 ... -2.0, using: &randomNumberGenerator)
        let sweepAngle = 2 * Double.pi * Double.random(in: 1.06 ... 1.14, using: &randomNumberGenerator)
        // Drift only outward, so the overlapping end never cuts into the element
        let radiusDriftByEnd = Double.random(in: 0.01 ... 0.07, using: &randomNumberGenerator)
        // Long thin rings tilt less: a few degrees swings their far ends a long way
        let ringAspectRatio = Double(max(horizontalRadius, verticalRadius) / max(min(horizontalRadius, verticalRadius), 1))
        let maximumTiltRadians = 0.06 / max(1, ringAspectRatio / 2)
        let tiltRadians = Double.random(in: -maximumTiltRadians ... maximumTiltRadians, using: &randomNumberGenerator)

        let approximatePerimeter = Double.pi * Double(horizontalRadius + verticalRadius) * 1.1
        let sampleCount = max(48, Int(approximatePerimeter / 3))

        var ringPoints: [CGPoint] = []
        for sampleIndex in 0...sampleCount {
            let fractionAroundRing = Double(sampleIndex) / Double(sampleCount)
            let angle = startAngle + sweepAngle * fractionAroundRing
            let radiusScale = 1 + radiusDriftByEnd * fractionAroundRing
            let unrotatedX = cos(angle) * Double(horizontalRadius) * radiusScale
            let unrotatedY = sin(angle) * Double(verticalRadius) * radiusScale
            ringPoints.append(CGPoint(
                x: ringCenter.x + CGFloat(unrotatedX * cos(tiltRadians) - unrotatedY * sin(tiltRadians)),
                y: ringCenter.y + CGFloat(unrotatedX * sin(tiltRadians) + unrotatedY * cos(tiltRadians))
            ))
        }

        let wobblyRingPoints = applyHandWobble(to: ringPoints, amplitude: 1.1, taperAtEnds: false, randomNumberGenerator: &randomNumberGenerator)
        return ScreenSketchStroke(points: wobblyRingPoints, lineWidth: markerLineWidth)
    }

    /// Radii of the snuggest ellipse that still clears all four corners of
    /// `ringedRect` with some room to spare. Both half-sizes are scaled by the
    /// same factor plus a fixed padding, and the factor is found by bisection:
    /// about 1.15 for long thin elements up to about 1.5 for square ones. A plain
    /// padded ellipse would cut through the corners of anything squarish.
    private static func enclosingRingRadii(for ringedRect: CGRect) -> (horizontalRadius: CGFloat, verticalRadius: CGFloat) {
        let halfWidth = Double(max(ringedRect.width / 2, 6))
        let halfHeight = Double(max(ringedRect.height / 2, 6))
        let fixedPadding = 8.0
        // Below 1 so wobble and tilt can't push a corner outside the line
        let targetCornerEllipseValue = 0.78

        func cornerEllipseValue(forScale scale: Double) -> Double {
            let horizontalTerm = halfWidth / (halfWidth * scale + fixedPadding)
            let verticalTerm = halfHeight / (halfHeight * scale + fixedPadding)
            return horizontalTerm * horizontalTerm + verticalTerm * verticalTerm
        }

        // cornerEllipseValue shrinks as the scale grows, so bisect for the target
        var lowerScale = 0.5
        var upperScale = 3.0
        for _ in 0..<40 {
            let middleScale = (lowerScale + upperScale) / 2
            if cornerEllipseValue(forScale: middleScale) > targetCornerEllipseValue {
                lowerScale = middleScale
            } else {
                upperScale = middleScale
            }
        }

        return (
            CGFloat(max(halfWidth * upperScale + fixedPadding, 16)),
            CGFloat(max(halfHeight * upperScale + fixedPadding, 14))
        )
    }

    /// A rectangle drawn in one go, clockwise from the top-left corner, that
    /// runs a little past where it started.
    private static func makeBoxStroke(around boxedRect: CGRect, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> ScreenSketchStroke {
        let topLeft = CGPoint(x: boxedRect.minX, y: boxedRect.minY)
        let topRight = CGPoint(x: boxedRect.maxX, y: boxedRect.minY)
        let bottomRight = CGPoint(x: boxedRect.maxX, y: boxedRect.maxY)
        let bottomLeft = CGPoint(x: boxedRect.minX, y: boxedRect.maxY)
        let overshootLength = min(boxedRect.width * 0.25, 14)
        let overshootEnd = CGPoint(x: topLeft.x + overshootLength, y: topLeft.y - 1.5)

        var boxPoints: [CGPoint] = []
        let corners = [topLeft, topRight, bottomRight, bottomLeft, topLeft, overshootEnd]
        for cornerIndex in 0..<(corners.count - 1) {
            let edgePoints = sampleSlightlyBowedLine(
                from: corners[cornerIndex],
                to: corners[cornerIndex + 1],
                maximumBow: 1.8,
                randomNumberGenerator: &randomNumberGenerator
            )
            boxPoints.append(contentsOf: cornerIndex == 0 ? edgePoints : Array(edgePoints.dropFirst()))
        }

        let wobblyBoxPoints = applyHandWobble(to: boxPoints, amplitude: 0.8, taperAtEnds: false, randomNumberGenerator: &randomNumberGenerator)
        return ScreenSketchStroke(points: wobblyBoxPoints, lineWidth: markerLineWidth)
    }

    /// A slightly curved arrow shaft plus a "V" head drawn in one motion.
    /// The tip stops just short of the target so it doesn't cover it.
    private static func makeArrowStrokes(
        fromTailPoint requestedTailPoint: CGPoint,
        toTipPoint requestedTipPoint: CGPoint,
        randomNumberGenerator: inout ScreenSketchRandomNumberGenerator
    ) -> (strokes: [ScreenSketchStroke], tailPoint: CGPoint, direction: CGVector) {
        var tailPoint = requestedTailPoint
        let tipTargetPoint = requestedTipPoint

        // A tail sitting on the tip can't make an arrow; come in from the upper left
        if hypot(tipTargetPoint.x - tailPoint.x, tipTargetPoint.y - tailPoint.y) < 24 {
            tailPoint = CGPoint(x: tipTargetPoint.x - 70, y: tipTargetPoint.y - 45)
        }

        let fullLength = hypot(tipTargetPoint.x - tailPoint.x, tipTargetPoint.y - tailPoint.y)
        let unitDirection = CGVector(dx: (tipTargetPoint.x - tailPoint.x) / fullLength, dy: (tipTargetPoint.y - tailPoint.y) / fullLength)
        let gapBeforeTarget = min(7, fullLength * 0.1)
        let tipPoint = CGPoint(x: tipTargetPoint.x - unitDirection.dx * gapBeforeTarget, y: tipTargetPoint.y - unitDirection.dy * gapBeforeTarget)
        let shaftLength = hypot(tipPoint.x - tailPoint.x, tipPoint.y - tailPoint.y)

        // Bow the shaft to one side like a hand-drawn arc
        let bowSign: CGFloat = Bool.random(using: &randomNumberGenerator) ? 1 : -1
        let bowAmount = shaftLength * CGFloat(Double.random(in: 0.06 ... 0.12, using: &randomNumberGenerator)) * bowSign
        let perpendicular = CGVector(dx: -unitDirection.dy, dy: unitDirection.dx)
        let controlPoint = CGPoint(
            x: (tailPoint.x + tipPoint.x) / 2 + perpendicular.dx * bowAmount,
            y: (tailPoint.y + tipPoint.y) / 2 + perpendicular.dy * bowAmount
        )

        let shaftSampleCount = max(16, Int(shaftLength / 3))
        let shaftPoints = (0...shaftSampleCount).map { sampleIndex -> CGPoint in
            // Quadratic bezier: B(t) = (1-t)²·tail + 2(1-t)t·control + t²·tip
            let curveParameter = CGFloat(sampleIndex) / CGFloat(shaftSampleCount)
            let oneMinusParameter: CGFloat = 1 - curveParameter
            let tailWeight: CGFloat = oneMinusParameter * oneMinusParameter
            let controlWeight: CGFloat = 2 * oneMinusParameter * curveParameter
            let tipWeight: CGFloat = curveParameter * curveParameter
            let curveX: CGFloat = tailWeight * tailPoint.x + controlWeight * controlPoint.x + tipWeight * tipPoint.x
            let curveY: CGFloat = tailWeight * tailPoint.y + controlWeight * controlPoint.y + tipWeight * tipPoint.y
            return CGPoint(x: curveX, y: curveY)
        }
        let wobblyShaftPoints = applyHandWobble(to: shaftPoints, amplitude: 0.8, taperAtEnds: true, randomNumberGenerator: &randomNumberGenerator)

        // The head follows the shaft's direction where it arrives, not the straight line
        let arrivalDirectionLength = hypot(tipPoint.x - controlPoint.x, tipPoint.y - controlPoint.y)
        let arrivalDirection = arrivalDirectionLength > 0
            ? CGVector(dx: (tipPoint.x - controlPoint.x) / arrivalDirectionLength, dy: (tipPoint.y - controlPoint.y) / arrivalDirectionLength)
            : unitDirection
        let headLength = min(max(shaftLength * 0.14, 12), 19)
        let barbAngle = Double.random(in: 0.42 ... 0.55, using: &randomNumberGenerator)

        func barbPoint(rotatedBy barbRotation: Double) -> CGPoint {
            let rotatedDirectionX = Double(arrivalDirection.dx) * cos(barbRotation) - Double(arrivalDirection.dy) * sin(barbRotation)
            let rotatedDirectionY = Double(arrivalDirection.dx) * sin(barbRotation) + Double(arrivalDirection.dy) * cos(barbRotation)
            return CGPoint(x: tipPoint.x - CGFloat(rotatedDirectionX) * headLength, y: tipPoint.y - CGFloat(rotatedDirectionY) * headLength)
        }

        let headPoints = sampleSlightlyBowedLine(from: barbPoint(rotatedBy: barbAngle), to: tipPoint, maximumBow: 0.8, randomNumberGenerator: &randomNumberGenerator)
            + Array(sampleSlightlyBowedLine(from: tipPoint, to: barbPoint(rotatedBy: -barbAngle), maximumBow: 0.8, randomNumberGenerator: &randomNumberGenerator).dropFirst())

        return (
            [
                ScreenSketchStroke(points: wobblyShaftPoints, lineWidth: markerLineWidth),
                ScreenSketchStroke(points: headPoints, lineWidth: markerLineWidth)
            ],
            tailPoint,
            unitDirection
        )
    }

    /// A slightly wavy line with a small upward flick at the end.
    private static func makeUnderlineStroke(fromPoint: CGPoint, toPoint: CGPoint, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> ScreenSketchStroke {
        var underlinePoints = sampleSlightlyBowedLine(from: fromPoint, to: toPoint, maximumBow: 2.5, randomNumberGenerator: &randomNumberGenerator)
        let flickSampleCount = max(underlinePoints.count / 8, 2)
        for flickIndex in 0..<flickSampleCount {
            let pointIndex = underlinePoints.count - flickSampleCount + flickIndex
            let flickAmount = CGFloat(flickIndex + 1) / CGFloat(flickSampleCount) * 3.5
            underlinePoints[pointIndex].y -= flickAmount
        }
        let wobblyUnderlinePoints = applyHandWobble(to: underlinePoints, amplitude: 0.6, taperAtEnds: true, randomNumberGenerator: &randomNumberGenerator)
        return ScreenSketchStroke(points: wobblyUnderlinePoints, lineWidth: markerLineWidth)
    }

    /// Wide translucent highlighter passes over `highlightedRect`. Tall areas get
    /// several back-and-forth passes like someone filling them in.
    private static func makeHighlightStrokes(over highlightedRect: CGRect, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> [ScreenSketchStroke] {
        let effectiveRect = highlightedRect.height < 10
            ? CGRect(x: highlightedRect.minX, y: highlightedRect.midY - 9, width: highlightedRect.width, height: 18)
            : highlightedRect
        let passCount = max(1, Int((effectiveRect.height / 30).rounded(.up)))
        let passHeight = effectiveRect.height / CGFloat(passCount)
        let highlighterWidth = min(max(passHeight * 1.05, 12), 34)

        return (0..<passCount).map { passIndex in
            let passCenterY = effectiveRect.minY + passHeight * (CGFloat(passIndex) + 0.5)
            let isLeftToRightPass = passIndex % 2 == 0
            let slope = CGFloat(Double.random(in: -1.5 ... 1.5, using: &randomNumberGenerator))
            let leftPoint = CGPoint(x: effectiveRect.minX - 3, y: passCenterY - slope)
            let rightPoint = CGPoint(x: effectiveRect.maxX + 3, y: passCenterY + slope)
            let passPoints = sampleSlightlyBowedLine(
                from: isLeftToRightPass ? leftPoint : rightPoint,
                to: isLeftToRightPass ? rightPoint : leftPoint,
                maximumBow: 1.2,
                randomNumberGenerator: &randomNumberGenerator
            )
            return ScreenSketchStroke(points: passPoints, lineWidth: highlighterWidth, isHighlighter: true)
        }
    }

    /// Two strokes forming an X across `crossedRect`.
    private static func makeCrossStrokes(over crossedRect: CGRect, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> [ScreenSketchStroke] {
        let insetRect = crossedRect.insetBy(dx: 2, dy: 2)
        let firstStrokePoints = sampleSlightlyBowedLine(
            from: CGPoint(x: insetRect.minX, y: insetRect.minY),
            to: CGPoint(x: insetRect.maxX, y: insetRect.maxY),
            maximumBow: 2,
            randomNumberGenerator: &randomNumberGenerator
        )
        let secondStrokePoints = sampleSlightlyBowedLine(
            from: CGPoint(x: insetRect.maxX, y: insetRect.minY),
            to: CGPoint(x: insetRect.minX, y: insetRect.maxY),
            maximumBow: 2,
            randomNumberGenerator: &randomNumberGenerator
        )
        return [firstStrokePoints, secondStrokePoints].map { strokePoints in
            ScreenSketchStroke(
                points: applyHandWobble(to: strokePoints, amplitude: 0.6, taperAtEnds: true, randomNumberGenerator: &randomNumberGenerator),
                lineWidth: markerLineWidth
            )
        }
    }

    /// A check mark: short stroke down, long stroke up to the right.
    private static func makeCheckStroke(centeredAt checkCenter: CGPoint, randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> ScreenSketchStroke {
        let checkSize: CGFloat = 24
        let startPoint = CGPoint(x: checkCenter.x - checkSize * 0.45, y: checkCenter.y)
        let bottomPoint = CGPoint(x: checkCenter.x - checkSize * 0.1, y: checkCenter.y + checkSize * 0.35)
        let endPoint = CGPoint(x: checkCenter.x + checkSize * 0.55, y: checkCenter.y - checkSize * 0.5)
        let checkPoints = sampleSlightlyBowedLine(from: startPoint, to: bottomPoint, maximumBow: 0.6, randomNumberGenerator: &randomNumberGenerator)
            + Array(sampleSlightlyBowedLine(from: bottomPoint, to: endPoint, maximumBow: 1.5, randomNumberGenerator: &randomNumberGenerator).dropFirst())
        return ScreenSketchStroke(points: checkPoints, lineWidth: markerLineWidth + 0.4)
    }

    /// A smooth line through Claude's points (Catmull-Rom spline).
    private static func makeFreehandStroke(through controlPoints: [CGPoint], randomNumberGenerator: inout ScreenSketchRandomNumberGenerator) -> ScreenSketchStroke {
        guard controlPoints.count > 2 else {
            let straightPoints = sampleSlightlyBowedLine(from: controlPoints[0], to: controlPoints[controlPoints.count - 1], maximumBow: 2, randomNumberGenerator: &randomNumberGenerator)
            return ScreenSketchStroke(points: straightPoints, lineWidth: markerLineWidth)
        }

        var splinePoints: [CGPoint] = [controlPoints[0]]
        for segmentIndex in 0..<(controlPoints.count - 1) {
            let previousPoint = controlPoints[max(segmentIndex - 1, 0)]
            let segmentStartPoint = controlPoints[segmentIndex]
            let segmentEndPoint = controlPoints[segmentIndex + 1]
            let nextPoint = controlPoints[min(segmentIndex + 2, controlPoints.count - 1)]
            let segmentLength = hypot(segmentEndPoint.x - segmentStartPoint.x, segmentEndPoint.y - segmentStartPoint.y)
            let segmentSampleCount = max(6, Int(segmentLength / 3))

            for sampleIndex in 1...segmentSampleCount {
                let curveParameter = CGFloat(sampleIndex) / CGFloat(segmentSampleCount)
                let parameterSquared = curveParameter * curveParameter
                let parameterCubed = parameterSquared * curveParameter
                func catmullRom(_ previousValue: CGFloat, _ startValue: CGFloat, _ endValue: CGFloat, _ nextValue: CGFloat) -> CGFloat {
                    0.5 * ((2 * startValue)
                        + (-previousValue + endValue) * curveParameter
                        + (2 * previousValue - 5 * startValue + 4 * endValue - nextValue) * parameterSquared
                        + (-previousValue + 3 * startValue - 3 * endValue + nextValue) * parameterCubed)
                }
                splinePoints.append(CGPoint(
                    x: catmullRom(previousPoint.x, segmentStartPoint.x, segmentEndPoint.x, nextPoint.x),
                    y: catmullRom(previousPoint.y, segmentStartPoint.y, segmentEndPoint.y, nextPoint.y)
                ))
            }
        }

        let wobblyFreehandPoints = applyHandWobble(to: splinePoints, amplitude: 0.6, taperAtEnds: true, randomNumberGenerator: &randomNumberGenerator)
        return ScreenSketchStroke(points: wobblyFreehandPoints, lineWidth: markerLineWidth)
    }

    // MARK: Labels

    /// Places the label beside its mark. A few spots are tried in order of how
    /// natural they look (arrows: at the tail; everything else: right, left,
    /// above, below), each also slid further out in small steps. Covering
    /// on-screen text (`labelObstacleRects`, from text recognition) or the mark
    /// itself costs far more than sitting a bit further away or in a less
    /// natural spot, so the label lands in the nearest clear space.
    private static func makeTextLabel(
        text labelText: String,
        kind: ScreenSketchMarkKind,
        markBounds: CGRect,
        markObstacleRects: [CGRect],
        arrowTailPointAndDirection: (tailPoint: CGPoint, direction: CGVector)?,
        textAnchorPoint: CGPoint?,
        canvasSize: CGSize,
        labelObstacleRects: [CGRect],
        randomNumberGenerator: inout ScreenSketchRandomNumberGenerator
    ) -> ScreenSketchTextLabel {
        let textSize = measureLabelText(labelText)
        let rotationDegrees = Double.random(in: -2.5 ... 2.5, using: &randomNumberGenerator)

        // A note's position was chosen by Claude; only keep it on screen
        if let textAnchorPoint {
            return ScreenSketchTextLabel(
                text: labelText,
                leadingCenterPoint: clampLabelOnScreen(leadingCenterPoint: textAnchorPoint, textSize: textSize, canvasSize: canvasSize),
                fontSize: labelFontSize,
                textSize: textSize,
                rotationDegrees: rotationDegrees
            )
        }

        let candidateLeadingCenterPoints = labelCandidateLeadingCenterPoints(
            kind: kind,
            markBounds: markBounds,
            arrowTailPointAndDirection: arrowTailPointAndDirection,
            textSize: textSize
        )

        // The paper tag is a little bigger than the text
        func paperRect(forLeadingCenterPoint leadingCenterPoint: CGPoint) -> CGRect {
            CGRect(x: leadingCenterPoint.x - 7, y: leadingCenterPoint.y - textSize.height / 2 - 2, width: textSize.width + 14, height: textSize.height + 4)
        }

        func coveredArea(byLeadingCenterPoint leadingCenterPoint: CGPoint) -> CGFloat {
            let candidatePaperRect = paperRect(forLeadingCenterPoint: leadingCenterPoint)
            var totalCoveredArea: CGFloat = 0
            // Covering the mark itself is worse than covering other text
            for markObstacleRect in markObstacleRects {
                let markOverlap = candidatePaperRect.intersection(markObstacleRect)
                if !markOverlap.isNull {
                    totalCoveredArea += markOverlap.width * markOverlap.height * 3
                }
            }
            for obstacleRect in labelObstacleRects {
                let obstacleOverlap = candidatePaperRect.intersection(obstacleRect.insetBy(dx: -2, dy: -2))
                if !obstacleOverlap.isNull {
                    totalCoveredArea += obstacleOverlap.width * obstacleOverlap.height
                }
            }
            return totalCoveredArea
        }

        var bestLeadingCenterPoint = clampLabelOnScreen(leadingCenterPoint: candidateLeadingCenterPoints[0].leadingCenterPoint, textSize: textSize, canvasSize: canvasSize)
        var bestPlacementCost = CGFloat.greatestFiniteMagnitude

        for (candidateIndex, candidate) in candidateLeadingCenterPoints.enumerated() {
            for slideStep in 0..<labelSlideStepCount {
                let slideDistance = CGFloat(slideStep) * labelSlideStepLength
                let slidLeadingCenterPoint = CGPoint(
                    x: candidate.leadingCenterPoint.x + candidate.slideDirection.dx * slideDistance,
                    y: candidate.leadingCenterPoint.y + candidate.slideDirection.dy * slideDistance
                )
                let onScreenLeadingCenterPoint = clampLabelOnScreen(leadingCenterPoint: slidLeadingCenterPoint, textSize: textSize, canvasSize: canvasSize)
                // A spot that had to be pushed back onto the screen no longer sits
                // where it was meant to, so the push counts like covering something
                let pushDistance = hypot(onScreenLeadingCenterPoint.x - slidLeadingCenterPoint.x, onScreenLeadingCenterPoint.y - slidLeadingCenterPoint.y)
                let pushPenalty = pushDistance > 2 ? pushDistance * textSize.height : 0

                let placementCost = (coveredArea(byLeadingCenterPoint: onScreenLeadingCenterPoint) + pushPenalty) * 10
                    + CGFloat(candidateIndex) * 12
                    + slideDistance

                if placementCost < bestPlacementCost {
                    bestPlacementCost = placementCost
                    bestLeadingCenterPoint = onScreenLeadingCenterPoint
                }
            }
            // The most natural spot is clear and right beside the mark
            if bestPlacementCost == 0 { break }
        }

        return ScreenSketchTextLabel(
            text: labelText,
            leadingCenterPoint: bestLeadingCenterPoint,
            fontSize: labelFontSize,
            textSize: textSize,
            rotationDegrees: rotationDegrees
        )
    }

    /// How far a label may slide out from its spot looking for clear space.
    static let labelSlideStepCount = 7
    static let labelSlideStepLength: CGFloat = 14

    /// Spots to try for a label, most natural first, as left-center points,
    /// each with the direction it slides further away from the mark.
    private static func labelCandidateLeadingCenterPoints(
        kind: ScreenSketchMarkKind,
        markBounds: CGRect,
        arrowTailPointAndDirection: (tailPoint: CGPoint, direction: CGVector)?,
        textSize: CGSize
    ) -> [(leadingCenterPoint: CGPoint, slideDirection: CGVector)] {
        let slideRight = CGVector(dx: 1, dy: 0)
        let slideLeft = CGVector(dx: -1, dy: 0)
        let slideUp = CGVector(dx: 0, dy: -1)
        let slideDown = CGVector(dx: 0, dy: 1)

        if let arrowTailPointAndDirection {
            let tailPoint = arrowTailPointAndDirection.tailPoint
            let direction = arrowTailPointAndDirection.direction
            let aboveTail = CGPoint(x: tailPoint.x - textSize.width / 2, y: tailPoint.y - labelGap - textSize.height / 2)
            let belowTail = CGPoint(x: tailPoint.x - textSize.width / 2, y: tailPoint.y + labelGap + textSize.height / 2)
            let leftOfTail = CGPoint(x: tailPoint.x - labelGap - textSize.width, y: tailPoint.y)
            let rightOfTail = CGPoint(x: tailPoint.x + labelGap, y: tailPoint.y)
            // On the far side of the tail from the tip, continuing the arrow's line
            let beyondTail: (leadingCenterPoint: CGPoint, slideDirection: CGVector) = abs(direction.dx) >= abs(direction.dy)
                ? (direction.dx >= 0 ? (leftOfTail, slideLeft) : (rightOfTail, slideRight))
                : (direction.dy >= 0 ? (aboveTail, slideUp) : (belowTail, slideDown))

            if abs(direction.dx) >= abs(direction.dy) * 2 {
                // Flat arrows usually run along a row (a slider, a line of text),
                // so a label on that line would cover it: go above or below
                return [(aboveTail, slideUp), (belowTail, slideDown), beyondTail]
            }
            if abs(direction.dy) >= abs(direction.dx) * 2 {
                let besideTail: (leadingCenterPoint: CGPoint, slideDirection: CGVector) = direction.dx >= 0 ? (leftOfTail, slideLeft) : (rightOfTail, slideRight)
                let otherSideOfTail: (leadingCenterPoint: CGPoint, slideDirection: CGVector) = direction.dx >= 0 ? (rightOfTail, slideRight) : (leftOfTail, slideLeft)
                return [beyondTail, besideTail, otherSideOfTail]
            }
            return [beyondTail, (aboveTail, slideUp), (belowTail, slideDown)]
        }

        let rightOfMark = CGPoint(x: markBounds.maxX + labelGap, y: markBounds.midY)
        let leftOfMark = CGPoint(x: markBounds.minX - labelGap - textSize.width, y: markBounds.midY)
        let aboveMark = CGPoint(x: markBounds.midX - textSize.width / 2, y: markBounds.minY - labelGap - textSize.height / 2)
        let belowMark = CGPoint(x: markBounds.midX - textSize.width / 2, y: markBounds.maxY + labelGap + textSize.height / 2)

        if kind == .underline || kind == .highlight {
            let belowMarkStart = CGPoint(x: markBounds.minX, y: markBounds.maxY + labelGap + textSize.height / 2)
            return [(belowMarkStart, slideDown), (aboveMark, slideUp), (rightOfMark, slideRight), (leftOfMark, slideLeft)]
        }
        return [(rightOfMark, slideRight), (leftOfMark, slideLeft), (aboveMark, slideUp), (belowMark, slideDown)]
    }

    private static func clampLabelOnScreen(leadingCenterPoint: CGPoint, textSize: CGSize, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(leadingCenterPoint.x, screenEdgeInset), max(canvasSize.width - screenEdgeInset - textSize.width, screenEdgeInset)),
            y: min(max(leadingCenterPoint.y, screenEdgeInset + textSize.height / 2), max(canvasSize.height - screenEdgeInset - textSize.height / 2, screenEdgeInset))
        )
    }

    static func measureLabelText(_ labelText: String) -> CGSize {
        let labelFont = NSFont(name: labelFontName, size: labelFontSize) ?? NSFont.systemFont(ofSize: labelFontSize, weight: .semibold)
        let measuredSize = (labelText as NSString).size(withAttributes: [.font: labelFont])
        return CGSize(width: ceil(measuredSize.width), height: ceil(measuredSize.height))
    }

    // MARK: Helpers

    /// Points along a straight line from `startPoint` to `endPoint`, bowed a
    /// little to one side so it doesn't look ruler-straight.
    private static func sampleSlightlyBowedLine(
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        maximumBow: CGFloat,
        randomNumberGenerator: inout ScreenSketchRandomNumberGenerator
    ) -> [CGPoint] {
        let lineLength = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        let sampleCount = max(4, Int(lineLength / 3))
        let bowAmount = CGFloat(Double.random(in: -1 ... 1, using: &randomNumberGenerator)) * maximumBow
        let perpendicular = lineLength > 0
            ? CGVector(dx: -(endPoint.y - startPoint.y) / lineLength, dy: (endPoint.x - startPoint.x) / lineLength)
            : CGVector(dx: 0, dy: 0)

        return (0...sampleCount).map { sampleIndex in
            let fractionAlongLine = CGFloat(sampleIndex) / CGFloat(sampleCount)
            // sin(pi * t) is 0 at both ends and 1 in the middle: a gentle arc
            let bowAtThisPoint = bowAmount * CGFloat(sin(Double.pi * Double(fractionAlongLine)))
            return CGPoint(
                x: startPoint.x + (endPoint.x - startPoint.x) * fractionAlongLine + perpendicular.dx * bowAtThisPoint,
                y: startPoint.y + (endPoint.y - startPoint.y) * fractionAlongLine + perpendicular.dy * bowAtThisPoint
            )
        }
    }

    /// Nudges each point sideways by a slow, smooth wave (two sine waves with
    /// random wavelengths and phases) so a stroke wavers like a real hand
    /// instead of looking noisy. `taperAtEnds` keeps the ends exactly in place,
    /// which matters for arrow tips.
    private static func applyHandWobble(
        to strokePoints: [CGPoint],
        amplitude: CGFloat,
        taperAtEnds: Bool,
        randomNumberGenerator: inout ScreenSketchRandomNumberGenerator
    ) -> [CGPoint] {
        guard strokePoints.count > 2 else { return strokePoints }

        let firstWavelength = Double.random(in: 70 ... 130, using: &randomNumberGenerator)
        let secondWavelength = Double.random(in: 25 ... 45, using: &randomNumberGenerator)
        let firstPhase = Double.random(in: 0 ... (2 * Double.pi), using: &randomNumberGenerator)
        let secondPhase = Double.random(in: 0 ... (2 * Double.pi), using: &randomNumberGenerator)

        var lengthsAlongStroke: [Double] = [0]
        for pointIndex in 1..<strokePoints.count {
            lengthsAlongStroke.append(lengthsAlongStroke[pointIndex - 1] + Double(hypot(
                strokePoints[pointIndex].x - strokePoints[pointIndex - 1].x,
                strokePoints[pointIndex].y - strokePoints[pointIndex - 1].y
            )))
        }
        let totalStrokeLength = max(lengthsAlongStroke[lengthsAlongStroke.count - 1], 1)

        return strokePoints.enumerated().map { pointIndex, point in
            let previousPoint = strokePoints[max(pointIndex - 1, 0)]
            let nextPoint = strokePoints[min(pointIndex + 1, strokePoints.count - 1)]
            let tangentLength = hypot(nextPoint.x - previousPoint.x, nextPoint.y - previousPoint.y)
            guard tangentLength > 0 else { return point }
            let normal = CGVector(dx: -(nextPoint.y - previousPoint.y) / tangentLength, dy: (nextPoint.x - previousPoint.x) / tangentLength)

            let lengthAlongStroke = lengthsAlongStroke[pointIndex]
            var wobbleOffset = Double(amplitude) * (
                0.7 * sin(2 * Double.pi * lengthAlongStroke / firstWavelength + firstPhase)
                + 0.3 * sin(2 * Double.pi * lengthAlongStroke / secondWavelength + secondPhase)
            )
            if taperAtEnds {
                wobbleOffset *= sin(Double.pi * lengthAlongStroke / totalStrokeLength)
            }

            return CGPoint(x: point.x + normal.dx * CGFloat(wobbleOffset), y: point.y + normal.dy * CGFloat(wobbleOffset))
        }
    }

    private static func normalizedRect(_ firstCorner: CGPoint, _ secondCorner: CGPoint) -> CGRect {
        CGRect(
            x: min(firstCorner.x, secondCorner.x),
            y: min(firstCorner.y, secondCorner.y),
            width: abs(secondCorner.x - firstCorner.x),
            height: abs(secondCorner.y - firstCorner.y)
        )
    }

    private static func expandedToMinimumSize(_ rect: CGRect, minimumSide: CGFloat) -> CGRect {
        let expandedWidth = max(rect.width, minimumSide)
        let expandedHeight = max(rect.height, minimumSide)
        return CGRect(x: rect.midX - expandedWidth / 2, y: rect.midY - expandedHeight / 2, width: expandedWidth, height: expandedHeight)
    }

    private static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let firstPoint = points.first else { return .zero }
        var minimumX = firstPoint.x, maximumX = firstPoint.x, minimumY = firstPoint.y, maximumY = firstPoint.y
        for point in points {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }

    private static func clampPointToCanvas(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), canvasSize.width),
            y: min(max(point.y, 0), canvasSize.height)
        )
    }
}

// MARK: - Background Brightness

enum ScreenshotBrightnessSampler {
    /// Average perceived brightness (0 = black, 1 = white) of `screenshotRect`
    /// (in screenshot pixels) within `screenshotImage`. Returns nil if the rect
    /// is empty or falls outside the image.
    static func averageBrightness(of screenshotImage: CGImage, in screenshotRect: CGRect) -> Double? {
        let imageBounds = CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height)
        let sampledRect = screenshotRect.standardized.insetBy(dx: -4, dy: -4).intersection(imageBounds).integral
        guard !sampledRect.isNull, sampledRect.width >= 1, sampledRect.height >= 1,
              let croppedImage = screenshotImage.cropping(to: sampledRect) else { return nil }

        // Scale the region into a tiny grayscale bitmap and average it; exact
        // per-pixel accuracy doesn't matter, only "dark or light".
        let sampleWidth = 16
        let sampleHeight = 8
        var grayscalePixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        let didDraw = grayscalePixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: pixelBuffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            grayscaleContext.interpolationQuality = .low
            grayscaleContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard didDraw else { return nil }

        let brightnessSum = grayscalePixels.reduce(0) { $0 + Int($1) }
        return Double(brightnessSum) / Double(grayscalePixels.count) / 255.0
    }

    /// How much of the same region changed between two screenshots of the
    /// same screen: the share (0...1) of cells in a small grayscale grid whose
    /// brightness moved noticeably. An average would be diluted by plain
    /// background; counting changed cells isn't. Measured on real screenshots:
    /// unchanged or recompressed ≤ 0.003, scrolled by even 8px ≥ 0.05.
    /// Cells overlapping `ignoredScreenshotRects` (like where the mouse
    /// pointer was in either screenshot) aren't counted. Returns nil if the
    /// rect falls outside either image.
    static func regionDifference(
        between firstScreenshotImage: CGImage,
        and secondScreenshotImage: CGImage,
        in screenshotRect: CGRect,
        ignoring ignoredScreenshotRects: [CGRect] = []
    ) -> Double? {
        let imageBounds = CGRect(x: 0, y: 0, width: firstScreenshotImage.width, height: firstScreenshotImage.height)
        let sampledRect = screenshotRect.standardized.intersection(imageBounds).integral
        guard !sampledRect.isNull,
              let firstGrid = grayscaleGrid(of: firstScreenshotImage, in: sampledRect),
              let secondGrid = grayscaleGrid(of: secondScreenshotImage, in: sampledRect),
              firstGrid.count == secondGrid.count, !firstGrid.isEmpty else { return nil }

        // About 30 of 255 brightness levels: well above JPEG noise
        let noticeableCellChange = 30
        let cellWidth = sampledRect.width / CGFloat(grayscaleGridWidth)
        let cellHeight = sampledRect.height / CGFloat(grayscaleGridHeight)
        var consideredCellCount = 0
        var changedCellCount = 0

        for cellIndex in firstGrid.indices {
            // The grid is drawn bottom-up (CGContext origin), screenshot rects are top-down
            let cellColumn = cellIndex % grayscaleGridWidth
            let cellRowFromBottom = cellIndex / grayscaleGridWidth
            let cellRect = CGRect(
                x: sampledRect.minX + CGFloat(cellColumn) * cellWidth,
                y: sampledRect.maxY - CGFloat(cellRowFromBottom + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            if ignoredScreenshotRects.contains(where: { $0.intersects(cellRect) }) { continue }
            consideredCellCount += 1
            if abs(Int(firstGrid[cellIndex]) - Int(secondGrid[cellIndex])) > noticeableCellChange {
                changedCellCount += 1
            }
        }
        guard consideredCellCount > 0 else { return 0 }
        return Double(changedCellCount) / Double(consideredCellCount)
    }

    private static let grayscaleGridWidth = 48
    private static let grayscaleGridHeight = 24

    private static func grayscaleGrid(of screenshotImage: CGImage, in screenshotRect: CGRect) -> [UInt8]? {
        let imageBounds = CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height)
        let sampledRect = screenshotRect.standardized.intersection(imageBounds).integral
        guard !sampledRect.isNull, sampledRect.width >= 2, sampledRect.height >= 2,
              let croppedImage = screenshotImage.cropping(to: sampledRect) else { return nil }

        let gridWidth = grayscaleGridWidth
        let gridHeight = grayscaleGridHeight
        var grayscalePixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let didDraw = grayscalePixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: pixelBuffer.baseAddress,
                width: gridWidth,
                height: gridHeight,
                bitsPerComponent: 8,
                bytesPerRow: gridWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            grayscaleContext.interpolationQuality = .medium
            grayscaleContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
            return true
        }
        return didDraw ? grayscalePixels : nil
    }

    /// Decodes screenshot JPEG/PNG data into a CGImage for sampling.
    static func decodeScreenshotImage(from screenshotImageData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(screenshotImageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}

// MARK: - The User's Own Ink

/// While the user holds the talk hotkey they can draw on the screen (circle a
/// button, underline a line) to show what they mean. The overlay doesn't
/// appear in screenshots, so the ink is drawn into the screenshot here before
/// it goes to Claude.
enum UserInkCompositor {
    /// Marker red, distinct from Clicky's blue so Claude can tell whose marks are whose.
    static let userInkRedGreenBlue: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.96, 0.18, 0.18)

    /// `screenshotImageData` with `inkStrokes` (each a list of points in the
    /// screenshot's pixels, top-left origin) drawn on top, as JPEG. Nil if the
    /// image can't be decoded.
    static func screenshotJPEGData(_ screenshotImageData: Data, withInkStrokes inkStrokes: [[CGPoint]]) -> Data? {
        guard let screenshotImage = ScreenshotBrightnessSampler.decodeScreenshotImage(from: screenshotImageData),
              let drawingContext = CGContext(
                data: nil,
                width: screenshotImage.width,
                height: screenshotImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let imageHeight = CGFloat(screenshotImage.height)
        drawingContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height))
        drawingContext.setStrokeColor(red: userInkRedGreenBlue.red, green: userInkRedGreenBlue.green, blue: userInkRedGreenBlue.blue, alpha: 0.95)
        drawingContext.setLineWidth(max(4, CGFloat(screenshotImage.width) / 280))
        drawingContext.setLineCap(.round)
        drawingContext.setLineJoin(.round)

        for inkStroke in inkStrokes where inkStroke.count > 1 {
            // CGContext's origin is bottom-left; the stroke's is top-left
            drawingContext.addLines(between: inkStroke.map { CGPoint(x: $0.x, y: imageHeight - $0.y) })
            drawingContext.strokePath()
        }

        guard let inkedImage = drawingContext.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: inkedImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
