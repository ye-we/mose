// Standalone tests for Clicky's screen sketching: the POINT/DRAW tag parser,
// the hand-drawn geometry and pen timeline, label placement, and snapping
// marks onto on-screen text. Run with scripts/run-sketch-tests.sh; they compile
// the app's own source files, so no Xcode, signing or app launch is needed.
import AppKit
import Foundation

var failureCount = 0
var checkCount = 0
func check(_ condition: Bool, _ description: String, file: String = #file, line: Int = #line) {
    checkCount += 1
    if !condition { failureCount += 1; print("❌ FAIL [line \(line)]: \(description)") }
}

// MARK: Parser — POINT
do {
    let basic = ClaudeVisualTagParser.parsePointTagBody("120,340")
    check(basic?.coordinate == CGPoint(x: 120, y: 340) && basic?.elementLabel == nil && basic?.screenNumber == nil, "POINT basic")
    let labelled = ClaudeVisualTagParser.parsePointTagBody("120, 340:save button")
    check(labelled?.elementLabel == "save button", "POINT label with space after comma")
    let screened = ClaudeVisualTagParser.parsePointTagBody("400,300:terminal:screen2")
    check(screened?.elementLabel == "terminal" && screened?.screenNumber == 2, "POINT label + screen")
    let screenOnly = ClaudeVisualTagParser.parsePointTagBody("400,300:screen2")
    check(screenOnly?.elementLabel == nil && screenOnly?.screenNumber == 2, "POINT screen without label is not taken as a label")
    check(ClaudeVisualTagParser.parsePointTagBody("none") == nil, "POINT none")
    check(ClaudeVisualTagParser.parsePointTagBody("abc") == nil, "POINT malformed")
    check(ClaudeVisualTagParser.parsePointTagBody("12") == nil, "POINT one number")
}

// MARK: Parser — DRAW
do {
    let circle = ClaudeVisualTagParser.parseDrawTagBody(#"circle 120,80,260,140 label="export""#)
    check(circle?.kind == .circle && circle?.screenshotPoints == [CGPoint(x: 120, y: 80), CGPoint(x: 260, y: 140)] && circle?.label == "export" && circle?.inkColor == .blue, "DRAW circle")
    let arrowRed = ClaudeVisualTagParser.parseDrawTagBody(#"arrow 10,10,200,150 label="click here" color=red screen=2"#)
    check(arrowRed?.kind == .arrow && arrowRed?.inkColor == .red && arrowRed?.screenNumber == 2 && arrowRed?.label == "click here", "DRAW arrow with color and screen")
    let digitsInLabel = ClaudeVisualTagParser.parseDrawTagBody(#"box 1,2,3,4 label="step 2 of 3""#)
    check(digitsInLabel?.screenshotPoints == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)] && digitsInLabel?.label == "step 2 of 3", "digits inside a label aren't coordinates")
    let curlyQuotes = ClaudeVisualTagParser.parseDrawTagBody("underline 5,50,90,50 label=“this one”")
    check(curlyQuotes?.label == "this one", "curly quotes")
    let singleQuotes = ClaudeVisualTagParser.parseDrawTagBody("text 30,40 label='hi there'")
    check(singleQuotes?.kind == .text && singleQuotes?.label == "hi there", "single quotes")
    let textKey = ClaudeVisualTagParser.parseDrawTagBody(#"text 30,40 text="drag me""#)
    check(textKey?.label == "drag me", "text= works as label")
    check(ClaudeVisualTagParser.parseDrawTagBody("text 30,40") == nil, "text without words is dropped")
    let screenSuffix = ClaudeVisualTagParser.parseDrawTagBody("check 30,40:screen3")
    check(screenSuffix?.kind == .check && screenSuffix?.screenNumber == 3 && screenSuffix?.screenshotPoints == [CGPoint(x: 30, y: 40)] && screenSuffix?.inkColor == .green, "check with :screen3 suffix, default green")
    let crossDefault = ClaudeVisualTagParser.parseDrawTagBody("cross 0,0,40,40")
    check(crossDefault?.inkColor == .red, "cross defaults to red")
    let highlightDefault = ClaudeVisualTagParser.parseDrawTagBody("highlight 0,0,40,10")
    check(highlightDefault?.inkColor == .yellow, "highlight defaults to yellow")
    let guidedTarget = ClaudeVisualTagParser.parseDrawTagBody(#"target 62,4,92,22 label="file""#)
    check(guidedTarget?.kind == .target && guidedTarget?.inkColor == .orange && guidedTarget?.label == "file" && guidedTarget?.screenshotPoints.count == 2, "DRAW target parses, orange by default")
    check(ClaudeVisualTagParser.parseDrawTagBody("target 62,4") == nil, "target needs a box")
    let unknownColor = ClaudeVisualTagParser.parseDrawTagBody("circle 0,0,40,40 color=chartreuse")
    check(unknownColor?.inkColor == .blue, "unknown color falls back to default")
    let pathOdd = ClaudeVisualTagParser.parseDrawTagBody("path 0,0 50,20 100,0 150")
    check(pathOdd?.screenshotPoints.count == 3, "path with an odd count drops the dangling number")
    check(ClaudeVisualTagParser.parseDrawTagBody("path 0,0") == nil, "path needs two points")
    check(ClaudeVisualTagParser.parseDrawTagBody("circle 1,2,3") == nil, "circle needs 4 numbers")
    check(ClaudeVisualTagParser.parseDrawTagBody("sparkle 1,2,3,4") == nil, "unknown kind")
    check(ClaudeVisualTagParser.parseDrawTagBody("Circle 1,2,3,4")?.kind == .circle, "kind is case-insensitive")
    let decimals = ClaudeVisualTagParser.parseDrawTagBody("arrow 10.5,20.25,30,40")
    check(decimals?.screenshotPoints.first == CGPoint(x: 10.5, y: 20.25), "decimal coordinates")
    let longLabel = ClaudeVisualTagParser.parseDrawTagBody(#"circle 0,0,10,10 label="this is a really long label that should get trimmed down""#)
    check((longLabel?.label?.count ?? 0) == ClaudeVisualTagParser.maximumLabelCharacterCount && longLabel?.label?.hasSuffix("…") == true, "long labels are truncated")
}

// MARK: Parser — full responses
do {
    let response = #"first click your project down here. [DRAW:circle 200,620,240,660 label="project"] then hit share up top. [POINT:1180,42:share button] that's it! [POINT:none]"#
    let result = ClaudeVisualTagParser.parseVisualBeats(from: response)
    check(result.spokenText == "first click your project down here. then hit share up top. that's it!", "spoken text cleaned: \(result.spokenText)")
    check(result.beats.count == 2, "two beats (none ignored)")
    if result.beats.count == 2 {
        check(result.beats[0].spokenTextOffsetWhereBeatIsDescribed == 0, "first beat at 0")
        let secondOffset = result.beats[1].spokenTextOffsetWhereBeatIsDescribed
        let fromSecond = String(result.spokenText.dropFirst(secondOffset)).trimmingCharacters(in: .whitespaces)
        check(fromSecond.hasPrefix("then hit share"), "second beat offset lands on its sentence: '\(fromSecond.prefix(20))'")
        if case .sketch(let mark) = result.beats[0].content { check(mark.kind == .circle, "first beat is the circle") } else { check(false, "first beat is a sketch") }
        if case .point(let coordinate, let label) = result.beats[1].content { check(coordinate == CGPoint(x: 1180, y: 42) && label == "share button", "second beat is the point") } else { check(false, "second beat is a point") }
    }

    let spaceBeforePunctuation = ClaudeVisualTagParser.parseVisualBeats(from: "see this [DRAW:check 10,10]. nice")
    check(spaceBeforePunctuation.spokenText == "see this. nice", "no space left before punctuation: '\(spaceBeforePunctuation.spokenText)'")

    let spacedTag = ClaudeVisualTagParser.parseVisualBeats(from: "here [DRAW: arrow 1,2,300,400] and [point:5,6]")
    check(spacedTag.beats.count == 2, "tolerates 'DRAW: ' and lowercase point")

    let malformed = ClaudeVisualTagParser.parseVisualBeats(from: "oops [DRAW:circle 1,2] still talking")
    check(malformed.beats.isEmpty && malformed.spokenText == "oops still talking", "malformed tag removed from speech")

    let many = (0..<20).map { "step \($0) [DRAW:check \($0 * 10),10]" }.joined(separator: " ")
    let manyResult = ClaudeVisualTagParser.parseVisualBeats(from: many)
    check(manyResult.beats.count == ClaudeVisualTagParser.maximumBeatCount, "beat count is capped")
    check(!manyResult.spokenText.contains("["), "all tags stripped even past the cap")

    let noTags = ClaudeVisualTagParser.parseVisualBeats(from: "just talking here.")
    check(noTags.beats.isEmpty && noTags.spokenText == "just talking here.", "no tags")
}

// MARK: Geometry
let canvasSize = CGSize(width: 1512, height: 982)
func allPointsFinite(_ drawing: ScreenSketchDrawing) -> Bool {
    drawing.strokes.allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
}
func allPointsNearCanvas(_ drawing: ScreenSketchDrawing, slack: CGFloat = 60) -> Bool {
    let bounds = CGRect(origin: .zero, size: canvasSize).insetBy(dx: -slack, dy: -slack)
    return drawing.strokes.allSatisfy { $0.points.allSatisfy { bounds.contains($0) } }
}
// Winding number: counts how many times the ring wraps around the point, so
// the overlapping end of a hand-drawn ring (winding 2 there) still counts as inside.
func pointInPolygon(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
    var windingNumber = 0
    for currentIndex in 0..<polygon.count {
        let a = polygon[currentIndex], b = polygon[(currentIndex + 1) % polygon.count]
        let crossProduct = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
        if a.y <= point.y {
            if b.y > point.y && crossProduct > 0 { windingNumber += 1 }
        } else if b.y <= point.y && crossProduct < 0 {
            windingNumber -= 1
        }
    }
    return windingNumber != 0
}

let sampleRequests: [(ScreenSketchMarkKind, [CGPoint], String?)] = [
    (.target, [CGPoint(x: 60, y: 4), CGPoint(x: 92, y: 22)], "1. file"),
    (.circle, [CGPoint(x: 600, y: 400), CGPoint(x: 800, y: 440)], "export"),
    (.circle, [CGPoint(x: 1490, y: 10), CGPoint(x: 1510, y: 30)], "corner thing"),
    (.box, [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300)], "settings panel"),
    (.arrow, [CGPoint(x: 300, y: 600), CGPoint(x: 700, y: 420)], "click this"),
    (.arrow, [CGPoint(x: 700, y: 100), CGPoint(x: 700, y: 400)], "down here"),
    (.arrow, [CGPoint(x: 50, y: 50), CGPoint(x: 52, y: 51)], nil),
    (.underline, [CGPoint(x: 200, y: 500), CGPoint(x: 420, y: 500)], "this setting"),
    (.highlight, [CGPoint(x: 200, y: 520), CGPoint(x: 420, y: 540)], nil),
    (.highlight, [CGPoint(x: 200, y: 520), CGPoint(x: 420, y: 640)], "whole block"),
    (.cross, [CGPoint(x: 900, y: 300), CGPoint(x: 960, y: 330)], "not this"),
    (.cross, [CGPoint(x: 900, y: 300), CGPoint(x: 902, y: 301)], nil),
    (.check, [CGPoint(x: 1000, y: 700)], "good"),
    (.path, [CGPoint(x: 100, y: 800), CGPoint(x: 300, y: 700), CGPoint(x: 500, y: 820), CGPoint(x: 700, y: 760)], "drag like this"),
    (.text, [CGPoint(x: 1450, y: 960)], "note near the corner"),
]

for (requestIndex, (kind, points, label)) in sampleRequests.enumerated() {
    let description = "\(kind.rawValue)#\(requestIndex)"
    let drawing = ScreenSketchGeometry.makeDrawing(kind: kind, localPoints: points, label: label, inkColor: kind.defaultInkColor, canvasSize: canvasSize, seed: UInt64(requestIndex + 1))
    check(allPointsFinite(drawing), "\(description): finite points")
    check(allPointsNearCanvas(drawing), "\(description): points stay near the canvas")
    check(kind == .text ? drawing.strokes.isEmpty : !drawing.strokes.isEmpty, "\(description): stroke count")
    check(drawing.drawingDurationSeconds >= 0.3 && drawing.drawingDurationSeconds <= 2.2, "\(description): duration \(drawing.drawingDurationSeconds)")

    // Progress behaves: monotonic ink, full ink at 1, nothing at 0
    for strokeIndex in drawing.strokes.indices {
        var previousInk: CGFloat = -1
        for step in 0...20 {
            let ink = drawing.inkedLength(ofStrokeAt: strokeIndex, atProgress: Double(step) / 20)
            check(ink >= previousInk - 0.001, "\(description): stroke \(strokeIndex) ink is monotonic")
            previousInk = ink
        }
        check(abs(drawing.inkedLength(ofStrokeAt: strokeIndex, atProgress: 1) - drawing.strokes[strokeIndex].totalLength) < 0.01, "\(description): stroke \(strokeIndex) fully drawn at 1")
        check(drawing.inkedLength(ofStrokeAt: strokeIndex, atProgress: 0) == 0 || strokeIndex > 0, "\(description): nothing drawn at 0")
    }
    if let textLabel = drawing.textLabel {
        check(drawing.revealedLabelCharacterCount(atProgress: 1) == textLabel.text.count, "\(description): label fully written at 1")
        check(drawing.revealedLabelCharacterCount(atProgress: 0) == 0 || drawing.strokes.isEmpty, "\(description): label not written at 0")
        let labelRect = CGRect(x: textLabel.leadingCenterPoint.x, y: textLabel.leadingCenterPoint.y - textLabel.textSize.height / 2, width: textLabel.textSize.width, height: textLabel.textSize.height)
        check(CGRect(origin: .zero, size: canvasSize).contains(labelRect), "\(description): label on screen \(labelRect)")
    }
    // Pen starts where the first stroke starts and moves continuously
    if let firstStroke = drawing.strokes.first {
        check(hypot(drawing.penStartPoint.x - firstStroke.points[0].x, drawing.penStartPoint.y - firstStroke.points[0].y) < 0.5, "\(description): pen starts at first stroke")
    }
    var previousPenPoint = drawing.penPoint(atProgress: 0)
    var largestPenJump: CGFloat = 0
    for step in 1...400 {
        let penPoint = drawing.penPoint(atProgress: Double(step) / 400)
        largestPenJump = max(largestPenJump, hypot(penPoint.x - previousPenPoint.x, penPoint.y - previousPenPoint.y))
        previousPenPoint = penPoint
    }
    check(largestPenJump < 40, "\(description): pen moves smoothly (largest jump \(largestPenJump))")

    // Deterministic per seed
    let sameSeedDrawing = ScreenSketchGeometry.makeDrawing(kind: kind, localPoints: points, label: label, inkColor: kind.defaultInkColor, canvasSize: canvasSize, seed: UInt64(requestIndex + 1))
    check(sameSeedDrawing.strokes.map(\.points) == drawing.strokes.map(\.points), "\(description): same seed, same drawing")
    if !drawing.strokes.isEmpty {
        let otherSeedDrawing = ScreenSketchGeometry.makeDrawing(kind: kind, localPoints: points, label: label, inkColor: kind.defaultInkColor, canvasSize: canvasSize, seed: UInt64(requestIndex + 1000))
        check(otherSeedDrawing.strokes.map(\.points) != drawing.strokes.map(\.points), "\(description): different seed, different wobble")
    }
}

// Rings fully enclose the element they circle, across shapes and seeds
for (width, height) in [(200.0, 40.0), (30.0, 30.0), (600.0, 30.0), (24.0, 120.0), (300.0, 200.0)] {
    for seed in 1...25 {
        let rect = CGRect(x: 500, y: 400, width: width, height: height)
        let drawing = ScreenSketchGeometry.makeDrawing(kind: .circle, localPoints: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], label: nil, inkColor: .blue, canvasSize: canvasSize, seed: UInt64(seed))
        let ringPoints = drawing.strokes[0].points
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        check(corners.allSatisfy { pointInPolygon($0, ringPoints) }, "ring \(width)x\(height) seed \(seed) encloses all corners")
    }
}

// Arrow tips land just short of the target
for seed in 1...25 {
    let target = CGPoint(x: 800, y: 300)
    let drawing = ScreenSketchGeometry.makeDrawing(kind: .arrow, localPoints: [CGPoint(x: 500, y: 500), target], label: nil, inkColor: .blue, canvasSize: canvasSize, seed: UInt64(seed))
    let shaftEnd = drawing.strokes[0].points.last!
    let distanceToTarget = hypot(shaftEnd.x - target.x, shaftEnd.y - target.y)
    check(distanceToTarget >= 3 && distanceToTarget <= 9, "arrow seed \(seed): tip \(distanceToTarget)pt from target")
}

// Labels avoid the right edge by flipping left
do {
    let drawing = ScreenSketchGeometry.makeDrawing(kind: .circle, localPoints: [CGPoint(x: 1420, y: 400), CGPoint(x: 1490, y: 430)], label: "right edge", inkColor: .blue, canvasSize: canvasSize, seed: 7)
    let labelMaxX = drawing.textLabel!.leadingCenterPoint.x + drawing.textLabel!.textSize.width
    check(labelMaxX < 1420, "label flips to the left of a mark at the right edge (maxX \(labelMaxX))")
}


// MARK: Label placement avoids on-screen text
do {
    // A ring at the right edge with text to its left: the label should go above or below, not over the text
    let ringRect = CGRect(x: 1400, y: 500, width: 80, height: 30)
    let textToTheLeft = CGRect(x: 1150, y: 495, width: 230, height: 40)
    let drawing = ScreenSketchGeometry.makeDrawing(kind: .circle, localPoints: [ringRect.origin, CGPoint(x: ringRect.maxX, y: ringRect.maxY)], label: "open", inkColor: .blue, canvasSize: canvasSize, seed: 11, labelObstacleRects: [textToTheLeft])
    let label = drawing.textLabel!
    let labelRect = CGRect(x: label.leadingCenterPoint.x, y: label.leadingCenterPoint.y - label.textSize.height / 2, width: label.textSize.width, height: label.textSize.height)
    check(!labelRect.intersects(textToTheLeft), "label avoids the text beside the ring (label \(labelRect))")
    check(CGRect(origin: .zero, size: canvasSize).contains(labelRect), "label stays on screen")
}
do {
    // Flat arrow: label sits above the tail, not along the row it points down
    let drawing = ScreenSketchGeometry.makeDrawing(kind: .arrow, localPoints: [CGPoint(x: 600, y: 400), CGPoint(x: 800, y: 400)], label: "drag right", inkColor: .blue, canvasSize: canvasSize, seed: 5)
    let label = drawing.textLabel!
    check(label.leadingCenterPoint.y + label.textSize.height / 2 < 400, "flat arrow label is above the row (center y \(label.leadingCenterPoint.y))")
}
do {
    // Labels never sit on top of their own mark
    for seed in 1...20 {
        let drawing = ScreenSketchGeometry.makeDrawing(kind: .box, localPoints: [CGPoint(x: 200, y: 200), CGPoint(x: 600, y: 400)], label: "settings panel", inkColor: .blue, canvasSize: canvasSize, seed: UInt64(seed))
        let label = drawing.textLabel!
        let labelRect = CGRect(x: label.leadingCenterPoint.x, y: label.leadingCenterPoint.y - label.textSize.height / 2, width: label.textSize.width, height: label.textSize.height)
        check(!labelRect.intersects(CGRect(x: 200, y: 200, width: 400, height: 200)), "box label seed \(seed) is outside the box")
    }
}

// MARK: Target snapping (synthetic text)
do {
    func line(_ text: String, _ rect: CGRect) -> RecognizedScreenTextLine {
        // Split the rect evenly between words, like Vision would roughly report
        let words = text.split(separator: " ").map(String.init)
        let wordWidth = rect.width / CGFloat(max(words.count, 1))
        return RecognizedScreenTextLine(text: text, screenshotRect: rect, words: words.enumerated().map { index, word in
            RecognizedScreenWord(text: word, screenshotRect: CGRect(x: rect.minX + wordWidth * CGFloat(index), y: rect.minY, width: wordWidth, height: rect.height))
        })
    }
    let lines = [
        line("SYNC", CGRect(x: 200, y: 430, width: 30, height: 10)),
        line("SYNC", CGRect(x: 1016, y: 428, width: 30, height: 10)),
        line("Save Changes", CGRect(x: 970, y: 652, width: 90, height: 16)),
        line("Theme", CGRect(x: 380, y: 180, width: 50, height: 16)),
        line("Light", CGRect(x: 1010, y: 182, width: 40, height: 16)),
        line("Click Register for the exam today", CGRect(x: 100, y: 600, width: 300, height: 14)),
    ]
    let missedSync = ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "sync button", proposedRect: CGRect(x: 1010, y: 460, width: 35, height: 12), recognizedTextLines: lines)
    check(missedSync.map { abs($0.midX - 1031) < 2 && abs($0.midY - 433) < 2 } == true, "a ring that missed SYNC snaps to the nearer SYNC: \(String(describing: missedSync))")
    let onTarget = ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "save changes", proposedRect: CGRect(x: 960, y: 645, width: 110, height: 30), recognizedTextLines: lines)
    check(onTarget == nil, "a ring already on its text is left alone")
    let offTarget = ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "save changes", proposedRect: CGRect(x: 960, y: 690, width: 110, height: 30), recognizedTextLines: lines)
    check(offTarget.map { abs($0.midY - 660) < 2 } == true, "a ring below Save Changes snaps up onto it")
    let partialLabel = ScreenSketchTargetSnapper.matchingTextRect(forLabel: "theme: light", near: CGRect(x: 990, y: 210, width: 80, height: 24), in: lines)
    check(partialLabel.map { abs($0.midX - 1030) < 2 } == true, "'theme: light' matches the nearby 'Light', not the far 'Theme'")
    check(ScreenSketchTargetSnapper.screenWordMatches("unew", labelWord: "new"), "an icon read as a stray letter still matches")
    check(ScreenSketchTargetSnapper.screenWordMatches("autornations", labelWord: "automations") == false, "two misread letters don't match")
    check(ScreenSketchTargetSnapper.screenWordMatches("automatlons", labelWord: "automations"), "one misread letter matches")
    check(ScreenSketchTargetSnapper.screenWordMatches("knew", labelWord: "kn") == false, "two-letter labels must match exactly")
    check(ScreenSketchTargetSnapper.screenWordMatches("cancel", labelWord: "save") == false, "different words don't match")
    let insideSentence = ScreenSketchTargetSnapper.matchingTextRect(forLabel: "register", near: CGRect(x: 100, y: 620, width: 60, height: 14), in: lines)
    check(insideSentence.map { $0.width < 100 } == true, "a word inside a sentence matches just that word, not the line")
    check(ScreenSketchTargetSnapper.matchingTextRect(forLabel: "low eq", near: CGRect(x: 570, y: 400, width: 20, height: 20), in: lines) == nil, "no text, no match")
    check(ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "sync", proposedRect: CGRect(x: 600, y: 100, width: 30, height: 12), recognizedTextLines: lines) == nil, "far away text is not snapped to")
    check(ScreenSketchTargetSnapper.correctedTargetRect(forLabel: nil, proposedRect: CGRect(x: 1010, y: 460, width: 35, height: 12), recognizedTextLines: lines) == nil, "no label, no snap")
    // The live bug: a big box around a card, labelled like the heading just above it
    let headingLines = [line("WHERE NEXT", CGRect(x: 176, y: 351, width: 94, height: 21))]
    check(ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "where next", proposedRect: CGRect(x: 201, y: 397, width: 611, height: 274), recognizedTextLines: headingLines) == nil, "a region-sized box is never shrunk onto a nearby heading")
    // ...but a ring the size of that heading which missed it still snaps
    check(ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "where next", proposedRect: CGRect(x: 180, y: 385, width: 100, height: 22), recognizedTextLines: headingLines) != nil, "a heading-sized ring that missed still snaps")
}

