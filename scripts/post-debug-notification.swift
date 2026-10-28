// Sends one of Clicky's debug automation notifications (the app must be
// launched with CLICKY_DEBUG_AUTOMATION=1; see AGENTS.md, "Testing screen
// sketching"). Usage:
//   swift scripts/post-debug-notification.swift com.clicky.debug.ask "text=what's on my screen?"
//   swift scripts/post-debug-notification.swift com.clicky.debug.clear
import Foundation

let commandLineArguments = CommandLine.arguments
guard commandLineArguments.count >= 2 else {
    print("usage: post-debug-notification.swift <notification name> [key=value ...]")
    exit(1)
}
var notificationUserInfo: [String: String] = [:]
for keyValueArgument in commandLineArguments.dropFirst(2) {
    let keyValueParts = keyValueArgument.split(separator: "=", maxSplits: 1).map(String.init)
    if keyValueParts.count == 2 { notificationUserInfo[keyValueParts[0]] = keyValueParts[1] }
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(commandLineArguments[1]),
    object: nil,
    userInfo: notificationUserInfo,
    deliverImmediately: true
)
