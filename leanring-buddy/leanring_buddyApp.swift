//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Companion app with a Dock icon and a small menu bar icon, and no main
//  window. Clicking either one opens a floating panel with companion voice
//  controls; right-clicking the Dock icon quits it like any app. (It used to
//  be menu bar only, but on notch Macs the tiny icon was easy to lose.)
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives in the panel managed by the AppDelegate. This empty
        // Settings scene satisfies SwiftUI's requirement for at least one
        // scene; its menu item opens the panel instead, where the settings are.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
                }
                .keyboardShortcut(",")
            }
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
    private var showPanelObserver: NSObjectProtocol?
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
        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.menuBarPanelManager?.showPanelFromReopen() }
        }
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

    /// Clicking the Dock icon, or opening Clicky again (Spotlight, Finder,
    /// Launchpad) while it's running, brings it up: setup if that isn't
    /// finished, otherwise the panel.
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
