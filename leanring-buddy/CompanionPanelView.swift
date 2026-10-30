//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content of the menu bar panel: what Clicky is doing right now,
//  the two shortcuts, any background tasks, and a few settings. When setup
//  isn't finished (Claude Code missing or signed out, a permission off), a
//  single card at the top says what's wrong and opens setup to fix it.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let setupProblem {
                setupProblemCard(setupProblem)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                shortcutHints
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                hairline
                CurrentConversationPanelRow(
                    conversationStore: companionManager.conversationStore,
                    onStartNew: { companionManager.startNewConversation() },
                    onOpenHistory: {
                        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                        NotificationCenter.default.post(name: .clickyOpenConversationHistory, object: nil)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if !companionManager.backgroundAgentJobs.isEmpty {
                hairline
                backgroundAgentJobsSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            hairline
            settingsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            hairline
            footerSection
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.Colors.hairline)
            .frame(height: 1)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 9) {
            CompanionCursorMark(markSize: 18)

            Text(AppIdentity.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 3)
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .animation(.easeOut(duration: 0.15), value: statusText)
        }
    }

    private var statusText: String {
        if setupProblem != nil { return "Needs setup" }
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Answering"
        }
    }

    private var statusDotColor: Color {
        if setupProblem != nil { return DS.Colors.nextStepInk }
        switch companionManager.voiceState {
        case .idle: return DS.Colors.doneInk
        case .listening, .processing, .responding: return DS.Colors.companionBlue
        }
    }

    // MARK: - Setup problems

    private struct SetupProblem {
        let title: String
        let explanation: String
    }

    /// The one thing standing between the user and a working Clicky, if any.
    private var setupProblem: SetupProblem? {
        switch companionManager.claudeCodeSetupState {
        case .notInstalled:
            return SetupProblem(title: "Claude Code isn't installed", explanation: "\(AppIdentity.displayName) needs it to answer you.")
        case .notSignedIn:
            return SetupProblem(title: "Claude Code isn't signed in", explanation: "Sign in with your Claude account to get answers.")
        case .problem(let problemDescription):
            return SetupProblem(title: "Claude Code isn't responding", explanation: problemDescription)
        case .checking, .ready:
            break
        }
        if !companionManager.allPermissionsGranted {
            return SetupProblem(title: "Some access is off", explanation: "\(AppIdentity.displayName) can't hear you or see your screen until it's back on.")
        }
        if !companionManager.hasCompletedOnboarding {
            return SetupProblem(title: "Finish setting up", explanation: "A few quick steps and it's ready.")
        }
        return nil
    }

    private func setupProblemCard(_ setupProblem: SetupProblem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(setupProblem.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(setupProblem.explanation)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open setup") { openSetup() }
                .buttonStyle(CompanionPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.nextStepInk.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.Colors.nextStepInk.opacity(0.28), lineWidth: 1)
        )
    }

    private func openSetup() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        NotificationCenter.default.post(name: .clickyOpenSetup, object: nil)
    }

    // MARK: - Shortcuts

    private var shortcutHints: some View {
        VStack(alignment: .leading, spacing: 9) {
            shortcutHintRow(keys: ShortcutKeycaps.talkKeys, explanation: "Hold to talk about your screen")
            shortcutHintRow(keys: ShortcutKeycaps.dictateKeys, explanation: "Hold to type with your voice")
        }
    }

    private func shortcutHintRow(keys: [(symbol: String, name: String)], explanation: String) -> some View {
        HStack(spacing: 10) {
            ShortcutKeycaps(keys: keys, keycapSize: .compact)
                .frame(width: 72, alignment: .leading)
            Text(explanation)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Background Tasks

    /// The latest background tasks, with what each is doing now or what it made.
    private var backgroundAgentJobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background tasks")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(companionManager.backgroundAgentJobs.prefix(4)) { backgroundAgentJob in
                backgroundAgentJobRow(backgroundAgentJob)
            }
        }
    }

    private func backgroundAgentJobRow(_ backgroundAgentJob: BackgroundAgentJob) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if backgroundAgentJob.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else if backgroundAgentJob.isDone {
                    // The engine's check is sized for the screen, so it's drawn
                    // at full size and scaled down to fit the row
                    InkMarkView(mark: .check, inkColor: .green, seed: UInt64(abs(backgroundAgentJob.id.hashValue % 1000)))
                        .frame(width: 34, height: 30)
                        .scaleEffect(0.55)
                        .frame(width: 18, height: 16)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .frame(width: 18, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(backgroundAgentJob.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Text(backgroundAgentJobSubtitle(backgroundAgentJob))
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Button(backgroundAgentJob.isRunning ? "Stop" : "Open") {
                if backgroundAgentJob.isRunning {
                    companionManager.stopBackgroundAgentJob(backgroundAgentJob)
                } else {
                    companionManager.openBackgroundAgentJobOutput(backgroundAgentJob)
                }
            }
            .buttonStyle(CompanionQuietButtonStyle())
        }
    }

    private func backgroundAgentJobSubtitle(_ backgroundAgentJob: BackgroundAgentJob) -> String {
        switch backgroundAgentJob.status {
        case "running":
            return backgroundAgentJob.latestProgress ?? "Getting started…"
        case "done":
            return backgroundAgentJob.resultHeadline ?? "Done"
        case "stopped":
            return "Stopped"
        case "interrupted":
            return "Interrupted when \(AppIdentity.displayName) quit"
        default:
            return backgroundAgentJob.resultHeadline ?? "Didn't finish"
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 0) {
            settingsRow(title: "Model", caption: modelCaption) {
                CompactChoiceControl(
                    choices: [
                        (label: "Haiku", value: "claude-haiku-4-5"),
                        (label: "Sonnet", value: "claude-sonnet-4-6"),
                        (label: "Opus", value: "claude-opus-4-6"),
                    ],
                    selectedValue: selectedModelChoice,
                    onSelect: { companionManager.setSelectedModel($0) }
                )
            }

            settingsRow(title: "Think before answering", caption: "More careful, but slower to start talking") {
                settingsToggle(
                    isOn: companionManager.isExtendedThinkingEnabled,
                    onChange: { companionManager.setExtendedThinkingEnabled($0) }
                )
            }

            settingsRow(title: "Devil mode", caption: "\(AppIdentity.displayName) can click and type for you") {
                settingsToggle(
                    isOn: companionManager.isDevilModeEnabled,
                    onChange: { companionManager.setDevilModeEnabled($0) }
                )
            }

            settingsRow(title: "Apps for background tasks", caption: connectedAppsCaption) {
                Button("Choose") {
                    NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                    NotificationCenter.default.post(name: .clickyOpenConnectedApps, object: nil)
                }
                .buttonStyle(CompanionQuietButtonStyle())
            }

            settingsRow(title: "Open at login", caption: nil) {
                settingsToggle(
                    isOn: companionManager.isOpenAtLoginEnabled,
                    onChange: { companionManager.setOpenAtLoginEnabled($0) }
                )
            }
        }
    }

    /// "None", or the apps background tasks may use ("Gmail, Google Drive").
    private var connectedAppsCaption: String {
        let allowedAppNames = companionManager.agentConnectedAppServerNames.map(AgentConnectedApps.displayName(forServerName:))
        return allowedAppNames.isEmpty ? "None, only the web and files" : allowedAppNames.joined(separator: ", ")
    }

    /// The stored model id, matched to the family shown in the picker.
    private var selectedModelChoice: String {
        switch ClaudeCodeCLI.modelAlias(forRequestedModel: companionManager.selectedModel) {
        case "haiku": return "claude-haiku-4-5"
        case "opus": return "claude-opus-4-6"
        default: return "claude-sonnet-4-6"
        }
    }

    private var modelCaption: String {
        switch ClaudeCodeCLI.modelAlias(forRequestedModel: companionManager.selectedModel) {
        case "haiku": return "Fastest answers"
        case "opus": return "Most capable, slowest"
        default: return "Fast and sharp"
        }
    }

    private func settingsRow<Control: View>(title: String, caption: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 7)
    }

    private func settingsToggle(isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: onChange))
            .toggleStyle(CompanionSwitchToggleStyle())
            .labelsHidden()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 4) {
            Button("Setup") { openSetup() }
                .buttonStyle(PanelFooterButtonStyle())
            Spacer()
            Button("Quit \(AppIdentity.displayName)") { NSApp.terminate(nil) }
                .buttonStyle(PanelFooterButtonStyle())
        }
    }

    private struct PanelFooterButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            FooterButtonBody(configuration: configuration)
        }

        private struct FooterButtonBody: View {
            let configuration: ButtonStyleConfiguration
            @State private var isHovered = false

            var body: some View {
                configuration.label
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(isHovered ? 0.06 : 0))
                    )
                    .onHover { isHovering in isHovered = isHovering }
                    .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}