// MARK: Text recognition on a real screenshot (from the app's own assets)
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let codexScreenshotPath = repositoryRoot.appendingPathComponent("scripts/sketch-tests/fixtures/codex-app-screenshot.jpg").path
if let codexScreenshotData = FileManager.default.contents(atPath: codexScreenshotPath),
   let fullSizeCodexScreenshot = ScreenshotBrightnessSampler.decodeScreenshotImage(from: codexScreenshotData) {
    // Scale to 1280 wide like the screenshots the app sends to Claude
    let screenshotSize = CGSize(width: 1280, height: 720)
    let scalingContext = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scalingContext.draw(fullSizeCodexScreenshot, in: CGRect(origin: .zero, size: screenshotSize))
    let codexScreenshot = scalingContext.makeImage()!

    let recognitionStarted = Date()
    let lines = ScreenTextRecognizer.recognizeTextLines(in: codexScreenshot)
    let recognitionSeconds = Date().timeIntervalSince(recognitionStarted)
    print("codex screenshot: \(lines.count) text lines in \(String(format: "%.2f", recognitionSeconds))s")
    check(lines.contains { $0.text.contains("New thread") }, "OCR finds New thread")
    check(lines.contains { $0.text.contains("Ask anything") }, "OCR finds Ask anything")
    check(recognitionSeconds < 2.0, "OCR is fast enough to hide behind Claude (\(recognitionSeconds)s)")

    // Change detection: the same screenshot is unchanged; a region that scrolled is changed
    check((ScreenshotBrightnessSampler.regionDifference(between: codexScreenshot, and: codexScreenshot, in: CGRect(x: 180, y: 110, width: 200, height: 60)) ?? 1) < 0.01, "an unchanged region reads as unchanged")
    let scrolledContext = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scrolledContext.draw(codexScreenshot, in: CGRect(x: 0, y: 60, width: 1280, height: 720))
    let scrolledScreenshot = scrolledContext.makeImage()!
    let sidebarDifference = ScreenshotBrightnessSampler.regionDifference(between: codexScreenshot, and: scrolledScreenshot, in: CGRect(x: 180, y: 110, width: 200, height: 160)) ?? 0
    check(sidebarDifference > 0.03, "a region whose content scrolled reads as changed (\(sidebarDifference))")
    // A mouse pointer drawn into one screenshot only counts when it isn't ignored
    let pointerContext = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pointerContext.draw(codexScreenshot, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
    pointerContext.setFillColor(CGColor(gray: 1, alpha: 1))
    // A 22x22 white "pointer" at screenshot (560, 560) (CGContext y is flipped)
    pointerContext.fill(CGRect(x: 560, y: 720 - 560 - 22, width: 22, height: 22))
    let screenshotWithPointer = pointerContext.makeImage()!
    let inputRegion = CGRect(x: 520, y: 520, width: 200, height: 100)
    let differenceWithPointer = ScreenshotBrightnessSampler.regionDifference(between: codexScreenshot, and: screenshotWithPointer, in: inputRegion) ?? 0
    let differenceIgnoringPointer = ScreenshotBrightnessSampler.regionDifference(between: codexScreenshot, and: screenshotWithPointer, in: inputRegion, ignoring: [CGRect(x: 548, y: 548, width: 44, height: 44)]) ?? 1
    check(differenceWithPointer > 0.03, "a pointer inside the region looks like a change (\(differenceWithPointer))")
    check(differenceIgnoringPointer < 0.005, "ignoring the pointer's spot, nothing changed (\(differenceIgnoringPointer))")
    // The user's ink is drawn into the screenshot where they drew it, and nowhere else
    let codexScreenshotJPEG = NSBitmapImageRep(cgImage: codexScreenshot).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    let inkStroke = (0...40).map { stepIndex -> CGPoint in
        let angle = Double(stepIndex) / 40 * 2 * Double.pi
        return CGPoint(x: 640 + 80 * cos(angle), y: 360 + 40 * sin(angle))
    }
    if let inkedJPEG = UserInkCompositor.screenshotJPEGData(codexScreenshotJPEG, withInkStrokes: [inkStroke]),
       let inkedScreenshot = ScreenshotBrightnessSampler.decodeScreenshotImage(from: inkedJPEG),
       let originalScreenshot = ScreenshotBrightnessSampler.decodeScreenshotImage(from: codexScreenshotJPEG) {
        check(inkedScreenshot.width == 1280 && inkedScreenshot.height == 720, "inked screenshot keeps its size")
        let inkedRegionDifference = ScreenshotBrightnessSampler.regionDifference(between: originalScreenshot, and: inkedScreenshot, in: CGRect(x: 550, y: 310, width: 180, height: 100)) ?? 0
        let farRegionDifference = ScreenshotBrightnessSampler.regionDifference(between: originalScreenshot, and: inkedScreenshot, in: CGRect(x: 180, y: 110, width: 200, height: 160)) ?? 1
        check(inkedRegionDifference > 0.05, "ink shows up where it was drawn (\(inkedRegionDifference))")
        check(farRegionDifference < 0.01, "ink doesn't touch the rest of the screenshot (\(farRegionDifference))")
    } else {
        check(false, "user ink can be drawn into a screenshot")
    }
    // A recompressed copy (JPEG noise) still reads as unchanged
    let recompressedData = NSBitmapImageRep(cgImage: codexScreenshot).representation(using: .jpeg, properties: [.compressionFactor: 0.6])!
    let recompressedScreenshot = ScreenshotBrightnessSampler.decodeScreenshotImage(from: recompressedData)!
    check((ScreenshotBrightnessSampler.regionDifference(between: codexScreenshot, and: recompressedScreenshot, in: CGRect(x: 520, y: 520, width: 450, height: 100)) ?? 1) < 0.01, "JPEG noise alone doesn't count as a change")

    // The sidebar's "New thread" sits around (187-246, 122-132) in 1280-wide pixels
    check(ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "new thread", proposedRect: CGRect(x: 185, y: 118, width: 65, height: 18), recognizedTextLines: lines) == nil, "a ring already on New thread is left alone")
    let snappedRing = ScreenSketchTargetSnapper.correctedTargetRect(forLabel: "new thread button", proposedRect: CGRect(x: 185, y: 150, width: 65, height: 18), recognizedTextLines: lines)
    check(snappedRing.map { $0.midY < 140 && $0.midX > 180 && $0.midX < 280 } == true, "a ring that dropped below New thread snaps back onto the sidebar item: \(String(describing: snappedRing))")
} else {
    check(false, "codex screenshot asset is readable at \(codexScreenshotPath)")
}

