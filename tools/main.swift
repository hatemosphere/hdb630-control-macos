// Screenshot generator for HDB630Control.
// Renders the real UI views with mock data via screencapture.
// Build: xcodegen && xcodebuild -scheme ScreenshotMock -configuration Debug build
// Usage: ./screenshot_mock [output_dir]   (default: HDB630Control/screenshots/)

import AppKit
import SwiftUI

@MainActor
func renderToPNG<V: View>(_ view: V, width: CGFloat, filename: String, outputDir: String) -> Bool {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    hosting.layoutSubtreeIfNeeded()
    let fittingSize = hosting.fittingSize
    let size = NSSize(width: width, height: fittingSize.height)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    window.backgroundColor = .windowBackgroundColor
    window.hasShadow = false
    window.setFrameOrigin(NSPoint(x: 100, y: 100))
    window.makeKeyAndOrderFront(nil)

    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

    let path = (outputDir as NSString).appendingPathComponent(filename)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-l\(window.windowNumber)", "-o", "-r", path]
    try? proc.run()
    proc.waitUntilExit()

    let ok = proc.terminationStatus == 0
    window.close()
    return ok
}

@MainActor
func main() {
    let outputDir: String
    if CommandLine.arguments.count > 1 {
        outputDir = CommandLine.arguments[1]
    } else {
        outputDir = "HDB630Control/screenshots"
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    let controller = HeadphoneController()
    let bluetooth = BluetoothManager()

    // 1. Popover — Equalizer mode
    let popover = StatusBarView(controller: controller, bluetooth: bluetooth)
        .environmentObject(bluetooth)
    if renderToPNG(popover, width: 320, filename: "screenshot_popover.png", outputDir: outputDir) {
        print("Wrote \(outputDir)/screenshot_popover.png")
    } else {
        print("ERROR: Failed to render popover")
        Foundation.exit(1)
    }

    // 2. Settings view
    let settings = SettingsView(controller: controller, bluetooth: bluetooth, showSettings: .constant(true))
    if renderToPNG(settings, width: 320, filename: "screenshot_settings.png", outputDir: outputDir) {
        print("Wrote \(outputDir)/screenshot_settings.png")
    } else {
        print("ERROR: Failed to render settings")
        Foundation.exit(1)
    }

    // 3. Popover — Parametric EQ mode
    controller.audioMode = .parametricEq
    let popoverPEQ = StatusBarView(controller: controller, bluetooth: bluetooth)
        .environmentObject(bluetooth)
    if renderToPNG(popoverPEQ, width: 320, filename: "screenshot_popover_peq.png", outputDir: outputDir) {
        print("Wrote \(outputDir)/screenshot_popover_peq.png")
    } else {
        print("ERROR: Failed to render popover (PEQ)")
        Foundation.exit(1)
    }
}

MainActor.assumeIsolated {
    main()
}
