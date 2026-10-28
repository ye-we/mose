//
//  ConversationHistoryWindow.swift
//  leanring-buddy
//
//  The History window: every saved conversation, newest first and grouped by
//  day, with search. Picking one shows what was said, what Clicky remembers
//  from its start when it's long, and lets the user continue it or delete it.
//  Also the panel's small "current conversation" row.
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// Opens the History window (posted by the menu bar panel).
    static let clickyOpenConversationHistory = Notification.Name("clickyOpenConversationHistory")
}

@MainActor
final class ConversationHistoryWindowController: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private var historyWindow: NSWindow?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeHistoryWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeHistoryWindow() -> NSWindow {
        let historyView = ConversationHistoryView(
            conversationStore: companionManager.conversationStore,
            onContinue: { [weak companionManager] conversationID in
                companionManager?.continueConversation(withID: conversationID)
            },
            onStartNew: { [weak companionManager] in
                companionManager?.startNewConversation()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppIdentity.displayName) History"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(DS.Colors.background)
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: historyView)
        window.delegate = self
        window.center()
        return window
    }
}

// MARK: - History window content

struct ConversationHistoryView: View {
    @ObservedObject var conversationStore: ConversationSessionStore
    let onContinue: (UUID) -> Void
    let onStartNew: () -> Void

    @State private var searchText = ""
    @State private var selectedConversationID: UUID?
    @State private var isConfirmingDeleteAll = false

    private var shownConversations: [ConversationSession] {
        ConversationSearch.sessions(conversationStore.sessions, matching: searchText)
    }

