//
//  scripts/app-icon/main.swift
//
//  Draws the app icon: Mose, a mascot head in the companion's cursor blue
//  with straight dark bangs, a deadpan stare and a chin-curtain beard (a
//  full beard along the jaw, no mustache), the look Mose is named after.
//  It's a mascot, not anyone's likeness. Run scripts/render-app-icon.sh to
//  write every size into the asset catalog.
//

import AppKit
import SwiftUI

// Everything is laid out on the 1024 canvas; the icon body is the 824pt
// rounded square in the middle (the macOS icon grid).

/// The head: wide at the temples, narrowing to a rounded jaw.
struct HeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var headPath = Path()
        headPath.move(to: CGPoint(x: 512, y: 236))
        // Crown to the temples
        headPath.addCurve(to: CGPoint(x: 730, y: 470), control1: CGPoint(x: 650, y: 236), control2: CGPoint(x: 730, y: 330))
        // Down the cheek to the jaw
        headPath.addCurve(to: CGPoint(x: 512, y: 800), control1: CGPoint(x: 730, y: 640), control2: CGPoint(x: 640, y: 800))
        headPath.addCurve(to: CGPoint(x: 294, y: 470), control1: CGPoint(x: 384, y: 800), control2: CGPoint(x: 294, y: 640))
        headPath.addCurve(to: CGPoint(x: 512, y: 236), control1: CGPoint(x: 294, y: 330), control2: CGPoint(x: 374, y: 236))
        headPath.closeSubpath()
        return headPath
    }
}

/// Straight, heavy bangs cut in one line across the forehead, falling to
/// short sideburns that meet the beard.
struct HairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var hairPath = Path()
        hairPath.move(to: CGPoint(x: 278, y: 500))
        // Up the left side and over the crown, a little outside the head for volume
        hairPath.addCurve(to: CGPoint(x: 512, y: 214), control1: CGPoint(x: 268, y: 330), control2: CGPoint(x: 360, y: 214))
        hairPath.addCurve(to: CGPoint(x: 746, y: 500), control1: CGPoint(x: 664, y: 214), control2: CGPoint(x: 756, y: 330))
        // The right sideburn, then the fringe: one straight cut, slightly tilted
        hairPath.addLine(to: CGPoint(x: 706, y: 500))
        hairPath.addLine(to: CGPoint(x: 700, y: 392))
        // A few strands along the cut, so it reads as hair rather than a helmet
        for (strandX, strandY) in [(652.0, 405.0), (612.0, 397.0), (556.0, 407.0), (500.0, 398.0), (444.0, 407.0), (392.0, 399.0)] {
            hairPath.addLine(to: CGPoint(x: strandX, y: strandY))
        }
        hairPath.addLine(to: CGPoint(x: 330, y: 404))
        hairPath.addLine(to: CGPoint(x: 318, y: 500))
        hairPath.closeSubpath()
        return hairPath
    }
}

/// The chin curtain: from the sideburns down along the jaw and full under
/// the chin, with the cheeks and upper lip shaved (no mustache).
struct ChinCurtainBeardShape: Shape {
    func path(in rect: CGRect) -> Path {
        var beardPath = Path()
        // Outer edge: just outside the jaw, hanging below the chin
        beardPath.move(to: CGPoint(x: 290, y: 496))
        beardPath.addCurve(to: CGPoint(x: 512, y: 850), control1: CGPoint(x: 288, y: 700), control2: CGPoint(x: 380, y: 850))
        beardPath.addCurve(to: CGPoint(x: 734, y: 496), control1: CGPoint(x: 644, y: 850), control2: CGPoint(x: 736, y: 700))
        // Inner edge: thin at the sideburns, a deep U under the mouth
        beardPath.addLine(to: CGPoint(x: 702, y: 496))
        beardPath.addCurve(to: CGPoint(x: 512, y: 742), control1: CGPoint(x: 700, y: 640), control2: CGPoint(x: 618, y: 742))
        beardPath.addCurve(to: CGPoint(x: 322, y: 496), control1: CGPoint(x: 406, y: 742), control2: CGPoint(x: 324, y: 640))
        beardPath.closeSubpath()
        return beardPath
    }
}

struct AppIconArtwork: View {
    private let hairAndBeardColors = [Color(red: 0.20, green: 0.15, blue: 0.11), Color(red: 0.09, green: 0.07, blue: 0.055)]
    private let faceFeatureColor = Color(red: 0.06, green: 0.09, blue: 0.2)

    var body: some View {
        ZStack {
            // macOS icon grid: an 824pt body centered in 1024, continuous corners
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                // Warm paper, like the screen Mose draws on, so the dark beard reads
                .fill(LinearGradient(colors: [Color(red: 0.97, green: 0.94, blue: 0.88), Color(red: 0.90, green: 0.85, blue: 0.76)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)

            // Ears, half under the sideburns
            Ellipse().fill(Color(red: 0.16, green: 0.42, blue: 0.92)).frame(width: 56, height: 96).position(x: 292, y: 520)
            Ellipse().fill(Color(red: 0.16, green: 0.42, blue: 0.92)).frame(width: 56, height: 96).position(x: 732, y: 520)

            // The face, in the cursor's blue with its glow
            HeadShape()
                .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.62, blue: 1.0), DS.Colors.overlayCursorBlue, Color(red: 0.13, green: 0.36, blue: 0.86)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.black.opacity(0.18), radius: 14, y: 8)

            // A deadpan stare: two small eyes under the fringe, a flat mouth
            Group {
                Ellipse().fill(faceFeatureColor).frame(width: 46, height: 34).position(x: 440, y: 478)
                Ellipse().fill(faceFeatureColor).frame(width: 46, height: 34).position(x: 584, y: 478)
                Capsule().fill(faceFeatureColor).frame(width: 92, height: 16).position(x: 512, y: 650)
            }

            ChinCurtainBeardShape()
                .fill(LinearGradient(colors: hairAndBeardColors, startPoint: .top, endPoint: .bottom))
            HairShape()
                .fill(LinearGradient(colors: hairAndBeardColors, startPoint: .top, endPoint: .bottom))
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
