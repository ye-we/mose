//
//  DevilMode.swift
//  leanring-buddy
//
//  Devil mode: Mose clicks, drags, scrolls and types for the user instead of
//  only showing them where to click. Claude asks for each action with a tag
//  ([CLICK:...], [DOUBLECLICK:...], [RIGHTCLICK:...], [DRAG:...],
//  [SCROLL:...], [TYPE:...], [KEY:...]), one step at a time, like guided steps.
//
//  This file is the pure part (no events are posted here), so the standalone
//  tests cover it: the tag parser, the shortcut parser, which actions of an
//  answer get done, the safety checks (risky actions, chat and mail apps,
//  the user's yes or no), the step budget, coordinate conversion and the
//  wording of follow-ups. DevilModeActionPerformer.swift posts the events.
//

import CoreGraphics
import Foundation

// MARK: - The mark on Mose's own events

enum DevilModeEventMark {
    /// Every event Mose posts carries this in `.eventSourceUserData` ("Mose"
    /// in ASCII), so its own clicks never count as the user's: not as a
    /// guided-step click, not as "the user took over, stop", and not as input
    /// that wipes drawings.
    static let eventSourceUserData: Int64 = 0x4D6F7365
}

// MARK: - Actions

enum DevilModeClickKind: String, Equatable {
    case click
    case doubleClick
    case rightClick
}

enum DevilModeAction: Equatable {
    /// Clicks the middle of a box in screenshot pixels, a tight box around
    /// the thing like a guided-step target, so it can be snapped onto the
    /// text its label names.
    case click(kind: DevilModeClickKind, screenshotRect: CGRect, label: String?, screenNumber: Int?)
    case drag(fromScreenshotPoint: CGPoint, toScreenshotPoint: CGPoint, label: String?, screenNumber: Int?)
    /// Positive lines scroll down (to see more below), negative scroll up.
    case scroll(atScreenshotPoint: CGPoint, lineCount: Int, screenNumber: Int?)
    case typeText(String)
    case pressKeys(DevilModeKeyShortcut)

    /// Clicks, drags and scrolls happen at a place on the screen; typing and
    /// keys go to whatever has keyboard focus.
    var isPointerAction: Bool {
        switch self {
        case .click, .drag, .scroll: return true
        case .typeText, .pressKeys: return false
        }
    }

    var screenNumber: Int? {
        switch self {
        case .click(_, _, _, let screenNumber), .drag(_, _, _, let screenNumber), .scroll(_, _, let screenNumber):
            return screenNumber
        case .typeText, .pressKeys:
            return nil
        }
    }

    /// The words that say what the action is about, checked for risky ones:
    /// the label of a click or drag, or the typed text.
    var labelOrTypedText: String? {
        switch self {
        case .click(_, _, let label, _), .drag(_, _, let label, _):
            return label
        case .typeText(let typedText):
            return typedText
        case .scroll, .pressKeys:
            return nil
        }
    }

    /// For the follow-up to Claude: "clicked export", "typed "hello"".
    var pastTenseDescription: String {
        switch self {
        case .click(let kind, _, let label, _):
            return "\(Self.clickVerb(kind, tense: .past)) \(label ?? "there")"
        case .drag(_, _, let label, _):
            return "dragged \(label ?? "from there to there")"
        case .scroll(_, let lineCount, _):
            return lineCount >= 0 ? "scrolled down" : "scrolled up"
        case .typeText(let typedText):
            return "typed \"\(Self.shortenedForSpeech(typedText))\""
        case .pressKeys(let keyShortcut):
            return "pressed \(keyShortcut.displayText)"
        }
    }

    /// For the note in the overlay while it happens: "Clicking export".
    var progressiveDescription: String {
        let lowercaseDescription: String
        switch self {
        case .click(let kind, _, let label, _):
            lowercaseDescription = "\(Self.clickVerb(kind, tense: .progressive)) \(label ?? "there")"
        case .drag(_, _, let label, _):
            lowercaseDescription = "dragging \(label ?? "")".trimmingCharacters(in: .whitespaces)
        case .scroll(_, let lineCount, _):
            lowercaseDescription = lineCount >= 0 ? "scrolling down" : "scrolling up"
        case .typeText(let typedText):
            lowercaseDescription = "typing \"\(Self.shortenedForSpeech(typedText))\""
        case .pressKeys(let keyShortcut):
            lowercaseDescription = "pressing \(keyShortcut.displayText)"
        }
        return lowercaseDescription.prefix(1).uppercased() + lowercaseDescription.dropFirst()
    }

