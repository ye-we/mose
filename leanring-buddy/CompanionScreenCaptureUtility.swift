//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures only the display the mouse pointer is on, as JPEG data.
    /// Other monitors are left out on purpose: Mose sees as little as it
    /// can, and the user's question is almost always about where they're
    /// pointing. Returned as an array so the rest of the pipeline stays
    /// the same; it holds one capture.
    static func captureCursorScreenAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // The display under the mouse, or the main one if the pointer is
        // somehow between screens
        let cursorDisplay = content.displays.first { display in
            (nsScreenByDisplayID[display.displayID]?.frame ?? display.frame).contains(mouseLocation)
        } ?? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0]

        // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
        // displayFrame is in the same coordinate system as NSEvent.mouseLocation
        // and the overlay window's screenFrame in BlueCursorView.
        let displayFrame = nsScreenByDisplayID[cursorDisplay.displayID]?.frame
            ?? CGRect(x: cursorDisplay.frame.origin.x, y: cursorDisplay.frame.origin.y,
                      width: CGFloat(cursorDisplay.width), height: CGFloat(cursorDisplay.height))

        let filter = SCContentFilter(display: cursorDisplay, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let aspectRatio = CGFloat(cursorDisplay.width) / CGFloat(cursorDisplay.height)
        if cursorDisplay.width >= cursorDisplay.height {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture the screen"])
        }

        let cursorScreenCapture = CompanionScreenCapture(
            imageData: jpegData,
            label: "screen 1 of 1 (primary focus)",
            // Even in the rare fallback, so marks land on the captured screen
            isCursorScreen: true,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )

        return [cursorScreenCapture]
    }
}
