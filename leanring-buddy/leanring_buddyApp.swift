//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var setupWindowController: SetupWindowController?
    private var openSetupObserver: NSObjectProtocol?
    private var conversationHistoryWindowController: ConversationHistoryWindowController?
    private var openConversationHistoryObserver: NSObjectProtocol?
    private var connectedAppsWindowController: ConnectedAppsWindowController?
    private var openConnectedAppsObserver: NSObjectProtocol?
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // PostHog is off for local builds: the upstream key would send your
        // voice transcripts and Claude's replies to the original author's project.
        // With setup skipped, every ClickyAnalytics.track* call is a no-op.
        // ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        let setupWindowController = SetupWindowController(companionManager: companionManager)
        self.setupWindowController = setupWindowController
        openSetupObserver = NotificationCenter.default.addObserver(
            forName: .clickyOpenSetup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setupWindowController?.showSetup() }
        }

        conversationHistoryWindowController = ConversationHistoryWindowController(companionManager: companionManager)
        openConversationHistoryObserver = NotificationCenter.default.addObserver(
            forName: .clickyOpenConversationHistory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.conversationHistoryWindowController?.showHistory() }
        }

        connectedAppsWindowController = ConnectedAppsWindowController(companionManager: companionManager)
        openConnectedAppsObserver = NotificationCenter.default.addObserver(
            forName: .clickyOpenConnectedApps,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.connectedAppsWindowController?.showConnectedApps() }
        }

        companionManager.start()
        companionManager.applyOpenAtLoginPreference()

        // Open setup if there's still something to do: first launch, a
        // permission was turned off, or Claude Code is missing or signed out.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            setupWindowController.showSetup()
        }
        Task { @MainActor [companionManager] in
            await companionManager.refreshClaudeCodeSetupState()
            if !companionManager.claudeCodeSetupState.isReady && !setupWindowController.isShowingSetup {
                setupWindowController.showSetup()
            }
        }
        // startSparkleUpdater()
    }

    /// Opening Clicky again (Spotlight, Finder, Launchpad) while it's running
    /// brings it up: setup if that isn't finished, otherwise the panel. That
    /// keeps it reachable when the menu bar is too full to show its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !companionManager.hasCompletedOnboarding || setupWindowController?.isShowingSetup == true {
            setupWindowController?.showSetup()
        } else {
            menuBarPanelManager?.showPanelFromReopen()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