    private var selectedConversation: ConversationSession? {
        let selectedID = selectedConversationID ?? conversationStore.currentSessionID ?? shownConversations.first?.id
        return selectedID.flatMap { conversationStore.session(withID: $0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: 290)
            Rectangle()
                .fill(DS.Colors.hairline)
                .frame(width: 1)
            conversationDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .alert("Delete every conversation?", isPresented: $isConfirmingDeleteAll) {
            Button("Delete All", role: .destructive) {
                conversationStore.deleteAllSessions()
                selectedConversationID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from this Mac and can't be brought back.")
        }
    }

    // MARK: List

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Conversations")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Say \u{201C}new chat\u{201D} to start over, or \u{201C}go back to the chat about\u{2026}\u{201D}")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("New") {
                    onStartNew()
                    selectedConversationID = nil
                }
                .buttonStyle(CompanionQuietButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if conversationStore.sessions.isEmpty {
                emptyListMessage("Nothing saved yet. Hold Control and Option and ask something; each conversation shows up here.")
            } else if shownConversations.isEmpty {
                emptyListMessage("No conversation mentions \u{201C}\(searchText)\u{201D}.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(conversationsGroupedByDay, id: \.dayTitle) { dayGroup in
                            Text(dayGroup.dayTitle)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(dayGroup.conversations) { conversationSession in
                                conversationRow(conversationSession)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
            }

            Spacer(minLength: 0)

            if !conversationStore.sessions.isEmpty {
                Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                Button("Delete all conversations…") { isConfirmingDeleteAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .pointerCursor()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Search what was said", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func emptyListMessage(_ messageText: String) -> some View {
        Text(messageText)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 16)
    }

    private func conversationRow(_ conversationSession: ConversationSession) -> some View {
        let isSelected = conversationSession.id == selectedConversation?.id
        let isCurrent = conversationSession.id == conversationStore.currentSessionID
        return Button(action: { selectedConversationID = conversationSession.id }) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(isCurrent ? DS.Colors.companionBlue : Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversationSession.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(rowCaption(for: conversationSession, isCurrent: isCurrent))
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func rowCaption(for conversationSession: ConversationSession, isCurrent: Bool) -> String {
        let timeText = Self.timeFormatter.string(from: conversationSession.lastActivityAt)
        let questionText = conversationSession.questionCount == 1 ? "1 question" : "\(conversationSession.questionCount) questions"
        return isCurrent ? "Current, \(questionText)" : "\(timeText), \(questionText)"
    }

    private var conversationsGroupedByDay: [(dayTitle: String, conversations: [ConversationSession])] {
        var dayGroups: [(dayTitle: String, conversations: [ConversationSession])] = []
        for conversationSession in shownConversations {
            let dayTitle = Self.dayTitle(for: conversationSession.lastActivityAt)
            if let lastGroupIndex = dayGroups.indices.last, dayGroups[lastGroupIndex].dayTitle == dayTitle {
                dayGroups[lastGroupIndex].conversations.append(conversationSession)
            } else {
                dayGroups.append((dayTitle, [conversationSession]))
            }
        }
        return dayGroups
    }

    // MARK: Detail

    @ViewBuilder
    private var conversationDetail: some View {
        if let selectedConversation {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(selectedConversation)
                    .padding(.horizontal, 28)
                    .padding(.top, 40)
                    .padding(.bottom, 16)
                Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let earlierSummary = selectedConversation.earlierSummary {
                            rememberedSummary(earlierSummary)
                        }
                        ForEach(selectedConversation.exchanges) { conversationExchange in
                            exchangeView(conversationExchange)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 640, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: 10) {
                CompanionCursorMark(markSize: 26)
                Text("Your conversations will show up here.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ conversationSession: ConversationSession) -> some View {
        let isCurrent = conversationSession.id == conversationStore.currentSessionID
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversationSession.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                Text("Started \(Self.dayTitle(for: conversationSession.startedAt).lowercased()) at \(Self.timeFormatter.string(from: conversationSession.startedAt))")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if isCurrent {
                Text("Current conversation")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
            } else {
                Button("Continue") { onContinue(conversationSession.id) }
                    .buttonStyle(CompanionPrimaryButtonStyle())
            }
            Button("Delete") {
                conversationStore.deleteSession(withID: conversationSession.id)
                selectedConversationID = nil
            }
            .buttonStyle(CompanionQuietButtonStyle())
        }
    }

    /// What Claude gets instead of the start of a long conversation.
    private func rememberedSummary(_ earlierSummary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What \(AppIdentity.displayName) remembers from the start")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(earlierSummary)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func exchangeView(_ conversationExchange: ConversationExchange) -> some View {
        let answerText = ConversationContext.spokenText(of: conversationExchange.assistantResponse)
        VStack(alignment: .leading, spacing: 10) {
            if conversationExchange.isGuidedStepFollowUp {
                Text(Self.guidedStepDescription(of: conversationExchange.userTranscript))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("You")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(exchangeCaption(conversationExchange))
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary.opacity(0.8))
                    }
                    Text(conversationExchange.userTranscript)
                        .font(.system(size: 13.5))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !answerText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    CompanionCursorMark(markSize: 12)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(answerText)
                            .font(.system(size: 13.5))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let screenMarksDescription = Self.screenMarksDescription(of: conversationExchange.assistantResponse) {
                            Text(screenMarksDescription)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func exchangeCaption(_ conversationExchange: ConversationExchange) -> String {
        let timeText = Self.timeFormatter.string(from: conversationExchange.askedAt)
        if let frontmostAppName = conversationExchange.frontmostAppName {
            return "\(timeText), in \(frontmostAppName)"
        }
        return timeText
    }

    // MARK: Text helpers

    /// "12:03 PM", or "12:03" on a 24-hour clock. Some regions' short style
    /// spells the time out ("12:03 in the afternoon"), too long for a list.
    static let timeFormatter: DateFormatter = {
        let timeFormatter = DateFormatter()
        let preferredHourPattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
        let usesTwelveHourClock = preferredHourPattern.contains("a") || preferredHourPattern.contains("B") || preferredHourPattern.contains("b")
        timeFormatter.dateFormat = usesTwelveHourClock ? "h:mm a" : "HH:mm"
        return timeFormatter
    }()

    private static let dayFormatter: DateFormatter = {
        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return dayFormatter
    }()

    static func dayTitle(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    /// "(guided step) i clicked export. what's next?" → "You clicked export"
    static func guidedStepDescription(of followUpTranscript: String) -> String {
        if let clickedRange = followUpTranscript.range(of: #"i clicked (somewhere else instead of )?(.+?)\. what"#, options: .regularExpression) {
            let clickedText = String(followUpTranscript[clickedRange])
                .replacingOccurrences(of: "i clicked ", with: "")
                .replacingOccurrences(of: ". what", with: "")
            return "You clicked \(clickedText)"
        }
        return "You clicked the next step"
    }

    /// A short note when the answer pointed or drew on the screen.
    static func screenMarksDescription(of assistantResponse: String) -> String? {
        let drawTagCount = assistantResponse.components(separatedBy: "[DRAW:").count - 1
        let pointTagCount = assistantResponse.components(separatedBy: "[POINT:").count - 1
            - (assistantResponse.contains("[POINT:none]") ? 1 : 0)
        let markCount = drawTagCount + max(pointTagCount, 0)
        guard markCount > 0 else { return nil }
        return markCount == 1 ? "Marked 1 thing on screen" : "Marked \(markCount) things on screen"
    }
}

// MARK: - Panel row

/// The current conversation in the menu bar panel, with New and History.
struct CurrentConversationPanelRow: View {
    @ObservedObject var conversationStore: ConversationSessionStore
    let onStartNew: () -> Void
    let onOpenHistory: () -> Void

    var body: some View {
        let currentConversation = conversationStore.currentSession
        VStack(alignment: .leading, spacing: 4) {
            Text(currentConversation?.title ?? "New conversation")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(caption(for: currentConversation))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if currentConversation != nil {
                    Button("New", action: onStartNew)
                        .buttonStyle(CompanionQuietButtonStyle())
                }
                Button("History", action: onOpenHistory)
                    .buttonStyle(CompanionQuietButtonStyle())
            }
        }
    }

    private func caption(for currentConversation: ConversationSession?) -> String {
        guard let currentConversation else { return "Starts with your next question" }
        let questionText = currentConversation.questionCount == 1 ? "1 question" : "\(currentConversation.questionCount) questions"
        return "\(questionText), last at \(ConversationHistoryView.timeFormatter.string(from: currentConversation.lastActivityAt))"
    }
}
