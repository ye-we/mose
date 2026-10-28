//
//  ConnectedAppsWindow.swift
//  leanring-buddy
//
//  The Connected Apps window, opened from the menu bar panel: the user's
//  Claude Code apps (MCP servers and claude.ai connectors), each with a switch
//  for whether background tasks may use it. All start off. It says plainly
//  that what a task does inside an app it's allowed is up to its instructions.
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// Opens the Connected Apps window (posted by the menu bar panel).
    static let clickyOpenConnectedApps = Notification.Name("clickyOpenConnectedApps")
}

@MainActor
final class ConnectedAppsWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private var connectedAppsWindow: NSWindow?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    func showConnectedApps() {
        if connectedAppsWindow == nil {
            connectedAppsWindow = makeConnectedAppsWindow()
        }
        // The list can change (an app connected on claude.ai), so look again
        companionManager.refreshConnectedApps()
        NSApp.activate(ignoringOtherApps: true)
        connectedAppsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeConnectedAppsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Apps for Background Tasks"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.minSize = NSSize(width: 440, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ConnectedAppsView(companionManager: companionManager))
        window.delegate = self
        window.center()
        return window
    }
}

// MARK: - Window content

struct ConnectedAppsView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Connected apps first, then turned-on apps that weren't found this time
    /// (so they can still be turned off), then the ones that need signing in.
    private var connectedApps: [ClaudeCodeConnectedApp] {
        (companionManager.availableConnectedApps ?? []).filter { $0.connectionStatus == .connected }
    }

    private var allowedAppsNotFound: [String] {
        guard let availableConnectedApps = companionManager.availableConnectedApps else { return [] }
        let foundServerNames = Set(availableConnectedApps.filter { $0.connectionStatus == .connected }.map(\.serverName))
        return companionManager.agentConnectedAppServerNames.filter { !foundServerNames.contains($0) }
    }

    /// Turned-on apps are already listed above, with their switch.
    private var appsNotConnected: [ClaudeCodeConnectedApp] {
        (companionManager.availableConnectedApps ?? []).filter { connectedApp in
            connectedApp.connectionStatus != .connected
                && !companionManager.agentConnectedAppServerNames.contains(connectedApp.serverName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apps for background tasks")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("When you hand \(AppIdentity.displayName) real work (\u{201C}make a doc of this\u{201D}, \u{201C}check my calendar and plan my week\u{201D}), the background task can use the apps you turn on here, through your Claude Code connections.")
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It reads what it needs and creates things there only when you ask. It's told never to send, share, delete or pay, but that's an instruction, not a lock, so only turn on apps you'd trust it with.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 16)
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if companionManager.availableConnectedApps == nil {
                        loadingOrProblem
                    } else {
                        if connectedApps.isEmpty && allowedAppsNotFound.isEmpty {
                            note("No apps are connected to Claude Code yet. Connect them at claude.ai under Settings, Connectors, or add an MCP server with \u{201C}claude mcp add\u{201D}.")
                        }
                        ForEach(connectedApps) { connectedApp in
                            appRow(serverName: connectedApp.serverName, caption: nil, canBeTurnedOn: true)
                        }
                        ForEach(allowedAppsNotFound, id: \.self) { serverName in
                            appRow(serverName: serverName, caption: "Not connected right now", canBeTurnedOn: false)
                        }
                        if !appsNotConnected.isEmpty {
                            Text("Not connected")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.top, 18)
                                .padding(.bottom, 4)
                                .padding(.horizontal, 10)
                            ForEach(appsNotConnected) { connectedApp in
                                appRow(
                                    serverName: connectedApp.serverName,
                                    caption: connectedApp.connectionStatus == .needsSignIn ? "Sign in to it at claude.ai first" : "Couldn't reach it",
                                    canBeTurnedOn: false
                                )
                            }
                        }
                        if companionManager.isLoadingConnectedApps {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text("Checking again\u{2026}")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 440, minHeight: 420)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var loadingOrProblem: some View {
        if let connectedAppsLoadingProblem = companionManager.connectedAppsLoadingProblem {
            note(connectedAppsLoadingProblem)
            Button("Try again") { companionManager.refreshConnectedApps() }
                .buttonStyle(CompanionQuietButtonStyle())
                .padding(.horizontal, 10)
                .padding(.top, 8)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking Claude Code which apps you've connected. This takes a few seconds.")
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func appRow(serverName: String, caption: String?, canBeTurnedOn: Bool) -> some View {
        let isAllowed = companionManager.agentConnectedAppServerNames.contains(serverName)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentConnectedApps.displayName(forServerName: serverName))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(canBeTurnedOn || isAllowed ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            // A turned-on app that isn't connected right now can still be turned off
            if canBeTurnedOn || isAllowed {
                Toggle(AgentConnectedApps.displayName(forServerName: serverName), isOn: Binding(
                    get: { isAllowed },
                    set: { companionManager.setAgentConnectedApp(serverName: serverName, isAllowed: $0) }
                ))
                .toggleStyle(CompanionSwitchToggleStyle())
                .labelsHidden()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func note(_ noteText: String) -> some View {
        Text(noteText)
            .font(.system(size: 12.5))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
    }
}
