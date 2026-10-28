// Draws a made-up Mac desktop (menu bar with the Apple menu, a Finder
// window) as a fixture for the answer checks, so questions about the menu bar
// can be tried without capturing a real screen.
// Run: swift scripts/answer-length-check/render-menu-bar-fixture.swift OUT.jpg

import AppKit
import SwiftUI

struct MadeUpDesktopView: View {
    let menuTitles = ["Finder", "File", "Edit", "View", "Go", "Window", "Help"]
    let sidebarItems = ["Recents", "Applications", "Desktop", "Documents", "Downloads"]
    let fileNames = ["Budget 2026.numbers", "Trip notes.pages", "Invoice March.pdf", "Logo draft.png", "Meeting recording.m4a"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.32, blue: 0.62), Color(red: 0.55, green: 0.38, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                    ForEach(Array(menuTitles.enumerated()), id: \.offset) { menuIndex, menuTitle in
                        Text(menuTitle).font(.system(size: 13, weight: menuIndex == 0 ? .bold : .regular))
                    }
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 13))
                    Image(systemName: "battery.75percent").font(.system(size: 14))
                    Text("Wed 28 Oct  14:05").font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 24)
                .background(Color.black.opacity(0.25))
                Spacer()
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                        Circle().fill(Color.yellow).frame(width: 12, height: 12)
                        Circle().fill(Color.green).frame(width: 12, height: 12)
                    }
                    .padding(.bottom, 14)
                    Text("Favorites").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(sidebarItems, id: \.self) { sidebarItem in
                        Label(sidebarItem, systemImage: "folder").font(.system(size: 13))
                    }
                    Spacer()
                }
                .padding(16)
                .frame(width: 190)
                .background(Color(white: 0.93))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Documents").font(.system(size: 15, weight: .semibold)).padding(16)
                    ForEach(Array(fileNames.enumerated()), id: \.offset) { fileIndex, fileName in
                        HStack {
                            Image(systemName: "doc")
                            Text(fileName).font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(fileIndex % 2 == 0 ? Color(white: 0.97) : Color.white)
                    }
                    Spacer()
                }
                .background(Color.white)
            }
            .foregroundStyle(.black)
            .frame(width: 760, height: 460)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .compositingGroup()
            .shadow(radius: 20)
            .offset(x: 300, y: 180)
        }
        .frame(width: 1512, height: 982)
    }
}

@MainActor
func renderFixture(to outputPath: String) {
    let imageRenderer = ImageRenderer(content: MadeUpDesktopView())
    imageRenderer.scale = 1
    guard let renderedImage = imageRenderer.nsImage,
          let tiffData = renderedImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        fatalError("couldn't render the fixture")
    }
    try! jpegData.write(to: URL(fileURLWithPath: outputPath))
    print("wrote \(outputPath)")
}

MainActor.assumeIsolated {
    renderFixture(to: CommandLine.arguments[1])
}
