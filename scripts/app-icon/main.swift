//
//  scripts/app-icon/main.swift
//
//  Draws the app icon: Mose's blue cursor as a character, tilted the way the
//  cursor sits on screen, with stern brows, a deadpan stare and a chin-curtain
//  beard along its jaw (a full beard with no mustache, the look Mose is named
//  after), on a light background. Run scripts/render-app-icon.sh to write
//  every size into the asset catalog.
//

import AppKit
import SwiftUI

// Everything is laid out on the 1024 canvas; the icon body is the 824pt
// rounded square in the middle (the macOS icon grid).

/// Places points given on a unit canvas (the cursor's own coordinates,
/// tip at y = -0.92, base at y = 0.5) onto the 1024 icon canvas.
struct CursorCanvasPlacement {
    let centerX: CGFloat
    let centerY: CGFloat
    let scale: CGFloat

    func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
        CGPoint(x: centerX + unitX * scale, y: centerY + unitY * scale)
    }
}

let cursorPlacement = CursorCanvasPlacement(centerX: 520, centerY: 480, scale: 330)
let cursorTiltDegrees: Double = -20

/// The cursor: a triangle pointing up, with softly rounded corners.
func cursorTrianglePath(_ placement: CursorCanvasPlacement) -> Path {
    let tipVertex = placement.point(0, -0.92)
    let rightBaseVertex = placement.point(0.8, 0.5)
    let leftBaseVertex = placement.point(-0.8, 0.5)
    var trianglePath = Path()
    trianglePath.move(to: CGPoint(x: (tipVertex.x + leftBaseVertex.x) / 2, y: (tipVertex.y + leftBaseVertex.y) / 2))
    trianglePath.addArc(tangent1End: tipVertex, tangent2End: rightBaseVertex, radius: 37)
    trianglePath.addArc(tangent1End: rightBaseVertex, tangent2End: leftBaseVertex, radius: 46)
    trianglePath.addArc(tangent1End: leftBaseVertex, tangent2End: tipVertex, radius: 46)
    trianglePath.closeSubpath()
    return trianglePath
}

/// The chin curtain: short sideburns up the two sides, round the base
/// corners and a little below the base, with the cheeks and upper lip bare.
func chinCurtainBeardPath(_ placement: CursorCanvasPlacement) -> Path {
    var beardPath = Path()
    // Outer edge
    beardPath.move(to: placement.point(-0.64, 0.18))
    beardPath.addLine(to: placement.point(-0.85, 0.5))
    beardPath.addCurve(to: placement.point(0, 0.68), control1: placement.point(-0.78, 0.66), control2: placement.point(-0.34, 0.68))
    beardPath.addCurve(to: placement.point(0.85, 0.5), control1: placement.point(0.34, 0.68), control2: placement.point(0.78, 0.66))
    beardPath.addLine(to: placement.point(0.64, 0.18))
    // Inner edge: thin at the sideburns, a U under the mouth
    beardPath.addLine(to: placement.point(0.53, 0.18))
    beardPath.addCurve(to: placement.point(0, 0.45), control1: placement.point(0.5, 0.38), control2: placement.point(0.24, 0.45))
    beardPath.addCurve(to: placement.point(-0.53, 0.18), control1: placement.point(-0.24, 0.45), control2: placement.point(-0.5, 0.38))
    beardPath.closeSubpath()
    return beardPath
}

/// Wavy strands drawn over the beard (clipped to it), so it reads as hair.
func beardStrandsPath() -> Path {
    var strandsPath = Path()
    var strandX: CGFloat = 150
    var strandIndex = 0
    while strandX <= 880 {
        let swayDirection: CGFloat = strandIndex % 2 == 0 ? 1 : -1
        strandsPath.move(to: CGPoint(x: strandX, y: 300))
        strandsPath.addCurve(
            to: CGPoint(x: strandX + swayDirection * 4.8, y: 900),
            control1: CGPoint(x: strandX + swayDirection * 12, y: 500),
            control2: CGPoint(x: strandX - swayDirection * 12, y: 700)
        )
        strandX += 20
        strandIndex += 1
    }
    return strandsPath
}

struct AppIconArtwork: View {
    private let cursorGlowBlue = Color(red: 0.2, green: 0.5, blue: 1.0)
    private let featureColor = Color(red: 0.03, green: 0.06, blue: 0.16)
    private let beardDarkBrown = Color(red: 0.085, green: 0.065, blue: 0.05)
    private let beardBrown = Color(red: 0.24, green: 0.17, blue: 0.12)
    private let beardStrandBrown = Color(red: 0.42, green: 0.31, blue: 0.22)

    var body: some View {
        ZStack {
            // macOS icon grid: an 824pt body centered in 1024, continuous corners
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(RadialGradient(
                    colors: [Color(red: 1.0, green: 0.98, blue: 0.94), Color(red: 0.88, green: 0.9, blue: 0.95)],
                    center: UnitPoint(x: 0.45, y: 0.3), startRadius: 40, endRadius: 640))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)

            ZStack {
                // The cursor, in its blue, with its glow
                cursorTrianglePath(cursorPlacement)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.52, green: 0.74, blue: 1.0), cursorGlowBlue, Color(red: 0.1, green: 0.31, blue: 0.84)],
                        startPoint: UnitPoint(x: 0.35, y: 0.15), endPoint: UnitPoint(x: 0.6, y: 0.8)))
                    .shadow(color: cursorGlowBlue.opacity(0.35), radius: 18)
                // A soft highlight along its edges
                cursorTrianglePath(cursorPlacement)
                    .stroke(Color.white.opacity(0.35), lineWidth: 10)
                    .blur(radius: 6)
                    .mask(cursorTrianglePath(cursorPlacement))

                // Stern brows (inner ends lower), deadpan eyes with a catchlight, a flat mouth
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule()
                        .fill(beardDarkBrown)
                        .frame(width: cursorPlacement.scale * 0.22, height: cursorPlacement.scale * 0.06)
                        .rotationEffect(.degrees(side * -9))
                        .position(cursorPlacement.point(side * 0.2, -0.19))
                    ZStack {
                        Ellipse()
                            .fill(featureColor)
                            .frame(width: cursorPlacement.scale * 0.13, height: cursorPlacement.scale * 0.1)
                        Circle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: cursorPlacement.scale * 0.035, height: cursorPlacement.scale * 0.035)
                            .offset(x: -cursorPlacement.scale * 0.025, y: -cursorPlacement.scale * 0.02)
                    }
                    .position(cursorPlacement.point(side * 0.2, -0.06))
                }
                Capsule()
                    .fill(featureColor)
                    .frame(width: cursorPlacement.scale * 0.22, height: cursorPlacement.scale * 0.042)
                    .position(cursorPlacement.point(0, 0.27))

                ZStack {
                    chinCurtainBeardPath(cursorPlacement)
                        .fill(LinearGradient(colors: [beardBrown, beardDarkBrown], startPoint: .top, endPoint: .bottom))
                    beardStrandsPath()
                        .stroke(beardStrandBrown.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .mask(chinCurtainBeardPath(cursorPlacement))
            }
            .frame(width: 1024, height: 1024)
            // Tilted like the cursor on screen
            .rotationEffect(.degrees(cursorTiltDegrees), anchor: UnitPoint(x: cursorPlacement.centerX / 1024, y: cursorPlacement.centerY / 1024))
            .offset(x: 10, y: 20)
            .mask(RoundedRectangle(cornerRadius: 186, style: .continuous).frame(width: 824, height: 824))

            // A faint rim, as macOS icons have
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 3)
                .frame(width: 824, height: 824)
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
