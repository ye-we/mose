// Stand-ins for the app types the setup window and panel use, so they can be
// rendered by scripts/render-ui-gallery.sh without the whole app. Keep the
// member names in step with CompanionManager.

import AppKit
import Combine
import SwiftUI

enum CompanionVoiceState { case idle, listening, processing, responding }

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    @Published var isShortcutCurrentlyPressed = false
}

enum PermissionRequestPresentationDestination { case none }

enum WindowPositionManager {
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination { .none }
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination { .none }
    static func openAccessibilitySettings() {}
    static func revealAppInFinder() {}
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var claudeCodeSetupState: ClaudeCodeSetupState = .checking
    @Published var hasMicrophonePermission = false
    @Published var hasAccessibilityPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasScreenContentPermission = false
    @Published var hasCompletedOnboarding = false
    @Published var completedVoiceAnswerCount = 0
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var backgroundAgentJobs: [BackgroundAgentJob] = []
    @Published var selectedModel = "claude-sonnet-4-6"
    @Published var isExtendedThinkingEnabled = false
    @Published var isOpenAtLoginEnabled = true
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    var conversationStore = ConversationSessionStore(
        conversationsDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("gallery-conversations-\(UUID().uuidString)")
    )
    var userMemoryStore = UserMemoryStore(
        memoryFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("gallery-memory-\(UUID().uuidString).json")
    )
    @Published var agentConnectedAppServerNames: [String] = []
    @Published var availableConnectedApps: [ClaudeCodeConnectedApp]?
    @Published var isLoadingConnectedApps = false
    @Published var connectedAppsLoadingProblem: String?
    func refreshConnectedApps() {}
    func setAgentConnectedApp(serverName: String, isAllowed: Bool) {
        agentConnectedAppServerNames = agentConnectedAppServerNames.filter { $0 != serverName } + (isAllowed ? [serverName] : [])
    }
    func startNewConversation() { conversationStore.startNewSession() }
    func continueConversation(withID conversationID: UUID) { conversationStore.resumeSession(withID: conversationID) }

    var allPermissionsGranted: Bool { hasMicrophonePermission && hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission }

    func refreshClaudeCodeSetupState(forceRefresh: Bool = false) async {}
    func openClaudeCodeInstallerInTerminal() {}
    func openClaudeCodeSignInInTerminal() {}
    func requestMicrophonePermission() {}
    func requestScreenContentPermission() {}
    func finishSetup() {}
    func showCompanionCursorForSetup() {}
    func setSelectedModel(_ model: String) { selectedModel = model }
    func setExtendedThinkingEnabled(_ isEnabled: Bool) { isExtendedThinkingEnabled = isEnabled }
    func setOpenAtLoginEnabled(_ isEnabled: Bool) { isOpenAtLoginEnabled = isEnabled }
    func stopBackgroundAgentJob(_ job: BackgroundAgentJob) {}
    func openBackgroundAgentJobOutput(_ job: BackgroundAgentJob) {}
}

extension Notification.Name { static let clickyDismissPanel = Notification.Name("clickyDismissPanel") }
