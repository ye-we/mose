//
//  DevilModeDrivingNoteView.swift
//  leanring-buddy
//
//  The small note in the cursor overlay while devil mode drives: "Mose is
//  driving, press Esc to stop", with what it's doing right now. It sits at
//  the bottom middle of the screen the mouse is on, above the Dock, where
//  it's least likely to cover what's being clicked.
//

import AppKit
import SwiftUI

struct DevilModeDrivingNoteView: View {
    let currentActionDescription: String?
    /// The overlay's screen, in global AppKit coordinates.
    let screenFrame: CGRect

    @State private var isRecordingDotDimmed = false

    private static let screenMargin: CGFloat = 18

    var body: some View {
        noteContent
            .padding(.bottom, dockInset + Self.screenMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var noteContent: some View {
        HStack(alignment: .center, spacing: 10) {
            // A slowly pulsing red dot, like a recording light: something is
            // happening on its own
            Circle()
                .fill(Color(red: 0.96, green: 0.26, blue: 0.21))
                .frame(width: 8, height: 8)
                .opacity(isRecordingDotDimmed ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isRecordingDotDimmed)
                .onAppear { isRecordingDotDimmed = true }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(AppIdentity.displayName) is driving")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("press")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("esc")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                    Text("to stop")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                if let currentActionDescription {
                    Text(currentActionDescription)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        // Action descriptions are already short (labels and typed text are cut)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .animation(.easeOut(duration: 0.2), value: currentActionDescription)
    }

    /// Room the Dock takes at the bottom of this screen.
    private var dockInset: CGFloat {
        guard let overlayScreen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else { return 0 }
        return overlayScreen.visibleFrame.minY - overlayScreen.frame.minY
    }
}