    /// For asking before a risky action: "click send message".
    var imperativeDescription: String {
        switch self {
        case .click(let kind, _, let label, _):
            return "\(Self.clickVerb(kind, tense: .imperative)) \(label ?? "there")"
        case .drag(_, _, let label, _):
            return "drag \(label ?? "that")"
        case .scroll(_, let lineCount, _):
            return lineCount >= 0 ? "scroll down" : "scroll up"
        case .typeText(let typedText):
            return "type \"\(Self.shortenedForSpeech(typedText))\""
        case .pressKeys(let keyShortcut):
            return "press \(keyShortcut.displayText)"
        }
    }

    private enum VerbTense { case past, progressive, imperative }

    private static func clickVerb(_ clickKind: DevilModeClickKind, tense: VerbTense) -> String {
        switch (clickKind, tense) {
        case (.click, .past): return "clicked"
        case (.click, .progressive): return "clicking"
        case (.click, .imperative): return "click"
        case (.doubleClick, .past): return "double-clicked"
        case (.doubleClick, .progressive): return "double-clicking"
        case (.doubleClick, .imperative): return "double-click"
        case (.rightClick, .past): return "right-clicked"
        case (.rightClick, .progressive): return "right-clicking"
        case (.rightClick, .imperative): return "right-click"
        }
    }

    /// Long typed text is cut in notes and questions, so they stay short.
    private static func shortenedForSpeech(_ text: String) -> String {
        let singleLineText = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard singleLineText.count > 40 else { return singleLineText }
        return String(singleLineText.prefix(37)) + "…"
    }
}

// MARK: - Tag parser

enum DevilModeActionTagParser {
    /// The tag names, as a regular expression alternation. "DOUBLE-CLICK" and
    /// "RIGHT_CLICK" are accepted too, since Claude sometimes writes them so.
    static let actionTagNamePattern = #"DOUBLE[-_ ]?CLICK|RIGHT[-_ ]?CLICK|CLICK|DRAG|SCROLL|TYPE|KEY"#

    /// Longest text a single [TYPE:...] may type.
    static let maximumTypedTextLength = 2000

