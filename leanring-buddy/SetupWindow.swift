//
//  SetupWindow.swift
//  leanring-buddy
//
//  The first-run setup: a short checklist in its own window. It connects
//  Claude Code, asks for the four permissions with a plain reason for each,
//  and ends with the user actually talking to Clicky once. Finished steps get
//  a hand-drawn check and the current step a hand-drawn ring, drawn by the
//  same engine Clicky marks the screen with. It can be reopened any time from
//  the menu bar panel.
//

import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    /// Opens the setup window (posted by the menu bar panel).
    static let clickyOpenSetup = Notification.Name("clickyOpenSetup")
}

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private var setupWindow: NSWindow?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    var isShowingSetup: Bool { setupWindow?.isVisible == true }

    func showSetup() {
        if setupWindow == nil {
            setupWindow = makeSetupWindow()
        }
        Task { await companionManager.refreshClaudeCodeSetupState(forceRefresh: true) }
        // A menu bar app isn't frontmost on its own, so bring it forward for the window
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSetup() {
        setupWindow?.close()
    }

    private func makeSetupWindow() -> NSWindow {
        let setupView = SetupView(
            companionManager: companionManager,
            shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor,
            onClose: { [weak self] in self?.closeSetup() }
        )
        let hostingView = NSHostingView(rootView: setupView)
        let windowSize = NSSize(width: SetupView.windowWidth, height: SetupView.windowHeight)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up \(AppIdentity.displayName)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = hostingView
        window.delegate = self
        window.center()
        return window
    }
}

// MARK: - The checklist

struct SetupView: View {
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 700

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    let onClose: () -> Void

    /// Answers heard before the "say hi" step was reached, so only a new one completes it.
    @State private var voiceAnswerCountWhenSayHiStarted: Int?

