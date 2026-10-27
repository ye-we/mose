//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// True while a walkthrough (points and drawings) still has beats left to
    /// show. BlueCursorView keeps the buddy parked on the current beat instead of
    /// flying back to the cursor, so it can go straight to the next one.
    @Published private(set) var isVisualSequenceAwaitingNextBeat: Bool = false

    // MARK: - Streaming Answer State

    /// Splits the answer streaming in into sentences to speak and tags to show.
    private var answerSegmenter = StreamingAnswerSegmenter()
    /// What the current answer's marks are placed against.
    private var answerScreenCaptures: [CompanionScreenCapture] = []
    private var answerScreenCaptureDate: Date = .distantPast
    private var answerScreenTextRecognitionTask: Task<[[RecognizedScreenTextLine]], Never>?
    /// Tags are resolved one after another (one may wait for text recognition or
    /// a fresh look at the screen); chaining them keeps Claude's order.
    private var answerVisualTagResolutionChain: Task<Void, Never>?
    /// Resolved beats waiting for the sentence they go with to start being spoken.
    private var visualBeatsWaitingForTheirSentence: [Int: [ResolvedVisualBeat]] = [:]
    private var answerSentenceIndicesStartedSpeaking: Set<Int> = []
    private var answerSentenceCount = 0
    private var isAnswerStreamComplete = false
    private var answerHasShownAnyVisualBeat = false
    private var answerPointBeatCount = 0
    private var answerHasGuidedTarget = false
    /// Bumped for every new answer so callbacks from an older one are ignored.
    private var answerGeneration = 0

    // MARK: - Screen Sketching State

    /// The newest mark for BlueCursorView to draw. Each one has a fresh id, so
    /// the overlay reacts even when two marks in a row are identical.
    @Published private(set) var latestSketchBeat: ResolvedSketchBeat?
    /// Bumped to wipe every drawing off the screen.
    @Published private(set) var sketchClearGeneration: Int = 0
    private var hasSketchDrawingsOnScreen = false
    /// Clicks and scrolls anywhere usually change what's under the drawings,
    /// so they wipe them once the walkthrough has finished.
    private var sketchClearingInputMonitor: Any?
    /// Wipes drawings that have been left on screen for a while.
    private var sketchIdleClearTask: Task<Void, Never>?
    private static let sketchIdleClearDelaySeconds: UInt64 = 90
    // MARK: - User Ink State

    /// What the user drew while holding the talk hotkey, in global screen
    /// coordinates, one list of points per stroke. It's drawn into the
    /// screenshot Claude sees, so they can circle what they're asking about.
    @Published private(set) var userInkStrokes: [[CGPoint]] = []
    /// True while the talk hotkey is held: the overlay catches the mouse so
    /// dragging draws instead of clicking the app underneath.
    @Published private(set) var isAcceptingUserInk = false

    // MARK: - Guided Steps State

    /// The one thing the user should click next in a guided walkthrough, in
    /// global screen coordinates. Their next click asks Claude for the next
    /// step against a fresh screenshot.
    private var pendingGuidedStepTarget: (globalRect: CGRect, label: String?)?
    /// Number for the next target ring's label ("2. export as pdf").
    private var guidedStepNumber = 0
    /// Automatic follow-up turns left, so a walkthrough can't keep going on
    /// the user's Claude usage forever. Reset whenever they ask something.
    private var guidedStepTurnsRemaining = CompanionManager.maximumGuidedStepTurns
    private static let maximumGuidedStepTurns = 10
    /// Time for the app to react to the click (open a menu, switch a pane)
    /// before the next screenshot is taken.
    private static let guidedStepScreenSettleDelaySeconds: Double = 0.8
    private var guidedStepAdvanceTask: Task<Void, Never>?
    /// The app the walkthrough is about (frontmost when the user asked). Clicks
    /// off the target only count as "doing something else" inside this app;
    /// clicks in other apps (say, a terminal they're also typing in) are ignored.
    private var guidedAppProcessIdentifier: pid_t?
    private var frontmostAppProcessIdentifierWhenScreenshotWasTaken: pid_t?
    /// Where the mouse pointer was when the screenshot Claude is answering from
    /// was taken. Screenshots include the pointer, so the change check ignores it.
    private var mouseLocationWhenScreenshotWasTaken: CGPoint = .zero

    /// When the user last clicked or scrolled anywhere. If that happens after a
    /// screenshot was taken, the screen has probably moved and marks computed
    /// from that screenshot would land in the wrong place.
    private var lastScreenChangingInputDate: Date = .distantPast

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Clicky answers with the Claude Code CLI directly (ClaudeCodeChatClient),
    /// speaks with the Mac's system voice and runs background tasks itself, so
    /// there's no server to start. Set CLICKY_BRIDGE_URL to send everything
    /// through an HTTP bridge instead: local-bridge/server.mjs on another port
    /// for testing, or a Cloudflare Worker that holds API keys.
    private static let externalBridgeBaseURL: String? = ProcessInfo.processInfo.environment["CLICKY_BRIDGE_URL"]

    private lazy var chatBackend: CompanionChatBackend = {
        if let externalBridgeBaseURL = Self.externalBridgeBaseURL {
            return ClaudeAPI(proxyURL: "\(externalBridgeBaseURL)/chat", model: selectedModel)
        }
        return ClaudeCodeChatClient(model: selectedModel, isExtendedThinkingEnabled: isExtendedThinkingEnabled)
    }()

    /// Speaks answers sentence by sentence as they stream in, in the Mac's
    /// system voice (an HTTP bridge can switch it to its own voice at launch).
    private lazy var sentenceSpeaker: CompanionSentenceSpeaker = Self.makeSystemVoiceSentenceSpeaker()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.externalBridgeBaseURL ?? "http://127.0.0.1:8787")/tts")
    }()

    /// `say` with the Mac's system voice, which can be a Siri voice. With an
    /// HTTP bridge, the in-app engine speaks until the bridge's voice is known.
    private static func makeSystemVoiceSentenceSpeaker() -> CompanionSentenceSpeaker {
        if externalBridgeBaseURL != nil {
            return SystemVoiceSentenceSpeaker()
        }
        return PrefetchedAudioSentenceSpeaker(
            speechAudioSource: MacSystemVoiceSpeechAudioSource(),
            voiceDescription: "macOS system voice (say)"
        )
    }

    /// Whether Claude Code is installed and signed in, for setup and the panel.
    @Published private(set) var claudeCodeSetupState: ClaudeCodeSetupState = .checking

    func refreshClaudeCodeSetupState(forceRefresh: Bool = false) async {
        guard Self.externalBridgeBaseURL == nil else {
            // The bridge has its own sign-in
            claudeCodeSetupState = .ready(ClaudeCodeAccount(email: nil, subscriptionType: nil, organizationName: nil))
            return
        }
        claudeCodeSetupState = await ClaudeCodeCLI.checkSetupState(forceRefresh: forceRefresh)
        print("🔑 Claude Code: \(claudeCodeSetupState)")
    }

    /// Whether Claude thinks before answering. Off by default: with it on,
    /// answers about real screens started up to ~18s later.
    @Published private(set) var isExtendedThinkingEnabled: Bool = UserDefaults.standard.bool(forKey: "isClaudeExtendedThinkingEnabled")

    func setExtendedThinkingEnabled(_ isEnabled: Bool) {
        isExtendedThinkingEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isClaudeExtendedThinkingEnabled")
        (chatBackend as? ClaudeCodeChatClient)?.isExtendedThinkingEnabled = isEnabled
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var dictationShortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        chatBackend.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Setup

    /// Answers that finished, so setup can tell when the user has talked to Clicky.
    @Published private(set) var completedVoiceAnswerCount = 0

    /// Shows the cursor during setup's last step, so the first answer has
    /// somewhere to point. The first time it appears it says hello.
    func showCompanionCursorForSetup() {
        guard isClickyCursorEnabled, !isOverlayVisible else { return }
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func finishSetup() {
        hasCompletedOnboarding = true
        // hasCompletedOnboarding lives in UserDefaults, so tell the panel it changed
        objectWillChange.send()
        showCompanionCursorForSetup()
    }

    func requestMicrophonePermission() {
        // The system prompt appears only the first time; after a "Don't Allow",
        // the switch is in System Settings.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(microphoneSettingsURL)
        }
    }

    func openClaudeCodeInstallerInTerminal() {
        ClaudeCodeTerminalCommands.runInTerminal(
            scriptLines: [
                "echo 'Installing Claude Code...'",
                "echo",
                ClaudeCodeTerminalCommands.installCommand,
                "echo",
                "echo 'All set. \(AppIdentity.displayName) notices on its own, so you can close this window.'",
            ],
            scriptName: "install-claude-code"
        )
    }

    func openClaudeCodeSignInInTerminal() {
        Task {
            guard let claudeCodeInstallation = try? await ClaudeCodeCLI.installation(forceRefresh: true) else {
                claudeCodeSetupState = .notInstalled
                return
            }
            ClaudeCodeTerminalCommands.runInTerminal(
                scriptLines: [
                    "echo 'Signing in to Claude Code. Your browser will open to finish.'",
                    "echo",
                    "\(ClaudeCodeTerminalCommands.shellQuoted(claudeCodeInstallation.binaryURL.path)) auth login",
                    "echo",
                    "echo 'All set. \(AppIdentity.displayName) notices on its own, so you can close this window.'",
                ],
                scriptName: "claude-code-sign-in"
            )
        }
    }

    // MARK: - Open at login

    private static let openAtLoginPreferenceDefaultsKey = "isOpenAtLoginPreferred"

    @Published private(set) var isOpenAtLoginEnabled = SMAppService.mainApp.status == .enabled

    /// Opens at login unless the user turned that off in the panel.
    func applyOpenAtLoginPreference() {
        let isOpenAtLoginPreferred = UserDefaults.standard.object(forKey: Self.openAtLoginPreferenceDefaultsKey) as? Bool ?? true
        setOpenAtLoginEnabled(isOpenAtLoginPreferred)
    }

    func setOpenAtLoginEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: Self.openAtLoginPreferenceDefaultsKey)
        let loginItemService = SMAppService.mainApp
        do {
            if isEnabled && loginItemService.status != .enabled {
                try loginItemService.register()
            } else if !isEnabled && loginItemService.status == .enabled {
                try loginItemService.unregister()
            }
        } catch {
            print("⚠️ Couldn't change open at login: \(error)")
        }
        isOpenAtLoginEnabled = loginItemService.status == .enabled
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        startSketchClearingInputMonitor()
        if Self.externalBridgeBaseURL != nil {
            Task { await useBridgeVoiceIfConfigured() }
        }
        Task { await loadBackgroundAgentJobsAtLaunch() }
        #if DEBUG
        installDebugAutomationObserversIfEnabled()
        #endif
        // With an HTTP bridge, this starts ClaudeAPI's TLS warmup early
        _ = chatBackend

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    /// Stops a walkthrough and wipes its drawings. Clearing the location makes
    /// BlueCursorView fly the buddy back to the cursor.
    private func cancelVisualSequence() {
        answerGeneration += 1
        answerVisualTagResolutionChain?.cancel()
        answerVisualTagResolutionChain = nil
        visualBeatsWaitingForTheirSentence.removeAll()
        isVisualSequenceAwaitingNextBeat = false
        clearDetectedElementLocation()
        clearSketchDrawings()
    }

    /// Wipes every drawing off the screen.
    func clearSketchDrawings() {
        sketchIdleClearTask?.cancel()
        sketchIdleClearTask = nil
        guard hasSketchDrawingsOnScreen else { return }
        hasSketchDrawingsOnScreen = false
        sketchClearGeneration += 1
    }

    // MARK: - Background Agents

    /// Background tasks, newest first. The panel lists them.
    @Published private(set) var backgroundAgentJobs: [BackgroundAgentJob] = []
    private lazy var backgroundAgentJobService: BackgroundAgentJobService = {
        if let externalBridgeBaseURL = Self.externalBridgeBaseURL {
            return BackgroundAgentJobsClient(bridgeBaseURL: externalBridgeBaseURL)
        }
        return BackgroundAgentJobRunner()
    }()
    private var backgroundAgentJobsPollingTask: Task<Void, Never>?
    /// Jobs whose finish has already been announced (or that finished before launch).
    private var announcedFinishedAgentJobIDs: Set<String> = []
    /// A separate voice so an announcement never tangles with an answer's sentences.
    private lazy var agentAnnouncementSpeaker: CompanionSentenceSpeaker = Self.makeSystemVoiceSentenceSpeaker()

    /// Hands the brief in an [AGENT:title|brief] tag to a background Claude Code
    /// session, with a screenshot of the screen the user was looking at when
    /// they asked.
    private func startBackgroundAgentJob(fromAgentTag agentTagText: String) {
        guard let (jobTitle, jobBrief) = BackgroundAgentTagParser.parseAgentTag(agentTagText) else {
            print("⚠️ Ignoring an agent tag without a usable brief: \(agentTagText)")
            return
        }
        let screenshotJPEGData = answerScreenCaptures.first(where: { $0.isCursorScreen })?.imageData
            ?? answerScreenCaptures.first?.imageData

        Task {
            do {
                let startedJob = try await backgroundAgentJobService.startJob(
                    title: jobTitle,
                    brief: jobBrief,
                    screenshotJPEGData: screenshotJPEGData
                )
                print("🤖 Background agent \(startedJob.id) started: \(startedJob.title)")
                await refreshBackgroundAgentJobs()
                startPollingBackgroundAgentJobsIfNeeded()
            } catch {
                print("⚠️ Couldn't start background agent: \(error)")
                let spokenProblem = (error as? ClaudeCodeCLIError)?.spokenExplanation ?? "I couldn't start that in the background."
                agentAnnouncementSpeaker.enqueueSentence(spokenProblem, sentenceIndex: 0)
            }
        }
    }

    func stopBackgroundAgentJob(_ backgroundAgentJob: BackgroundAgentJob) {
        Task {
            try? await backgroundAgentJobService.stopJob(withID: backgroundAgentJob.id)
            await refreshBackgroundAgentJobs()
        }
    }

    /// Opens what the job made (its output folder), or the job folder if it made nothing.
    func openBackgroundAgentJobOutput(_ backgroundAgentJob: BackgroundAgentJob) {
        let outputFolderURL = URL(fileURLWithPath: backgroundAgentJob.folder).appendingPathComponent("output")
        let folderToOpenURL = backgroundAgentJob.outputFiles.isEmpty ? URL(fileURLWithPath: backgroundAgentJob.folder) : outputFolderURL
        NSWorkspace.shared.open(folderToOpenURL)
    }

    /// Loads the job list once at launch. Jobs that already finished are never
    /// announced; ones still running are watched.
    private func loadBackgroundAgentJobsAtLaunch() async {
        guard let jobs = try? await backgroundAgentJobService.listJobs() else { return }
        announcedFinishedAgentJobIDs = Set(jobs.filter { !$0.isRunning }.map(\.id))
        backgroundAgentJobs = jobs
        startPollingBackgroundAgentJobsIfNeeded()
    }

    private func refreshBackgroundAgentJobs() async {
        guard let jobs = try? await backgroundAgentJobService.listJobs() else { return }
        backgroundAgentJobs = jobs
        for finishedJob in jobs where !finishedJob.isRunning && !announcedFinishedAgentJobIDs.contains(finishedJob.id) {
            announcedFinishedAgentJobIDs.insert(finishedJob.id)
            announceFinishedBackgroundAgentJob(finishedJob)
        }
    }

    /// Checks on running jobs every couple of seconds until none are left.
    private func startPollingBackgroundAgentJobsIfNeeded() {
        guard backgroundAgentJobsPollingTask == nil, backgroundAgentJobs.contains(where: \.isRunning) else { return }
        backgroundAgentJobsPollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refreshBackgroundAgentJobs()
                if !self.backgroundAgentJobs.contains(where: \.isRunning) { break }
            }
            self?.backgroundAgentJobsPollingTask = nil
        }
    }

    /// Says the job's first sentence out loud, after any answer that's being spoken.
    private func announceFinishedBackgroundAgentJob(_ finishedJob: BackgroundAgentJob) {
        let announcement: String
        switch finishedJob.status {
        case "done":
            announcement = finishedJob.resultHeadline.map { "\(finishedJob.title) is done. \($0)" } ?? "\(finishedJob.title) is done."
        case "stopped":
            return
        default:
            announcement = "\(finishedJob.title) didn't finish. The details are in the menu bar panel."
        }
        print("🤖 Background agent \(finishedJob.id) \(finishedJob.status): \(finishedJob.resultHeadline ?? "")")

        Task { [weak self] in
            // Don't talk over an answer or over the user
            while let self, self.sentenceSpeaker.isSpeaking || self.voiceState == .listening {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.agentAnnouncementSpeaker.enqueueSentence(announcement, sentenceIndex: 0)
        }
    }

    // MARK: - Voice

    /// With an HTTP bridge: it says which voice it has, ElevenLabs (when its
    /// keys are set) or macOS `say`, and Clicky speaks through it either way.
    /// If the bridge can't be reached at launch, the in-app voice stays.
    private func useBridgeVoiceIfConfigured() async {
        guard let externalBridgeBaseURL = Self.externalBridgeBaseURL,
              let bridgeConfigurationURL = URL(string: "\(externalBridgeBaseURL)/config"),
              let (configurationData, _) = try? await URLSession.shared.data(from: bridgeConfigurationURL),
              let bridgeConfiguration = try? JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              let bridgeVoiceName = bridgeConfiguration["tts"] as? String,
              bridgeVoiceName == "elevenlabs" || bridgeVoiceName == "macos" else { return }
        let bridgeVoiceDescription = bridgeVoiceName == "elevenlabs" ? "ElevenLabs" : "macOS system voice (say)"
        sentenceSpeaker.stopSpeaking()
        sentenceSpeaker = PrefetchedAudioSentenceSpeaker(
            speechAudioSource: elevenLabsTTSClient,
            voiceDescription: "\(bridgeVoiceDescription) via the bridge"
        )
        agentAnnouncementSpeaker.stopSpeaking()
        agentAnnouncementSpeaker = PrefetchedAudioSentenceSpeaker(
            speechAudioSource: elevenLabsTTSClient,
            voiceDescription: "\(bridgeVoiceDescription) via the bridge"
        )
    }

    // MARK: - Streaming Answers

    /// Seconds since 2001 with millisecond precision, for timing logs.
    static func logTimestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSinceReferenceDate)
    }

    /// Gets ready to speak and draw a new answer against these screenshots.
    private func beginStreamingAnswer(
        screenCaptures: [CompanionScreenCapture],
        screenCaptureDate: Date,
        screenTextRecognitionTask: Task<[[RecognizedScreenTextLine]], Never>
    ) {
        answerGeneration += 1
        answerSegmenter = StreamingAnswerSegmenter()
        answerScreenCaptures = screenCaptures
        answerScreenCaptureDate = screenCaptureDate
        answerScreenTextRecognitionTask = screenTextRecognitionTask
        answerVisualTagResolutionChain = nil
        visualBeatsWaitingForTheirSentence = [:]
        answerSentenceIndicesStartedSpeaking = []
        answerSentenceCount = 0
        isAnswerStreamComplete = false
        answerHasShownAnyVisualBeat = false
        answerPointBeatCount = 0
        answerHasGuidedTarget = false

        let currentAnswerGeneration = answerGeneration
        sentenceSpeaker.onSentenceStartedSpeaking = { [weak self] sentenceIndex in
            self?.handleAnswerSentenceStartedSpeaking(sentenceIndex, answerGeneration: currentAnswerGeneration)
        }
        sentenceSpeaker.onFinishedSpeaking = { [weak self] in
            // Back to idle once the answer has been said, unless more is on the way
            guard let self, self.answerGeneration == currentAnswerGeneration,
                  self.isAnswerStreamComplete, self.voiceState == .responding else { return }
            self.voiceState = .idle
        }
    }

    /// Feeds in the answer so far (call again as more streams in). Complete
    /// sentences start speaking right away; complete tags are resolved and
    /// shown when their sentence starts being spoken.
    private func receiveStreamedAnswerText(_ accumulatedAnswerText: String, isAnswerComplete: Bool) {
        let answerPieces = answerSegmenter.consume(accumulatedAnswerText: accumulatedAnswerText, isAnswerComplete: isAnswerComplete)
        for answerPiece in answerPieces {
            switch answerPiece {
            case .sentence(let sentenceIndex, let sentenceText):
                answerSentenceCount = sentenceIndex + 1
                sentenceSpeaker.enqueueSentence(sentenceText, sentenceIndex: sentenceIndex)
            case .tag(let tagText, let sentenceIndex):
                if StreamingAnswerSegmenter.isAgentTag(tagText) {
                    startBackgroundAgentJob(fromAgentTag: tagText)
                } else {
                    resolveVisualTagInOrder(tagText, sentenceIndex: sentenceIndex)
                }
            }
        }

        if isAnswerComplete {
            let currentAnswerGeneration = answerGeneration
            let previousTagResolution = answerVisualTagResolutionChain
            answerVisualTagResolutionChain = Task { [weak self] in
                await previousTagResolution?.value
                guard let self, self.answerGeneration == currentAnswerGeneration else { return }
                self.completeStreamingAnswer()
            }
        }
    }

    /// Returns once every tag of the current answer has been shown or queued.
    private func waitForStreamingAnswerToSettle() async {
        await answerVisualTagResolutionChain?.value
    }

    private func resolveVisualTagInOrder(_ tagText: String, sentenceIndex: Int) {
        let currentAnswerGeneration = answerGeneration
        let previousTagResolution = answerVisualTagResolutionChain
        answerVisualTagResolutionChain = Task { [weak self] in
            await previousTagResolution?.value
            guard let self, self.answerGeneration == currentAnswerGeneration else { return }
            await self.resolveAndScheduleVisualTag(tagText, sentenceIndex: sentenceIndex, answerGeneration: currentAnswerGeneration)
        }
    }

    private func resolveAndScheduleVisualTag(_ tagText: String, sentenceIndex: Int, answerGeneration resolvingAnswerGeneration: Int) async {
        let parsedVisualBeats = ClaudeVisualTagParser.parseVisualBeats(from: tagText).beats
        guard !parsedVisualBeats.isEmpty else { return }

        // Text recognition started with the screenshot, so it's almost always done
        let recognizedTextLinesByCaptureIndex = await answerScreenTextRecognitionTask?.value ?? []
        var resolvedVisualBeats = resolveVisualBeats(
            parsedVisualBeats,
            screenCaptures: answerScreenCaptures,
            recognizedTextLinesByCaptureIndex: recognizedTextLinesByCaptureIndex
        )

        // A click or scroll since the screenshot may have moved what Claude was
        // looking at. Look again and drop the mark if its spot changed; the
        // answer is still spoken either way.
        if !resolvedVisualBeats.isEmpty && lastScreenChangingInputDate > answerScreenCaptureDate {
            resolvedVisualBeats = await visualBeatsStillMatchingTheScreen(resolvedVisualBeats, screenCaptures: answerScreenCaptures)
        }
        guard answerGeneration == resolvingAnswerGeneration else { return }

        for resolvedVisualBeat in resolvedVisualBeats {
            let preparedVisualBeat = prepareGuidedStepTarget(resolvedVisualBeat)
            if hasAnswerSentenceStartedSpeaking(atOrAfter: sentenceIndex) {
                showStreamedVisualBeat(preparedVisualBeat)
            } else {
                visualBeatsWaitingForTheirSentence[sentenceIndex, default: []].append(preparedVisualBeat)
            }
        }
        updateVisualSequenceAwaitingFlag()
    }

    private func hasAnswerSentenceStartedSpeaking(atOrAfter sentenceIndex: Int) -> Bool {
        answerSentenceIndicesStartedSpeaking.contains { $0 >= sentenceIndex }
    }

    private func handleAnswerSentenceStartedSpeaking(_ sentenceIndex: Int, answerGeneration speakingAnswerGeneration: Int) {
        guard answerGeneration == speakingAnswerGeneration else { return }
        print("🗣️ Sentence \(sentenceIndex) started speaking at \(Self.logTimestamp())")
        answerSentenceIndicesStartedSpeaking.insert(sentenceIndex)
        voiceState = .responding

        // Show this sentence's marks, and any earlier ones still waiting
        for waitingSentenceIndex in visualBeatsWaitingForTheirSentence.keys.sorted() where waitingSentenceIndex <= sentenceIndex {
            for waitingVisualBeat in visualBeatsWaitingForTheirSentence.removeValue(forKey: waitingSentenceIndex) ?? [] {
                showStreamedVisualBeat(waitingVisualBeat)
            }
        }
        updateVisualSequenceAwaitingFlag()
    }

    /// Everything Claude wrote has been handled. Marks whose sentence will
    /// never be spoken (an answer that's only tags, or speech that failed) are
    /// shown now, and an answer without a target ends a guided walkthrough.
    private func completeStreamingAnswer() {
        isAnswerStreamComplete = true

        if !answerHasGuidedTarget {
            if pendingGuidedStepTarget != nil || guidedStepNumber > 0 {
                print("👣 Guided steps finished")
            }
            pendingGuidedStepTarget = nil
        }

        for waitingSentenceIndex in visualBeatsWaitingForTheirSentence.keys.sorted()
        where waitingSentenceIndex >= answerSentenceCount || !sentenceSpeaker.isSpeaking {
            for waitingVisualBeat in visualBeatsWaitingForTheirSentence.removeValue(forKey: waitingSentenceIndex) ?? [] {
                showStreamedVisualBeat(waitingVisualBeat)
            }
        }
        if !answerHasShownAnyVisualBeat && visualBeatsWaitingForTheirSentence.isEmpty {
            print("🎯 Element pointing: no element")
        }
        updateVisualSequenceAwaitingFlag()

        // Speech may have caught up with Claude before the answer ended
        if voiceState == .responding && !sentenceSpeaker.isSpeaking {
            voiceState = .idle
        }
    }

    /// Tells BlueCursorView whether more beats may still come, so it stays
    /// parked on the current one instead of flying home.
    private func updateVisualSequenceAwaitingFlag() {
        isVisualSequenceAwaitingNextBeat = !visualBeatsWaitingForTheirSentence.isEmpty
            || (answerHasShownAnyVisualBeat && !isAnswerStreamComplete)
    }

    private func showStreamedVisualBeat(_ visualBeat: ResolvedVisualBeat) {
        // The spinner hides the triangle; switch away from it so the flight is visible
        if voiceState == .processing {
            voiceState = .idle
        }
        answerHasShownAnyVisualBeat = true
        updateVisualSequenceAwaitingFlag()
        showVisualBeat(visualBeat)
    }

    /// Publishes one beat: a point for BlueCursorView to fly to, or a mark to draw.
    private func showVisualBeat(_ visualBeat: ResolvedVisualBeat) {
        switch visualBeat.content {
        case .point(let globalScreenLocation, let elementLabel):
            answerPointBeatCount += 1
            // The bubble names the element; from the second point on it's
            // numbered ("2. share button") so the order is clear
            detectedElementBubbleText = answerPointBeatCount > 1
                ? "\(answerPointBeatCount). \(elementLabel ?? "here")"
                : elementLabel
            detectedElementDisplayFrame = visualBeat.displayFrame
            detectedElementScreenLocation = globalScreenLocation
            ClickyAnalytics.trackElementPointed(elementLabel: elementLabel)
            print("🎯 Element pointing \(answerPointBeatCount): \"\(elementLabel ?? "element")\"")
        case .sketch(let sketchBeat):
            hasSketchDrawingsOnScreen = true
            latestSketchBeat = sketchBeat
            scheduleSketchIdleClear()
            print("✏️ Sketching \(sketchBeat.kind.rawValue)\(sketchBeat.label.map { " \"\($0)\"" } ?? "") at \(Self.logTimestamp())")
        }
    }

    private func scheduleSketchIdleClear() {
        sketchIdleClearTask?.cancel()
        sketchIdleClearTask = Task {
            try? await Task.sleep(nanoseconds: Self.sketchIdleClearDelaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            clearSketchDrawings()
            clearUserInk()
        }
    }

    /// Watches for clicks and scrolls anywhere on the Mac (listen-only; uses the
    /// Accessibility permission the hotkey already needs). Once a walkthrough
    /// has finished, the user acting on the screen means the drawings are stale.
    private func startSketchClearingInputMonitor() {
        guard sketchClearingInputMonitor == nil else { return }
        sketchClearingInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] inputEvent in
            let isLeftClick = inputEvent.type == .leftMouseDown
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                self.lastScreenChangingInputDate = Date()

                // In a guided walkthrough the click is the user doing the step
                if isLeftClick && self.advanceGuidedStepIfWaiting(afterClickAt: clickLocation) {
                    return
                }

                guard !self.isVisualSequenceAwaitingNextBeat, !self.isAcceptingUserInk else { return }
                self.clearUserInk()
                guard self.hasSketchDrawingsOnScreen else { return }
                self.clearSketchDrawings()
            }
        }
    }

    // MARK: - User Ink

    private func setAcceptingUserInk(_ shouldAcceptUserInk: Bool) {
        isAcceptingUserInk = shouldAcceptUserInk
        overlayWindowManager.setAcceptsMouseInput(shouldAcceptUserInk)
    }

    func beginUserInkStroke(atGlobalLocation globalLocation: CGPoint) {
        guard isAcceptingUserInk else { return }
        userInkStrokes.append([globalLocation])
    }

    func continueUserInkStroke(toGlobalLocation globalLocation: CGPoint) {
        guard isAcceptingUserInk, !userInkStrokes.isEmpty else { return }
        userInkStrokes[userInkStrokes.count - 1].append(globalLocation)
    }

    func clearUserInk() {
        if !userInkStrokes.isEmpty {
            userInkStrokes = []
        }
    }

    /// The screenshots with the user's strokes drawn in, each on the screen it was drawn on.
    private func screenCapturesWithUserInk(_ screenCaptures: [CompanionScreenCapture]) -> [CompanionScreenCapture] {
        screenCaptures.map { screenCapture in
            let inkStrokesOnThisScreen = userInkStrokes
                .filter { inkStroke in inkStroke.contains { screenCapture.displayFrame.contains($0) } }
                .map { inkStroke in inkStroke.map { Self.screenshotCoordinate(forGlobalScreenLocation: $0, in: screenCapture) } }
            guard !inkStrokesOnThisScreen.isEmpty,
                  let inkedImageData = UserInkCompositor.screenshotJPEGData(screenCapture.imageData, withInkStrokes: inkStrokesOnThisScreen) else {
                return screenCapture
            }
            print("🖍️ Drew \(inkStrokesOnThisScreen.count) user stroke(s) into the screenshot of \(screenCapture.label)")
            #if DEBUG
            saveDebugCopyOfInkedScreenshot(inkedImageData)
            #endif
            return CompanionScreenCapture(
                imageData: inkedImageData,
                label: screenCapture.label,
                isCursorScreen: screenCapture.isCursorScreen,
                displayWidthInPoints: screenCapture.displayWidthInPoints,
                displayHeightInPoints: screenCapture.displayHeightInPoints,
                displayFrame: screenCapture.displayFrame,
                screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
                screenshotHeightInPixels: screenCapture.screenshotHeightInPixels
            )
        }
    }

    // MARK: - Guided Steps

    /// Starts a fresh guided walkthrough budget. Called whenever the user asks
    /// something themselves, so automatic steps never outlive their question.
    private func resetGuidedSteps() {
        guidedStepAdvanceTask?.cancel()
        guidedStepAdvanceTask = nil
        pendingGuidedStepTarget = nil
        guidedStepNumber = 0
        guidedStepTurnsRemaining = Self.maximumGuidedStepTurns
        guidedAppProcessIdentifier = nil
    }

    /// If a guided step is waiting for a click, treats this click as the user
    /// doing it: stops talking, wipes the old step, waits for the app to update
    /// and asks Claude for the next step. Clicks off the target still advance,
    /// and Claude is told, so it can see what happened and steer them back.
    /// Returns whether the click was used.
    @discardableResult
    func advanceGuidedStepIfWaiting(afterClickAt clickLocation: CGPoint) -> Bool {
        guard let pendingGuidedStepTarget,
              guidedStepTurnsRemaining > 0,
              voiceState != .listening else { return false }

        // Generous margin: the ring is drawn a little bigger than the target
        let didClickTarget = pendingGuidedStepTarget.globalRect.insetBy(dx: -24, dy: -24).contains(clickLocation)
        if !didClickTarget,
           let guidedAppProcessIdentifier,
           Self.processIdentifierOfWindow(atGlobalLocation: clickLocation) != guidedAppProcessIdentifier {
            // A click in some other app isn't part of this walkthrough
            return false
        }
        let targetName = pendingGuidedStepTarget.label ?? "the thing you marked"
        self.pendingGuidedStepTarget = nil
        guidedStepTurnsRemaining -= 1
        clearUserInk()

        currentResponseTask?.cancel()
        sentenceSpeaker.stopSpeaking()
        cancelVisualSequence()

        let followUpTranscript = didClickTarget
            ? "(guided step) i clicked \(targetName). what's next?"
            : "(guided step) i clicked somewhere else instead of \(targetName). what now?"
        print("👣 Guided step: \(didClickTarget ? "clicked the target" : "clicked elsewhere"), \(guidedStepTurnsRemaining) automatic steps left")

        guidedStepAdvanceTask?.cancel()
        guidedStepAdvanceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.guidedStepScreenSettleDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            sendTranscriptToClaudeWithScreenshot(transcript: followUpTranscript)
        }
        return true
    }

    /// The app whose window is under a global (AppKit) point, skipping Clicky's
    /// own overlay windows. Window owners and bounds don't need any permission.
    private static func processIdentifierOfWindow(atGlobalLocation globalLocation: CGPoint) -> pid_t? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryScreenHeight = NSScreen.screens.first?.frame.height else { return nil }
        // Window bounds use a top-left origin on the primary display
        let topLeftOriginPoint = CGPoint(x: globalLocation.x, y: primaryScreenHeight - globalLocation.y)
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        // The list is ordered front to back, so the first hit is what was clicked
        for windowInfo in windowInfoList {
            guard let ownerProcessIdentifier = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessIdentifier != ownProcessIdentifier,
                  (windowInfo[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowBounds = CGRect(dictionaryRepresentation: windowBoundsDictionary),
                  windowBounds.contains(topLeftOriginPoint) else { continue }
            return ownerProcessIdentifier
        }
        return nil
    }

    /// If this beat is a guided-step target, numbers its ring ("2. export") and
    /// remembers it as the click to wait for. Other beats pass through as is.
    private func prepareGuidedStepTarget(_ resolvedVisualBeat: ResolvedVisualBeat) -> ResolvedVisualBeat {
        guard case .sketch(let targetSketchBeat) = resolvedVisualBeat.content,
              targetSketchBeat.kind == .target else { return resolvedVisualBeat }

        if guidedStepNumber == 0 {
            guidedAppProcessIdentifier = frontmostAppProcessIdentifierWhenScreenshotWasTaken
        }
        guidedStepNumber += 1
        answerHasGuidedTarget = true
        let targetXValues = targetSketchBeat.globalScreenPoints.map(\.x)
        let targetYValues = targetSketchBeat.globalScreenPoints.map(\.y)
        let targetGlobalRect = CGRect(
            x: targetXValues.min() ?? 0,
            y: targetYValues.min() ?? 0,
            width: (targetXValues.max() ?? 0) - (targetXValues.min() ?? 0),
            height: (targetYValues.max() ?? 0) - (targetYValues.min() ?? 0)
        )
        pendingGuidedStepTarget = (targetGlobalRect, targetSketchBeat.label)
        print("👣 Guided step \(guidedStepNumber) target: \"\(targetSketchBeat.label ?? "")\" at \(targetGlobalRect.integral)")

        let numberedTargetSketchBeat = ResolvedSketchBeat(
            id: targetSketchBeat.id,
            kind: targetSketchBeat.kind,
            globalScreenPoints: targetSketchBeat.globalScreenPoints,
            label: "\(guidedStepNumber). \(targetSketchBeat.label ?? "click here")",
            inkColor: targetSketchBeat.inkColor,
            displayFrame: targetSketchBeat.displayFrame,
            isOverDarkBackground: targetSketchBeat.isOverDarkBackground,
            labelObstacleGlobalRects: targetSketchBeat.labelObstacleGlobalRects
        )
        return ResolvedVisualBeat(
            content: .sketch(numberedTargetSketchBeat),
            displayFrame: resolvedVisualBeat.displayFrame,
            spokenTextOffsetWhereBeatIsDescribed: resolvedVisualBeat.spokenTextOffsetWhereBeatIsDescribed
        )
    }

    func stop() {
        chatBackend.shutDown()
        backgroundAgentJobService.stopAllRunningJobs()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        answerVisualTagResolutionChain?.cancel()
        sentenceSpeaker.stopSpeaking()
        sketchIdleClearTask?.cancel()
        if let sketchClearingInputMonitor {
            NSEvent.removeMonitor(sketchClearingInputMonitor)
            self.sketchClearingInputMonitor = nil
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
        dictationShortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .dictationShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleDictationShortcutTransition(transition)
            }
    }

    // MARK: - Dictation Into Any App

    /// fn + control: record while held, then type the cleaned-up words into
    /// whatever text field has focus. Nothing goes to Claude.
    private func handleDictationShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Clicky talking would end up in the recording
            currentResponseTask?.cancel()
            sentenceSpeaker.stopSpeaking()
            cancelVisualSequence()

            // Show the waveform at the cursor while listening
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.typeDictatedText(finalTranscript)
                    }
                )
            }
        case .released:
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    func typeDictatedText(_ rawTranscript: String) {
        let cleanedDictation = DictationTextCleaner.cleanedDictation(rawTranscript)
        guard !cleanedDictation.isEmpty else { return }
        print("⌨️ Dictation: \"\(cleanedDictation)\"")
        FocusedFieldTextInserter.typeIntoFocusedField(cleanedDictation)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Start Claude Code now, so it's ready by the time they finish talking
            chatBackend.prepareForUpcomingRequest(systemPrompt: Self.companionVoiceResponseSystemPrompt)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            sentenceSpeaker.stopSpeaking()
            cancelVisualSequence()
            resetGuidedSteps()
            clearUserInk()
            setAcceptingUserInk(true)

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            setAcceptingUserInk(false)
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two short sentences. be direct and dense.
    - when they want to do something on screen, guide them one step at a time with a target on the next thing to click (see guided steps below). never walk through a whole long process in one answer.
    - only go long when they ask you to explain an idea in depth, not for how-tos.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    showing things on screen:
    you can point and draw right on top of their screen, like a friend leaning over their shoulder with a marker. the cursor flies over and does it while you talk. use it whenever showing would help more than telling: where a button is, what to click next, which setting matters, what's wrong. skip it for general questions that have nothing to do with the screen.

    every coordinate is in pixels of the screenshot you're looking at. the images are labeled with their sizes. (0,0) is the top-left corner, x goes right, y goes down. be precise and look carefully at where the element really is. a mark in the wrong spot is worse than no mark.

    if the screenshot has red hand-drawn marks on it, the user drew them while asking: they circled or pointed at what they mean, so talk about that thing.

    point: [POINT:x,y:label] flies the cursor to one spot with a little label bubble. good for "it's right here".

    draw: [DRAW:kind numbers label="..."]
    - [DRAW:circle x1,y1,x2,y2 label="..."] rings the element whose box goes from top-left (x1,y1) to bottom-right (x2,y2). fit the box tightly around the element itself.
    - [DRAW:arrow x1,y1,x2,y2 label="..."] arrow from (x1,y1) to (x2,y2), the tip lands on (x2,y2). start it in empty space about 80 to 200 pixels away and put the label at the start, so nothing important gets covered.
    - [DRAW:box x1,y1,x2,y2 label="..."] rectangle around a bigger area, like a panel, a row or a group of settings.
    - [DRAW:underline x1,y1,x2,y2] line under a word or value, from its left end to its right end.
    - [DRAW:highlight x1,y1,x2,y2] highlighter over a line of text.
    - [DRAW:cross x1,y1,x2,y2] an x over something wrong or to avoid. red by default.
    - [DRAW:check x,y] a check mark next to something that's right. green by default.
    - [DRAW:path x1,y1,x2,y2,x3,y3,...] a freehand line through the points, for showing a drag or a gesture.
    - [DRAW:text x,y label="..."] a short handwritten note whose left edge starts at (x,y). put it in empty space.
    optional on any of them: color=blue|red|green|yellow|orange|purple (blue is the default, use red for problems and green for what's right), and screen=N when it's on another screen (N from the image labels; without it the mark lands on the cursor's screen).

    how to use them:
    - put each tag right after the sentence it goes with. they're shown in order as you say each sentence.
    - labels are one to three words, lowercase. never sentences.
    - most answers need one to three marks. never more than six.
    - if their next move is a click, mark it with a target, not a circle, even when it's a single click. circles, arrows and the rest are for explaining and showing where things are.
    - only mark things you can see in the screenshot right now. if a step's button only shows up after an earlier click (like something inside a menu that isn't open yet), say that step in words, and they can ask again once it's open.
    - if showing wouldn't help at all, end with [POINT:none].

    background tasks:
    if they ask you to go do something that takes real work rather than a quick answer, like researching a topic, writing or making a file (a document, a pdf, a spreadsheet, a small website), comparing options, or tidying files, hand it to a background agent: say in one short sentence that you're on it, then add [AGENT:short title|the full brief]. the brief goes to another claude that can't hear them and only sees a screenshot of this screen, so spell out the goal, every detail they gave, and what to make in what format. no square brackets inside the brief. it can browse the web and make files, but it can't use their accounts or send anything, so don't promise that. don't use it for quick questions or for clicking through an app with them; you do those yourself. if you're not sure they want you to go off and do it, ask.

    guided steps:
    when they want help doing something on screen that takes a few clicks, walk them through it one step at a time. say only the very next step in one short sentence and mark the exact thing to click with [DRAW:target x1,y1,x2,y2 label="..."], a tight box around it like a circle. as soon as they click, you automatically get a fresh screenshot and a message like "(guided step) i clicked export. what's next?", and you give the next step the same way. if they clicked somewhere else, look at the new screen and get them back on track. if the next step isn't a click (typing, dragging, a keyboard shortcut), say it plainly without a target and they'll tell you when they're ready. when the task is done, say so in a few words and don't add a target. at most one target per answer; you can still add other marks to explain.

    examples:
    - user asks how to color grade in final cut: "open the color inspector with this button up in the toolbar. [DRAW:target 1086,30,1114,54 label="color inspector"]"
    - user asks where their downloads went: "they're in this downloads folder in the sidebar. [DRAW:circle 20,310,130,330 label="downloads"]"
    - user asks what html is: "html is the skeleton of every web page, it says what's on the page and css decides how it looks. [POINT:none]"
    - user asks how to export their project: "first click your project down here to select it. [DRAW:target 150,628,290,652 label="your project"]" then, after "(guided step) i clicked your project. what's next?": "now hit share in the top right corner. [DRAW:target 1160,36,1192,60 label="share"]"
    - user asks you to research standing desks under 500 dollars and make a one page pdf of the top three: "on it, i'll put a comparison together in the background and tell you when it's ready. [AGENT:standing desk comparison|research standing desks under 500 us dollars that are well reviewed in 2026, pick the top three, and make a clean one page pdf comparing price, height range, weight capacity, warranty and standout pros and cons, with links to where to buy each. save it as output/standing-desks.pdf.]"
    - user asks why their formula is broken: "this cell points at the wrong column. [DRAW:cross 402,310,470,330] it should use column c instead. [DRAW:arrow 600,250,520,318 label="use column c"]"
    - element is on screen 2 (not where cursor is): "that's on your other monitor, the terminal window. [POINT:400,300:terminal:screen2]"
    - user asks how to export their document as a pdf: "click file up in the menu bar. [DRAW:target 62,4,92,22 label="file"]" then, after "(guided step) i clicked file. what's next?": "now pick export as pdf near the bottom of the menu. [DRAW:target 70,410,190,430 label="export as pdf"]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via TTS. The cursor stays in the
    /// spinner/processing state until the first point or drawing (or the audio).
    /// Claude's response may include [POINT:...] and [DRAW:...] tags that fly
    /// the buddy to elements and sketch on the screen.
    func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        sentenceSpeaker.stopSpeaking()
        cancelVisualSequence()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                var screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // The overlay isn't in screenshots, so draw the user's own marks in
                let didUserDrawOnScreen = !userInkStrokes.isEmpty
                if didUserDrawOnScreen {
                    screenCaptures = screenCapturesWithUserInk(screenCaptures)
                }

                guard !Task.isCancelled else { return }

                let screenCaptureDate = Date()
                frontmostAppProcessIdentifierWhenScreenshotWasTaken = NSWorkspace.shared.frontmostApplication?.processIdentifier
                mouseLocationWhenScreenshotWasTaken = NSEvent.mouseLocation

                // Read the screen's text while Claude thinks, to line drawings up with it
                let screenTextRecognitionTask = Self.startScreenTextRecognition(for: screenCaptures)
                beginStreamingAnswer(
                    screenCaptures: screenCaptures,
                    screenCaptureDate: screenCaptureDate,
                    screenTextRecognitionTask: screenTextRecognitionTask
                )

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await chatBackend.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: didUserDrawOnScreen
                        ? "\(transcript)\n\n(i drew on my screen in red to show you what i mean)"
                        : transcript,
                    onTextChunk: { [weak self] accumulatedResponseText in
                        // Start speaking (and drawing) each sentence as soon as it's complete
                        guard !Task.isCancelled else { return }
                        self?.receiveStreamedAnswerText(accumulatedResponseText, isAnswerComplete: false)
                    }
                )

                guard !Task.isCancelled else { return }

                print("🤖 Claude response: \(fullResponseText)")

                receiveStreamedAnswerText(fullResponseText, isAnswerComplete: true)
                await waitForStreamingAnswerToSettle()

                // History keeps the tags: answers without them teach Claude to
                // stop pointing and drawing in later turns.
                conversationHistory.append((userTranscript: transcript, assistantResponse: fullResponseText))
                completedVoiceAnswerCount += 1
                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                ClickyAnalytics.trackAIResponseReceived(response: ClaudeVisualTagParser.parseVisualBeats(from: fullResponseText).spokenText)
            } catch where Self.isCancellation(error) {
                // User spoke again (or clicked a guided step) — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakAnswerFailure(error)
            }

            if !Task.isCancelled {
                if voiceState == .processing {
                    voiceState = .idle
                }
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// How different a mark's surroundings may look before the mark is
    /// considered stale (0...1, from ScreenshotBrightnessSampler.regionDifference).
    private static let maximumRegionDifferenceForStillValidMark = 0.03

    /// Re-captures the screens and keeps only beats whose surroundings look the
    /// same as in the screenshot Claude answered from.
    private func visualBeatsStillMatchingTheScreen(
        _ resolvedVisualBeats: [ResolvedVisualBeat],
        screenCaptures: [CompanionScreenCapture]
    ) async -> [ResolvedVisualBeat] {
        guard let freshScreenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() else {
            print("🚫 Not drawing: the screen changed and couldn't be checked again")
            return []
        }
        let mouseLocationsToIgnore = [mouseLocationWhenScreenshotWasTaken, NSEvent.mouseLocation]

        var decodedImagePairsByDisplayFrame: [String: (original: CGImage, fresh: CGImage, capture: CompanionScreenCapture)] = [:]
        for originalScreenCapture in screenCaptures {
            guard let freshScreenCapture = freshScreenCaptures.first(where: { $0.displayFrame == originalScreenCapture.displayFrame }),
                  let originalImage = ScreenshotBrightnessSampler.decodeScreenshotImage(from: originalScreenCapture.imageData),
                  let freshImage = ScreenshotBrightnessSampler.decodeScreenshotImage(from: freshScreenCapture.imageData),
                  originalImage.width == freshImage.width, originalImage.height == freshImage.height else { continue }
            decodedImagePairsByDisplayFrame[NSStringFromRect(originalScreenCapture.displayFrame)] = (originalImage, freshImage, originalScreenCapture)
        }

        return resolvedVisualBeats.filter { visualBeat in
            guard let imagePair = decodedImagePairsByDisplayFrame[NSStringFromRect(visualBeat.displayFrame)] else { return false }

            let beatGlobalPoints: [CGPoint]
            switch visualBeat.content {
            case .point(let globalScreenLocation, _): beatGlobalPoints = [globalScreenLocation]
            case .sketch(let sketchBeat): beatGlobalPoints = sketchBeat.globalScreenPoints
            }
            let beatScreenshotPoints = beatGlobalPoints.map { Self.screenshotCoordinate(forGlobalScreenLocation: $0, in: imagePair.capture) }
            let screenshotXValues = beatScreenshotPoints.map(\.x)
            let screenshotYValues = beatScreenshotPoints.map(\.y)
            // Include some surroundings: a mark is still right if what's around it didn't move
            let surroundingsRect = CGRect(
                x: (screenshotXValues.min() ?? 0) - 40,
                y: (screenshotYValues.min() ?? 0) - 40,
                width: (screenshotXValues.max() ?? 0) - (screenshotXValues.min() ?? 0) + 80,
                height: (screenshotYValues.max() ?? 0) - (screenshotYValues.min() ?? 0) + 80
            )
            // The pointer moving around isn't the screen changing
            let pointerScreenshotRects = mouseLocationsToIgnore.map { mouseLocation -> CGRect in
                let pointerScreenshotPoint = Self.screenshotCoordinate(forGlobalScreenLocation: mouseLocation, in: imagePair.capture)
                return CGRect(x: pointerScreenshotPoint.x - 12, y: pointerScreenshotPoint.y - 12, width: 44, height: 44)
            }
            guard let regionDifference = ScreenshotBrightnessSampler.regionDifference(
                between: imagePair.original,
                and: imagePair.fresh,
                in: surroundingsRect,
                ignoring: pointerScreenshotRects
            ) else {
                return false
            }
            let isStillValid = regionDifference <= Self.maximumRegionDifferenceForStillValidMark
            if !isStillValid {
                print("🚫 Not drawing a mark: the screen changed under it (difference \(String(format: "%.3f", regionDifference)))")
            }
            return isStillValid
        }
    }

    /// The inverse of `globalScreenLocation(forScreenshotCoordinate:in:)`.
    static func screenshotCoordinate(forGlobalScreenLocation globalScreenLocation: CGPoint, in screenCapture: CompanionScreenCapture) -> CGPoint {
        let displayFrame = screenCapture.displayFrame
        let displayLocalX = globalScreenLocation.x - displayFrame.origin.x
        let displayLocalYFromBottom = globalScreenLocation.y - displayFrame.origin.y
        let displayLocalYFromTop = CGFloat(screenCapture.displayHeightInPoints) - displayLocalYFromBottom
        return CGPoint(
            x: displayLocalX * CGFloat(screenCapture.screenshotWidthInPixels) / CGFloat(screenCapture.displayWidthInPoints),
            y: displayLocalYFromTop * CGFloat(screenCapture.screenshotHeightInPixels) / CGFloat(screenCapture.displayHeightInPoints)
        )
    }

    /// Recognizes the text on every captured screen in the background. The
    /// result is indexed like `screenCaptures`; screens that fail come back empty.
    static func startScreenTextRecognition(for screenCaptures: [CompanionScreenCapture]) -> Task<[[RecognizedScreenTextLine]], Never> {
        let screenshotImageDatas = screenCaptures.map(\.imageData)
        return Task.detached(priority: .userInitiated) {
            screenshotImageDatas.map { screenshotImageData in
                guard let screenshotImage = ScreenshotBrightnessSampler.decodeScreenshotImage(from: screenshotImageData) else { return [] }
                return ScreenTextRecognizer.recognizeTextLines(in: screenshotImage)
            }
        }
    }

    /// Converts parsed beats from screenshot pixels to global screen coordinates,
    /// dropping any that refer to a screen that doesn't exist. Marks whose label
    /// names on-screen text they clearly missed are moved onto that text.
    private func resolveVisualBeats(
        _ parsedVisualBeats: [ParsedVisualBeat],
        screenCaptures: [CompanionScreenCapture],
        recognizedTextLinesByCaptureIndex: [[RecognizedScreenTextLine]]
    ) -> [ResolvedVisualBeat] {
        // Decoded lazily, only for screens that get a drawing
        var decodedScreenshotImagesByCaptureIndex: [Int: CGImage] = [:]

        return parsedVisualBeats.compactMap { parsedVisualBeat in
            // Pick the screen capture matching Claude's screen number,
            // falling back to the cursor screen if not specified.
            let targetCaptureIndex: Int? = {
                if let screenNumber = parsedVisualBeat.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenNumber - 1
                }
                return screenCaptures.firstIndex(where: { $0.isCursorScreen })
            }()
            guard let targetCaptureIndex else { return nil }
            let targetScreenCapture = screenCaptures[targetCaptureIndex]
            let recognizedTextLines = recognizedTextLinesByCaptureIndex.indices.contains(targetCaptureIndex)
                ? recognizedTextLinesByCaptureIndex[targetCaptureIndex]
                : []

            switch parsedVisualBeat.content {
            case .point(let proposedCoordinate, let elementLabel):
                var coordinate = proposedCoordinate
                if let correctedTargetRect = ScreenSketchTargetSnapper.correctedTargetRect(
                    forLabel: elementLabel,
                    proposedRect: CGRect(x: proposedCoordinate.x - 12, y: proposedCoordinate.y - 12, width: 24, height: 24),
                    recognizedTextLines: recognizedTextLines
                ) {
                    coordinate = CGPoint(x: correctedTargetRect.midX, y: correctedTargetRect.midY)
                    print("🧲 Snapped point \"\(elementLabel ?? "")\" from (\(Int(proposedCoordinate.x)),\(Int(proposedCoordinate.y))) to (\(Int(coordinate.x)),\(Int(coordinate.y)))")
                }
                return ResolvedVisualBeat(
                    content: .point(
                        globalScreenLocation: Self.globalScreenLocation(forScreenshotCoordinate: coordinate, in: targetScreenCapture),
                        elementLabel: elementLabel
                    ),
                    displayFrame: targetScreenCapture.displayFrame,
                    spokenTextOffsetWhereBeatIsDescribed: parsedVisualBeat.spokenTextOffsetWhereBeatIsDescribed
                )

            case .sketch(let proposedMarkRequest):
                let markRequest = Self.markRequestSnappedToNamedText(proposedMarkRequest, recognizedTextLines: recognizedTextLines)
                if decodedScreenshotImagesByCaptureIndex[targetCaptureIndex] == nil {
                    decodedScreenshotImagesByCaptureIndex[targetCaptureIndex] = ScreenshotBrightnessSampler.decodeScreenshotImage(from: targetScreenCapture.imageData)
                }
                let markXValues = markRequest.screenshotPoints.map(\.x)
                let markYValues = markRequest.screenshotPoints.map(\.y)
                let markScreenshotBounds = CGRect(
                    x: markXValues.min() ?? 0,
                    y: markYValues.min() ?? 0,
                    width: (markXValues.max() ?? 0) - (markXValues.min() ?? 0),
                    height: (markYValues.max() ?? 0) - (markYValues.min() ?? 0)
                )
                let backgroundBrightness = decodedScreenshotImagesByCaptureIndex[targetCaptureIndex].flatMap {
                    ScreenshotBrightnessSampler.averageBrightness(of: $0, in: markScreenshotBounds)
                } ?? 1

                let sketchBeat = ResolvedSketchBeat(
                    id: UUID(),
                    kind: markRequest.kind,
                    globalScreenPoints: markRequest.screenshotPoints.map {
                        Self.globalScreenLocation(forScreenshotCoordinate: $0, in: targetScreenCapture)
                    },
                    label: markRequest.label,
                    inkColor: markRequest.inkColor,
                    displayFrame: targetScreenCapture.displayFrame,
                    isOverDarkBackground: backgroundBrightness < 0.45,
                    // Labels steer clear of on-screen text
                    labelObstacleGlobalRects: recognizedTextLines.map {
                        Self.globalScreenRect(forScreenshotRect: $0.screenshotRect, in: targetScreenCapture)
                    }
                )
                return ResolvedVisualBeat(
                    content: .sketch(sketchBeat),
                    displayFrame: targetScreenCapture.displayFrame,
                    spokenTextOffsetWhereBeatIsDescribed: parsedVisualBeat.spokenTextOffsetWhereBeatIsDescribed
                )
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while sentenceSpeaker.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Cancelling a task cancels its URLSession requests too, and those surface
    /// as URLError.cancelled rather than CancellationError. Either way the user
    /// interrupted on purpose, so it must not be reported as a failure.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// Says why there's no answer. A sign-in or install problem also refreshes
    /// the setup state so the panel shows how to fix it.
    private func speakAnswerFailure(_ answerError: Error) {
        let claudeCodeError = answerError as? ClaudeCodeCLIError
        let spokenExplanation = claudeCodeError?.spokenExplanation
            ?? "I couldn't reach Claude. Try again in a moment."
        sentenceSpeaker.stopSpeaking()
        agentAnnouncementSpeaker.enqueueSentence(spokenExplanation, sentenceIndex: 0)
        switch claudeCodeError {
        case .notInstalled, .notSignedIn:
            Task { await refreshClaudeCodeSetupState(forceRefresh: true) }
        default:
            break
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// A mark ready for BlueCursorView to draw, in global AppKit screen coordinates.
    struct ResolvedSketchBeat: Equatable {
        let id: UUID
        let kind: ScreenSketchMarkKind
        let globalScreenPoints: [CGPoint]
        let label: String?
        let inkColor: ScreenSketchInkColor
        let displayFrame: CGRect
        let isOverDarkBackground: Bool
        /// On-screen text the mark's label should avoid covering.
        let labelObstacleGlobalRects: [CGRect]
    }

    enum ResolvedVisualBeatContent {
        case point(globalScreenLocation: CGPoint, elementLabel: String?)
        case sketch(ResolvedSketchBeat)
    }

    /// A POINT or DRAW beat converted to global screen coordinates.
    struct ResolvedVisualBeat {
        let id = UUID()
        let content: ResolvedVisualBeatContent
        let displayFrame: CGRect
        let spokenTextOffsetWhereBeatIsDescribed: Int

        var isPoint: Bool {
            if case .point = content { return true }
            return false
        }
    }

    /// Moves a ring, box, highlight or cross onto the on-screen text its label
    /// names when Claude's box clearly missed it. Other marks are returned as is.
    private static func markRequestSnappedToNamedText(
        _ proposedMarkRequest: ScreenSketchMarkRequest,
        recognizedTextLines: [RecognizedScreenTextLine]
    ) -> ScreenSketchMarkRequest {
        // Boxes mark regions (a panel, a card), not one named element
        let snappableKinds: Set<ScreenSketchMarkKind> = [.circle, .target, .highlight, .cross]
        guard snappableKinds.contains(proposedMarkRequest.kind),
              proposedMarkRequest.screenshotPoints.count >= 2 else { return proposedMarkRequest }

        let firstCorner = proposedMarkRequest.screenshotPoints[0]
        let secondCorner = proposedMarkRequest.screenshotPoints[1]
        let proposedRect = CGRect(
            x: min(firstCorner.x, secondCorner.x),
            y: min(firstCorner.y, secondCorner.y),
            width: abs(secondCorner.x - firstCorner.x),
            height: abs(secondCorner.y - firstCorner.y)
        )
        guard let correctedTargetRect = ScreenSketchTargetSnapper.correctedTargetRect(
            forLabel: proposedMarkRequest.label,
            proposedRect: proposedRect,
            recognizedTextLines: recognizedTextLines
        ) else { return proposedMarkRequest }

        print("🧲 Snapped \(proposedMarkRequest.kind.rawValue) \"\(proposedMarkRequest.label ?? "")\" from \(proposedRect.integral) to \(correctedTargetRect.integral)")
        return ScreenSketchMarkRequest(
            kind: proposedMarkRequest.kind,
            screenshotPoints: [
                CGPoint(x: correctedTargetRect.minX, y: correctedTargetRect.minY),
                CGPoint(x: correctedTargetRect.maxX, y: correctedTargetRect.maxY)
            ],
            label: proposedMarkRequest.label,
            inkColor: proposedMarkRequest.inkColor,
            screenNumber: proposedMarkRequest.screenNumber
        )
    }

    /// Converts a rect in a screenshot's pixel space to a global AppKit rect.
    static func globalScreenRect(forScreenshotRect screenshotRect: CGRect, in screenCapture: CompanionScreenCapture) -> CGRect {
        let firstCorner = globalScreenLocation(forScreenshotCoordinate: CGPoint(x: screenshotRect.minX, y: screenshotRect.minY), in: screenCapture)
        let secondCorner = globalScreenLocation(forScreenshotCoordinate: CGPoint(x: screenshotRect.maxX, y: screenshotRect.maxY), in: screenCapture)
        return CGRect(
            x: min(firstCorner.x, secondCorner.x),
            y: min(firstCorner.y, secondCorner.y),
            width: abs(secondCorner.x - firstCorner.x),
            height: abs(secondCorner.y - firstCorner.y)
        )
    }

    /// Converts a coordinate in a screenshot's pixel space (top-left origin,
    /// e.g. 1280x831) to a global AppKit screen location on that display.
    static func globalScreenLocation(
        forScreenshotCoordinate screenshotCoordinate: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        // Clamp to screenshot coordinate space
        let clampedX = max(0, min(screenshotCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(screenshotCoordinate.y, screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    // MARK: - Debug Automation

    #if DEBUG
    /// Lets a terminal drive Clicky while developing, so features like sketching
    /// can be tested end to end without holding the hotkey and talking:
    ///   com.clicky.debug.ask       userInfo["text"]: ask Claude as if spoken
    ///   com.clicky.debug.present   userInfo["text"]: show and speak a canned answer
    ///   com.clicky.debug.snapshot  userInfo["name"]: save the main display, overlay included
    ///   com.clicky.debug.click     userInfo["x"], ["y"]: a click at a global point (guided steps)
    ///   com.clicky.debug.dictate   userInfo["text"]: type it into the focused field as dictation
    ///   com.clicky.debug.ink       userInfo["points"]: "x,y x,y ...": the user's ink, as if drawn
    ///   com.clicky.debug.clear     cancel the walkthrough and wipe drawings
    /// Only active in debug builds launched with CLICKY_DEBUG_AUTOMATION=1:
    /// the snapshot hook would otherwise let any local process capture the
    /// screen through Clicky's Screen Recording permission.
    private func installDebugAutomationObserversIfEnabled() {
        guard ProcessInfo.processInfo.environment["CLICKY_DEBUG_AUTOMATION"] == "1" else { return }
        let distributedNotificationCenter = DistributedNotificationCenter.default()

        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.ask"), object: nil, queue: .main) { [weak self] notification in
            guard let transcript = notification.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                print("🧪 Debug ask: \(transcript)")
                self?.resetGuidedSteps()
                self?.sendTranscriptToClaudeWithScreenshot(transcript: transcript)
            }
        }
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.present"), object: nil, queue: .main) { [weak self] notification in
            guard let responseText = notification.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                print("🧪 Debug present: \(responseText)")
                self?.debugPresentResponse(responseText)
            }
        }
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.snapshot"), object: nil, queue: .main) { [weak self] notification in
            let snapshotName = notification.userInfo?["name"] as? String ?? "latest"
            Task { @MainActor in
                self?.saveDebugSnapshotOfMainDisplay(named: snapshotName)
            }
        }
        // Simulates the user clicking at a global screen point (AppKit coordinates)
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.click"), object: nil, queue: .main) { [weak self] notification in
            guard let xText = notification.userInfo?["x"] as? String, let x = Double(xText),
                  let yText = notification.userInfo?["y"] as? String, let y = Double(yText) else { return }
            Task { @MainActor in
                print("🧪 Debug click at (\(Int(x)),\(Int(y)))")
                self?.lastScreenChangingInputDate = Date()
                self?.advanceGuidedStepIfWaiting(afterClickAt: CGPoint(x: x, y: y))
            }
        }
        // Sets the user's ink as if they had drawn it: userInfo["points"] = "x1,y1 x2,y2 ..." in global coordinates
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.ink"), object: nil, queue: .main) { [weak self] notification in
            guard let pointsText = notification.userInfo?["points"] as? String else { return }
            let inkPoints = pointsText.split(separator: " ").compactMap { pointText -> CGPoint? in
                let coordinates = pointText.split(separator: ",").compactMap { Double($0) }
                return coordinates.count == 2 ? CGPoint(x: coordinates[0], y: coordinates[1]) : nil
            }
            Task { @MainActor in
                guard let self else { return }
                print("🧪 Debug ink: \(inkPoints.count) points")
                self.isAcceptingUserInk = true
                self.userInkStrokes = [inkPoints]
                self.isAcceptingUserInk = false
            }
        }
        // Types text into the focused field as if it had been dictated
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.dictate"), object: nil, queue: .main) { [weak self] notification in
            guard let dictatedText = notification.userInfo?["text"] as? String else { return }
            Task { @MainActor in
                self?.typeDictatedText(dictatedText)
            }
        }
        distributedNotificationCenter.addObserver(forName: Notification.Name("com.clicky.debug.clear"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                print("🧪 Debug clear")
                self?.cancelVisualSequence()
            }
        }
        print("🧪 Debug automation enabled")
    }

    /// Shows and speaks `responseText` as if Claude had just answered with it,
    /// against a fresh screenshot, without calling Claude.
    private func debugPresentResponse(_ responseText: String) {
        currentResponseTask?.cancel()
        sentenceSpeaker.stopSpeaking()
        cancelVisualSequence()

        currentResponseTask = Task {
            voiceState = .processing
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }
                mouseLocationWhenScreenshotWasTaken = NSEvent.mouseLocation
                beginStreamingAnswer(
                    screenCaptures: screenCaptures,
                    screenCaptureDate: Date(),
                    screenTextRecognitionTask: Self.startScreenTextRecognition(for: screenCaptures)
                )
                receiveStreamedAnswerText(responseText, isAnswerComplete: true)
                await waitForStreamingAnswerToSettle()
            } catch {
                print("⚠️ Debug present failed: \(error)")
            }
            if !Task.isCancelled && voiceState == .processing {
                voiceState = .idle
            }
        }
    }

    /// Keeps the last screenshot sent to Claude with the user's ink drawn in,
    /// when debug automation is on, so tests can check what Claude saw.
    private func saveDebugCopyOfInkedScreenshot(_ inkedImageData: Data) {
        guard ProcessInfo.processInfo.environment["CLICKY_DEBUG_AUTOMATION"] == "1",
              let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let snapshotDirectory = cachesDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "clicky")
            .appendingPathComponent("debug-snapshots")
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try? inkedImageData.write(to: snapshotDirectory.appendingPathComponent("last-inked-screenshot.jpg"))
    }

    /// Saves the main display to ~/Library/Caches/<bundle id>/debug-snapshots/<name>.png.
    /// Unlike the screenshots sent to Claude, this includes Clicky's own windows,
    /// since the point is to see what the overlay drew.
    private func saveDebugSnapshotOfMainDisplay(named requestedSnapshotName: String) {
        let allowedNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedSnapshotName = String(requestedSnapshotName.unicodeScalars.filter { allowedNameCharacters.contains($0) }.prefix(60))
        let snapshotName = sanitizedSnapshotName.isEmpty ? "latest" : sanitizedSnapshotName

        Task {
            do {
                let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let mainDisplay = shareableContent.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? shareableContent.displays.first else { return }

                let contentFilter = SCContentFilter(display: mainDisplay, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = mainDisplay.width
                configuration.height = mainDisplay.height
                let snapshotImage = try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)

                guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
                let snapshotDirectory = cachesDirectory
                    .appendingPathComponent(Bundle.main.bundleIdentifier ?? "clicky")
                    .appendingPathComponent("debug-snapshots")
                try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
                let snapshotURL = snapshotDirectory.appendingPathComponent("\(snapshotName).png")
                let snapshotBitmap = NSBitmapImageRep(cgImage: snapshotImage)
                try snapshotBitmap.representation(using: .png, properties: [:])?.write(to: snapshotURL)
                print("📸 Debug snapshot saved: \(snapshotURL.path)")
            } catch {
                print("⚠️ Debug snapshot failed: \(error)")
            }
        }
    }
    #endif

}