    static func isActionTag(_ tagText: String) -> Bool {
        tagText.range(of: #"^\[\s*(\#(actionTagNamePattern))\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Every action tag in an answer, in order. Malformed ones are skipped.
    static func parseActions(fromAnswerText answerText: String) -> [DevilModeAction] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"\[\s*(?:\#(actionTagNamePattern))\s*:[^\]]*\]"#, options: [.caseInsensitive]) else { return [] }
        let answerTextAsNSString = answerText as NSString
        return tagRegex
            .matches(in: answerText, range: NSRange(location: 0, length: answerTextAsNSString.length))
            .compactMap { parseActionTag(answerTextAsNSString.substring(with: $0.range)) }
    }

    /// One complete tag, brackets included, like `[CLICK:10,20,90,40 label="export"]`.
    static func parseActionTag(_ tagText: String) -> DevilModeAction? {
        guard let colonIndex = tagText.firstIndex(of: ":") else { return nil }
        let tagName = tagText[tagText.index(after: tagText.startIndex)..<colonIndex]
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
            .replacingOccurrences(of: #"[-_ ]"#, with: "", options: .regularExpression)
        var tagBody = String(tagText[tagText.index(after: colonIndex)...])
        if tagBody.hasSuffix("]") {
            tagBody.removeLast()
        }

        switch tagName {
        case "CLICK":
            return parseClickBody(tagBody, kind: .click)
        case "DOUBLECLICK":
            return parseClickBody(tagBody, kind: .doubleClick)
        case "RIGHTCLICK":
            return parseClickBody(tagBody, kind: .rightClick)
        case "DRAG":
            // An arrow has the same shape: from (x1,y1) to (x2,y2), a label, a screen
            guard let arrowRequest = ClaudeVisualTagParser.parseDrawTagBody("arrow " + tagBody),
                  arrowRequest.screenshotPoints.count == 2 else { return nil }
            return .drag(
                fromScreenshotPoint: arrowRequest.screenshotPoints[0],
                toScreenshotPoint: arrowRequest.screenshotPoints[1],
                label: arrowRequest.label,
                screenNumber: arrowRequest.screenNumber
            )
        case "SCROLL":
            return parseScrollBody(tagBody)
        case "TYPE":
            let typedText = tagBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typedText.isEmpty, typedText.count <= maximumTypedTextLength else { return nil }
            return .typeText(typedText)
        case "KEY":
            return DevilModeKeyShortcutParser.parse(tagBody).map { .pressKeys($0) }
        default:
            return nil
        }
    }

    /// "x1,y1,x2,y2 label="..." screen=N", read like a DRAW:target. A bare
    /// "x,y" point is accepted too, as a small box around it.
    private static func parseClickBody(_ clickTagBody: String, kind clickKind: DevilModeClickKind) -> DevilModeAction? {
        if let targetRequest = ClaudeVisualTagParser.parseDrawTagBody("target " + clickTagBody),
           targetRequest.screenshotPoints.count == 2 {
            let firstCorner = targetRequest.screenshotPoints[0]
            let secondCorner = targetRequest.screenshotPoints[1]
            let screenshotRect = CGRect(
                x: min(firstCorner.x, secondCorner.x),
                y: min(firstCorner.y, secondCorner.y),
                width: abs(secondCorner.x - firstCorner.x),
                height: abs(secondCorner.y - firstCorner.y)
            )
            return .click(kind: clickKind, screenshotRect: screenshotRect, label: targetRequest.label, screenNumber: targetRequest.screenNumber)
        }
        // A check mark takes a single point, so it reads "x,y label=... screen=N"
        if let pointRequest = ClaudeVisualTagParser.parseDrawTagBody("check " + clickTagBody),
           let clickPoint = pointRequest.screenshotPoints.first {
            let screenshotRect = CGRect(x: clickPoint.x - 12, y: clickPoint.y - 12, width: 24, height: 24)
            return .click(kind: clickKind, screenshotRect: screenshotRect, label: pointRequest.label, screenNumber: pointRequest.screenNumber)
        }
        return nil
    }

    /// Most lines one SCROLL may move, so a typo can't fling a page to its end.
    static let maximumScrollLineCount = 30

    /// "x,y,lines" with an optional "screen=N".
    private static func parseScrollBody(_ scrollTagBody: String) -> DevilModeAction? {
        var remainingBody = scrollTagBody
        var screenNumber: Int?
        if let screenRange = remainingBody.range(of: #":?\s*screen\s*=?\s*(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            screenNumber = Int(remainingBody[screenRange].filter(\.isNumber))
            remainingBody.removeSubrange(screenRange)
        }
        guard let numberRegex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return nil }
        let remainingBodyAsNSString = remainingBody as NSString
        let numbers = numberRegex
            .matches(in: remainingBody, range: NSRange(location: 0, length: remainingBodyAsNSString.length))
            .compactMap { Double(remainingBodyAsNSString.substring(with: $0.range)) }
        guard numbers.count >= 3 else { return nil }
        let lineCount = max(-maximumScrollLineCount, min(maximumScrollLineCount, Int(numbers[2].rounded())))
        guard lineCount != 0 else { return nil }
        return .scroll(atScreenshotPoint: CGPoint(x: numbers[0], y: numbers[1]), lineCount: lineCount, screenNumber: screenNumber)
    }
}

// MARK: - Key shortcuts

struct DevilModeKeyModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let command = DevilModeKeyModifiers(rawValue: 1 << 0)
    static let shift = DevilModeKeyModifiers(rawValue: 1 << 1)
    static let control = DevilModeKeyModifiers(rawValue: 1 << 2)
    static let option = DevilModeKeyModifiers(rawValue: 1 << 3)
    static let function = DevilModeKeyModifiers(rawValue: 1 << 4)
}

