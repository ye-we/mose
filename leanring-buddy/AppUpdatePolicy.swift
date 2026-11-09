//
//  AppUpdatePolicy.swift
//  leanring-buddy
//
//  Which copy of Mose may update itself. Only the downloadable release
//  (bundle id com.yewe.mose, built by scripts/build-shareable-dmg.sh) does:
//  the copy Xcode builds (com.yewe.clicky-local) must never install a release
//  over itself, and it has no feed anyway, since SUFeedURL only gets a value
//  in the Release configuration (MOSE_UPDATE_FEED_URL). No Sparkle here, so
//  the standalone tests and the UI gallery can use it.
//

import Foundation

extension Notification.Name {
    /// Posted by the panel's "Check for updates" button; the app delegate asks
    /// Sparkle to check, which shows its own window either way.
    static let clickyCheckForUpdates = Notification.Name("clickyCheckForUpdates")
}

enum AppUpdatePolicy {
    /// The bundle id of the copy people download.
    static let releaseBundleIdentifier = "com.yewe.mose"

    /// Whether a copy with this bundle id and feed may check for updates and
    /// install them. The feed must be https, or plain http on this Mac only
    /// (local update tests serve an appcast from 127.0.0.1). The update
    /// itself is trusted only if its EdDSA signature matches SUPublicEDKey,
    /// which Sparkle checks whatever the feed.
    static func canUpdateItself(bundleIdentifier: String?, updateFeedURLString: String?) -> Bool {
        guard bundleIdentifier == releaseBundleIdentifier else { return false }
        guard let updateFeedURL = feedURL(fromInfoPlistValue: updateFeedURLString) else { return false }
        return isAllowedFeedURL(updateFeedURL)
    }

    /// The running copy, from its own Info.plist.
    static var canThisCopyUpdateItself: Bool {
        canUpdateItself(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            updateFeedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        )
    }

    /// The Info.plist value is "$(MOSE_UPDATE_FEED_URL)", which Xcode turns
    /// into an empty string in configurations that don't set it.
    static func feedURL(fromInfoPlistValue infoPlistValue: String?) -> URL? {
        guard let trimmedValue = infoPlistValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty,
              !trimmedValue.contains("$(") else {
            return nil
        }
        return URL(string: trimmedValue)
    }

    static func isAllowedFeedURL(_ updateFeedURL: URL) -> Bool {
        guard let scheme = updateFeedURL.scheme?.lowercased(),
              let host = updateFeedURL.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        switch scheme {
        case "https":
            return true
        case "http":
            return host == "127.0.0.1" || host == "localhost"
        default:
            return false
        }
    }
}
