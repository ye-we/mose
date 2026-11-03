//
//  DevilModeActionPerformer.swift
//  leanring-buddy
//
//  Does devil mode's actions on the real Mac: posts clicks, drags, scrolls
//  and keys as CGEvents (the Accessibility permission Mose already has for
//  its hotkeys covers this), types by key or by paste, and watches for the
//  user taking over (Esc, or their own mouse) so a run stops at once.
//
//  Every event posted here carries DevilModeEventMark, so Mose's own input is
//  never mistaken for the user's.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Posting events

@MainActor
enum DevilModeEventPoster {
    /// Where the mouse should be (Quartz global coordinates): where Mose last
    /// put it, or where it was when the run started. The takeover monitor
    /// only counts the user's mouse as moving once it gets away from here.
    private(set) static var expectedQuartzMouseLocation: CGPoint?

    /// A run is starting: the pointer belongs where the user left it.
    static func expectMouseToStayWhereItIs() {
        expectedQuartzMouseLocation = CGEvent(source: nil)?.location
    }

    /// Short pauses between the events of one action, so apps see a mouse
    /// that moved, then pressed, then let go, like a hand.
    private static let pauseBetweenEventsNanoseconds: UInt64 = 35_000_000
    private static let pauseBetweenTypedKeysNanoseconds: UInt64 = 18_000_000

    private static func makeMarkedEventSource() -> CGEventSource? {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        eventSource?.userData = DevilModeEventMark.eventSourceUserData
        return eventSource
    }