struct DevilModeKeyShortcut: Equatable {
    /// macOS virtual key code (US layout positions, like Apple's kVK_ constants).
    let virtualKeyCode: UInt16
    let modifiers: DevilModeKeyModifiers
    /// The key's name as written, without modifiers: "s", "return", "f5".
    let keyName: String

    /// "cmd+shift+s", modifiers in the usual order, for notes and questions.
    var displayText: String {
        var displayParts: [String] = []
        if modifiers.contains(.control) { displayParts.append("ctrl") }
        if modifiers.contains(.option) { displayParts.append("option") }
        if modifiers.contains(.shift) { displayParts.append("shift") }
        if modifiers.contains(.command) { displayParts.append("cmd") }
        if modifiers.contains(.function) { displayParts.append("fn") }
        displayParts.append(keyName)
        return displayParts.joined(separator: "+")
    }

    /// The flags for the key events. Set explicitly on every event, so a key
    /// the user happens to hold can't turn it into another shortcut.
    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Return or enter, which sends in chat and mail apps.
    var isReturnKey: Bool {
        virtualKeyCode == DevilModeKeyShortcutParser.returnKeyCode || virtualKeyCode == DevilModeKeyShortcutParser.keypadEnterKeyCode
    }
}

enum DevilModeKeyShortcutParser {
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53
    static let deleteKeyCode: UInt16 = 51
    static let forwardDeleteKeyCode: UInt16 = 117

    private static let modifiersByName: [String: DevilModeKeyModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command, "meta": .command, "super": .command,
        "shift": .shift, "⇧": .shift,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control, "^": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "fn": .function, "function": .function,
    ]

    /// Named keys and every printable key, by their US layout positions.
    private static let virtualKeyCodesByName: [String: UInt16] = {
        var keyCodes: [String: UInt16] = [
            "return": returnKeyCode, "enter": returnKeyCode, "↩": returnKeyCode, "⏎": returnKeyCode,
            "keypadenter": keypadEnterKeyCode,
            "tab": 48, "⇥": 48,
            "space": 49, "spacebar": 49,
            "delete": deleteKeyCode, "backspace": deleteKeyCode, "⌫": deleteKeyCode,
            "forwarddelete": forwardDeleteKeyCode, "del": forwardDeleteKeyCode, "⌦": forwardDeleteKeyCode,
            "escape": escapeKeyCode, "esc": escapeKeyCode, "⎋": escapeKeyCode,
            "left": 123, "leftarrow": 123, "←": 123,
            "right": 124, "rightarrow": 124, "→": 124,
            "down": 125, "downarrow": 125, "↓": 125,
            "up": 126, "uparrow": 126, "↑": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        let printableKeyCodes: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
            ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        for (keyCharacter, keyCode) in printableKeyCodes {
            keyCodes[String(keyCharacter)] = keyCode
        }
        keyCodes["comma"] = 43
        keyCodes["period"] = 47
        keyCodes["slash"] = 44
        keyCodes["minus"] = 27
        keyCodes["equals"] = 24
        keyCodes["plus"] = 24
        return keyCodes
    }()

    /// "cmd+shift+s", "return", "Command + ,", "ctrl+option+left" → key code
    /// and modifiers. Nil when there's no key, an unknown name, or more than one key.
    static func parse(_ shortcutText: String) -> DevilModeKeyShortcut? {
        let trimmedText = shortcutText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedText.isEmpty else { return nil }

        // "cmd++" means command and the plus key: the last "+" is the key itself
        var shortcutParts = trimmedText.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmedText.hasSuffix("++") {
            shortcutParts = Array(shortcutParts.dropLast(2)) + ["plus"]
        }

        // "page up" is one key, but "cmd s" is two words: split on spaces
        // only when the words together aren't a key name
        let shortcutWords = shortcutParts.flatMap { shortcutPart -> [String] in
            let partWithoutSpaces = shortcutPart.replacingOccurrences(of: " ", with: "")
            if modifiersByName[shortcutPart] != nil || virtualKeyCodesByName[partWithoutSpaces] != nil {
                return [partWithoutSpaces]
            }
            return shortcutPart.split(separator: " ").map(String.init)
        }

        var modifiers: DevilModeKeyModifiers = []
        var keyName: String?
        for shortcutWord in shortcutWords where !shortcutWord.isEmpty {
            if let modifier = modifiersByName[shortcutWord] {
                modifiers.insert(modifier)
                continue
            }
            // Two keys at once isn't a shortcut this can press
            guard keyName == nil else { return nil }
            keyName = shortcutWord
        }
        guard let keyName, let virtualKeyCode = virtualKeyCodesByName[keyName] else { return nil }
        return DevilModeKeyShortcut(virtualKeyCode: virtualKeyCode, modifiers: modifiers, keyName: keyName)
    }
}

// MARK: - Which actions of an answer get done

enum DevilModeActionPlan {
    /// Most actions done for one answer.
    static let maximumActionsPerAnswer = 4

