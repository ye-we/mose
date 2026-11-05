//
//  InkAndKeycapViews.swift
//  leanring-buddy
//
//  Small pieces shared by the setup window and the menu bar panel:
//
//  - InkMarkView: a hand-drawn check or ring, made by the same sketch engine
//    Clicky draws on the screen with, so the app's own windows speak the same
//    visual language as its marks. It draws itself with the pen when it
//    appears, which is the one piece of motion that marks progress.
//  - KeycapView: a shortcut key that visibly presses down while the user
//    holds it, so the hotkeys can be learned by trying them.
//  - The quiet row and choice controls the panel's settings are built from.
//

import SwiftUI

// MARK: - App identity

/// The product's name in one place, so renaming it is a one-line change.
enum AppIdentity {
    static let displayName = "Mose"
}

// MARK: - Colors used by setup and the panel

extension DS.Colors {
    /// The cursor's blue, used for primary actions so buttons match the companion.
    static let companionBlue = ScreenSketchInkColor.blue.swiftUIColor
    /// The marker orange of a guided-step target ring: "this is the next thing".
    static let nextStepInk = ScreenSketchInkColor.orange.swiftUIColor
    /// The marker green of an on-screen check: "this is done".
    static let doneInk = ScreenSketchInkColor.green.swiftUIColor
    /// Hairlines between rows; quieter than the card borders.
    static let hairline = Color.white.opacity(0.07)
}

// MARK: - Hand-drawn marks

/// A hand-drawn check or ring that the pen draws when the view appears.
struct InkMarkView: View {
    enum Mark {
        /// A check centered in the frame.
        case check
        /// A ring around the middle of the frame, inset by this much.
        case ring(inset: CGFloat)
    }

    let mark: Mark
    let inkColor: ScreenSketchInkColor
    /// Different seeds give different wobbles, so two checks never look stamped.
    let seed: UInt64
    var lineWidthScale: CGFloat = 1

    @State private var penStartDate = Date()
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled

    /// Snapshot renders show marks finished instead of mid-animation.
    nonisolated(unsafe) static var drawsFinishedMarksImmediately = false

    var body: some View {
        GeometryReader { geometry in
            let drawing = makeDrawing(in: geometry.size)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isFinishedDrawing(drawing))) { timeline in
                ScreenSketchLayer(activeSketchDrawings: [
                    ActiveScreenSketchDrawing(drawing: drawing, drawingProgress: drawingProgress(of: drawing, at: timeline.date))
                ])
            }
        }
        .onAppear { penStartDate = Date() }
        .accessibilityHidden(true)
    }

    private func makeDrawing(in canvasSize: CGSize) -> ScreenSketchDrawing {
        let markKind: ScreenSketchMarkKind
        let localPoints: [CGPoint]
        switch mark {
        case .check:
            markKind = .check
            // The engine draws a 24pt check whose center sits a little left of its visual middle
            localPoints = [CGPoint(x: canvasSize.width / 2 - 1, y: canvasSize.height / 2 + 2)]
        case .ring(let inset):
            markKind = .circle
            localPoints = [
                CGPoint(x: inset, y: inset),
                CGPoint(x: canvasSize.width - inset, y: canvasSize.height - inset),
            ]
        }
        let drawing = ScreenSketchGeometry.makeDrawing(
            kind: markKind,
            localPoints: localPoints,
            label: nil,
            inkColor: inkColor,
            canvasSize: canvasSize,
            seed: seed,
            isOverDarkBackground: true,
            id: Self.stableDrawingID(forSeed: seed)
        )
        guard lineWidthScale != 1 else { return drawing }
        return ScreenSketchDrawing(
            id: drawing.id,
            kind: drawing.kind,
            inkColor: drawing.inkColor,
            isOverDarkBackground: drawing.isOverDarkBackground,
            strokes: drawing.strokes.map { stroke in
                ScreenSketchStroke(points: stroke.points, lineWidth: stroke.lineWidth * lineWidthScale, isHighlighter: stroke.isHighlighter)
            },
            textLabel: drawing.textLabel,
            penSegments: drawing.penSegments,
            penSegmentDurations: drawing.penSegmentDurations,
            drawingDurationSeconds: drawing.drawingDurationSeconds
        )
    }

    private func drawingProgress(of drawing: ScreenSketchDrawing, at date: Date) -> Double {
        if isReduceMotionEnabled || Self.drawsFinishedMarksImmediately { return 1 }
        let elapsedSeconds = date.timeIntervalSince(penStartDate)
        return min(max(elapsedSeconds / max(drawing.drawingDurationSeconds, 0.01), 0), 1)
    }

    private func isFinishedDrawing(_ drawing: ScreenSketchDrawing) -> Bool {
        isReduceMotionEnabled || Self.drawsFinishedMarksImmediately
            || Date().timeIntervalSince(penStartDate) > drawing.drawingDurationSeconds + 0.1
    }

    /// The same seed always makes the same drawing id, so SwiftUI doesn't see
    /// a new drawing on every frame.
    private static func stableDrawingID(forSeed seed: UInt64) -> UUID {
        var seedBytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: seed.littleEndian) { rawSeedBytes in
            for (byteIndex, seedByte) in rawSeedBytes.enumerated() { seedBytes[byteIndex] = seedByte }
        }
        return UUID(uuid: (seedBytes[0], seedBytes[1], seedBytes[2], seedBytes[3], seedBytes[4], seedBytes[5], seedBytes[6], seedBytes[7],
                           seedBytes[8], seedBytes[9], seedBytes[10], seedBytes[11], seedBytes[12], seedBytes[13], seedBytes[14], seedBytes[15]))
    }
}