// MARK: Streaming answers: sentences come out as they complete, tags attach to their sentence
func describeAnswerPieces(_ answerPieces: [StreamingAnswerPiece]) -> [String] {
    answerPieces.map { answerPiece in
        switch answerPiece {
        case .sentence(let sentenceIndex, let sentenceText): return "S\(sentenceIndex):\(sentenceText)"
        case .tag(let tagText, let sentenceIndex): return "T\(sentenceIndex):\(tagText)"
        }
    }
}
func streamAnswer(_ answer: String, chunkSize: Int) -> [String] {
    var segmenter = StreamingAnswerSegmenter()
    var answerPieces: [StreamingAnswerPiece] = []
    var accumulatedAnswer = ""
    var chunkStart = answer.startIndex
    while chunkStart < answer.endIndex {
        let chunkEnd = answer.index(chunkStart, offsetBy: chunkSize, limitedBy: answer.endIndex) ?? answer.endIndex
        accumulatedAnswer += answer[chunkStart..<chunkEnd]
        chunkStart = chunkEnd
        answerPieces += segmenter.consume(accumulatedAnswerText: accumulatedAnswer, isAnswerComplete: false)
    }
    answerPieces += segmenter.consume(accumulatedAnswerText: accumulatedAnswer, isAnswerComplete: true)
    return describeAnswerPieces(answerPieces)
}
do {
    let streamedAnswer = #"first click your project down here. [DRAW:target 150,628,290,652 label="your project"] then hit share up top! it costs 3.5 dollars, see file.pdf. [POINT:none]"#
    let expectedPieces = ["S0:first click your project down here.", #"T0:[DRAW:target 150,628,290,652 label="your project"]"#, "S1:then hit share up top!", "S2:it costs 3.5 dollars, see file.pdf.", "T2:[POINT:none]"]
    for chunkSize in [1, 2, 3, 5, 8, 13, 400] {
        check(streamAnswer(streamedAnswer, chunkSize: chunkSize) == expectedPieces, "streamed in chunks of \(chunkSize): \(streamAnswer(streamedAnswer, chunkSize: chunkSize))")
    }
    check(streamAnswer(#"[DRAW:circle 1,2,3,4] look here."#, chunkSize: 4) == ["T0:[DRAW:circle 1,2,3,4]", "S0:look here."], "a leading tag belongs to the first sentence")
    check(streamAnswer(#"click this [DRAW:target 1,2,3,4] and you're set."#, chunkSize: 3) == ["S0:click this", "T0:[DRAW:target 1,2,3,4]", "S1:and you're set."], "a tag closes the sentence before it")
    check(streamAnswer("press [enter] now. done.", chunkSize: 2) == ["S0:press [enter] now.", "S1:done."], "brackets that aren't tags are spoken")
    check(streamAnswer("first line\n\nsecond line", chunkSize: 4) == ["S0:first line", "S1:second line"], "newlines end sentences")
    check(streamAnswer("no punctuation at all", chunkSize: 5) == ["S0:no punctuation at all"], "the last sentence comes out when the answer ends")
    check(streamAnswer("look [DRAW:circle 1,2", chunkSize: 3) == ["S0:look [DRAW:circle 1,2"], "a cut-off tag at the end is spoken, not lost")
    check(streamAnswer("[POINT:1,2:a]. [POINT:3,4:b]", chunkSize: 2) == ["T0:[POINT:1,2:a]", "T0:[POINT:3,4:b]"], "punctuation left between tags isn't spoken")

    var earlySegmenter = StreamingAnswerSegmenter()
    check(describeAnswerPieces(earlySegmenter.consume(accumulatedAnswerText: "one. two", isAnswerComplete: false)) == ["S0:one."], "the first sentence is released before the rest arrives")
    check(describeAnswerPieces(earlySegmenter.consume(accumulatedAnswerText: "one. two. three", isAnswerComplete: false)) == ["S1:two."], "the next sentence is released when its end arrives")
    var decimalSegmenter = StreamingAnswerSegmenter()
    check(describeAnswerPieces(decimalSegmenter.consume(accumulatedAnswerText: "costs 3.", isAnswerComplete: false)).isEmpty, "a period at the end of a chunk waits")
    check(describeAnswerPieces(decimalSegmenter.consume(accumulatedAnswerText: "costs 3.5 now.", isAnswerComplete: true)) == ["S0:costs 3.5 now."], "...and turns out to be a decimal")

    let wholeAnswerSpeech = ClaudeVisualTagParser.parseVisualBeats(from: streamedAnswer).spokenText
    let streamedSpeech = streamAnswer(streamedAnswer, chunkSize: 7).filter { $0.hasPrefix("S") }.map { String($0.drop(while: { $0 != ":" }).dropFirst()) }.joined(separator: " ")
    check(streamedSpeech == wholeAnswerSpeech, "streamed speech matches the whole-answer speech")
}

// MARK: Background agent tags
do {
    let parsedWithTitle = BackgroundAgentTagParser.parseAgentTag("[AGENT:standing desks|research standing desks under 500 dollars and make a one page pdf]")
    check(parsedWithTitle?.title == "standing desks" && parsedWithTitle?.brief == "research standing desks under 500 dollars and make a one page pdf", "agent tag with a title")
    let parsedWithoutTitle = BackgroundAgentTagParser.parseAgentTag("[AGENT: find the three cheapest flights to lisbon next friday and list them]")
    check(parsedWithoutTitle?.title == "find the three cheapest flights to" && parsedWithoutTitle?.brief.hasPrefix("find the three") == true, "agent tag without a title uses the brief's first words")
    check(BackgroundAgentTagParser.parseAgentTag("[AGENT:hi|do it]") == nil, "a brief too short to act on is ignored")
    let briefWithPipe = BackgroundAgentTagParser.parseAgentTag("[AGENT:report|compare plan a | plan b on price and support, save output/plans.md]")
    check(briefWithPipe?.brief.contains("plan a | plan b") == true, "only the first pipe separates the title")
    check(StreamingAnswerSegmenter.isAgentTag("[AGENT:x|y]") && StreamingAnswerSegmenter.isAgentTag("[agent : x]") && !StreamingAnswerSegmenter.isAgentTag("[DRAW:circle 1,2,3,4]"), "agent tags are recognized")
    check(streamAnswer("on it, i'll do that now. [AGENT:desks|research standing desks and make a pdf comparison]", chunkSize: 6) == ["S0:on it, i'll do that now.", "T0:[AGENT:desks|research standing desks and make a pdf comparison]"], "agent tags are kept out of the speech")

    func job(result: String?) -> BackgroundAgentJob {
        BackgroundAgentJob(id: "a", title: "t", status: "done", startedAt: "", finishedAt: nil, latestProgress: nil, result: result, folder: "/tmp", outputFiles: [])
    }
    check(job(result: "Saved the top 3 headlines to `output/headlines.md`. Each has a link.").resultHeadline == "Saved the top 3 headlines to output/headlines.md.", "the spoken headline is the first sentence, without markdown")
    check(job(result: "**Done**: your pdf is ready").resultHeadline == "Done: your pdf is ready", "a result without a period is used whole")
    check(job(result: "  ").resultHeadline == nil, "an empty result has no headline")
}

// MARK: Dictation cleanup
do {
    let cases: [(String, String)] = [
        ("um so I think we should uh ship it tomorrow", "So I think we should ship it tomorrow"),
        ("Um, let's meet at 3.30. uh thanks", "Let's meet at 3.30. Thanks"),
        ("hello , world", "Hello, world"),
        ("the umbrella and the hum stay", "The umbrella and the hum stay"),
        ("she said uh-huh to that", "She said uh-huh to that"),
        ("go to example.com/docs. then open notes.pdf", "Go to example.com/docs. Then open notes.pdf"),
        ("Hmm. Erm, okay then.", "Okay then."),
        ("  uh  ", ""),
        ("email me at sam@example.com, thanks", "Email me at sam@example.com, thanks"),
    ]
    for (rawTranscript, expectedDictation) in cases {
        let cleaned = DictationTextCleaner.cleanedDictation(rawTranscript)
        check(cleaned == expectedDictation, "dictation '\(rawTranscript)' -> '\(cleaned)' (expected '\(expectedDictation)')")
    }
}

// MARK: Claude Code — sign-in status
do {
    let signedIn = ClaudeCodeCLI.setupState(fromAuthStatusOutput: #"{"loggedIn": true, "authMethod": "claude.ai", "email": "sam@example.com", "orgName": "Acme", "subscriptionType": "team"}"#)
    check(signedIn == .ready(ClaudeCodeAccount(email: "sam@example.com", subscriptionType: "team", organizationName: "Acme")), "auth status: signed in")
    if case .ready(let account) = signedIn {
        check(account.planDescription == "Team plan", "plan description reads 'Team plan'")
    }
    check(ClaudeCodeCLI.setupState(fromAuthStatusOutput: #"{"loggedIn": false}"#) == .notSignedIn, "auth status: signed out")
    let withNoise = ClaudeCodeCLI.setupState(fromAuthStatusOutput: "some warning first\n{\"loggedIn\": true}")
    check(withNoise.isReady, "auth status: text before the JSON is skipped")
    if case .problem = ClaudeCodeCLI.setupState(fromAuthStatusOutput: "not json") {} else {
        check(false, "auth status: unreadable output is a problem")
    }
    check(ClaudeCodeAccount(email: nil, subscriptionType: nil, organizationName: nil).planDescription == nil, "no plan, no description")
}

// MARK: Claude Code — models, environment and messages
do {
    check(ClaudeCodeCLI.modelAlias(forRequestedModel: "claude-sonnet-4-6") == "sonnet", "sonnet alias")
    check(ClaudeCodeCLI.modelAlias(forRequestedModel: "claude-opus-4-6") == "opus", "opus alias")
    check(ClaudeCodeCLI.modelAlias(forRequestedModel: "claude-haiku-4-5") == "haiku", "haiku alias")
    check(ClaudeCodeCLI.modelAlias(forRequestedModel: "") == "sonnet", "unknown model falls back to sonnet")

    let environment = ClaudeCodeCLI.processEnvironment(
        inheritedEnvironment: ["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "token", "CLAUDECODE": "1", "HOME": "/Users/sam", "PATH": "/usr/bin:/bin"],
        loginShellSearchPath: "/Users/sam/.nvm/bin:/opt/homebrew/bin:/usr/bin",
        claudeBinaryDirectoryPath: "/opt/homebrew/bin",
        homeDirectoryPath: "/Users/sam"
    )
    check(environment["ANTHROPIC_API_KEY"] == nil && environment["ANTHROPIC_AUTH_TOKEN"] == nil, "API keys are removed so the Claude sign-in is used")
    check(environment["CLAUDECODE"] == nil, "a parent Claude Code session's marker is removed")
    check(environment["HOME"] == "/Users/sam", "other variables are kept")
    let searchPathDirectories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    check(searchPathDirectories.first == "/Users/sam/.nvm/bin", "the shell's PATH comes first")
    check(searchPathDirectories.contains("/sbin") && searchPathDirectories.contains("/Users/sam/.local/bin"), "standard folders are added")
    check(Set(searchPathDirectories).count == searchPathDirectories.count, "PATH has no duplicates")
    let noShellEnvironment = ClaudeCodeCLI.processEnvironment(inheritedEnvironment: [:], loginShellSearchPath: nil, claudeBinaryDirectoryPath: "/x/bin", homeDirectoryPath: "/h")
    check(noShellEnvironment["PATH"]?.hasPrefix("/x/bin:") == true, "without a shell PATH, claude's own folder comes first")

    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
    check(ClaudeCodeCLI.imageMediaType(for: pngBytes) == "image/png" && ClaudeCodeCLI.imageMediaType(for: jpegBytes) == "image/jpeg", "image types")

    let messageLine = try! ClaudeCodeCLI.userMessageLine(
        images: [(data: jpegBytes, label: "screen 1 of 1")],
        conversationHistory: [(userPlaceholder: "my name is sam", assistantResponse: "hi sam")],
        userPrompt: "what's my name?"
    )
    check(messageLine.hasSuffix("\n") && messageLine.filter({ $0 == "\n" }).count == 1, "the message is exactly one line")
    let messageFields = try! JSONSerialization.jsonObject(with: Data(messageLine.utf8)) as! [String: Any]
    let content = (messageFields["message"] as! [String: Any])["content"] as! [[String: Any]]
    check(messageFields["type"] as? String == "user" && content.count == 4, "history, image, label and prompt blocks")
    check((content[0]["text"] as? String)?.contains("user: my name is sam\nyou: hi sam") == true, "earlier turns become a transcript")
    check(content[1]["type"] as? String == "image" && ((content[1]["source"] as? [String: Any])?["media_type"] as? String) == "image/jpeg", "the image keeps its type")
    check(content[3]["text"] as? String == "what's my name?", "the question comes last")
    let noHistoryLine = try! ClaudeCodeCLI.userMessageLine(images: [], conversationHistory: [], userPrompt: "hi")
    let noHistoryContent = ((try! JSONSerialization.jsonObject(with: Data(noHistoryLine.utf8)) as! [String: Any])["message"] as! [String: Any])["content"] as! [[String: Any]]
    check(noHistoryContent.count == 1, "no history, no transcript block")

    let voiceArguments = ClaudeCodeChatClient.claudeArguments(modelAlias: "sonnet", systemPrompt: "be brief", isExtendedThinkingEnabled: false)
    check(voiceArguments.contains("--tools") && voiceArguments[voiceArguments.firstIndex(of: "--tools")! + 1] == "", "voice turns get no tools")
    check(voiceArguments.contains(#"{"alwaysThinkingEnabled":false}"#), "thinking is off by default")
    check(!ClaudeCodeChatClient.claudeArguments(modelAlias: "sonnet", systemPrompt: "x", isExtendedThinkingEnabled: true).contains("--settings"), "thinking can be turned back on")
    check(voiceArguments[voiceArguments.firstIndex(of: "--system-prompt")! + 1] == "be brief", "the system prompt is passed as one argument")
}

// MARK: Claude Code — reading its output
do {
    if case .textDelta(let textChunk) = ClaudeCodeCLI.parseOutputLine(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hey there"}}}"#) {
        check(textChunk == "hey there", "text delta")
    } else { check(false, "text delta parses") }
    check(ClaudeCodeCLI.parseOutputLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#) == nil, "thinking isn't spoken")
    check(ClaudeCodeCLI.parseOutputLine(#"{"type":"system","subtype":"init"}"#) == nil, "system events are skipped")
    check(ClaudeCodeCLI.parseOutputLine("not json") == nil, "junk lines are skipped")
    if case .result(let isError, let resultText) = ClaudeCodeCLI.parseOutputLine(#"{"type":"result","is_error":true,"result":"Invalid API key · Please run /login"}"#) {
        check(isError && resultText == "Invalid API key · Please run /login", "result event")
    } else { check(false, "result parses") }
    if case .assistantMessage(let contentBlocks) = ClaudeCodeCLI.parseOutputLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"on it"},{"type":"tool_use","name":"WebSearch","input":{"query":"desks"}}]}}"#) {
        check(contentBlocks.count == 2, "assistant message blocks")
        if case .toolUse(let toolName, let toolInput) = contentBlocks[1] {
            check(toolName == "WebSearch" && toolInput["query"] as? String == "desks", "tool use block")
        } else { check(false, "tool use block parses") }
    } else { check(false, "assistant message parses") }

    func failureKind(_ exitCode: Int32, _ resultEvent: (isError: Bool, resultText: String?)?, _ standardError: String = "") -> String {
        switch ClaudeCodeCLI.failure(exitCode: exitCode, resultEvent: resultEvent, standardErrorText: standardError) {
        case nil: return "none"
        case .notSignedIn: return "notSignedIn"
        case .usageLimitReached: return "usageLimit"
        case .notInstalled: return "notInstalled"
        case .failed(let failureMessage): return "failed: \(failureMessage)"
        }
    }
    check(failureKind(0, (false, "ok")) == "none", "a clean run isn't a failure")
    check(failureKind(1, (true, "Invalid API key · Please run /login")) == "notSignedIn", "signed out is recognized")
    check(failureKind(1, (true, "Claude AI usage limit reached|1761000000")) == "usageLimit", "usage limit is recognized")
    check(failureKind(1, nil, "  boom  \n") == "failed: boom", "stderr explains other failures")
    check(failureKind(2, nil) == "failed: claude exited with code 2", "an exit code alone still explains")
}

// MARK: Child processes — line splitting
do {
    let lineSplitter = OutputLineSplitter()
    check(lineSplitter.append(Data("first\nsec".utf8)) == ["first"], "complete lines come out, the rest waits")
    check(lineSplitter.append(Data("ond\nthird".utf8)) == ["second"], "a line split across reads is joined")
    check(lineSplitter.finish() == "third", "the last line without a newline is kept")
    check(lineSplitter.finish() == nil, "nothing left after finishing")
    let euroSignBytes = Array("€\n".utf8)
    let multiByteSplitter = OutputLineSplitter()
    check(multiByteSplitter.append(Data(euroSignBytes.prefix(1))).isEmpty && multiByteSplitter.append(Data(euroSignBytes.dropFirst())) == ["€"], "a character split across reads stays intact")
}

// MARK: Background agents — runner helpers
do {
    check(BackgroundAgentJobRunner.folderSlug(forTitle: "Standing desk comparison!") == "standing-desk-comparison", "folder slug")
    check(BackgroundAgentJobRunner.folderSlug(forTitle: "  ¿¿ ") == "task", "a title with no letters becomes 'task'")
    check(BackgroundAgentJobRunner.folderSlug(forTitle: String(repeating: "ab ", count: 30)).count <= 40, "slugs stay short")
    check(!BackgroundAgentJobRunner.folderSlug(forTitle: String(repeating: "abcdefghi ", count: 5)).hasSuffix("-"), "a cut slug doesn't end in a dash")
    check(BackgroundAgentJobRunner.titleFromBrief("research standing desks under 500 dollars and make a pdf.") == "research standing desks under 500 dollars", "title from the brief's first words")
    check(BackgroundAgentJobRunner.describeToolUse(toolName: "WebSearch", toolInput: ["query": "desks"]) == "searching the web for \"desks\"", "web search progress")
    check(BackgroundAgentJobRunner.describeToolUse(toolName: "WebFetch", toolInput: ["url": "https://www.example.com/a/b"]) == "reading www.example.com", "web page progress")
    check(BackgroundAgentJobRunner.describeToolUse(toolName: "Write", toolInput: ["file_path": "/x/output/report.pdf"]) == "writing report.pdf", "file progress")
    check(BackgroundAgentJobRunner.describeToolUse(toolName: "Bash", toolInput: ["command": "ls", "description": "list files"]) == "running list files", "shell progress prefers the description")
    check(BackgroundAgentJobRunner.describeToolUse(toolName: "Mystery", toolInput: [:]) == "using Mystery", "unknown tools")
    let agentArguments = BackgroundAgentJobRunner.claudeArguments()
    check(agentArguments.contains("dontAsk") && agentArguments.contains(BackgroundAgentJobRunner.sandboxSettingsJSON), "agents never ask and run sandboxed")
    check(!agentArguments.contains(where: { $0.contains("research") }), "the brief isn't passed as an argument")
    check(BackgroundAgentJobRunner.disallowedTools.contains("Read(~/.ssh/**)") && BackgroundAgentJobRunner.allowedTools.contains("Write(./**)"), "agents can't read credentials and only write in their folder")
    check(agentArguments.contains("--no-session-persistence") && BackgroundAgentJobRunner.claudeArguments(connectedAppServerNames: ["invoices"]).contains("--no-session-persistence"), "Claude Code doesn't keep background task sessions")
    check(ClaudeCodeChatClient.claudeArguments(modelAlias: "sonnet", systemPrompt: "x", isExtendedThinkingEnabled: false).contains("--no-session-persistence"), "nor voice answers")

    let jobFolderForScreenshotTest = FileManager.default.temporaryDirectory.appendingPathComponent("job-screenshot-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: jobFolderForScreenshotTest.appendingPathComponent("tmp"), withIntermediateDirectories: true)
    try? Data([0xFF, 0xD8]).write(to: jobFolderForScreenshotTest.appendingPathComponent("tmp/screen.jpg"))
    try? "keep me".write(to: jobFolderForScreenshotTest.appendingPathComponent("tmp/notes.txt"), atomically: true, encoding: .utf8)
    BackgroundAgentJobRunner.removeScreenshot(fromJobFolderPath: jobFolderForScreenshotTest.path)
    check(!FileManager.default.fileExists(atPath: jobFolderForScreenshotTest.appendingPathComponent("tmp/screen.jpg").path)
          && FileManager.default.fileExists(atPath: jobFolderForScreenshotTest.appendingPathComponent("tmp/notes.txt").path), "a finished task's screenshot is deleted, its other files stay")
    BackgroundAgentJobRunner.removeScreenshot(fromJobFolderPath: jobFolderForScreenshotTest.path)
    try? FileManager.default.removeItem(at: jobFolderForScreenshotTest)

    let savedByNodeBridge = #"{"id":"ab12cd34","title":"t","brief":"b","folder":"/tmp/x","status":"done","startedAt":"2026-10-27T10:00:00.000Z","finishedAt":null,"progress":[{"at":"2026-10-27T10:00:01.000Z","text":"writing a.txt"}],"result":"Done.","outputFiles":["a.txt"],"wasStopRequested":false}"#
    let decodedJobRecord = try? JSONDecoder().decode(BackgroundAgentJobRecord.self, from: Data(savedByNodeBridge.utf8))
    check(decodedJobRecord?.progress.first?.text == "writing a.txt" && decodedJobRecord?.finishedAt == nil, "jobs saved by the old Node bridge still load")
}

// MARK: Guided step cards
do {
    let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    var cardDeck = GuidedStepCardDeck()
    check(cardDeck.isEmpty, "a new walkthrough has no cards")

    cardDeck.showStep(number: 1, instructionText: "Click File up in the menu bar.", targetGlobalRect: CGRect(x: 60, y: 950, width: 30, height: 20), displayFrame: screenFrame)
    check(cardDeck.cards.count == 1 && cardDeck.cards[0].kind == .step(number: 1) && !cardDeck.cards[0].isDone, "a step shows as the current card")
    check(cardDeck.targetGlobalRect != nil, "the card knows what it must not cover")

    cardDeck.updateCurrentStepText("Click File up in the menu bar, near the top left.")
    check(cardDeck.cards[0].instructionText == "Click File up in the menu bar, near the top left.", "the finished answer replaces the card's text")

    cardDeck.markCurrentStepDone()
    check(cardDeck.cards[0].isDone && cardDeck.targetGlobalRect == nil, "clicking the target ticks the step off")

    cardDeck.showStep(number: 2, instructionText: "Now pick Export as PDF.", targetGlobalRect: CGRect(x: 70, y: 600, width: 120, height: 20), displayFrame: screenFrame)
    cardDeck.showStep(number: 3, instructionText: "That was the wrong menu, open File again.", targetGlobalRect: CGRect(x: 60, y: 950, width: 30, height: 20), displayFrame: screenFrame)
    check(cardDeck.cards.map(\.kind) == [.step(number: 1), .step(number: 3)], "a step that was never done is replaced by the corrected one")

    cardDeck.markCurrentStepDone()
    cardDeck.finish(closingText: "Done, your PDF is saving.")
    check(cardDeck.cards.last?.kind == .closingNote && cardDeck.cards.last?.instructionText == "Done, your PDF is saving.", "the walkthrough ends with a closing note")
    check(cardDeck.targetGlobalRect == nil, "nothing to avoid once it's over")

    var unfinishedDeck = GuidedStepCardDeck()
    unfinishedDeck.showStep(number: 1, instructionText: "Click Share.", targetGlobalRect: .zero, displayFrame: screenFrame)
    unfinishedDeck.finish(closingText: "Now type the file name and press return.")
    check(unfinishedDeck.cards.map(\.kind) == [.closingNote] && unfinishedDeck.cards[0].instructionText.hasPrefix("Now type"), "a step that isn't a click stays up as the closing note")

    var finishedSilently = GuidedStepCardDeck()
    finishedSilently.showStep(number: 1, instructionText: "Click Share.", targetGlobalRect: .zero, displayFrame: screenFrame)
    finishedSilently.markCurrentStepDone()
    finishedSilently.finish(closingText: "")
    check(finishedSilently.cards.map(\.kind) == [.step(number: 1)], "an answer with nothing to say adds no note")

    var longDeck = GuidedStepCardDeck()
    for stepNumber in 1...6 {
        longDeck.showStep(number: stepNumber, instructionText: "Step \(stepNumber).", targetGlobalRect: .zero, displayFrame: screenFrame)
        longDeck.markCurrentStepDone()
    }
    check(longDeck.shownCards.count == GuidedStepCardDeck.maximumShownCardCount && longDeck.shownCards.last?.kind == .step(number: 6), "only the latest steps are shown")

    longDeck.clear()
    check(longDeck.isEmpty && longDeck.displayFrame == nil, "asking something new clears the cards")

    check(GuidedStepCardDeck.cardText(fromAnswerText: "now hit share in the top right corner. [DRAW:target 1160,36,1192,60 label=\"share\"]") == "Now hit share in the top right corner.", "card text drops the tag and starts with a capital")
    check(GuidedStepCardDeck.cardText(fromAnswerText: "click file [POINT:62,4:file] , then wait.") == "Click file, then wait.", "spacing around removed tags is tidied")
    check(GuidedStepCardDeck.cardText(fromAnswerText: "[POINT:none]") == "", "an answer that's only a tag has no card text")
    let longCardText = GuidedStepCardDeck.cardText(fromAnswerText: String(repeating: "open the settings panel and ", count: 12))
    check(longCardText.count <= GuidedStepCardDeck.maximumInstructionLength + 1 && longCardText.hasSuffix("…") && !longCardText.contains("  "), "long text is cut at a word with an ellipsis: \(longCardText)")

    let screenSize = CGSize(width: 1512, height: 982)
    let cardSize = CGSize(width: 300, height: 130)
    check(GuidedStepCardDeck.cardCorner(screenSize: screenSize, topInset: 37, cardSize: cardSize, margin: 16, avoiding: nil) == .topTrailing, "cards go top right by default")
    check(GuidedStepCardDeck.cardCorner(screenSize: screenSize, topInset: 37, cardSize: cardSize, margin: 16, avoiding: CGRect(x: 700, y: 500, width: 80, height: 30)) == .topTrailing, "a target in the middle doesn't move them")
    check(GuidedStepCardDeck.cardCorner(screenSize: screenSize, topInset: 37, cardSize: cardSize, margin: 16, avoiding: CGRect(x: 1400, y: 60, width: 40, height: 24)) == .bottomTrailing, "a target under the top-right corner moves them down")
    check(GuidedStepCardDeck.cardCorner(screenSize: screenSize, topInset: 37, cardSize: cardSize, margin: 16, avoiding: CGRect(x: 1180, y: 40, width: 320, height: 930)) == .topLeading, "a tall target on the right moves them to the left")
}

// MARK: Guided steps — a click said without a mark
do {
    let clickInstructionsWithoutTarget = [
        "open system settings from the apple menu. [POINT:none]",
        "Open System Settings from the Apple menu.",
        "first click file, then export as pdf.",
        "it's in the view menu, then pick show sidebar.",
        "you’ll want to open the share menu in the top right.",
        "start by selecting your project down here.",
        "now hit share in the top right corner.",
        "go to the privacy tab and turn it on. [DRAW:circle 10,10,40,40 label=\"privacy\"]",
    ]
    for answerText in clickInstructionsWithoutTarget {
        check(GuidedStepAnswerCheck.isClickInstructionWithoutTarget(answerText), "a click with no mark is caught: \(answerText)")
    }

    let answersThatAreFine = [
        "click file up in the menu bar. [DRAW:target 62,4,92,22 label=\"file\"]",
        "now hit share in the top right corner. [DRAW:target 1160,36,1192,60 label=\"share\"]",
        "html is the skeleton of every web page, it says what's on the page. [POINT:none]",
        "press command comma to open settings.",
        "type your email in the box and press return.",
        "that's it, your pdf is saving.",
        "it opens in a new window. [POINT:none]",
        "the key is to cut the bass before you blend.",
        "on it, i'll put a comparison together in the background. [AGENT:desks|research standing desks]",
        "try a lower volume first.",
        "openly, i'd pick the second one.",
        "just hit command shift n while the finder window is active and it'll create a new folder right there. [POINT:none]",
        "hit the return key to send it.",
        "tap escape to close it.",
        "boil the water first, then pick a sauce you like.",
        "open up to them about how you feel.",
        "choose whichever plan fits your budget.",
        "they're in this downloads folder in the sidebar. [DRAW:circle 20,310,130,330 label=\"downloads\"]",
    ]
    for answerText in answersThatAreFine {
        check(!GuidedStepAnswerCheck.isClickInstructionWithoutTarget(answerText), "not a click without a mark: \(answerText)")
    }
    check(GuidedStepAnswerCheck.answerHasTarget("now pick export. [DRAW: target 70,410,190,430 label=\"export\"]"), "a target with a space after the colon still counts")
    check(GuidedStepAnswerCheck.missingTargetFollowUpTranscript.hasPrefix("(guided step)"), "the follow-up is saved as a guided step")
}

// MARK: Conversations — voice commands
do {
    func parsed(_ transcript: String) -> ConversationVoiceCommand? { ConversationVoiceCommand.parse(transcript) }
    check(parsed("Start a new session.") == .startNewSession(followingQuestion: nil), "\"start a new session\"")
    check(parsed("new chat please") == .startNewSession(followingQuestion: nil), "\"new chat please\"")
    check(parsed("Hey Clicky, start over.") == .startNewSession(followingQuestion: nil), "a wake word before the command")
    check(parsed("Hey Mose, start over.") == .startNewSession(followingQuestion: nil), "the app's own name works as a wake word")
    check(parsed("okay mose new chat") == .startNewSession(followingQuestion: nil), "the wake word without punctuation")
    check(ConversationTitle.title(fromFirstQuestion: "hey mose how do I export this") == "How do I export this", "the wake word isn't part of the title")
    check(parsed("Let's start fresh") == .startNewSession(followingQuestion: nil), "\"let's start fresh\"")
    check(parsed("forget everything") == .startNewSession(followingQuestion: nil), "\"forget everything\"")
    check(parsed("Clear the context.") == .startNewSession(followingQuestion: nil), "\"clear the context\"")
    check(parsed("New chat. How do I export this as a PDF?") == .startNewSession(followingQuestion: "How do I export this as a PDF?"), "a command followed by a question keeps the question")
    check(parsed("new topic, what's a context window") == .startNewSession(followingQuestion: "what's a context window"), "\"new topic\" then a question")
    check(parsed("How do I start a new chat?") == nil, "a question about starting a chat isn't a command")
    check(parsed("start a new chat in slack") == nil, "a request about an app isn't a command")
    check(parsed("start a new thread") == nil, "\"new thread\" is left to apps like Slack")
    check(parsed("what do you see here?") == nil, "ordinary questions aren't commands")
    check(parsed("Go back to the chat about DJ transitions.") == .resumeSession(topic: "dj transitions"), "going back to a chat by topic")
    check(parsed("can we go back to the conversation about invoices, please") == .resumeSession(topic: "invoices"), "a polite resume keeps its topic")
    check(parsed("continue my last conversation") == .resumeSession(topic: nil), "\"continue my last conversation\"")
    check(parsed("back to our previous chat") == .resumeSession(topic: nil), "\"back to our previous chat\"")
    check(parsed("open the chat") == nil, "\"open the chat\" could be about an app")
}

// MARK: Conversations — titles, context and summaries
do {
    check(ConversationTitle.title(fromFirstQuestion: "hey, how do i export this as a pdf?") == "How do I export this as a…", "a title from the first question: \(ConversationTitle.title(fromFirstQuestion: "hey, how do i export this as a pdf?"))")
    check(ConversationTitle.title(fromFirstQuestion: "um what's a context window") == "What's a context window", "fillers are dropped from titles")
    check(ConversationTitle.title(fromFirstQuestion: "  ") == "New conversation", "an empty question gets a plain title")

    func makeExchange(_ index: Int, answerLength: Int = 40, isGuidedStep: Bool = false) -> ConversationExchange {
        ConversationExchange(id: UUID(), askedAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index * 60)),
                             userTranscript: "question \(index)", assistantResponse: String(repeating: "a", count: answerLength),
                             isGuidedStepFollowUp: isGuidedStep, frontmostAppName: nil)
    }
    func makeSession(exchangeCount: Int, answerLength: Int = 40, summarizedExchangeCount: Int = 0, summary: String? = nil) -> ConversationSession {
        ConversationSession(id: UUID(), title: "t", startedAt: Date(), lastActivityAt: Date(),
                            exchanges: (0..<exchangeCount).map { makeExchange($0, answerLength: answerLength) },
                            earlierSummary: summary, summarizedExchangeCount: summarizedExchangeCount)
    }

    let shortConversation = makeSession(exchangeCount: 5)
    check(ConversationContext.context(for: shortConversation).recentExchanges.count == 5 && ConversationContext.context(for: shortConversation).earlierSummary == nil, "a short conversation goes whole")
    check(ConversationContext.exchangesToSummarize(in: shortConversation) == nil, "a short conversation needs no summary")
    check(ConversationContext.context(for: nil).recentExchanges.isEmpty, "no conversation, no context")

    let longUnsummarized = makeSession(exchangeCount: 20)
    let foldPlan = ConversationContext.exchangesToSummarize(in: longUnsummarized)
    check(foldPlan?.exchanges.count == 8 && foldPlan?.summarizedExchangeCountAfterwards == 8, "the exchanges past the window get summarized")
    check(ConversationContext.context(for: longUnsummarized).recentExchanges.count == 20, "until the summary exists, nothing is dropped")

    let longSummarized = makeSession(exchangeCount: 20, summarizedExchangeCount: 8, summary: "they were mixing two songs")
    let summarizedContext = ConversationContext.context(for: longSummarized)
    check(summarizedContext.earlierSummary == "they were mixing two songs" && summarizedContext.recentExchanges.count == ConversationContext.maximumVerbatimExchangeCount, "a summary plus the most recent exchanges")
    check(summarizedContext.recentExchanges.first?.userTranscript == "question 8", "the recent part starts right where the summary ends")
    check(ConversationContext.exchangesToSummarize(in: longSummarized) == nil, "an up-to-date summary needs no update")

    let veryLongUnsummarized = makeSession(exchangeCount: 40)
    check(ConversationContext.context(for: veryLongUnsummarized).recentExchanges.count <= ConversationContext.maximumVerbatimExchangeCount * 2, "a summary that keeps failing can't grow the context forever")

    let longAnswers = makeSession(exchangeCount: 10, answerLength: 2_000, summarizedExchangeCount: 10, summary: "s")
    let longAnswersContext = ConversationContext.context(for: longAnswers)
    let longAnswersCharacters = longAnswersContext.recentExchanges.reduce(0) { $0 + $1.userTranscript.count + $1.assistantResponse.count }
    check(longAnswersCharacters <= ConversationContext.verbatimCharacterBudget && longAnswersContext.recentExchanges.count >= 1, "long answers are limited by the character budget")

    let oneHugeAnswer = makeSession(exchangeCount: 1, answerLength: 20_000)
    check(ConversationContext.context(for: oneHugeAnswer).recentExchanges.count == 1, "the latest exchange always goes, even when it's long")

    check(ConversationContext.spokenText(of: "click file. [DRAW:target 1,2,3,4 label=\"file\"] [SESSION:new]") == "click file.", "saved answers are shown without tags")
    let summaryRequest = ConversationContext.summaryRequest(previousSummary: "they asked about bpm", exchangesToFold: [makeExchange(1)])
    check(summaryRequest.contains("they asked about bpm") && summaryRequest.contains("they said: question 1"), "the summary request has the old summary and the new exchanges")
}

// MARK: Conversations — saved on disk
MainActor.assumeIsolated {
    let conversationsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-conversation-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: conversationsFolder) }
    let conversationStore = ConversationSessionStore(conversationsDirectoryURL: conversationsFolder)
    check(conversationStore.sessions.isEmpty && conversationStore.currentSession == nil, "a new store is empty")

    let firstAskedAt = Date().addingTimeInterval(-7_200)
    conversationStore.recordExchange(ConversationExchange(id: UUID(), askedAt: firstAskedAt, userTranscript: "how do i mix two songs smoothly", assistantResponse: "match the bpm first. [POINT:none]", isGuidedStepFollowUp: false, frontmostAppName: "Mixxx"))
    conversationStore.recordExchange(ConversationExchange(id: UUID(), askedAt: firstAskedAt.addingTimeInterval(60), userTranscript: "and the bass?", assistantResponse: "cut it until the drop.", isGuidedStepFollowUp: false, frontmostAppName: "Mixxx"))
    let firstConversationID = conversationStore.currentSessionID
    check(conversationStore.sessions.count == 1 && conversationStore.currentSession?.exchanges.count == 2, "exchanges go into one conversation")
    check(conversationStore.currentSession?.title == "How do I mix two songs smoothly", "the conversation is titled from its first question")
    let savedFileNames = (try? FileManager.default.contentsOfDirectory(atPath: conversationsFolder.path)) ?? []
    check(savedFileNames.count == 1 && savedFileNames[0].hasSuffix(".json"), "each conversation is saved as a file")

    conversationStore.startNewSession()
    check(conversationStore.currentSession == nil, "starting over leaves nothing current until the next question")
    conversationStore.recordExchange(ConversationExchange(id: UUID(), askedAt: firstAskedAt.addingTimeInterval(3_600), userTranscript: "how do i export this as a pdf", assistantResponse: "click file.", isGuidedStepFollowUp: false, frontmostAppName: "Pages"))
    check(conversationStore.sessions.count == 2 && conversationStore.currentSessionID != firstConversationID, "the next question starts a second conversation")
    let secondConversationID = conversationStore.currentSessionID

    let reopenedStore = ConversationSessionStore(conversationsDirectoryURL: conversationsFolder)
    check(reopenedStore.sessions.count == 2 && reopenedStore.sessions.first?.id == secondConversationID, "conversations come back after a restart, newest first")
    check(reopenedStore.session(withID: firstConversationID!)?.exchanges.last?.frontmostAppName == "Mixxx", "saved exchanges keep their details")

    reopenedStore.resumeSession(withID: firstConversationID!)
    check(reopenedStore.currentSessionID == firstConversationID, "an older conversation can be continued")
    check(!reopenedStore.isCurrentSessionIdle(at: Date(), idleLimitSeconds: 1_800), "a conversation just picked to continue isn't idle")

    reopenedStore.updateEarlierSummary(ofSessionWithID: firstConversationID!, summary: "they mix music", summarizedExchangeCount: 1)
    check(reopenedStore.session(withID: firstConversationID!)?.earlierSummary == "they mix music", "summaries are saved")
    reopenedStore.updateEarlierSummary(ofSessionWithID: firstConversationID!, summary: "stale", summarizedExchangeCount: 1)
    check(reopenedStore.session(withID: firstConversationID!)?.earlierSummary == "they mix music", "a summary never replaces a newer one")

    let idleStore = ConversationSessionStore(conversationsDirectoryURL: conversationsFolder)
    idleStore.resumeSession(withID: firstConversationID!)
    check(idleStore.isCurrentSessionIdle(at: Date().addingTimeInterval(3_600), idleLimitSeconds: 1_800), "an hour of quiet makes the conversation idle")

    let searchCandidates = reopenedStore.sessions
    check(ConversationSearch.bestMatchingSession(forTopic: "dj mixing", in: searchCandidates, excludingSessionID: nil)?.id == firstConversationID, "\"mixing\" finds the music conversation by its words")
    check(ConversationSearch.bestMatchingSession(forTopic: "exporting", in: searchCandidates, excludingSessionID: nil)?.id == secondConversationID, "a title match wins, and word endings don't matter")
    check(ConversationSearch.bestMatchingSession(forTopic: "spreadsheets", in: searchCandidates, excludingSessionID: nil) == nil, "an unknown topic finds nothing")
    check(ConversationSearch.bestMatchingSession(forTopic: nil, in: searchCandidates, excludingSessionID: firstConversationID)?.id == secondConversationID, "no topic means the most recent other conversation")
    check(ConversationSearch.sessions(searchCandidates, matching: "bpm drop").count == 1 && ConversationSearch.sessions(searchCandidates, matching: "bpm pdf").isEmpty, "history search needs every word")

    reopenedStore.deleteSession(withID: firstConversationID!)
    check(reopenedStore.sessions.count == 1 && reopenedStore.currentSessionID == nil, "deleting the current conversation leaves none current")
    reopenedStore.deleteAllSessions()
    let remainingFileNames = (try? FileManager.default.contentsOfDirectory(atPath: conversationsFolder.path)) ?? []
    check(reopenedStore.sessions.isEmpty && remainingFileNames.isEmpty, "delete all removes every file")
}

// MARK: Conversations — the SESSION tag
do {
    check(StreamingAnswerSegmenter.isSessionTag("[SESSION:new]") && StreamingAnswerSegmenter.isClickyTag("[SESSION:new]"), "the SESSION tag is a Clicky tag")
    var sessionSegmenter = StreamingAnswerSegmenter()
    let sessionPieces = sessionSegmenter.consume(accumulatedAnswerText: "okay, fresh start. [SESSION:new]", isAnswerComplete: true)
    let spokenSessionPieces = sessionPieces.compactMap { piece -> String? in if case .sentence(_, let text) = piece { return text } else { return nil } }
    check(spokenSessionPieces == ["okay, fresh start."], "the SESSION tag is never spoken: \(spokenSessionPieces)")
}

// MARK: Memory — fact text
do {
    check(UserMemoryText.cleanedFact("  + \"they use final cut pro\"  ") == "they use final cut pro", "list markers and quotes are trimmed")
    check(UserMemoryText.cleanedFact("they [use] final\ncut pro") == "they use final cut pro", "brackets and line breaks go")
    let longFact = UserMemoryText.cleanedFact(String(repeating: "they like long words ", count: 20))
    check(longFact.count <= UserMemoryText.maximumFactLength && !longFact.hasSuffix(" "), "long facts are cut at a word")
    check(UserMemoryText.isSameFact("they use Final Cut Pro.", "They use final cut pro"), "case and punctuation don't make a new fact")
    check(UserMemoryText.isSameFact("they edit their videos in final cut pro", "they edit videos in final cut pro"), "small wording changes are the same fact")
    check(!UserMemoryText.isSameFact("they use final cut pro", "they use premiere pro"), "a different app is a different fact")
    check(UserMemoryText.forgetRequestsToApply(["everything"], answerAskedForNewConversation: true).isEmpty, "starting over never forgets everything, even if Claude says so")
    check(UserMemoryText.forgetRequestsToApply(["they use imovie", "everything"], answerAskedForNewConversation: false) == ["they use imovie", "everything"], "without a start-over every forget request stands")
    check(UserMemoryText.forgetRequestsToApply(["they use imovie"], answerAskedForNewConversation: true) == ["they use imovie"], "a named fact is still forgotten alongside a start-over")
    check(UserMemoryText.isForgetEverythingRequest("Everything") && UserMemoryText.isForgetEverythingRequest("everything about me") && !UserMemoryText.isForgetEverythingRequest("everything in dropbox"), "\"everything\" means every fact, but only on its own")
    check(UserMemoryText.factAddressedToUser("they keep their invoices in dropbox") == "You keep your invoices in dropbox", "facts are shown to the user as \"you\"")
    check(UserMemoryText.factAddressedToUser("they're learning to beatmatch") == "You're learning to beatmatch", "contractions are turned too")
    check(UserMemoryText.factAddressedToUser("they write documents and send them as pdfs") == "You write documents and send them as pdfs", "\"them\" about things is left alone")
}

// MARK: Memory — the store
MainActor.assumeIsolated {
    let memoryFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-memory-tests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: memoryFileURL) }
    let memoryStore = UserMemoryStore(memoryFileURL: memoryFileURL)
    check(memoryStore.facts.isEmpty && memoryStore.isMemoryEnabled, "memory starts empty and on")

    let conversationID = UUID()
    let firstRememberedAt = Date().addingTimeInterval(-600)
    memoryStore.remember("they use final cut pro", origin: .learnedFromConversation, conversationID: conversationID, at: firstRememberedAt)
    memoryStore.remember("they keep their invoices in dropbox", origin: .askedToRemember, conversationID: nil, at: firstRememberedAt.addingTimeInterval(60))
    check(memoryStore.facts.map(\.text) == ["they keep their invoices in dropbox", "they use final cut pro"], "facts are kept newest first")
    check(memoryStore.remember("   ", origin: .askedToRemember, conversationID: nil) == nil && memoryStore.facts.count == 2, "an empty fact isn't saved")

    memoryStore.remember("They use Final Cut Pro.", origin: .askedToRemember, conversationID: nil, at: firstRememberedAt.addingTimeInterval(120))
    check(memoryStore.facts.count == 2 && memoryStore.facts.first?.text == "They use Final Cut Pro.", "a repeated fact is freshened, not added twice")
    check(memoryStore.facts.first?.origin == .learnedFromConversation && memoryStore.facts.first?.conversationID == conversationID, "a freshened fact keeps where it came from")

    let reopenedMemoryStore = UserMemoryStore(memoryFileURL: memoryFileURL)
    check(reopenedMemoryStore.facts.map(\.text) == memoryStore.facts.map(\.text), "facts come back after a restart")

    check(memoryStore.forget(matching: "spreadsheets in excel").isEmpty && memoryStore.facts.count == 2, "forgetting something unknown removes nothing")
    let forgottenFacts = memoryStore.forget(matching: "invoices in dropbox")
    check(forgottenFacts.map(\.text) == ["they keep their invoices in dropbox"] && memoryStore.facts.count == 1, "forgetting by a few of its words removes that fact")
    memoryStore.remember("they keep their invoices in dropbox", origin: .askedToRemember, conversationID: nil)
    memoryStore.dropFacts(sameAs: "everything")
    check(memoryStore.facts.count == 2, "an out-of-date note from Haiku never clears everything")
    memoryStore.dropFacts(sameAs: "they use final cut pro")
    check(memoryStore.facts.map(\.text) == ["they keep their invoices in dropbox"], "an out-of-date fact is dropped when it's the same fact")
    memoryStore.remember("they use premiere pro", origin: .learnedFromConversation, conversationID: nil)
    check(memoryStore.forget(matching: "everything").count == 2 && memoryStore.facts.isEmpty, "forget everything clears every fact")

    for factNumber in 1...45 {
        memoryStore.remember("they have hobby number \(factNumber) of many", origin: factNumber <= 3 ? .askedToRemember : .learnedFromConversation, conversationID: nil, at: Date().addingTimeInterval(Double(factNumber)))
    }
    check(memoryStore.facts.count == UserMemoryStore.maximumFactCount, "memory keeps at most \(UserMemoryStore.maximumFactCount) facts")
    check(memoryStore.facts.filter { $0.origin == .askedToRemember }.count == 3, "facts the user asked for are kept over learned ones")

    memoryStore.setMemoryEnabled(false)
    check(!UserMemoryStore(memoryFileURL: memoryFileURL).isMemoryEnabled, "turning memory off is remembered too")
    memoryStore.deleteFact(withID: memoryStore.facts[0].id)
    check(memoryStore.facts.count == UserMemoryStore.maximumFactCount - 1, "a single fact can be deleted")
    memoryStore.deleteAllFacts()
    check(UserMemoryStore(memoryFileURL: memoryFileURL).facts.isEmpty, "deleting everything is saved")
}

// MARK: Memory — what Claude gets, and learning from conversations
MainActor.assumeIsolated {
    let olderFact = RememberedFact(id: UUID(), text: "they dj with mixxx", rememberedAt: Date().addingTimeInterval(-86_400), origin: .learnedFromConversation, conversationID: nil)
    let newerFact = RememberedFact(id: UUID(), text: "they keep invoices in dropbox", rememberedAt: Date(), origin: .askedToRemember, conversationID: nil)
    check(UserMemoryContext.noteForClaude(facts: [], isMemoryEnabled: true) == nil, "no facts, no note")
    let memoryNote = UserMemoryContext.noteForClaude(facts: [newerFact, olderFact], isMemoryEnabled: true) ?? ""
    check(memoryNote.contains("- they dj with mixxx\n- they keep invoices in dropbox"), "facts go to Claude oldest first: \(memoryNote)")
    let memoryOffNote = UserMemoryContext.noteForClaude(facts: [newerFact], isMemoryEnabled: false) ?? ""
    check(memoryOffNote.contains("memory is turned off") && !memoryOffNote.contains("dropbox"), "with memory off Claude is told so, and gets no facts")

    let learningReply = UserMemoryContext.parseLearningReply("+ they edit videos in final cut pro\n- they use imovie\nsome stray line\n+ \"they post on youtube\"")
    check(learningReply.factsToAdd == ["they edit videos in final cut pro", "they post on youtube"] && learningReply.factsToDrop == ["they use imovie"], "the learning reply's lines are read")
    check(UserMemoryContext.parseLearningReply("none").factsToAdd.isEmpty, "\"none\" adds nothing")
    let floodedReply = (1...9).map { "+ they like thing \($0)" }.joined(separator: "\n")
    check(UserMemoryContext.parseLearningReply(floodedReply).factsToAdd.count == 5, "a reply can't add more than five facts at once")

    let now = Date()
    func conversation(minutesAgo: Double, exchangeCount: Int, reviewedExchangeCount: Int? = nil) -> ConversationSession {
        let exchanges = (0..<exchangeCount).map { exchangeIndex in
            ConversationExchange(id: UUID(), askedAt: now.addingTimeInterval(-minutesAgo * 60), userTranscript: "question \(exchangeIndex)", assistantResponse: "answer \(exchangeIndex) [POINT:none]", isGuidedStepFollowUp: false, frontmostAppName: "Pages")
        }
        var conversationSession = ConversationSession(id: UUID(), title: "Conversation", startedAt: now.addingTimeInterval(-minutesAgo * 60), lastActivityAt: now.addingTimeInterval(-minutesAgo * 60), exchanges: exchanges, earlierSummary: nil, summarizedExchangeCount: 0)
        conversationSession.memoryReviewedExchangeCount = reviewedExchangeCount
        return conversationSession
    }
    let currentActiveConversation = conversation(minutesAgo: 2, exchangeCount: 2)
    let currentQuietConversation = conversation(minutesAgo: 45, exchangeCount: 2)
    let finishedConversation = conversation(minutesAgo: 10, exchangeCount: 3)
    let reviewedConversation = conversation(minutesAgo: 20, exchangeCount: 3, reviewedExchangeCount: 3)
    let continuedAfterReviewConversation = conversation(minutesAgo: 25, exchangeCount: 4, reviewedExchangeCount: 3)
    let oldConversation = conversation(minutesAgo: 60 * 24 * 5, exchangeCount: 3)
    let emptyConversation = conversation(minutesAgo: 30, exchangeCount: 0)
    let allConversations = [currentActiveConversation, finishedConversation, reviewedConversation, continuedAfterReviewConversation, oldConversation, emptyConversation]

    let toLearnFrom = UserMemoryContext.conversationsToLearnFrom(in: allConversations, currentSessionID: currentActiveConversation.id, now: now, idleLimitSeconds: 1_800)
    check(toLearnFrom.map(\.id) == [finishedConversation.id, continuedAfterReviewConversation.id], "only finished, recent conversations with something new are looked through, newest first")
    let toLearnFromWhenQuiet = UserMemoryContext.conversationsToLearnFrom(in: [currentQuietConversation], currentSessionID: currentQuietConversation.id, now: now, idleLimitSeconds: 1_800)
    check(toLearnFromWhenQuiet.count == 1, "the current conversation counts as over once it's been quiet past the idle limit")

    var conversationWithGuidedStep = finishedConversation
    conversationWithGuidedStep.exchanges.append(ConversationExchange(id: UUID(), askedAt: now, userTranscript: "(guided step) i clicked file. what's next?", assistantResponse: "now pick export. [DRAW:target 1,2,3,4 label=\"export\"]", isGuidedStepFollowUp: true, frontmostAppName: "Pages"))
    let learningRequest = UserMemoryContext.learningRequest(conversationSession: conversationWithGuidedStep, knownFacts: [olderFact])
    check(learningRequest.contains("- they dj with mixxx") && learningRequest.contains("they said (in Pages): question 0"), "the learning request has the known facts and the conversation")
    check(!learningRequest.contains("(guided step)") && !learningRequest.contains("[POINT"), "guided-step turns and tags are left out of the learning request")

    let markerFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-memory-marker-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerFolder) }
    let markerStore = ConversationSessionStore(conversationsDirectoryURL: markerFolder)
    markerStore.recordExchange(ConversationExchange(id: UUID(), askedAt: now, userTranscript: "hi", assistantResponse: "hey", isGuidedStepFollowUp: false, frontmostAppName: nil))
    let markedConversationID = markerStore.currentSessionID!
    markerStore.markReviewedForMemory(sessionWithID: markedConversationID, exchangeCount: 1)
    check(ConversationSessionStore(conversationsDirectoryURL: markerFolder).session(withID: markedConversationID)?.memoryReviewedExchangeCount == 1, "a conversation remembers it was looked through")
}

// MARK: Background agents — connected apps
do {
    let serverListOutput = """
    Checking MCP server health…

    claude.ai Gmail: https://gmailmcp.example.com/mcp - ✔ Connected
    claude.ai Notion: https://mcp.notion.example.com/mcp - ! Needs authentication
    claude.ai Fathom – Your Meeting Intelligence Layer: https://fathom.example.com/mcp - ! Needs authentication
    claude.ai fleetforward-onboarding: https://ff.example.com/mcp - ✔ Connected
    invoices: https://invoices.example.com/mcp (HTTP) - ✔ Connected
    local-notes: node /Users/someone/notes-server.js --mode - fast - ✘ Failed to connect
    """
    let connectedApps = AgentConnectedApps.parseServerList(serverListOutput)
    check(connectedApps.map(\.serverName) == ["claude.ai Gmail", "claude.ai Notion", "claude.ai Fathom – Your Meeting Intelligence Layer", "claude.ai fleetforward-onboarding", "invoices", "local-notes"], "every server line is read: \(connectedApps.map(\.serverName))")
    check(connectedApps.map(\.connectionStatus) == [.connected, .needsSignIn, .needsSignIn, .connected, .connected, .failed], "connection status is read")
    check(connectedApps[0].displayName == "Gmail" && connectedApps[4].displayName == "invoices", "claude.ai connectors are shown without the prefix")

    check(AgentConnectedApps.toolPermissionRule(forServerName: "claude.ai Google Calendar") == "mcp__claude_ai_Google_Calendar", "connector names become Claude Code's tool prefix")
    check(AgentConnectedApps.toolPermissionRule(forServerName: "claude.ai Fathom – Your Meeting Intelligence Layer") == "mcp__claude_ai_Fathom_Your_Meeting_Intelligence_Layer", "runs of odd characters become one underscore")
    check(AgentConnectedApps.toolPermissionRule(forServerName: "claude.ai fleetforward-onboarding") == "mcp__claude_ai_fleetforward-onboarding", "hyphens stay")

    let argumentsWithoutApps = BackgroundAgentJobRunner.claudeArguments()
    check(argumentsWithoutApps.contains("--strict-mcp-config") && !argumentsWithoutApps.joined(separator: " ").contains("mcp__"), "with no apps turned on, MCP servers aren't loaded at all")
    let argumentsWithApps = BackgroundAgentJobRunner.claudeArguments(connectedAppServerNames: ["claude.ai Gmail", "invoices"])
    let allowedToolsArgument = argumentsWithApps[(argumentsWithApps.firstIndex(of: "--allowedTools") ?? 0) + 1]
    check(!argumentsWithApps.contains("--strict-mcp-config"), "with apps turned on, Claude Code loads the user's servers")
    check(allowedToolsArgument.hasSuffix("Edit(./**) mcp__claude_ai_Gmail mcp__invoices"), "only the turned-on apps are allowed: \(allowedToolsArgument)")
    check(argumentsWithApps.contains("dontAsk"), "everything else is still refused without asking")
    let instructionsArgument = argumentsWithApps[(argumentsWithApps.firstIndex(of: "--append-system-prompt") ?? 0) + 1]
    check(instructionsArgument.contains("these apps of theirs: Gmail, invoices") && instructionsArgument.contains("Never send"), "the agent is told which apps it has and not to send")

    check(BackgroundAgentJobRunner.describeToolUse(toolName: "mcp__claude_ai_Google_Calendar__list_events", toolInput: [:]) == "using Google Calendar: list events", "app tool use reads as a sentence")
    check(AgentConnectedApps.noteForVoiceAnswers(appDisplayNames: []) == nil, "no apps, no note for the voice answers")
    check(AgentConnectedApps.noteForVoiceAnswers(appDisplayNames: ["Gmail"])?.contains("Gmail") == true, "the voice answers hear which apps tasks can use")
}

// MARK: Memory — the REMEMBER and FORGET tags
do {
    check(StreamingAnswerSegmenter.isRememberTag("[REMEMBER:they use final cut pro]") && StreamingAnswerSegmenter.isClickyTag("[REMEMBER:they use final cut pro]"), "the REMEMBER tag is a Clicky tag")
    check(StreamingAnswerSegmenter.isForgetTag("[FORGET:everything]") && StreamingAnswerSegmenter.isClickyTag("[FORGET:everything]"), "the FORGET tag is a Clicky tag")
    check(StreamingAnswerSegmenter.tagContent("[REMEMBER: they keep invoices in dropbox ]") == "they keep invoices in dropbox", "a tag's content is read without the brackets")
    var memorySegmenter = StreamingAnswerSegmenter()
    let memoryPieces = memorySegmenter.consume(accumulatedAnswerText: "got it, i'll remember that. [REMEMBER:they keep invoices in dropbox]", isAnswerComplete: true)
    let spokenMemoryPieces = memoryPieces.compactMap { piece -> String? in if case .sentence(_, let text) = piece { return text } else { return nil } }
    check(spokenMemoryPieces == ["got it, i'll remember that."], "the REMEMBER tag is never spoken: \(spokenMemoryPieces)")
    check(ConversationContext.spokenText(of: "done. [FORGET:they use imovie]") == "done.", "saved answers are shown without memory tags")
    check(GuidedStepCardDeck.cardText(fromAnswerText: "got it. [REMEMBER:they use pages]") == "Got it.", "step cards leave memory tags out")

    let messageWithMemory = (try? ClaudeCodeCLI.userMessageLine(images: [], notesAboutUser: "what you remember about them:\n- they use pages", conversationHistory: [], userPrompt: "hi")) ?? ""
    let decodedMessage = (try? JSONSerialization.jsonObject(with: Data(messageWithMemory.utf8))) as? [String: Any]
    let contentBlocks = ((decodedMessage?["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    check((contentBlocks.first?["text"] as? String)?.hasPrefix("what you remember about them") == true && (contentBlocks.last?["text"] as? String) == "hi", "the memory note goes first in the user message, the question last")
}

// MARK: Devil mode — action tags
do {
    check(DevilModeActionTagParser.parseActionTag(#"[CLICK:62,4,92,22 label="file"]"#) == .click(kind: .click, screenshotRect: CGRect(x: 62, y: 4, width: 30, height: 18), label: "file", screenNumber: nil), "CLICK reads a box and a label")
    check(DevilModeActionTagParser.parseActionTag(#"[CLICK:92,22,62,4 label="file"]"#) == .click(kind: .click, screenshotRect: CGRect(x: 62, y: 4, width: 30, height: 18), label: "file", screenNumber: nil), "CLICK corners in either order")
    check(DevilModeActionTagParser.parseActionTag(#"[DOUBLECLICK:10,10,50,30 label="report.pdf"]"#) == .click(kind: .doubleClick, screenshotRect: CGRect(x: 10, y: 10, width: 40, height: 20), label: "report.pdf", screenNumber: nil), "DOUBLECLICK")
    check(DevilModeActionTagParser.parseActionTag(#"[RIGHTCLICK:10,10,50,30 label="desktop" screen=2]"#) == .click(kind: .rightClick, screenshotRect: CGRect(x: 10, y: 10, width: 40, height: 20), label: "desktop", screenNumber: 2), "RIGHTCLICK with a screen")
    check(DevilModeActionTagParser.parseActionTag(#"[double-click:10,10,50,30]"#) == .click(kind: .doubleClick, screenshotRect: CGRect(x: 10, y: 10, width: 40, height: 20), label: nil, screenNumber: nil), "double-click spelled with a dash, in lowercase")
    check(DevilModeActionTagParser.parseActionTag(#"[RIGHT_CLICK:10,10,50,30:screen3]"#)?.screenNumber == 3, "RIGHT_CLICK with a :screen3 suffix")
    check(DevilModeActionTagParser.parseActionTag(#"[CLICK:120,40 label="ok"]"#) == .click(kind: .click, screenshotRect: CGRect(x: 108, y: 28, width: 24, height: 24), label: "ok", screenNumber: nil), "CLICK with only a point gets a small box around it")
    check(DevilModeActionTagParser.parseActionTag(#"[CLICK:10,10,50,30 label="step 2 of 3"]"#)?.labelOrTypedText == "step 2 of 3", "digits in a click's label aren't coordinates")
    check(DevilModeActionTagParser.parseActionTag("[CLICK:here]") == nil, "CLICK without numbers")
    check(DevilModeActionTagParser.parseActionTag(#"[DRAG:100,200,400,260 label="photo to album"]"#) == .drag(fromScreenshotPoint: CGPoint(x: 100, y: 200), toScreenshotPoint: CGPoint(x: 400, y: 260), label: "photo to album", screenNumber: nil), "DRAG reads from, to and a label")
    check(DevilModeActionTagParser.parseActionTag("[DRAG:100,200]") == nil, "DRAG needs an end")
    check(DevilModeActionTagParser.parseActionTag("[SCROLL:400,300,5]") == .scroll(atScreenshotPoint: CGPoint(x: 400, y: 300), lineCount: 5, screenNumber: nil), "SCROLL down")
    check(DevilModeActionTagParser.parseActionTag("[SCROLL:400,300,-3 screen=2]") == .scroll(atScreenshotPoint: CGPoint(x: 400, y: 300), lineCount: -3, screenNumber: 2), "SCROLL up on screen 2")
    check(DevilModeActionTagParser.parseActionTag("[SCROLL:400,300,500]") == .scroll(atScreenshotPoint: CGPoint(x: 400, y: 300), lineCount: 30, screenNumber: nil), "SCROLL is capped")
    check(DevilModeActionTagParser.parseActionTag("[SCROLL:400,300,0]") == nil && DevilModeActionTagParser.parseActionTag("[SCROLL:400,300]") == nil, "SCROLL needs a nonzero amount")
    check(DevilModeActionTagParser.parseActionTag("[TYPE:flights to lisbon]") == .typeText("flights to lisbon"), "TYPE")
    check(DevilModeActionTagParser.parseActionTag("[TYPE: meeting at 10:30, room 4 ]") == .typeText("meeting at 10:30, room 4"), "TYPE keeps colons and commas, trims the ends")
    check(DevilModeActionTagParser.parseActionTag("[TYPE:   ]") == nil, "TYPE with nothing to type")
    check(DevilModeActionTagParser.parseActionTag("[TYPE:" + String(repeating: "a", count: 2001) + "]") == nil, "TYPE that's far too long")
    check(DevilModeActionTagParser.parseActionTag("[KEY:cmd+s]") == .pressKeys(DevilModeKeyShortcut(virtualKeyCode: 1, modifiers: .command, keyName: "s")), "KEY cmd+s")
    check(DevilModeActionTagParser.parseActionTag("[KEY:nonsense]") == nil, "KEY with an unknown key")
    check(DevilModeActionTagParser.parseActionTag("[POINT:1,2:x]") == nil && !DevilModeActionTagParser.isActionTag("[POINT:1,2:x]"), "POINT isn't an action")
    for actionTag in ["[CLICK:1,2,3,4]", "[DOUBLECLICK:1,2,3,4]", "[RIGHTCLICK:1,2,3,4]", "[DRAG:1,2,3,4]", "[SCROLL:1,2,3]", "[TYPE:hi]", "[KEY:tab]", "[ click :1,2,3,4]"] {
        check(DevilModeActionTagParser.isActionTag(actionTag) && StreamingAnswerSegmenter.isClickyTag(actionTag), "\(actionTag) is an action tag and a Clicky tag")
    }
    check(!StreamingAnswerSegmenter.isClickyTag("[clicks]") && !StreamingAnswerSegmenter.isClickyTag("[keyboard shortcut]"), "brackets without a colon aren't tags")
    let parsedAnswerActions = DevilModeActionTagParser.parseActions(fromAnswerText: #"typing it in. [CLICK:400,120,880,150 label="search"] [TYPE:flights to lisbon] [KEY:return] [POINT:none]"#)
    check(parsedAnswerActions.count == 3 && parsedAnswerActions[1] == .typeText("flights to lisbon") && parsedAnswerActions[2] == .pressKeys(DevilModeKeyShortcutParser.parse("return")!), "an answer's actions, in order, without the POINT")
}

// MARK: Devil mode — key shortcuts
do {
    let saveAs = DevilModeKeyShortcutParser.parse("cmd+shift+s")
    check(saveAs?.virtualKeyCode == 1 && saveAs?.modifiers == [.command, .shift], "cmd+shift+s")
    check(saveAs?.eventFlags.contains(.maskCommand) == true && saveAs?.eventFlags.contains(.maskShift) == true && saveAs?.eventFlags.contains(.maskControl) == false, "cmd+shift+s flags")
    check(saveAs?.displayText == "shift+cmd+s", "display text puts modifiers in the usual order: \(saveAs?.displayText ?? "")")
    check(DevilModeKeyShortcutParser.parse("return")?.virtualKeyCode == 36 && DevilModeKeyShortcutParser.parse("return")?.modifiers == [], "return")
    check(DevilModeKeyShortcutParser.parse("Enter")?.isReturnKey == true && DevilModeKeyShortcutParser.parse("cmd+return")?.isReturnKey == true, "enter and cmd+return are return keys")
    check(DevilModeKeyShortcutParser.parse("tab")?.virtualKeyCode == 48 && DevilModeKeyShortcutParser.parse("shift+tab")?.modifiers == .shift, "tab and shift+tab")
    check(DevilModeKeyShortcutParser.parse("escape")?.virtualKeyCode == 53 && DevilModeKeyShortcutParser.parse("esc")?.virtualKeyCode == 53, "escape")
    check(DevilModeKeyShortcutParser.parse("Command + ,")?.virtualKeyCode == 43 && DevilModeKeyShortcutParser.parse("Command + ,")?.modifiers == .command, "Command + , (settings)")
    check(DevilModeKeyShortcutParser.parse("ctrl+option+left")?.virtualKeyCode == 123 && DevilModeKeyShortcutParser.parse("ctrl+option+left")?.modifiers == [.control, .option], "ctrl+option+left")
    check(DevilModeKeyShortcutParser.parse("cmd s")?.virtualKeyCode == 1 && DevilModeKeyShortcutParser.parse("cmd s")?.modifiers == .command, "cmd s with a space")
    check(DevilModeKeyShortcutParser.parse("page up")?.virtualKeyCode == 116, "page up is one key")
    check(DevilModeKeyShortcutParser.parse("cmd++")?.virtualKeyCode == 24 && DevilModeKeyShortcutParser.parse("cmd++")?.modifiers == .command, "cmd++ (zoom in)")
    check(DevilModeKeyShortcutParser.parse("cmd+-")?.virtualKeyCode == 27, "cmd+- (zoom out)")
    check(DevilModeKeyShortcutParser.parse("F5")?.virtualKeyCode == 96 && DevilModeKeyShortcutParser.parse("cmd+space")?.virtualKeyCode == 49, "f5 and cmd+space")
    check(DevilModeKeyShortcutParser.parse("⌘⇧N".lowercased()) == nil, "symbols run together aren't parsed")
    check(DevilModeKeyShortcutParser.parse("⌘+⇧+n")?.modifiers == [.command, .shift], "symbols joined by plus")
    check(DevilModeKeyShortcutParser.parse("cmd+shift") == nil, "modifiers without a key")
    check(DevilModeKeyShortcutParser.parse("a+b") == nil, "two keys at once")
    check(DevilModeKeyShortcutParser.parse("hyper+q") == nil, "an unknown modifier")
    check(DevilModeKeyShortcutParser.parse("  ") == nil, "nothing")
    check(DevilModeKeyShortcutParser.parse("fn+f11")?.eventFlags.contains(.maskSecondaryFn) == true, "fn")
}

// MARK: Devil mode — never spoken
do {
    let devilAnswer = #"opening the apple menu. [CLICK:8,2,34,24 label="apple menu"] then i'll pick settings."#
    let expectedDevilPieces = ["S0:opening the apple menu.", #"T0:[CLICK:8,2,34,24 label="apple menu"]"#, "S1:then i'll pick settings."]
    for chunkSize in [1, 3, 7, 400] {
        check(streamAnswer(devilAnswer, chunkSize: chunkSize) == expectedDevilPieces, "a CLICK tag is pulled out of the speech in chunks of \(chunkSize): \(streamAnswer(devilAnswer, chunkSize: chunkSize))")
    }
    let typedAnswer = "typing it. [TYPE:hello. this is sam! see you at 3.5?] [KEY:return] done."
    check(streamAnswer(typedAnswer, chunkSize: 4) == ["S0:typing it.", "T0:[TYPE:hello. this is sam! see you at 3.5?]", "T0:[KEY:return]", "S1:done."], "typed text is never spoken, even with sentence ends inside: \(streamAnswer(typedAnswer, chunkSize: 4))")
    check(streamAnswer("[DRAG:1,2,3,4 label=\"file\"] [SCROLL:5,6,3] [DOUBLECLICK:1,2,3,4] [RIGHTCLICK:1,2,3,4] moved it.", chunkSize: 5).filter { $0.hasPrefix("S") } == ["S0:moved it."], "DRAG, SCROLL, DOUBLECLICK and RIGHTCLICK aren't spoken")
    check(ConversationContext.spokenText(of: #"exporting it. [CLICK:1,2,3,4 label="export"] [TYPE:report] [KEY:cmd+s] [double-click:1,2,3,4]"#) == "exporting it.", "saved answers are shown without action tags")
    check(GuidedStepCardDeck.cardText(fromAnswerText: #"opening it. [RIGHTCLICK:1,2,3,4 label="file"] [DRAG:1,2,3,4] [SCROLL:1,2,3]"#) == "Opening it.", "step cards leave action tags out")
}

// MARK: Devil mode — one step per answer
do {
    let clickField = DevilModeActionTagParser.parseActionTag(#"[CLICK:1,2,3,4 label="name"]"#)!
    let secondClick = DevilModeActionTagParser.parseActionTag(#"[CLICK:5,6,7,8 label="save"]"#)!
    let typeName = DevilModeAction.typeText("Ada")
    let pressReturn = DevilModeAction.pressKeys(DevilModeKeyShortcutParser.parse("return")!)
    check(DevilModeActionPlan.actionsToPerform([clickField, typeName, pressReturn]) == [clickField, typeName, pressReturn], "a click, then typing and a key, all go")
    check(DevilModeActionPlan.actionsToPerform([clickField, secondClick]) == [clickField], "a second click waits for the next screenshot")
    check(DevilModeActionPlan.actionsToPerform([typeName, clickField, typeName]) == [typeName], "a click after anything else waits")
    check(DevilModeActionPlan.actionsToPerform(Array(repeating: pressReturn, count: 7)).count == DevilModeActionPlan.maximumActionsPerAnswer, "at most four actions per answer")
    check(DevilModeActionPlan.actionsToPerform([]).isEmpty, "no actions, nothing to do")
    check(DevilModeActionPlan.actionsToPerform(fromAnswerText: #"it's empty, should i still hit send? [CLICK:522,145,795,198 label="send message"]"#).isEmpty, "an answer that ends with a question doesn't act, even with a tag")
    check(DevilModeActionPlan.actionsToPerform(fromAnswerText: #"typing it. [TYPE:are you free at 3?]"#) == [.typeText("are you free at 3?")], "a question mark inside typed text isn't the answer asking")
    check(DevilModeActionPlan.actionsToPerform(fromAnswerText: #"want it as a pdf? exporting it now. [CLICK:1,2,3,4 label="export"]"#).count == 1, "a question earlier in the answer doesn't stop it")
    check(DevilModeActionPlan.answerEndsWithAQuestion("should i send it?  [POINT:none]") && !DevilModeActionPlan.answerEndsWithAQuestion("sending. [CLICK:1,2,3,4]"), "an answer asks when its spoken text ends with a question mark")
}

// MARK: Devil mode — risky actions
do {
    let finder = DevilModeAppContext(bundleIdentifier: "com.apple.finder", appName: "Finder", windowTitle: "Downloads")
    let messages = DevilModeAppContext(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages", windowTitle: "Sam")
    let gmailInChrome = DevilModeAppContext(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Inbox (3) - you@example.com - Gmail")
    let flightsInChrome = DevilModeAppContext(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Google Flights - Find Cheap Flights")

    for riskyLabel in ["Send Message", "send", "Post", "Publish", "Buy now", "Place order", "Pay", "Delete", "Move to Trash", "Submit", "Share…", "Invite people", "Checkout", "Confirm purchase"] {
        check(DevilModeSafetyCheck.containsRiskyWords(riskyLabel), "\"\(riskyLabel)\" is risky")
    }
    for safeLabel in ["Export", "Save Draft", "Sender name", "postcode", "File", "System Settings", "sharp", nil] as [String?] {
        check(!DevilModeSafetyCheck.containsRiskyWords(safeLabel), "\"\(safeLabel ?? "nil")\" is safe")
    }
    let clickSend = DevilModeActionTagParser.parseActionTag(#"[CLICK:1,2,3,4 label="send message"]"#)!
    check(DevilModeSafetyCheck.confirmationQuestion(for: clickSend, appContext: finder) == "Should I click send message?", "a send button is asked about first")
    let clickArrow = DevilModeActionTagParser.parseActionTag(#"[CLICK:1,2,3,4 label="blue arrow"]"#)!
    check(DevilModeSafetyCheck.confirmationQuestion(for: clickArrow, appContext: finder, textUnderTarget: "Send") != nil, "the text under the click counts too, whatever the label says")
    check(DevilModeSafetyCheck.confirmationQuestion(for: clickArrow, appContext: finder, textUnderTarget: "Export") == nil, "a harmless click goes ahead")
    let pressReturn = DevilModeAction.pressKeys(DevilModeKeyShortcutParser.parse("return")!)
    check(DevilModeSafetyCheck.confirmationQuestion(for: pressReturn, appContext: messages) == "Should I press return to send it?", "return in Messages sends")
    check(DevilModeSafetyCheck.confirmationQuestion(for: pressReturn, appContext: gmailInChrome) != nil, "return in Gmail in a browser sends")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .pressKeys(DevilModeKeyShortcutParser.parse("cmd+return")!), appContext: DevilModeAppContext(bundleIdentifier: "com.apple.mail", appName: "Mail", windowTitle: nil)) != nil, "cmd+return in Mail sends")
    check(DevilModeSafetyCheck.confirmationQuestion(for: pressReturn, appContext: flightsInChrome) == nil, "return in a flight search doesn't")
    check(DevilModeSafetyCheck.confirmationQuestion(for: pressReturn, appContext: finder) == nil, "return in the Finder doesn't")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .pressKeys(DevilModeKeyShortcutParser.parse("cmd+delete")!), appContext: finder) != nil, "cmd+delete trashes")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .pressKeys(DevilModeKeyShortcutParser.parse("delete")!), appContext: finder) == nil, "delete alone is editing")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .typeText("please delete the old invoices"), appContext: finder) != nil, "typed text with a risky word is asked about")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .typeText("flights to lisbon"), appContext: messages) == nil, "typing alone doesn't send")
    check(DevilModeSafetyCheck.confirmationQuestion(for: DevilModeActionTagParser.parseActionTag(#"[DRAG:1,2,3,4 label="file to trash"]"#)!, appContext: finder) != nil, "dragging to the trash is asked about")
    check(DevilModeSafetyCheck.confirmationQuestion(for: .scroll(atScreenshotPoint: .zero, lineCount: 5, screenNumber: nil), appContext: messages) == nil, "scrolling is never risky")
    check(DevilModeSafetyCheck.isChatOrMailApp(DevilModeAppContext(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: nil)), "Slack is a chat app")
    check(DevilModeSafetyCheck.isQuestionAboutARiskyAction("it's ready to go, should i send it to sam?"), "a question about sending")
    check(DevilModeSafetyCheck.isQuestionAboutARiskyAction("found three old ones. should i delete them?"), "a question about deleting")
    check(!DevilModeSafetyCheck.isQuestionAboutARiskyAction("the notes are empty. want me to type something first?"), "a question about something harmless doesn't approve a send")
    check(!DevilModeSafetyCheck.isQuestionAboutARiskyAction("i sent it to sam. anything else?"), "only the question itself counts, not an earlier sentence")
    check(!DevilModeSafetyCheck.isQuestionAboutARiskyAction("sending it now."), "not a question")
    check(!DevilModeSafetyCheck.isChatOrMailApp(finder), "the Finder isn't")
}

// MARK: Devil mode — the user's yes or no
do {
    for yesReply in ["yes", "Yeah, go ahead.", "yes please", "sure", "do it", "hey mose, yes", "okay", "yep send it", "go for it"] {
        check(DevilModeConfirmationReply.classify(yesReply) == .yes, "\"\(yesReply)\" is a yes")
    }
    for noReply in ["no", "No, wait.", "don't", "nope", "wait", "not yet", "cancel that", "yes, but wait"] {
        check(DevilModeConfirmationReply.classify(noReply) == .no, "\"\(noReply)\" is a no")
    }
    for otherReply in ["what's the weather like", "", "yes and then also make the title bigger and export it as a pdf", "send it to anna instead of sam please and also cc bob on it"] {
        check(DevilModeConfirmationReply.classify(otherReply) == .somethingElse, "\"\(otherReply)\" isn't an answer to the question")
    }
}

// MARK: Devil mode — step budget and follow-ups
do {
    var stepBudget = DevilModeStepBudget()
    var stepsTaken = 0
    while stepBudget.useOneStep() { stepsTaken += 1 }
    check(stepsTaken == DevilModeStepBudget.maximumAutomaticSteps && stepsTaken == 15, "fifteen automatic steps per request")
    check(stepBudget.isUsedUp && !stepBudget.useOneStep(), "then no more")
    stepBudget.reset()
    check(stepBudget.stepsRemaining == 15 && !stepBudget.isUsedUp, "a new request starts a fresh budget")

    let clickExport = DevilModeActionTagParser.parseActionTag(#"[CLICK:1,2,3,4 label="export"]"#)!
    check(DevilModeFollowUp.transcript(afterPerforming: [clickExport]) == "(devil step) you clicked export. what's next?", "the follow-up after one click")
    let fieldActions = [DevilModeActionTagParser.parseActionTag(#"[CLICK:1,2,3,4 label="name"]"#)!, DevilModeAction.typeText("Ada"), DevilModeAction.pressKeys(DevilModeKeyShortcutParser.parse("return")!)]
    check(DevilModeFollowUp.transcript(afterPerforming: fieldActions) == #"(devil step) you clicked name, typed "Ada", then pressed return. what's next?"#, "the follow-up after several actions: \(DevilModeFollowUp.transcript(afterPerforming: fieldActions))")
    check(DevilModeFollowUp.transcript(afterPerforming: [.scroll(atScreenshotPoint: .zero, lineCount: -4, screenNumber: nil)]) == "(devil step) you scrolled up. what's next?", "the follow-up after a scroll")
    check(DevilModeFollowUp.isDevilStepTranscript("(devil step) you clicked export. what's next?") && !DevilModeFollowUp.isDevilStepTranscript("(guided step) i clicked export. what's next?"), "devil steps are told apart from guided steps")
    check(DevilModeFollowUp.historyDescription(of: "(devil step) you clicked export. what's next?", assistantName: "Mose") == "Mose clicked export", "the History window says what Mose did")
    let approvalTranscript = DevilModeFollowUp.transcript(afterApprovalOf: "Should I click send message?")
    check(approvalTranscript.hasPrefix("(devil step)") && approvalTranscript.contains("before you click send message, and i said yes"), "after a yes, Claude is told to go ahead: \(approvalTranscript)")
    check(DevilModeFollowUp.historyDescription(of: approvalTranscript, assistantName: "Mose") == "You said yes", "the History window shows the yes")
    check(DevilModeFollowUp.noteForClaude(isDevilModeEnabled: true).contains("devil mode is on") && DevilModeFollowUp.noteForClaude(isDevilModeEnabled: false).contains("devil mode is off"), "Claude is told whether devil mode is on")

    check(clickExport.progressiveDescription == "Clicking export" && clickExport.imperativeDescription == "click export", "describing a click")
    check(DevilModeActionTagParser.parseActionTag(#"[DOUBLECLICK:1,2,3,4 label="report"]"#)!.progressiveDescription == "Double-clicking report", "describing a double-click")
    let longTypedText = DevilModeAction.typeText(String(repeating: "word ", count: 20))
    check(longTypedText.progressiveDescription.hasSuffix("…\"") && longTypedText.progressiveDescription.count < 60, "long typed text is cut in the note: \(longTypedText.progressiveDescription)")
}

// MARK: Devil mode — coordinates and typing
do {
    let primaryScreenHeight: CGFloat = 982
    check(DevilModeScreenCoordinates.quartzGlobalPoint(fromAppKitGlobalPoint: CGPoint(x: 100, y: 900), primaryScreenHeight: primaryScreenHeight) == CGPoint(x: 100, y: 82), "AppKit to Quartz flips y on the primary screen")
    check(DevilModeScreenCoordinates.quartzGlobalPoint(fromAppKitGlobalPoint: CGPoint(x: 100, y: 1200), primaryScreenHeight: primaryScreenHeight) == CGPoint(x: 100, y: -218), "a screen above the primary one has negative Quartz y")
    check(DevilModeScreenCoordinates.quartzGlobalPoint(fromAppKitGlobalPoint: CGPoint(x: -1440, y: 300), primaryScreenHeight: primaryScreenHeight) == CGPoint(x: -1440, y: 682), "a screen to the left keeps its negative x")
    let roundTripPoint = CGPoint(x: 512.5, y: 77.25)
    check(DevilModeScreenCoordinates.appKitGlobalPoint(fromQuartzGlobalPoint: DevilModeScreenCoordinates.quartzGlobalPoint(fromAppKitGlobalPoint: roundTripPoint, primaryScreenHeight: primaryScreenHeight), primaryScreenHeight: primaryScreenHeight) == roundTripPoint, "the conversion goes both ways")

    let dragPath = DevilModeScreenCoordinates.dragPathPoints(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 160), stepCount: 20)
    check(dragPath.count == 20 && dragPath.last == CGPoint(x: 400, y: 160), "a drag path ends exactly on the drop point")
    check(dragPath.first != CGPoint(x: 100, y: 100) && zip(dragPath, dragPath.dropFirst()).allSatisfy { $0.x <= $1.x }, "it moves away from the start and only forward")
    check(DevilModeScreenCoordinates.dragPathPoints(from: .zero, to: CGPoint(x: 5, y: 5), stepCount: 0) == [CGPoint(x: 5, y: 5)], "no steps still ends at the drop point")

    check(!DevilModeTyping.shouldPaste("flights to lisbon"), "short text is typed key by key")
    check(DevilModeTyping.shouldPaste(String(repeating: "a", count: 41)), "long text is pasted")
    check(DevilModeTyping.shouldPaste("line one\nline two"), "text with a line break is pasted, so it can't press return")
    let keystrokeUnits = DevilModeTyping.keystrokeUnits(of: "hé👍")
    check(keystrokeUnits.count == 3 && keystrokeUnits[2].count == 2, "an emoji goes out as one key event of two UTF-16 units")
    check(DevilModeEventMark.eventSourceUserData == 0x4D6F7365, "Mose's events are marked \"Mose\"")

    let pointerAtRest = CGPoint(x: 500, y: 300)
    check(!DevilModeTakeoverRule.isUserMovingTheMouse(eventLocation: CGPoint(x: 501, y: 299), expectedMouseLocation: pointerAtRest), "a hand resting on the mouse twitching a point doesn't stop a run")
    check(!DevilModeTakeoverRule.isUserMovingTheMouse(eventLocation: CGPoint(x: 508, y: 306), expectedMouseLocation: pointerAtRest), "nor a few points")
    check(!DevilModeTakeoverRule.isUserMovingTheMouse(eventLocation: CGPoint(x: 499, y: 316), expectedMouseLocation: pointerAtRest), "nor a 16-point nudge (one stopped a real run)")
    check(DevilModeTakeoverRule.isUserMovingTheMouse(eventLocation: CGPoint(x: 560, y: 300), expectedMouseLocation: pointerAtRest), "a real move does")
    check(DevilModeTakeoverRule.isMosesOwnEvent(eventSourceUserData: DevilModeEventMark.eventSourceUserData, eventSourceProcessIdentifier: 0, ownProcessIdentifier: 42), "a marked event is Mose's")
    check(DevilModeTakeoverRule.isMosesOwnEvent(eventSourceUserData: 0, eventSourceProcessIdentifier: 42, ownProcessIdentifier: 42), "so is one from Mose's own process, even if the mark was lost")
    check(!DevilModeTakeoverRule.isMosesOwnEvent(eventSourceUserData: 0, eventSourceProcessIdentifier: 0, ownProcessIdentifier: 42), "a hardware event is the user's")
    check(!DevilModeTakeoverRule.isMosesOwnEvent(eventSourceUserData: 0, eventSourceProcessIdentifier: 777, ownProcessIdentifier: 42), "so is one another app posted")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