    /// One step at a time: a click, drag or scroll only when it comes first,
    /// since the screenshot its coordinates come from is stale once anything
    /// has happened. Typing and keys may follow it (click a field, type into
    /// it, press return). Everything from a later click on waits for the next
    /// screenshot.
    static func actionsToPerform(fromAnswerText answerText: String) -> [DevilModeAction] {
        guard !answerEndsWithAQuestion(answerText) else { return [] }
        return actionsToPerform(DevilModeActionTagParser.parseActions(fromAnswerText: answerText))
    }

    /// An answer that ends by asking ("should i still hit send?") waits for
    /// the user's reply, even when Claude added an action tag to it anyway.
    static func answerEndsWithAQuestion(_ answerText: String) -> Bool {
        answerText
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("?")
    }

    static func actionsToPerform(_ parsedActions: [DevilModeAction]) -> [DevilModeAction] {
        var actionsToPerform: [DevilModeAction] = []
        for parsedAction in parsedActions {
            if parsedAction.isPointerAction && !actionsToPerform.isEmpty { break }
            actionsToPerform.append(parsedAction)
            if actionsToPerform.count == maximumActionsPerAnswer { break }
        }
        return actionsToPerform
    }
}

// MARK: - Safety

/// The app an action would go to: the frontmost app for keys and typing.
struct DevilModeAppContext: Equatable {
    let bundleIdentifier: String?
    let appName: String?
    let windowTitle: String?
}

enum DevilModeSafetyCheck {
    /// Words that mean the action can't be taken back: it sends, posts, buys,
    /// pays, deletes, submits, publishes, shares or invites.
    private static let riskyWordPattern = #"(?i)\b(send|sends|sending|sent|post|posts|posting|publish|publishes|publishing|tweet|buy|buys|buying|purchase|purchases|order|orders|checkout|check out|pay|pays|paying|payment|delete|deletes|deleting|remove|removes|trash|erase|erases|discard|submit|submits|submitting|share|shares|sharing|invite|invites|inviting|transfer|transfers|confirm|confirms)\b"#

    static func containsRiskyWords(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.range(of: riskyWordPattern, options: .regularExpression) != nil
    }

    /// Claude asking before a risky step ("it's ready, should i send it?"):
    /// the user's yes to it lets the next answer do that step.
    static func isQuestionAboutARiskyAction(_ spokenAnswerText: String) -> Bool {
        let trimmedAnswerText = spokenAnswerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAnswerText.hasSuffix("?") else { return false }
        // The last sentence is the question
        let lastSentence = trimmedAnswerText
            .dropLast()
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .last ?? ""
        return containsRiskyWords(lastSentence)
    }

    private static let chatAndMailBundleIdentifiers: Set<String> = [
        "com.apple.mobilesms", "com.apple.mail", "com.apple.ichat",
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "ru.keepcoder.telegram", "org.telegram.desktop",
        "net.whatsapp.whatsapp", "desktop.whatsapp", "com.microsoft.teams", "com.microsoft.teams2",
        "com.microsoft.outlook", "com.facebook.archon", "com.readdle.smartemail-mac",
        "com.superhuman.electron", "com.mimestream.mimestream", "com.google.chat", "us.zoom.xos",
        "com.apple.facetime", "org.whispersystems.signal-desktop", "com.skype.skype", "com.linkedin.linkedin",
    ]

    /// Names of chat and mail apps and sites, matched against the app's name
    /// and its front window's title (a browser showing Gmail, say).
    private static let chatAndMailNamePattern = #"(?i)\b(mail|gmail|inbox|outlook|messages|messenger|imessage|slack|discord|telegram|whatsapp|signal|teams|chat|chatgpt|claude|dm|direct messages|linkedin|twitter|x\.com|facebook|instagram)\b"#