    /// Marks and posts one event. The source already carries the mark; it's
    /// set on the event too, so it survives however the event was made.
    private static func postMarked(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: DevilModeEventMark.eventSourceUserData)
        event.post(tap: .cghidEventTap)
        if [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp].contains(event.type) {
            expectedQuartzMouseLocation = event.location
        }
    }

    private static func mouseEvent(_ mouseEventType: CGEventType, at quartzPoint: CGPoint, button mouseButton: CGMouseButton = .left, clickState: Int64 = 1) -> CGEvent? {
        let mouseEvent = CGEvent(
            mouseEventSource: makeMarkedEventSource(),
            mouseType: mouseEventType,
            mouseCursorPosition: quartzPoint,
            mouseButton: mouseButton
        )
        mouseEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
        // No modifier the user happens to hold should turn a click into a cmd-click
        mouseEvent?.flags = []
        return mouseEvent
    }

    static func moveMouse(to quartzPoint: CGPoint) {
        postMarked(mouseEvent(.mouseMoved, at: quartzPoint))
    }

    static func click(_ clickKind: DevilModeClickKind, at quartzPoint: CGPoint) async throws {
        moveMouse(to: quartzPoint)
        try await Task.sleep(nanoseconds: pauseBetweenEventsNanoseconds)
        switch clickKind {
        case .click:
            postMarked(mouseEvent(.leftMouseDown, at: quartzPoint))
            try? await Task.sleep(nanoseconds: pauseBetweenEventsNanoseconds)
            postMarked(mouseEvent(.leftMouseUp, at: quartzPoint))
        case .doubleClick:
            // The click state is how apps tell a double-click from two clicks
            for clickState: Int64 in [1, 2] {
                postMarked(mouseEvent(.leftMouseDown, at: quartzPoint, clickState: clickState))
                try? await Task.sleep(nanoseconds: 20_000_000)
                postMarked(mouseEvent(.leftMouseUp, at: quartzPoint, clickState: clickState))
                if clickState == 1 {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }
        case .rightClick:
            postMarked(mouseEvent(.rightMouseDown, at: quartzPoint, button: .right))
            try? await Task.sleep(nanoseconds: pauseBetweenEventsNanoseconds)
            postMarked(mouseEvent(.rightMouseUp, at: quartzPoint, button: .right))
        }
    }

    /// Presses at the start, moves through the path, lets go at the end. If
    /// it's stopped halfway, the button is still let go, so the user is never
    /// left holding something they didn't pick up.
    static func drag(from startQuartzPoint: CGPoint, to endQuartzPoint: CGPoint) async throws {
        moveMouse(to: startQuartzPoint)
        try await Task.sleep(nanoseconds: pauseBetweenEventsNanoseconds)
        postMarked(mouseEvent(.leftMouseDown, at: startQuartzPoint))
        do {
            // Hold a moment first: some apps wait before they start a drag
            try await Task.sleep(nanoseconds: 120_000_000)
            let dragDistance = hypot(endQuartzPoint.x - startQuartzPoint.x, endQuartzPoint.y - startQuartzPoint.y)
            let dragStepCount = max(12, min(40, Int(dragDistance / 15)))
            for dragPathPoint in DevilModeScreenCoordinates.dragPathPoints(from: startQuartzPoint, to: endQuartzPoint, stepCount: dragStepCount) {
                postMarked(mouseEvent(.leftMouseDragged, at: dragPathPoint))
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            // Let the drop target notice the item before letting go
            try await Task.sleep(nanoseconds: 120_000_000)
            postMarked(mouseEvent(.leftMouseUp, at: endQuartzPoint))
        } catch {
            let currentQuartzMouseLocation = CGEvent(source: nil)?.location ?? endQuartzPoint
            postMarked(mouseEvent(.leftMouseUp, at: currentQuartzMouseLocation))
            throw error
        }
    }

    /// Scrolls the view under the point by whole lines; positive is down.
    static func scroll(at quartzPoint: CGPoint, lineCount: Int) async throws {
        moveMouse(to: quartzPoint)
        try await Task.sleep(nanoseconds: pauseBetweenEventsNanoseconds)
        // A wheel event's positive delta scrolls up, so "down" is negative.
        // A few lines at a time, so it reads as scrolling rather than a jump.
        var linesLeftToScroll = abs(lineCount)
        let scrollDirection: Int32 = lineCount > 0 ? -1 : 1
        while linesLeftToScroll > 0 {
            let linesThisEvent = min(3, linesLeftToScroll)
            postMarked(CGEvent(
                scrollWheelEvent2Source: makeMarkedEventSource(),
                units: .line,
                wheelCount: 1,
                wheel1: scrollDirection * Int32(linesThisEvent),
                wheel2: 0,
                wheel3: 0
            ))
            linesLeftToScroll -= linesThisEvent
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    static func pressKeys(_ keyShortcut: DevilModeKeyShortcut) async throws {
        let keyDownEvent = CGEvent(keyboardEventSource: makeMarkedEventSource(), virtualKey: keyShortcut.virtualKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: makeMarkedEventSource(), virtualKey: keyShortcut.virtualKeyCode, keyDown: false)
        keyDownEvent?.flags = keyShortcut.eventFlags
        keyUpEvent?.flags = keyShortcut.eventFlags
        postMarked(keyDownEvent)
        try? await Task.sleep(nanoseconds: 30_000_000)
        postMarked(keyUpEvent)
    }

    /// Short text goes in key by key, longer text is pasted (with the
    /// clipboard put back afterwards, as dictation does).
    static func type(_ text: String) async throws {
        if DevilModeTyping.shouldPaste(text) {
            FocusedFieldTextInserter.typeIntoFocusedField(text)
            // Paste restores the clipboard after 0.6s; don't start anything
            // else that might use it before then
            try await Task.sleep(nanoseconds: 700_000_000)
            return
        }
        for keystrokeUnits in DevilModeTyping.keystrokeUnits(of: text) {
            try Task.checkCancellation()
            let keyDownEvent = CGEvent(keyboardEventSource: makeMarkedEventSource(), virtualKey: 0, keyDown: true)
            let keyUpEvent = CGEvent(keyboardEventSource: makeMarkedEventSource(), virtualKey: 0, keyDown: false)
            for keyEvent in [keyDownEvent, keyUpEvent] {
                keyEvent?.flags = []
                keyEvent?.keyboardSetUnicodeString(stringLength: keystrokeUnits.count, unicodeString: keystrokeUnits)
            }
            postMarked(keyDownEvent)
            postMarked(keyUpEvent)
            try await Task.sleep(nanoseconds: pauseBetweenTypedKeysNanoseconds)
        }
    }
}

// MARK: - Looking at the Mac before acting

@MainActor
enum DevilModeScreenInspector {
    /// macOS turns this on while a password field has focus, and then won't
    /// let other apps see or post keys there. Mose doesn't try to type then.
    static func isSecureTextInputOn() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Whether the window under a point (Quartz global coordinates) is one of
    /// Mose's own, skipping its overlay windows, which cover every screen.
    static func isOwnWindow(atQuartzPoint quartzPoint: CGPoint, overlayWindowNumbers: Set<Int>) -> Bool {
        let windowInfo = windowInfo(atQuartzPoint: quartzPoint, overlayWindowNumbers: overlayWindowNumbers)
        return windowInfo?[kCGWindowOwnerPID as String] as? pid_t == ProcessInfo.processInfo.processIdentifier
    }

    /// The name of the app whose window is under a point, for live tests that
    /// only allow the practice window.
    static func ownerNameOfWindow(atQuartzPoint quartzPoint: CGPoint, overlayWindowNumbers: Set<Int>) -> String? {
        windowInfo(atQuartzPoint: quartzPoint, overlayWindowNumbers: overlayWindowNumbers)?[kCGWindowOwnerName as String] as? String
    }

    /// The frontmost window that contains the point, other than the overlay.
    /// Window owners and bounds don't need any permission.
    private static func windowInfo(atQuartzPoint quartzPoint: CGPoint, overlayWindowNumbers: Set<Int>) -> [String: Any]? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // Front to back, so the first window that contains the point is the one clicked
        return windowInfoList.first { windowInfo in
            guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                  !overlayWindowNumbers.contains(windowNumber),
                  (windowInfo[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: windowBoundsDictionary) else { return false }
            return windowBounds.contains(quartzPoint)
        }
    }

    /// The app keys and typing would go to, with its front window's title
    /// (window titles are readable with the Screen Recording permission).
    static func frontmostAppContext() -> DevilModeAppContext {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        var frontWindowTitle: String?
        if let frontmostProcessIdentifier = frontmostApplication?.processIdentifier,
           let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            frontWindowTitle = windowInfoList.first { windowInfo in
                windowInfo[kCGWindowOwnerPID as String] as? pid_t == frontmostProcessIdentifier
                    && windowInfo[kCGWindowLayer as String] as? Int == 0
            }?[kCGWindowName as String] as? String
        }
        return DevilModeAppContext(
            bundleIdentifier: frontmostApplication?.bundleIdentifier,
            appName: frontmostApplication?.localizedName,
            windowTitle: frontWindowTitle
        )
    }

    static func isMoseFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

// MARK: - Noticing the user taking over

/// While Mose drives, watches every key and mouse event (listen-only, so
/// nothing is blocked or changed) for Esc or the user's own mouse. Events
/// carrying Mose's mark are skipped.
final class DevilModeTakeoverMonitor {
    enum TakeoverReason: String {
        case escapeKey = "pressed Esc"
        case userMovedMouse = "moved the mouse"
        case userClicked = "clicked"
        case userScrolled = "scrolled"

        /// Said when the run stops, with the reason, so a stop the user
        /// didn't mean to cause can be told apart.
        var spokenStopNotice: String {
            switch self {
            case .escapeKey: return "Stopped."
            case .userMovedMouse: return "Stopped, you moved the mouse."
            case .userClicked: return "Stopped, you clicked."
            case .userScrolled: return "Stopped, you scrolled."
            }
        }
    }

    /// Called on the main thread, once per takeover, with the reason and the
    /// event's details for the log.
    var onUserTookOver: ((TakeoverReason, String) -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?

    var isRunning: Bool { eventTap != nil }

    func start() {
        guard eventTap == nil else { return }
        let watchedEventTypes: [CGEventType] = [
            .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]
        let eventMask = watchedEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }
        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let takeoverMonitor = Unmanaged<DevilModeTakeoverMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            takeoverMonitor.handle(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            print("⚠️ Devil mode: couldn't watch for the user taking over")
            return
        }
        eventTap = createdEventTap
        eventTapRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    deinit {
        stop()
    }

    /// Runs on the main run loop (where the tap's source was added).
    private func handle(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        let eventSourceProcessIdentifier = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard !DevilModeTakeoverRule.isMosesOwnEvent(
            eventSourceUserData: event.getIntegerValueField(.eventSourceUserData),
            eventSourceProcessIdentifier: eventSourceProcessIdentifier,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ) else { return }
        let expectedQuartzMouseLocation = MainActor.assumeIsolated { DevilModeEventPoster.expectedQuartzMouseLocation }

        let takeoverReason: TakeoverReason?
        switch eventType {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            takeoverReason = keyCode == DevilModeKeyShortcutParser.escapeKeyCode ? .escapeKey : nil
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let isUserMovingTheMouse = expectedQuartzMouseLocation.map {
                DevilModeTakeoverRule.isUserMovingTheMouse(eventLocation: event.location, expectedMouseLocation: $0)
            } ?? true
            takeoverReason = isUserMovingTheMouse ? .userMovedMouse : nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            takeoverReason = .userClicked
        case .scrollWheel:
            takeoverReason = .userScrolled
        default:
            takeoverReason = nil
        }
        guard let takeoverReason else { return }
        let expectedLocationText = expectedQuartzMouseLocation.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "unknown"
        let eventDetails = "event type \(eventType.rawValue) at (\(Int(event.location.x)),\(Int(event.location.y))), mouse expected at \(expectedLocationText), from process \(eventSourceProcessIdentifier)"
        onUserTookOver?(takeoverReason, eventDetails)
    }
}
