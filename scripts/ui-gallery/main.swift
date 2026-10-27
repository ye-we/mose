import AppKit
import SwiftUI

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let onlyScenario = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

@MainActor
func render<V: View>(_ view: V, size: NSSize, name: String) {
    if let onlyScenario, onlyScenario != name { return }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .black
    let hostingView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    hostingView.frame = NSRect(origin: .zero, size: size)
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    hostingView.layoutSubtreeIfNeeded()
    let fitting = hostingView.fittingSize
    let finalSize = NSSize(width: size.width, height: size.height > 0 ? size.height : fitting.height)
    window.setContentSize(finalSize); hostingView.frame = NSRect(origin: .zero, size: finalSize)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let png = bitmap.representation(using: .png, properties: [:])!
    try! png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    print("rendered \(name) \(Int(finalSize.width))x\(Int(finalSize.height))")
}

@MainActor
func manager(_ configure: (CompanionManager) -> Void) -> CompanionManager {
    let m = CompanionManager(); configure(m); return m
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    InkMarkView.drawsFinishedMarksImmediately = true
    let account = ClaudeCodeAccount(email: "you@example.com", subscriptionType: "team", organizationName: "Example Co")
    let setupSize = NSSize(width: SetupView.windowWidth, height: SetupView.windowHeight)

    let scenarios: [(String, CompanionManager)] = [
        ("setup-1-not-installed", manager { $0.claudeCodeSetupState = .notInstalled }),
        ("setup-1-signed-out", manager { $0.claudeCodeSetupState = .notSignedIn }),
        ("setup-2-permissions", manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true }),
        ("setup-3-say-hi", manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true; $0.hasAccessibilityPermission = true; $0.hasScreenRecordingPermission = true; $0.hasScreenContentPermission = true }),
        ("setup-4-done", manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true; $0.hasAccessibilityPermission = true; $0.hasScreenRecordingPermission = true; $0.hasScreenContentPermission = true; $0.hasCompletedOnboarding = true }),
    ]
    for (name, m) in scenarios {
        render(SetupView(companionManager: m, shortcutMonitor: m.globalPushToTalkShortcutMonitor, onClose: {}), size: setupSize, name: name)
    }

    let pressed = manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true; $0.hasAccessibilityPermission = true; $0.hasScreenRecordingPermission = true; $0.hasScreenContentPermission = true; $0.voiceState = .listening }
    pressed.globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed = true
    render(SetupView(companionManager: pressed, shortcutMonitor: pressed.globalPushToTalkShortcutMonitor, onClose: {}), size: setupSize, name: "setup-3-holding-keys")

    let jobs = [
        BackgroundAgentJob(id: "a1", title: "Standing desk comparison", status: "running", startedAt: "2026-10-27T10:00:00.000Z", finishedAt: nil, latestProgress: "searching the web for \"standing desks under $500\"", result: nil, folder: "/tmp", outputFiles: []),
        BackgroundAgentJob(id: "b2", title: "Q3 invoice summary", status: "done", startedAt: "2026-10-27T09:00:00.000Z", finishedAt: "2026-10-27T09:04:00.000Z", latestProgress: nil, result: "Made a one-page PDF of the Q3 invoices in the output folder. Two are overdue.", folder: "/tmp", outputFiles: ["q3.pdf"]),
    ]
    let panelReady = manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true; $0.hasAccessibilityPermission = true; $0.hasScreenRecordingPermission = true; $0.hasScreenContentPermission = true; $0.hasCompletedOnboarding = true }
    render(CompanionPanelView(companionManager: panelReady).padding(24).background(Color(white: 0.35)), size: NSSize(width: 368, height: 0), name: "panel-ready")
    let panelJobs = manager { $0.claudeCodeSetupState = .ready(account); $0.hasMicrophonePermission = true; $0.hasAccessibilityPermission = true; $0.hasScreenRecordingPermission = true; $0.hasScreenContentPermission = true; $0.hasCompletedOnboarding = true; $0.backgroundAgentJobs = jobs; $0.voiceState = .responding; $0.selectedModel = "claude-haiku-4-5" }
    render(CompanionPanelView(companionManager: panelJobs).padding(24).background(Color(white: 0.35)), size: NSSize(width: 368, height: 0), name: "panel-with-tasks")
    let panelProblem = manager { $0.claudeCodeSetupState = .notSignedIn; $0.hasCompletedOnboarding = true }
    render(CompanionPanelView(companionManager: panelProblem).padding(24).background(Color(white: 0.35)), size: NSSize(width: 368, height: 0), name: "panel-signed-out")
}
