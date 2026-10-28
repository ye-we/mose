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
    // Step cards over a real app screenshot, as the overlay would show them
    let fixtureScreenshot = NSImage(contentsOfFile: CommandLine.arguments[0].components(separatedBy: "/").dropLast().joined(separator: "/") + "/codex-app-screenshot.jpg")
        ?? NSImage(contentsOfFile: ProcessInfo.processInfo.environment["CLICKY_GALLERY_SCREENSHOT"] ?? "")
    let fakeScreenFrame = CGRect(x: 0, y: 0, width: 1280, height: 820)
    func stepCardsScene(_ deck: GuidedStepCardDeck) -> some View {
        ZStack {
            if let fixtureScreenshot { Image(nsImage: fixtureScreenshot).resizable().frame(width: 1280, height: 820) }
            GuidedStepCardsView(guidedStepCardDeck: deck, screenFrame: fakeScreenFrame)
        }
        .frame(width: 1280, height: 820)
    }
    var firstStepDeck = GuidedStepCardDeck()
    firstStepDeck.showStep(number: 1, instructionText: "Click File up in the menu bar.", targetGlobalRect: CGRect(x: 60, y: 790, width: 30, height: 20), displayFrame: fakeScreenFrame)
    render(stepCardsScene(firstStepDeck), size: NSSize(width: 1280, height: 820), name: "cards-1-first-step")
    var thirdStepDeck = firstStepDeck
    thirdStepDeck.markCurrentStepDone()
    thirdStepDeck.showStep(number: 2, instructionText: "Now pick Export as PDF near the bottom of the menu.", targetGlobalRect: CGRect(x: 70, y: 400, width: 120, height: 20), displayFrame: fakeScreenFrame)
    thirdStepDeck.markCurrentStepDone()
    thirdStepDeck.showStep(number: 3, instructionText: "Hit Save in the top right corner of the dialog.", targetGlobalRect: CGRect(x: 1180, y: 760, width: 60, height: 24), displayFrame: fakeScreenFrame)
    render(stepCardsScene(thirdStepDeck), size: NSSize(width: 1280, height: 820), name: "cards-2-target-top-right")
    var closedDeck = thirdStepDeck
    closedDeck.markCurrentStepDone()
    closedDeck.finish(closingText: "Done, your PDF is saving to Downloads.")
    render(stepCardsScene(closedDeck), size: NSSize(width: 1280, height: 820), name: "cards-3-done")

    let panelProblem = manager { $0.claudeCodeSetupState = .notSignedIn; $0.hasCompletedOnboarding = true }
    render(CompanionPanelView(companionManager: panelProblem).padding(24).background(Color(white: 0.35)), size: NSSize(width: 368, height: 0), name: "panel-signed-out")
}
