//
//  scripts/app-icon/main.swift
//
//  Draws the app icon: the companion's blue pointer aimed at a button that
//  Clicky has circled in orange marker. The ring comes from the app's own
//  sketch engine, so it has the same hand-drawn wobble as marks on screen.
//  Run scripts/render-app-icon.sh to write every size into the asset catalog.
//

import AppKit
import SwiftUI

// The ring comes from the real sketch engine at screen scale (so its wobble has
// the same character as on screen) and is scaled up for the icon.
let ringScale: CGFloat = 4.0
let circledElementRect = CGRect(x: 312, y: 352, width: 300, height: 128)
let ringCanvasSize = CGSize(width: 256, height: 256)
let ringDrawing = ScreenSketchGeometry.makeDrawing(
    kind: .circle,
    localPoints: [
        CGPoint(x: circledElementRect.minX / ringScale, y: circledElementRect.minY / ringScale),
        CGPoint(x: circledElementRect.maxX / ringScale, y: circledElementRect.maxY / ringScale),
    ],
    label: nil, inkColor: .orange, canvasSize: ringCanvasSize, seed: 11, isOverDarkBackground: true)

/// An arrowhead with a notched back, pointing up: unmistakably a pointer at icon size.
struct NotchedPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + unitX * rect.width / 2, y: rect.midY + unitY * rect.height / 2)
        }
        var pointerPath = Path()
        pointerPath.move(to: point(0, -0.9))
        pointerPath.addLine(to: point(0.56, 0.78))
        pointerPath.addLine(to: point(0, 0.42))
        pointerPath.addLine(to: point(-0.56, 0.78))
        pointerPath.closeSubpath()
        return pointerPath
    }
}

struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824pt body centered in 1024, continuous corners
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.135, green: 0.15, blue: 0.145), Color(red: 0.055, green: 0.063, blue: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)

            // The thing being pointed out: a small button on someone's screen
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 0.25, green: 0.27, blue: 0.265))
                .overlay(
                    Capsule().fill(Color.white.opacity(0.55)).frame(width: 150, height: 22)
                )
                .frame(width: circledElementRect.width - 54, height: circledElementRect.height - 34)
                .position(x: circledElementRect.midX, y: circledElementRect.midY)

            Canvas { context, _ in
                context.scaleBy(x: ringScale, y: ringScale)
                for stroke in ringDrawing.strokes {
                    var ringPath = Path(); ringPath.addLines(stroke.points)
                    context.drawLayer { glowContext in
                        glowContext.addFilter(.shadow(color: Color(red: 1, green: 0.58, blue: 0).opacity(0.5), radius: 3))
                        glowContext.stroke(ringPath, with: .color(ScreenSketchInkColor.orange.swiftUIColor), style: StrokeStyle(lineWidth: 5.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: 1024, height: 1024)

            // The cursor, just below and right of the ring, pointing at it
            NotchedPointerShape()
                .fill(DS.Colors.overlayCursorBlue)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.85), radius: 30)
                .frame(width: 250, height: 250)
                .rotationEffect(.degrees(-40))
                .position(x: 660, y: 650)
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: AppIconArtwork())
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else { fatalError("render failed") }
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    for pixelSize in [16, 32, 64, 128, 256, 512, 1024] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: NSSize(width: 1024, height: 1024)).draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(pixelSize)-mac.png"))
    }
    print("icons written")
}
