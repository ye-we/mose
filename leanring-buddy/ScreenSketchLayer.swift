//
//  ScreenSketchLayer.swift
//  leanring-buddy
//
//  Renders Clicky's hand-drawn marks (see ScreenSketch.swift) in the cursor
//  overlay. Each drawing carries its own 0...1 progress, so strokes appear
//  as the pen moves along them and labels are written letter by letter.
//

import SwiftUI

/// A drawing on screen plus how much of it the pen has drawn so far.
struct ActiveScreenSketchDrawing: Identifiable {
    let drawing: ScreenSketchDrawing
    var drawingProgress: Double

    var id: UUID { drawing.id }
}

extension ScreenSketchInkColor {
    var swiftUIColor: Color {
        let components = redGreenBlueComponents
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: 1)
    }
}

struct ScreenSketchLayer: View {
    let activeSketchDrawings: [ActiveScreenSketchDrawing]

    /// Highlighter ink is see-through so the text under it stays readable.
    private let highlighterOpacity: Double = 0.42
    private let darkBackgroundHighlighterOpacity: Double = 0.2
    private let labelPaperHorizontalPadding: CGFloat = 7
    private let labelPaperVerticalPadding: CGFloat = 2

    var body: some View {
        Canvas { graphicsContext, _ in
            for activeSketchDrawing in activeSketchDrawings {
                drawStrokes(of: activeSketchDrawing, in: graphicsContext)
                drawLabel(of: activeSketchDrawing, in: graphicsContext)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawStrokes(of activeSketchDrawing: ActiveScreenSketchDrawing, in graphicsContext: GraphicsContext) {
        let drawing = activeSketchDrawing.drawing
        let inkColor = drawing.inkColor.swiftUIColor

        for (strokeIndex, stroke) in drawing.strokes.enumerated() {
            let inkedLength = drawing.inkedLength(ofStrokeAt: strokeIndex, atProgress: activeSketchDrawing.drawingProgress)
            let inkedPoints = stroke.points(upToDistance: inkedLength)
            guard inkedPoints.count > 1 else { continue }

            var strokePath = Path()
            strokePath.addLines(inkedPoints)

            if stroke.isHighlighter {
                // The overlay is its own window, so ink can only be laid over other
                // apps with plain transparency (blend modes can't reach them). On dark
                // backgrounds a strong yellow wash turns muddy and hides the text, so
                // it stays faint there and the geometry adds a solid underline instead.
                graphicsContext.stroke(
                    strokePath,
                    with: .color(inkColor.opacity(drawing.isOverDarkBackground ? darkBackgroundHighlighterOpacity : highlighterOpacity)),
                    style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
                )
            } else {
                // A soft dark shadow keeps bright ink readable on light
                // backgrounds without adding an outline on dark ones.
                graphicsContext.drawLayer { shadowedContext in
                    shadowedContext.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.6, x: 0, y: 1))
                    shadowedContext.stroke(
                        strokePath,
                        with: .color(inkColor),
                        style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    /// Labels are written on a small white paper tag so they read on any
    /// background. The tag is sized for the whole label up front so it
    /// doesn't grow while the letters appear.
    private func drawLabel(of activeSketchDrawing: ActiveScreenSketchDrawing, in graphicsContext: GraphicsContext) {
        let drawing = activeSketchDrawing.drawing
        guard let textLabel = drawing.textLabel,
              drawing.isLabelVisible(atProgress: activeSketchDrawing.drawingProgress) else { return }

        let revealedCharacterCount = drawing.revealedLabelCharacterCount(atProgress: activeSketchDrawing.drawingProgress)
        let revealedLabelText = String(textLabel.text.prefix(revealedCharacterCount))
        let labelFont = Font.custom(ScreenSketchGeometry.labelFontName, size: textLabel.fontSize)

        graphicsContext.drawLayer { labelContext in
            // Tilt the tag around its own left-center point
            labelContext.translateBy(x: textLabel.leadingCenterPoint.x, y: textLabel.leadingCenterPoint.y)
            labelContext.rotate(by: .degrees(textLabel.rotationDegrees))

            let paperRect = CGRect(
                x: -labelPaperHorizontalPadding,
                y: -textLabel.textSize.height / 2 - labelPaperVerticalPadding,
                width: textLabel.textSize.width + labelPaperHorizontalPadding * 2,
                height: textLabel.textSize.height + labelPaperVerticalPadding * 2
            )
            let paperPath = Path(roundedRect: paperRect, cornerRadius: 5, style: .continuous)

            labelContext.drawLayer { paperContext in
                paperContext.addFilter(.shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1.5))
                paperContext.fill(paperPath, with: .color(Color(.sRGB, red: 1, green: 0.99, blue: 0.96, opacity: 0.97)))
            }

            let resolvedLabelText = labelContext.resolve(
                Text(revealedLabelText)
                    .font(labelFont)
                    .foregroundColor(labelInkColor(for: drawing.inkColor))
            )
            labelContext.draw(resolvedLabelText, at: .zero, anchor: .leading)
        }
    }

    /// Yellow is a highlighter color and is unreadable as text on white paper,
    /// so highlight labels are written in a darker amber instead.
    private func labelInkColor(for inkColor: ScreenSketchInkColor) -> Color {
        if inkColor == .yellow {
            return Color(.sRGB, red: 0.72, green: 0.52, blue: 0.0, opacity: 1)
        }
        return inkColor.swiftUIColor
    }
}