// MARK: - The companion's cursor

/// The cursor triangle, upright: equilateral, centred on its centroid, the
/// same shape as the overlay's cursor so Mose's face fits it the same way.
struct UprightCursorTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let triangleSide = min(rect.width, rect.height)
        let triangleHeight = triangleSide * sqrt(3.0) / 2.0
        var cursorPath = Path()
        cursorPath.move(to: CGPoint(x: rect.midX, y: rect.midY - triangleHeight / 1.5))
        cursorPath.addLine(to: CGPoint(x: rect.midX - triangleSide / 2, y: rect.midY + triangleHeight / 3))
        cursorPath.addLine(to: CGPoint(x: rect.midX + triangleSide / 2, y: rect.midY + triangleHeight / 3))
        cursorPath.closeSubpath()
        return cursorPath
    }
}

/// The app's mark at any size: Mose's blue cursor with its beard and eyes,
/// pointing up-left like the cursor on screen. The panel header, setup,
/// History, the step cards and the menu bar icon all use it.
struct CompanionCursorMark: View {
    var markSize: CGFloat = 28
    var hasGlow = true

    var body: some View {
        let triangleSide = markSize * 0.78
        ZStack {
            UprightCursorTriangleShape()
                .fill(DS.Colors.overlayCursorBlue)
            BeardedCursorFaceView()
        }
        .frame(width: triangleSide, height: triangleSide)
        .rotationEffect(.degrees(-35))
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(hasGlow ? 0.55 : 0), radius: markSize * 0.25)
        .frame(width: markSize, height: markSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Mose's face on the cursor

/// Places points on an upright equilateral triangle filling `rect`, centred
/// on its centroid the way the overlay's `Triangle` draws the cursor. Points
/// are in the app icon's cursor units (tip at y = -0.92, base at y = 0.5,
/// base corners at x = ±0.8), so the face matches the icon.
struct BeardedCursorGeometry {
    let rect: CGRect

    var triangleSide: CGFloat { min(rect.width, rect.height) }
    var triangleHeight: CGFloat { triangleSide * sqrt(3.0) / 2.0 }
    /// How many points one horizontal unit is.
    var horizontalUnit: CGFloat { (triangleSide / 2) / 0.8 }

    func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint {
        CGPoint(
            x: rect.midX + unitX * horizontalUnit,
            y: rect.midY + triangleHeight / 3 + (unitY - 0.5) * (triangleHeight / 1.42)
        )
    }
}

/// The chin curtain on the cursor: short sideburns up the sides, round the
/// base corners and a little below the base, the face above it bare.
struct BeardedCursorBeardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cursorGeometry = BeardedCursorGeometry(rect: rect)
        func point(_ unitX: CGFloat, _ unitY: CGFloat) -> CGPoint { cursorGeometry.point(unitX, unitY) }
        var beardPath = Path()
        beardPath.move(to: point(-0.64, 0.18))
        beardPath.addLine(to: point(-0.85, 0.5))
        beardPath.addCurve(to: point(0, 0.68), control1: point(-0.78, 0.66), control2: point(-0.34, 0.68))
        beardPath.addCurve(to: point(0.85, 0.5), control1: point(0.34, 0.68), control2: point(0.78, 0.66))
        beardPath.addLine(to: point(0.64, 0.18))
        beardPath.addLine(to: point(0.53, 0.18))
        beardPath.addCurve(to: point(0, 0.42), control1: point(0.5, 0.36), control2: point(0.24, 0.42))
        beardPath.addCurve(to: point(-0.53, 0.18), control1: point(-0.24, 0.42), control2: point(-0.5, 0.36))
        beardPath.closeSubpath()
        return beardPath
    }
}

/// Mose's face, drawn over the blue cursor triangle in the same frame: the
/// beard, two eyes, and stern brows once the cursor is big enough for them
/// to read. Eyes are drawn larger than the icon's at small sizes, or they'd
/// vanish on a 16-point cursor.
struct BeardedCursorFaceView: View {
    // A warm mid brown rather than near black, so the beard still reads at
    // menu bar size against dark menu bars, panels and screens
    static let beardDarkBrown = Color(red: 0.3, green: 0.2, blue: 0.13)
    static let beardBrown = Color(red: 0.5, green: 0.34, blue: 0.22)
    private static let eyeColor = Color(red: 0.03, green: 0.06, blue: 0.16)

