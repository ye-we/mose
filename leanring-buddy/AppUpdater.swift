//
//  AppUpdater.swift
//  leanring-buddy
//
//  Updates through Sparkle, for the release copy only (AppUpdatePolicy).
//  Sparkle checks the feed about once a day (SUEnableAutomaticChecks and
//  SUScheduledCheckInterval in Info.plist) and offers a new version in its
//  own window; installing is one click. A check only downloads the appcast:
//  system profiling is off (SUEnableSystemProfiling, SUSendProfileInfo).
//  The app isn't sandboxed, so Sparkle installs without its XPC services.
//

import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an install is under way, and in copies that
    /// can't update themselves, so the menu item and panel button grey out.
    @Published private(set) var canCheckForUpdates = false

    private var sparkleUpdaterController: SPUStandardUpdaterController?

    private init() {}

    /// Called once at launch. Does nothing in the Xcode copy.
    func startIfThisCopyCanUpdateItself() {
        guard sparkleUpdaterController == nil else { return }
        guard AppUpdatePolicy.canThisCopyUpdateItself else {
            print("🎯 Clicky: Updates are off in this copy (\(Bundle.main.bundleIdentifier ?? "no bundle id"))")
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        sparkleUpdaterController = updaterController
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        do {
            try updaterController.updater.start()
            print("🎯 Clicky: Updates on, feed \(updaterController.updater.feedURL?.absoluteString ?? "none")")
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }

    /// "Check for Updates…": Sparkle's window says what it found, including
    /// "you're up to date".
    func checkForUpdates() {
        guard let sparkleUpdaterController, canCheckForUpdates else { return }
        sparkleUpdaterController.checkForUpdates(nil)
    }
}

/// The app menu's "Check for Updates…" item, next to Settings…
struct CheckForUpdatesMenuButton: View {
    @ObservedObject var appUpdater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { appUpdater.checkForUpdates() }
            .disabled(!appUpdater.canCheckForUpdates)
    }
}