    enum SetupStep: Int, CaseIterable, Identifiable {
        case connectClaudeCode = 1
        case allowAccess
        case sayHi

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .connectClaudeCode: return "Connect Claude Code"
            case .allowAccess: return "Allow access"
            case .sayHi: return "Say hi"
            }
        }
    }

    private func isStepDone(_ setupStep: SetupStep) -> Bool {
        switch setupStep {
        case .connectClaudeCode:
            return companionManager.claudeCodeSetupState.isReady
        case .allowAccess:
            return companionManager.allPermissionsGranted
        case .sayHi:
            guard let voiceAnswerCountWhenSayHiStarted else { return companionManager.hasCompletedOnboarding }
            return companionManager.hasCompletedOnboarding
                || companionManager.completedVoiceAnswerCount > voiceAnswerCountWhenSayHiStarted
        }
    }

    /// The first step that isn't done; nil when everything is.
    private var currentStep: SetupStep? {
        SetupStep.allCases.first { !isStepDone($0) }
    }

    private var isEverythingDone: Bool { currentStep == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 26)

            ForEach(SetupStep.allCases) { setupStep in
                Rectangle()
                    .fill(DS.Colors.hairline)
                    .frame(height: 1)
                stepSection(setupStep)
            }
            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(height: 1)

            if isEverythingDone {
                thingsToTry
                    .padding(.top, 24)
                    .transition(.opacity)
            }

            Spacer(minLength: 16)

            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 46)
        .padding(.bottom, 26)
        .frame(width: Self.windowWidth, height: Self.windowHeight, alignment: .topLeading)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .onChange(of: currentStep) { _, newCurrentStep in
            prepare(for: newCurrentStep)
        }
        .onAppear { prepare(for: currentStep) }
        .task(id: currentStep) {
            // While Claude Code isn't ready, keep checking, so signing in or
            // installing in Terminal completes this step without a click here
            guard currentStep == .connectClaudeCode else { return }
            while !Task.isCancelled && !companionManager.claudeCodeSetupState.isReady {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                await companionManager.refreshClaudeCodeSetupState(
                    forceRefresh: companionManager.claudeCodeSetupState == .notInstalled
                )
            }
        }
    }

    private func prepare(for setupStep: SetupStep?) {
        guard setupStep == .sayHi else { return }
        if voiceAnswerCountWhenSayHiStarted == nil {
            voiceAnswerCountWhenSayHiStarted = companionManager.completedVoiceAnswerCount
        }
        // The cursor appears now, so the first answer has somewhere to point
        companionManager.showCompanionCursorForSetup()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompanionCursorMark(markSize: 34)
                .padding(.leading, -4)

            Text("Set up \(AppIdentity.displayName)")
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(DS.Colors.textPrimary)

            Text("\(AppIdentity.displayName) lives next to your cursor. Hold two keys, ask about anything on your screen, and it answers out loud and draws on the screen to show you.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430, alignment: .leading)
        }
    }

    // MARK: Steps

    private func stepSection(_ setupStep: SetupStep) -> some View {
        let isCurrent = currentStep == setupStep
        let isDone = isStepDone(setupStep)

        return HStack(alignment: .top, spacing: 16) {
            stepMarker(setupStep, isCurrent: isCurrent, isDone: isDone)
                .frame(width: 34, height: 34)
                .padding(.top, -6)

            VStack(alignment: .leading, spacing: 5) {
                Text(setupStep.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isDone || isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)

                if let summaryText = stepSummary(setupStep, isCurrent: isCurrent, isDone: isDone) {
                    Text(summaryText)
                        .font(.system(size: 12.5))
                        .foregroundColor(isDone ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isCurrent {
                    stepDetail(setupStep)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .animation(.easeOut(duration: 0.25), value: currentStep)
    }

    /// Upcoming steps show their number, the current one gets a hand-drawn
    /// orange ring like a guided-step target, and finished ones a green check.
    @ViewBuilder
    private func stepMarker(_ setupStep: SetupStep, isCurrent: Bool, isDone: Bool) -> some View {
        ZStack {
            if isDone {
                InkMarkView(mark: .check, inkColor: .green, seed: UInt64(10 + setupStep.rawValue))
                    .id("done-\(setupStep.rawValue)")
            } else {
                Text("\(setupStep.rawValue)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                if isCurrent {
                    InkMarkView(mark: .ring(inset: 8), inkColor: .orange, seed: UInt64(20 + setupStep.rawValue), lineWidthScale: 0.7)
                        .frame(width: 44, height: 44)
                        .id("current-\(setupStep.rawValue)")
                } else {
                    Circle()
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDone ? "Step \(setupStep.rawValue), done" : (isCurrent ? "Step \(setupStep.rawValue), current" : "Step \(setupStep.rawValue)"))
    }

    private func stepSummary(_ setupStep: SetupStep, isCurrent: Bool, isDone: Bool) -> String? {
        switch setupStep {
        case .connectClaudeCode:
            if case .ready(let claudeCodeAccount) = companionManager.claudeCodeSetupState {
                return signedInDescription(for: claudeCodeAccount)
            }
            return "\(AppIdentity.displayName) answers with your Claude plan, through Claude Code."
        case .allowAccess:
            if isDone { return "Microphone, accessibility and screen access are on." }
            return "So it can hear you, see your screen when you ask, and react to the hotkeys."
        case .sayHi:
            if isDone { return "You talked to \(AppIdentity.displayName)." }
            return "Try it once to see how it works."
        }
    }

    private func signedInDescription(for claudeCodeAccount: ClaudeCodeAccount) -> String {
        switch (claudeCodeAccount.email, claudeCodeAccount.planDescription) {
        case (let email?, let planDescription?): return "Signed in as \(email) on the \(planDescription)."
        case (let email?, nil): return "Signed in as \(email)."
        default: return "Signed in."
        }
    }

    @ViewBuilder
    private func stepDetail(_ setupStep: SetupStep) -> some View {
        switch setupStep {
        case .connectClaudeCode: connectClaudeCodeDetail
        case .allowAccess: allowAccessDetail
        case .sayHi: sayHiDetail
        }
    }

    // MARK: Step 1: Claude Code

    @ViewBuilder
    private var connectClaudeCodeDetail: some View {
        switch companionManager.claudeCodeSetupState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for Claude Code on this Mac…")
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        case .notInstalled:
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude Code isn't on this Mac yet. It's Anthropic's free command line tool, and it's what lets \(AppIdentity.displayName) use your Claude subscription without an API key.")
                    .detailTextStyle()
                HStack(spacing: 8) {
                    Button("Install in Terminal") { companionManager.openClaudeCodeInstallerInTerminal() }
                        .buttonStyle(CompanionPrimaryButtonStyle())
                    Button("Install guide") {
                        if let installGuideURL = URL(string: "https://claude.com/claude-code") {
                            NSWorkspace.shared.open(installGuideURL)
                        }
                    }
                    .buttonStyle(CompanionQuietButtonStyle())
                }
                Text(ClaudeCodeTerminalCommands.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
            }
        case .notSignedIn:
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude Code is installed. Sign in with your Claude account and this step finishes on its own.")
                    .detailTextStyle()
                Button("Sign in to Claude") { companionManager.openClaudeCodeSignInInTerminal() }
                    .buttonStyle(CompanionPrimaryButtonStyle())
            }
        case .problem(let problemDescription):
            VStack(alignment: .leading, spacing: 12) {
                Text(problemDescription)
                    .detailTextStyle()
                Button("Check again") {
                    Task { await companionManager.refreshClaudeCodeSetupState(forceRefresh: true) }
                }
                .buttonStyle(CompanionQuietButtonStyle())
            }
        case .ready:
            EmptyView()
        }
    }

    // MARK: Step 2: permissions

    private enum AccessKind: CaseIterable {
        case microphone
        case accessibility
        case screenRecording
        case screenContent
    }

    private func isGranted(_ accessKind: AccessKind) -> Bool {
        switch accessKind {
        case .microphone: return companionManager.hasMicrophonePermission
        case .accessibility: return companionManager.hasAccessibilityPermission
        case .screenRecording: return companionManager.hasScreenRecordingPermission
        case .screenContent: return companionManager.hasScreenContentPermission
        }
    }

    private var allowAccessDetail: some View {
        let nextAccessToAllow = AccessKind.allCases.first { !isGranted($0) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(AccessKind.allCases.enumerated()), id: \.offset) { accessIndex, accessKind in
                if accessIndex > 0 {
                    Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                }
                accessRow(accessKind, isNextToAllow: accessKind == nextAccessToAllow)
            }
        }
    }

    private func accessRow(_ accessKind: AccessKind, isNextToAllow: Bool) -> some View {
        let accessTexts = accessDescription(accessKind)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(accessTexts.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(accessTexts.reason)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if accessKind == .accessibility && !isGranted(.accessibility) {
                    Button("Not in the list? Show \(AppIdentity.displayName) in Finder") {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if isGranted(accessKind) {
                InkMarkView(mark: .check, inkColor: .green, seed: UInt64(40 + accessTexts.seedOffset))
                    .frame(width: 34, height: 30)
            } else if accessKind == .screenContent && !isGranted(.screenRecording) {
                Text("After screen recording")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else if isNextToAllow {
                Button("Allow") { allow(accessKind) }
                    .buttonStyle(CompanionPrimaryButtonStyle())
            } else {
                Button("Allow") { allow(accessKind) }
                    .buttonStyle(CompanionQuietButtonStyle())
            }
        }
        .padding(.vertical, 10)
    }

    private func accessDescription(_ accessKind: AccessKind) -> (name: String, reason: String, seedOffset: Int) {
        switch accessKind {
        case .microphone:
            return ("Microphone", "To hear you while you hold the keys.", 1)
        case .accessibility:
            return ("Accessibility", "For the hotkeys, and to type what you dictate.", 2)
        case .screenRecording:
            return ("Screen recording", "To see your screen when you ask. If macOS asks, quit and reopen \(AppIdentity.displayName).", 3)
        case .screenContent:
            return ("Screen capture", "macOS confirms once more before an app can capture the screen.", 4)
        }
    }

    private func allow(_ accessKind: AccessKind) {
        switch accessKind {
        case .microphone: companionManager.requestMicrophonePermission()
        case .accessibility: _ = WindowPositionManager.requestAccessibilityPermission()
        case .screenRecording: _ = WindowPositionManager.requestScreenRecordingPermission()
        case .screenContent: companionManager.requestScreenContentPermission()
        }
    }

    // MARK: Step 3: say hi

    private var sayHiDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hold control and option, say \u{201C}hi, what can you do?\u{201D}, then let go.")
                .detailTextStyle()

            HStack(alignment: .center, spacing: 18) {
                ShortcutKeycaps(
                    keys: ShortcutKeycaps.talkKeys,
                    isPressed: shortcutMonitor.isShortcutCurrentlyPressed,
                    keycapSize: .large
                )
                Text(sayHiStatusText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(companionManager.voiceState == .idle ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .animation(.easeOut(duration: 0.15), value: companionManager.voiceState)
            }
            .padding(.bottom, 4)

            HStack(spacing: 8) {
                ShortcutKeycaps(keys: ShortcutKeycaps.dictateKeys, keycapSize: .compact)
                Text("Later, hold fn and control to type with your voice in any text field.")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var sayHiStatusText: String {
        switch companionManager.voiceState {
        case .idle: return shortcutMonitor.isShortcutCurrentlyPressed ? "Listening…" : "Waiting for you"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Answering out loud"
        }
    }

    // MARK: Things to try

    /// One example for each kind of help, so the first real question is easy.
    private var thingsToTry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Things to ask first")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            exampleQuestion("\u{201C}How do I export this as a PDF?\u{201D}", whatHappens: "It marks the next thing to click, then the next, one step at a time.")
            exampleQuestion("\u{201C}What does this error mean?\u{201D}", whatHappens: "It circles the problem and explains it out loud.")
            exampleQuestion("\u{201C}Research standing desks under $500 and make me a PDF.\u{201D}", whatHappens: "It works on that in the background and tells you when it's done.")
        }
    }

    private func exampleQuestion(_ questionText: String, whatHappens: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(questionText)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            Text(whatHappens)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if isEverythingDone {
                Text("\(AppIdentity.displayName) is in your Dock whenever you need it.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if isEverythingDone {
                Button("Start using \(AppIdentity.displayName)") {
                    companionManager.finishSetup()
                    onClose()
                }
                .buttonStyle(CompanionPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish later") { onClose() }
                    .buttonStyle(CompanionQuietButtonStyle())
            }
        }
    }
}

private extension Text {
    func detailTextStyle() -> some View {
        self
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 400, alignment: .leading)
    }
}

// MARK: - Terminal helpers

/// Claude Code's sign-in and installer are interactive, so they run in
/// Terminal, where the user can see and answer them.
enum ClaudeCodeTerminalCommands {
    /// Anthropic's installer for the native Claude Code build.
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// Opens Terminal running a short script. A `.command` file opens in
    /// Terminal by default, so this needs no Automation permission.
    static func runInTerminal(scriptLines: [String], scriptName: String) {
        let scriptFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(scriptName).command")
        let scriptText = (["#!/bin/zsh -l", "clear"] + scriptLines).joined(separator: "\n") + "\n"
        do {
            try scriptText.write(to: scriptFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFileURL.path)
            NSWorkspace.shared.open(scriptFileURL)
        } catch {
            print("⚠️ Couldn't open Terminal: \(error)")
        }
    }

    /// Wraps text in single quotes for zsh.
    static func shellQuoted(_ unquotedText: String) -> String {
        "'" + unquotedText.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