    var body: some View {
        GeometryReader { geometryProxy in
            let cursorGeometry = BeardedCursorGeometry(rect: CGRect(origin: .zero, size: geometryProxy.size))
            let isLargeEnoughForBrows = cursorGeometry.triangleSide >= 28
            let eyeDiameter = max(cursorGeometry.horizontalUnit * 0.14, 2.3)
            ZStack {
                BeardedCursorBeardShape()
                    .fill(LinearGradient(colors: [Self.beardBrown, Self.beardDarkBrown], startPoint: .top, endPoint: .bottom))
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Ellipse()
                        .fill(Self.eyeColor)
                        .frame(width: eyeDiameter, height: eyeDiameter * 0.82)
                        .position(cursorGeometry.point(side * 0.22, -0.08))
                    if isLargeEnoughForBrows {
                        Capsule()
                            .fill(Self.beardDarkBrown)
                            .frame(width: cursorGeometry.horizontalUnit * 0.22, height: cursorGeometry.horizontalUnit * 0.06)
                            .rotationEffect(.degrees(side * -9))
                            .position(cursorGeometry.point(side * 0.2, -0.21))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Keycaps

/// One key of a shortcut, drawn like a real key. It sinks and lights up
/// while it's held, so trying the shortcut shows it working.
struct KeycapView: View {
    let keySymbol: String
    let keyName: String
    var isPressed: Bool = false
    var keycapSize: KeycapSize = .regular

    enum KeycapSize {
        case compact
        case regular
        case large
    }

    var body: some View {
        let keycapMetrics = metrics
        VStack(spacing: keycapMetrics.labelSpacing) {
            Text(keySymbol)
                .font(.system(size: keycapMetrics.symbolSize, weight: .medium))
            if keycapSize != .compact {
                Text(keyName)
                    .font(.system(size: keycapMetrics.nameSize, weight: .medium))
                    .foregroundColor(isPressed ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            }
        }
        .foregroundColor(isPressed ? .white : DS.Colors.textSecondary)
        .frame(minWidth: keycapMetrics.width, minHeight: keycapMetrics.height)
        .padding(.horizontal, keycapSize == .compact ? 5 : 0)
        .background(
            ZStack(alignment: .top) {
                // The key's side, which disappears as it's pressed down
                RoundedRectangle(cornerRadius: keycapMetrics.cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .offset(y: isPressed ? 0 : keycapMetrics.sideDepth)
                RoundedRectangle(cornerRadius: keycapMetrics.cornerRadius, style: .continuous)
                    .fill(isPressed ? DS.Colors.companionBlue.opacity(0.9) : DS.Colors.surface3)
                RoundedRectangle(cornerRadius: keycapMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isPressed ? 0.25 : 0.09), lineWidth: 0.75)
            }
        )
        .offset(y: isPressed ? keycapMetrics.sideDepth : 0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyName)
    }

    private var metrics: (width: CGFloat, height: CGFloat, symbolSize: CGFloat, nameSize: CGFloat, labelSpacing: CGFloat, cornerRadius: CGFloat, sideDepth: CGFloat) {
        switch keycapSize {
        case .compact: return (22, 20, 11, 0, 0, 5, 1.5)
        case .regular: return (46, 40, 14, 9, 1, 7, 2.5)
        case .large: return (76, 64, 22, 11, 3, 11, 4)
        }
    }
}

/// The keys of a shortcut side by side.
struct ShortcutKeycaps: View {
    let keys: [(symbol: String, name: String)]
    var isPressed: Bool = false
    var keycapSize: KeycapView.KeycapSize = .regular

    var body: some View {
        HStack(spacing: keycapSize == .large ? 10 : 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeycapView(keySymbol: key.symbol, keyName: key.name, isPressed: isPressed, keycapSize: keycapSize)
            }
        }
    }

    static let talkKeys: [(symbol: String, name: String)] = [("⌃", "control"), ("⌥", "option")]
    static let dictateKeys: [(symbol: String, name: String)] = [("fn", "fn"), ("⌃", "control")]
}

// MARK: - Buttons

/// The one filled button on a screen: the thing to do next.
struct CompanionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(isEnabled ? 1 : 0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.companionBlue.opacity(isEnabled ? (isHovered ? 1 : 0.88) : 0.35))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovering in isHovered = isHovering }
                .pointerCursor()
        }
    }
}

/// A quiet button for secondary actions.
struct CompanionQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.1 : 0.06)))
                )
                .onHover { isHovering in isHovered = isHovering }
                .pointerCursor()
        }
    }
}

// MARK: - Switch

/// A switch that stays blue when on. The system switch turns grey whenever
/// the app isn't frontmost, and the menu bar panel never makes Clicky
/// frontmost, so on and off would look almost the same.
struct CompanionSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? DS.Colors.companionBlue : Color.white.opacity(0.14))
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Choice control

/// A small segmented choice ("Haiku · Sonnet · Opus") that fits a panel row.
struct CompactChoiceControl<ChoiceValue: Hashable>: View {
    let choices: [(label: String, value: ChoiceValue)]
    let selectedValue: ChoiceValue
    let onSelect: (ChoiceValue) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                ChoiceButton(
                    label: choice.label,
                    isSelected: choice.value == selectedValue,
                    action: { onSelect(choice.value) }
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private struct ChoiceButton: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : (isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering in isHovered = isHovering }
            .pointerCursor()
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
