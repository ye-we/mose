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

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
