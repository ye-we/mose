//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
    /// Buddy is the pen: its tip traces a hand-drawn mark on the screen
    case drawingSketch
}

/// One thing for the buddy to do: fly to a point, or draw a mark.
private enum OverlayVisualBeat {
    case point(screenLocation: CGPoint, bubbleText: String?)
    case sketch(CompanionManager.ResolvedSketchBeat)
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Visual Beat Queue

    /// Points and marks waiting their turn. The buddy does one at a time, so a
    /// beat that arrives mid-flight or mid-drawing never cuts the current one short.
    @State private var pendingVisualBeats: [OverlayVisualBeat] = []
    @State private var isPerformingVisualBeat: Bool = false
    /// Incremented for every beat performed (and on cancel). Delayed callbacks
    /// (bubble streaming, hold timers, the pen) check it so leftovers from an
    /// earlier beat can't fade or fly away from a newer one.
    @State private var visualBeatGeneration: Int = 0

    // MARK: - Screen Sketching State

    /// Marks drawn on this screen, with how far the pen has drawn each one.
    @State private var activeSketchDrawings: [ActiveScreenSketchDrawing] = []
    /// Faded to 0 to wipe the drawings, then reset once they're removed.
    @State private var sketchLayerOpacity: Double = 1.0
    /// Moves the pen along a mark at 60fps while it draws.
    @State private var penDrawingTimer: Timer?

    /// True between the mouse going down and up while the user is drawing.
    @State private var isDrawingUserInkStroke = false

    /// Where the triangle's tip sits relative to its center at the resting
    /// -35° angle, so the tip (not the middle of the triangle) traces strokes.
    private let penTipOffsetFromTriangleCenter = CGPoint(x: -4.6, y: -6.6)

    /// Bubble text captured when the flight toward the current target started,
    /// so the next step of a walkthrough can't swap its label in mid-flight.
    @State private var bubbleTextForCurrentTarget: String?


    private let fullWelcomeMessage = "hey! i'm \(AppIdentity.displayName.lowercased())"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Clicky's hand-drawn marks sit under the cursor and its bubbles
            ScreenSketchLayer(activeSketchDrawings: activeSketchDrawings)
                .opacity(sketchLayerOpacity)

            // A guided walkthrough's steps, pinned in a corner away from the target
            GuidedStepCardsView(guidedStepCardDeck: companionManager.guidedStepCardDeck, screenFrame: screenFrame)

            // While devil mode clicks and types, on the screen the mouse is on
            if companionManager.isDevilModeDriving && isCursorOnThisScreen {
                DevilModeDrivingNoteView(
                    currentActionDescription: companionManager.devilModeCurrentActionDescription,
                    screenFrame: screenFrame
                )
            }