    /// Where pressing return sends what's been typed.
    static func isChatOrMailApp(_ appContext: DevilModeAppContext) -> Bool {
        if let bundleIdentifier = appContext.bundleIdentifier?.lowercased(),
           chatAndMailBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        for appText in [appContext.appName, appContext.windowTitle].compactMap({ $0 }) {
            if appText.range(of: chatAndMailNamePattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// The question to ask before doing this, or nil when it's safe to just
    /// do it. `textUnderTarget` is the on-screen text inside a click's box,
    /// so a "send" button is caught even when the label calls it something else.
    static func confirmationQuestion(
        for action: DevilModeAction,
        appContext: DevilModeAppContext,
        textUnderTarget: String? = nil
    ) -> String? {
        switch action {
        case .pressKeys(let keyShortcut):
            if keyShortcut.isReturnKey && isChatOrMailApp(appContext) {
                return "Should I press \(keyShortcut.displayText) to send it?"
            }
            // Command delete moves to the trash in the Finder and deletes elsewhere
            let isDeleteKey = keyShortcut.virtualKeyCode == DevilModeKeyShortcutParser.deleteKeyCode
                || keyShortcut.virtualKeyCode == DevilModeKeyShortcutParser.forwardDeleteKeyCode
            if isDeleteKey && keyShortcut.modifiers.contains(.command) {
                return "Should I press \(keyShortcut.displayText)? That deletes it."
            }
            return nil
        case .scroll:
            return nil
        case .click, .drag, .typeText:
            guard containsRiskyWords(action.labelOrTypedText) || containsRiskyWords(textUnderTarget) else { return nil }
            return "Should I \(action.imperativeDescription)?"
        }
    }
}

// MARK: - The user's answer to "should I…?"

enum DevilModeConfirmationReply: Equatable {
    case yes
    case no
    /// Not an answer to the question: they asked something else.
    case somethingElse

    private static let noPattern = #"(?i)\b(no|nope|nah|don't|dont|do not|not|stop|cancel|wait|hold on|never mind|nevermind|abort)\b"#
    private static let yesPattern = #"(?i)^(yes|yeah|yep|yup|ya|yah|sure|ok|okay|alright|all right|go ahead|go for it|do it|please do|send it|confirm|confirmed|absolutely|of course|definitely|correct|affirmative|right|uh huh|mhm)\b"#

    /// A short reply: "yes", "yeah go ahead", "no, wait". Longer ones are a
    /// new request, even if they start with "yes".
    static func classify(_ transcript: String) -> DevilModeConfirmationReply {
        let normalizedTranscript = transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .filter { !["mose", "hey", "um", "uh", "so", "oh"].contains($0) }
            .joined(separator: " ")
        guard !normalizedTranscript.isEmpty else { return .somethingElse }
        let wordCount = normalizedTranscript.split(separator: " ").count

        if normalizedTranscript.range(of: noPattern, options: .regularExpression) != nil {
            return wordCount <= 8 ? .no : .somethingElse
        }
        if wordCount <= 6, normalizedTranscript.range(of: yesPattern, options: .regularExpression) != nil {
            return .yes
        }
        return .somethingElse
    }
}

// MARK: - Step budget

/// Automatic follow-up turns left in one devil mode run, so a run can't keep
/// going on the user's Claude usage (or their Mac) forever. Reset whenever
/// they ask something themselves.
struct DevilModeStepBudget: Equatable {
    static let maximumAutomaticSteps = 15

    private(set) var stepsRemaining = DevilModeStepBudget.maximumAutomaticSteps

    var isUsedUp: Bool { stepsRemaining <= 0 }

    /// Takes one step from the budget. False when none were left.
    mutating func useOneStep() -> Bool {
        guard stepsRemaining > 0 else { return false }
        stepsRemaining -= 1
        return true
    }

    mutating func reset() {
        stepsRemaining = Self.maximumAutomaticSteps
    }
}

// MARK: - Follow-ups

enum DevilModeFollowUp {
    static let transcriptPrefix = "(devil step)"

    /// Goes in the user message with memory (the system prompt has to stay
    /// the same for the pre-started Claude Code process, so the switch can't
    /// change it).
    static func noteForClaude(isDevilModeEnabled: Bool) -> String {
        isDevilModeEnabled
            ? "devil mode is on: when they ask you to do something for them, do it yourself with action tags, one step at a time."
            : "devil mode is off: never use action tags (click, drag, scroll, type, key). show them with guided steps instead."
    }

    /// What Claude is told after the actions are done, with a fresh screenshot:
    /// "(devil step) you clicked export. what's next?"
    static func transcript(afterPerforming performedActions: [DevilModeAction]) -> String {
        let actionDescriptions = performedActions.map(\.pastTenseDescription)
        let joinedDescriptions = actionDescriptions.count <= 1
            ? (actionDescriptions.first ?? "did that")
            : actionDescriptions.dropLast().joined(separator: ", ") + ", then " + (actionDescriptions.last ?? "")
        return "\(transcriptPrefix) you \(joinedDescriptions). what's next?"
    }

    /// After the user said yes to "should I…?": Claude looks again and does it.
    static func transcript(afterApprovalOf approvedQuestion: String) -> String {
        let approvedAction = approvedQuestion
            .replacingOccurrences(of: #"(?i)^should i "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\?.*$"#, with: "", options: .regularExpression)
        return "\(transcriptPrefix) you stopped to check before you \(approvedAction.lowercased()), and i said yes. go ahead and do it."
    }

    static func isDevilStepTranscript(_ transcript: String) -> Bool {
        transcript.hasPrefix(transcriptPrefix)
    }

    /// For the History window: "Mose clicked export".
    static func historyDescription(of devilStepTranscript: String, assistantName: String) -> String {
        if devilStepTranscript.contains("you stopped to check before") {
            return "You said yes"
        }
        let actionText = devilStepTranscript
            .replacingOccurrences(of: transcriptPrefix, with: "")
            .replacingOccurrences(of: #"^\s*you "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\. what's next\?$"#, with: "", options: .regularExpression)
        return "\(assistantName) \(actionText)"
    }
}

// MARK: - Coordinates

enum DevilModeScreenCoordinates {
    /// AppKit's global coordinates start at the bottom-left of the primary
    /// display with y going up; CGEvent's (Quartz) start at its top-left
    /// with y going down. x is the same in both.
    static func quartzGlobalPoint(fromAppKitGlobalPoint appKitGlobalPoint: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitGlobalPoint.x, y: primaryScreenHeight - appKitGlobalPoint.y)
    }

    static func appKitGlobalPoint(fromQuartzGlobalPoint quartzGlobalPoint: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: quartzGlobalPoint.x, y: primaryScreenHeight - quartzGlobalPoint.y)
    }

    /// The points a drag passes through after pressing at `startPoint`,
    /// ending exactly on `endPoint`, eased so it speeds up and slows down
    /// like a hand (some apps only start a drag once the mouse moves a bit).
    static func dragPathPoints(from startPoint: CGPoint, to endPoint: CGPoint, stepCount: Int) -> [CGPoint] {
        guard stepCount > 0 else { return [endPoint] }
        return (1...stepCount).map { stepIndex in
            let linearProgress = Double(stepIndex) / Double(stepCount)
            let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
            return CGPoint(
                x: startPoint.x + (endPoint.x - startPoint.x) * easedProgress,
                y: startPoint.y + (endPoint.y - startPoint.y) * easedProgress
            )
        }
    }
}

// MARK: - Typing

enum DevilModeTyping {
    /// Short text is typed key by key, which works even where pasting is
    /// blocked and looks like typing. Longer text, or text with line breaks
    /// (a typed line break is a return key, which could send), is pasted.
    static let longestTextTypedKeyByKey = 40

    static func shouldPaste(_ text: String) -> Bool {
        text.count > longestTextTypedKeyByKey || text.contains(where: \.isNewline)
    }

    /// One key event's worth of UTF-16 per character, so emoji and accented
    /// letters made of several code units go out whole.
    static func keystrokeUnits(of text: String) -> [[UniChar]] {
        text.map { Array(String($0).utf16) }
    }
}
