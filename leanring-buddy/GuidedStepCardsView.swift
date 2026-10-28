//
//  GuidedStepCardsView.swift
//  leanring-buddy
//
//  Draws a guided walkthrough's step cards (GuidedStepCardDeck) in the
//  cursor overlay: one small dark card pinned to a corner of the screen the
//  walkthrough is on, away from the thing to click. Finished steps get a
//  hand-drawn green check, the current one an orange ring around its number
//  like its target on screen, and the closing note Clicky's cursor.
//

import AppKit
import SwiftUI

struct GuidedStepCardsView: View {
    let guidedStepCardDeck: GuidedStepCardDeck
    /// The overlay's screen, in global AppKit coordinates.
    let screenFrame: CGRect

    static let cardWidth: CGFloat = 300
    private static let screenMargin: CGFloat = 16

    var body: some View {
        if isWalkthroughOnThisScreen && !guidedStepCardDeck.isEmpty {
            let screenInsets = menuBarAndDockInsets
            cardStack
                .frame(width: Self.cardWidth)
                .padding(.top, screenInsets.top + Self.screenMargin)
                .padding(.bottom, screenInsets.bottom + Self.screenMargin)
                .padding(.horizontal, Self.screenMargin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: cardCorner(topInset: screenInsets.top)))
                .allowsHitTesting(false)
        }
    }

    private var cardStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(guidedStepCardDeck.shownCards.enumerated()), id: \.element.id) { cardIndex, guidedStepCard in
                if cardIndex > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                }
                cardRow(guidedStepCard)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: guidedStepCardDeck.cards)
    }

    @ViewBuilder
    private func cardRow(_ guidedStepCard: GuidedStepCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            cardMarker(guidedStepCard)
                .frame(width: 22, height: 20)

            Text(guidedStepCard.instructionText)
                .font(.system(size: isCurrentStep(guidedStepCard) ? 13.5 : 12, weight: isCurrentStep(guidedStepCard) ? .medium : .regular))
                .foregroundColor(textColor(for: guidedStepCard))
                .lineLimit(isCurrentStep(guidedStepCard) ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCurrentStep(guidedStepCard) ? 11 : 8)
    }

    @ViewBuilder
    private func cardMarker(_ guidedStepCard: GuidedStepCard) -> some View {
        switch guidedStepCard.kind {
        case .step(let stepNumber) where guidedStepCard.isDone:
            // The engine's check is screen-sized, so it's scaled down to fit the row
            InkMarkView(mark: .check, inkColor: .green, seed: UInt64(60 + stepNumber))
                .frame(width: 34, height: 30)
                .scaleEffect(0.55)
                .frame(width: 22, height: 20)
                .id("done-\(guidedStepCard.id)")
        case .step(let stepNumber):
            ZStack {
                Text("\(stepNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                InkMarkView(mark: .ring(inset: 6), inkColor: .orange, seed: UInt64(80 + stepNumber), lineWidthScale: 0.6)
                    .frame(width: 30, height: 30)
                    .id("current-\(guidedStepCard.id)")
            }
        case .closingNote:
            CompanionCursorMark(markSize: 13)
        }
    }

    private func isCurrentStep(_ guidedStepCard: GuidedStepCard) -> Bool {
        if case .step = guidedStepCard.kind { return !guidedStepCard.isDone }
        return false
    }

    private func textColor(for guidedStepCard: GuidedStepCard) -> Color {
        switch guidedStepCard.kind {
        case .closingNote: return DS.Colors.textPrimary
        case .step: return guidedStepCard.isDone ? DS.Colors.textTertiary : DS.Colors.textPrimary
        }
    }

    // MARK: - Placement

    private var isWalkthroughOnThisScreen: Bool {
        guard let walkthroughDisplayFrame = guidedStepCardDeck.displayFrame else { return false }
        return walkthroughDisplayFrame.intersects(screenFrame)
    }

    /// Room taken by the menu bar at the top and the Dock at the bottom.
    private var menuBarAndDockInsets: (top: CGFloat, bottom: CGFloat) {
        guard let overlayScreen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else { return (32, 0) }
        return (
            overlayScreen.frame.maxY - overlayScreen.visibleFrame.maxY,
            overlayScreen.visibleFrame.minY - overlayScreen.frame.minY
        )
    }

    private func cardCorner(topInset: CGFloat) -> GuidedStepCardDeck.ScreenCorner {
        let targetLocalRect = guidedStepCardDeck.targetGlobalRect.map { targetGlobalRect in
            CGRect(
                x: targetGlobalRect.minX - screenFrame.minX,
                y: screenFrame.maxY - targetGlobalRect.maxY,
                width: targetGlobalRect.width,
                height: targetGlobalRect.height
            )
        }
        // Roughly how tall the cards are, for keeping them off the target
        let estimatedCardHeight = CGFloat(40 + 44 * guidedStepCardDeck.shownCards.count)
        return GuidedStepCardDeck.cardCorner(
            screenSize: screenFrame.size,
            topInset: topInset,
            cardSize: CGSize(width: Self.cardWidth, height: estimatedCardHeight),
            margin: Self.screenMargin,
            avoiding: targetLocalRect
        )
    }

    private func alignment(for screenCorner: GuidedStepCardDeck.ScreenCorner) -> Alignment {
        switch screenCorner {
        case .topTrailing: return .topTrailing
        case .bottomTrailing: return .bottomTrailing
        case .topLeading: return .topLeading
        case .bottomLeading: return .bottomLeading
        }
    }
}