            // What the user draws while holding the talk hotkey, in red
            Canvas { graphicsContext, _ in
                for userInkStroke in companionManager.userInkStrokes where userInkStroke.count > 1 {
                    var userInkPath = Path()
                    userInkPath.addLines(userInkStroke.map { convertScreenPointToSwiftUICoordinates($0) })
                    graphicsContext.stroke(
                        userInkPath,
                        with: .color(Color(
                            .sRGB,
                            red: UserInkCompositor.userInkRedGreenBlue.red,
                            green: UserInkCompositor.userInkRedGreenBlue.green,
                            blue: UserInkCompositor.userInkRedGreenBlue.blue,
                            opacity: 0.9
                        )),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .allowsHitTesting(false)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle || companionManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        // Only active while the talk hotkey is held (the window ignores the
        // mouse otherwise): dragging draws the user's own ink
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { dragValue in
                    if !isDrawingUserInkStroke {
                        isDrawingUserInkStroke = true
                        companionManager.beginUserInkStroke(atGlobalLocation: convertSwiftUIPointToScreenCoordinates(dragValue.startLocation))
                    }
                    companionManager.continueUserInkStroke(toGlobalLocation: convertSwiftUIPointToScreenCoordinates(dragValue.location))
                }
                .onEnded { _ in
                    isDrawingUserInkStroke = false
                },
            including: companionManager.isAcceptingUserInk ? .all : .none
        )
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            penDrawingTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                // The target was cleared from outside (the user talked again or a
                // walkthrough was cancelled) while the buddy was still out
                // pointing, so bring it home.
                if newLocation == nil && buddyNavigationMode != .followingCursor && !isReturningToCursor {
                    stopVisualBeatsAndFlyHome()
                }
                return
            }

            guard isOnThisScreen(displayFrame: displayFrame) else {
                // The next beat of a walkthrough is on another monitor. Stand this
                // screen's buddy down without clearing the target the other
                // screen's buddy is about to fly to.
                if buddyNavigationMode != .followingCursor {
                    handOffVisualBeatsToAnotherScreen()
                }
                return
            }

            enqueueVisualBeat(.point(
                screenLocation: screenLocation,
                bubbleText: companionManager.detectedElementBubbleText
            ))
        }
        .onChange(of: companionManager.latestSketchBeat?.id) { _ in
            guard let sketchBeat = companionManager.latestSketchBeat else { return }

            guard isOnThisScreen(displayFrame: sketchBeat.displayFrame) else {
                if buddyNavigationMode != .followingCursor {
                    handOffVisualBeatsToAnotherScreen()
                }
                return
            }

            enqueueVisualBeat(.sketch(sketchBeat))
        }
        .onChange(of: companionManager.sketchClearGeneration) { _ in
            wipeSketchDrawings()
        }
        .onChange(of: companionManager.isVisualSequenceAwaitingNextBeat) { isAwaitingNextBeat in
            // The answer finished while the buddy was parked on its last beat
            // waiting for more: linger a moment, then fly home
            guard !isAwaitingNextBeat,
                  !isPerformingVisualBeat,
                  pendingVisualBeats.isEmpty,
                  buddyNavigationMode == .pointingAtTarget || buddyNavigationMode == .drawingSketch else { return }
            finishCurrentVisualBeat(lingerSecondsBeforeReturning: 1.5)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget, .drawingSketch:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    /// The inverse of convertScreenPointToSwiftUICoordinates.
    private func convertSwiftUIPointToScreenCoordinates(_ swiftUIPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: swiftUIPoint.x + screenFrame.origin.x,
            y: screenFrame.origin.y + screenFrame.height - swiftUIPoint.y
        )
    }

    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint, bubbleText: String?) {
        bubbleTextForCurrentTarget = bubbleText

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        let currentVisualBeatGeneration = visualBeatGeneration

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo
        // or a numbered walkthrough step) if available, otherwise fall back to a
        // random pointer phrase
        let pointerPhrase = bubbleTextForCurrentTarget
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(
            phrase: pointerPhrase,
            characterIndex: 0,
            visualBeatGeneration: currentVisualBeatGeneration
        ) {
            // All characters streamed — give the bubble a moment to be read,
            // then move on (3 seconds in total before flying home, as before)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard self.buddyNavigationMode == .pointingAtTarget,
                      self.visualBeatGeneration == currentVisualBeatGeneration else { return }
                self.finishCurrentVisualBeat(lingerSecondsBeforeReturning: 2.0)
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        visualBeatGeneration streamingVisualBeatGeneration: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget,
              visualBeatGeneration == streamingVisualBeatGeneration else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                visualBeatGeneration: streamingVisualBeatGeneration,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        resetNavigationStateWithoutClearingTarget()
        companionManager.clearDetectedElementLocation()
    }

    /// Puts this screen's buddy back into cursor-following mode but leaves the
    /// shared target alone, for when another screen's buddy is taking over.
    private func resetNavigationStateWithoutClearingTarget() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        stopPenDrawing()
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
    }

    // MARK: - Visual Beats

    private func isOnThisScreen(displayFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY)) || displayFrame == screenFrame
    }

    private func enqueueVisualBeat(_ visualBeat: OverlayVisualBeat) {
        pendingVisualBeats.append(visualBeat)
        if !isPerformingVisualBeat {
            performNextVisualBeat()
        }
    }

    /// Starts the next queued point or mark, flying straight from wherever the
    /// buddy is: the cursor, or the previous beat of a walkthrough.
    private func performNextVisualBeat() {
        guard !pendingVisualBeats.isEmpty else {
            isPerformingVisualBeat = false
            return
        }

        // Don't interrupt the welcome animation
        guard !showWelcome || welcomeText.isEmpty else {
            pendingVisualBeats.removeAll()
            isPerformingVisualBeat = false
            return
        }

        let nextVisualBeat = pendingVisualBeats.removeFirst()
        isPerformingVisualBeat = true
        visualBeatGeneration += 1
        stopPenDrawing()

        switch nextVisualBeat {
        case .point(let screenLocation, let bubbleText):
            startNavigatingToElement(screenLocation: screenLocation, bubbleText: bubbleText)
        case .sketch(let sketchBeat):
            startDrawingSketch(sketchBeat)
        }
    }

    /// Called once a point's bubble has been read or a mark is fully drawn.
    /// Goes straight to the next beat if one is waiting, stays parked if the
    /// walkthrough has more coming, and otherwise lingers, then flies home.
    private func finishCurrentVisualBeat(lingerSecondsBeforeReturning: Double) {
        if !pendingVisualBeats.isEmpty {
            performNextVisualBeat()
            return
        }

        isPerformingVisualBeat = false

        // Mid-walkthrough: stay parked here until the next beat arrives
        guard !companionManager.isVisualSequenceAwaitingNextBeat else { return }

        let finishedVisualBeatGeneration = visualBeatGeneration
        func isStillParkedOnFinishedBeat() -> Bool {
            visualBeatGeneration == finishedVisualBeatGeneration
                && !isPerformingVisualBeat
                && (buddyNavigationMode == .pointingAtTarget || buddyNavigationMode == .drawingSketch)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + lingerSecondsBeforeReturning) {
            guard isStillParkedOnFinishedBeat() else { return }
            self.navigationBubbleOpacity = 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard isStillParkedOnFinishedBeat() else { return }
                self.startFlyingBackToCursor()
            }
        }
    }

    /// Drops any queued beats and sends the buddy back to the cursor.
    private func stopVisualBeatsAndFlyHome() {
        pendingVisualBeats.removeAll()
        stopPenDrawing()
        visualBeatGeneration += 1
        isPerformingVisualBeat = false
        if buddyNavigationMode != .followingCursor && !isReturningToCursor {
            startFlyingBackToCursor()
        }
    }

    /// Another screen's buddy is taking over the walkthrough: finish any
    /// half-drawn mark here instantly and go back to following the cursor.
    private func handOffVisualBeatsToAnotherScreen() {
        pendingVisualBeats.removeAll()
        visualBeatGeneration += 1
        isPerformingVisualBeat = false
        for drawingIndex in activeSketchDrawings.indices {
            activeSketchDrawings[drawingIndex].drawingProgress = 1
        }
        resetNavigationStateWithoutClearingTarget()
    }

    // MARK: - Screen Sketching

    /// Lays out the mark for this screen, flies the buddy to where the pen
    /// starts, then traces it.
    private func startDrawingSketch(_ sketchBeat: CompanionManager.ResolvedSketchBeat) {
        let localPoints = sketchBeat.globalScreenPoints.map { convertScreenPointToSwiftUICoordinates($0) }

        // Seed the wobble from the beat's id so the mark is decided once
        let uuidBytes = sketchBeat.id.uuid
        let wobbleSeed = [uuidBytes.0, uuidBytes.1, uuidBytes.2, uuidBytes.3, uuidBytes.4, uuidBytes.5, uuidBytes.6, uuidBytes.7]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        let localLabelObstacleRects = sketchBeat.labelObstacleGlobalRects.map { globalRect -> CGRect in
            let firstCorner = convertScreenPointToSwiftUICoordinates(CGPoint(x: globalRect.minX, y: globalRect.minY))
            let secondCorner = convertScreenPointToSwiftUICoordinates(CGPoint(x: globalRect.maxX, y: globalRect.maxY))
            return CGRect(
                x: min(firstCorner.x, secondCorner.x),
                y: min(firstCorner.y, secondCorner.y),
                width: abs(secondCorner.x - firstCorner.x),
                height: abs(secondCorner.y - firstCorner.y)
            )
        }

        let sketchDrawing = ScreenSketchGeometry.makeDrawing(
            kind: sketchBeat.kind,
            localPoints: localPoints,
            label: sketchBeat.label,
            inkColor: sketchBeat.inkColor,
            canvasSize: screenFrame.size,
            seed: wobbleSeed,
            isOverDarkBackground: sketchBeat.isOverDarkBackground,
            labelObstacleRects: localLabelObstacleRects,
            id: sketchBeat.id
        )
        sketchLayerOpacity = 1.0
        activeSketchDrawings.append(ActiveScreenSketchDrawing(drawing: sketchDrawing, drawingProgress: 0))

        // Navigating hides any pointer bubble left from a previous beat
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false
        let currentVisualBeatGeneration = visualBeatGeneration

        animateBezierFlightArc(to: triangleCenter(forPenTip: sketchDrawing.penStartPoint)) {
            guard self.visualBeatGeneration == currentVisualBeatGeneration else { return }
            self.runPenAlongDrawing(withID: sketchDrawing.id)
        }
    }

    /// Moves the pen tip along the drawing at 60fps, inking it as it goes.
    private func runPenAlongDrawing(withID drawingID: UUID) {
        guard let drawingIndex = activeSketchDrawings.firstIndex(where: { $0.id == drawingID }) else {
            finishCurrentVisualBeat(lingerSecondsBeforeReturning: 1.0)
            return
        }
        let sketchDrawing = activeSketchDrawings[drawingIndex].drawing

        buddyNavigationMode = .drawingSketch
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0

        let drawingStartDate = Date()
        let currentVisualBeatGeneration = visualBeatGeneration
        penDrawingTimer?.invalidate()
        penDrawingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard self.visualBeatGeneration == currentVisualBeatGeneration,
                  let currentDrawingIndex = self.activeSketchDrawings.firstIndex(where: { $0.id == drawingID }) else {
                self.stopPenDrawing()
                return
            }

            let drawingProgress = min(Date().timeIntervalSince(drawingStartDate) / sketchDrawing.drawingDurationSeconds, 1)
            self.activeSketchDrawings[currentDrawingIndex].drawingProgress = drawingProgress
            self.cursorPosition = self.triangleCenter(forPenTip: sketchDrawing.penPoint(atProgress: drawingProgress))

            if drawingProgress >= 1 {
                self.stopPenDrawing()
                self.finishCurrentVisualBeat(lingerSecondsBeforeReturning: 1.0)
            }
        }
    }

    private func stopPenDrawing() {
        penDrawingTimer?.invalidate()
        penDrawingTimer = nil
    }

    private func triangleCenter(forPenTip penTipPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: penTipPoint.x - penTipOffsetFromTriangleCenter.x,
            y: penTipPoint.y - penTipOffsetFromTriangleCenter.y
        )
    }

    /// Fades every drawing out, and sends the buddy home if it was still
    /// out on a walkthrough.
    private func wipeSketchDrawings() {
        stopVisualBeatsAndFlyHome()

        guard !activeSketchDrawings.isEmpty else { return }
        let wipedDrawingIDs = Set(activeSketchDrawings.map(\.id))
        withAnimation(.easeOut(duration: 0.3)) {
            sketchLayerOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.activeSketchDrawings.removeAll { wipedDrawingIDs.contains($0.id) }
            self.sketchLayerOpacity = 1.0
        }
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    /// While the user holds the talk hotkey the overlay catches the mouse, so
    /// dragging draws on the screen instead of clicking the app underneath.
    func setAcceptsMouseInput(_ shouldAcceptMouseInput: Bool) {
        for window in overlayWindows {
            window.ignoresMouseEvents = !shouldAcceptMouseInput
        }
    }

    /// The overlay windows cover every screen, so devil mode skips them when
    /// it checks whose window is under a click.
    var overlayWindowNumbers: Set<Int> {
        Set(overlayWindows.map(\.windowNumber))
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
