// Screenshot generator for HDB630Control.
// Renders the real UI views with mock data.
// Build and usage: see README "Screenshots".

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

    // Render in-process; screencapture needs Screen Recording permission.
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let path = (outputDir as NSString).appendingPathComponent(filename)
    let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
    window.close()
    return ok
}

// Matches the popover chrome in AppDelegate's ControlRootView.
@MainActor
func panel<V: View>(_ view: V, height: CGFloat) -> some View {
    view
        .frame(width: 360, height: height, alignment: .top)
        .background {
            LinearGradient(
                colors: [ControlStyle.background, Color(red: 0.09, green: 0.14, blue: 0.19)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .preferredColorScheme(.dark)
        .tint(ControlStyle.accent)
}

@MainActor
func main() {
    let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screenshots"

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Key/active window so controls render in their active (accent) state.
    app.activate(ignoringOtherApps: true)

    try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    let controller = HeadphoneController()
    let bluetooth = BluetoothManager()
    let dongle = DongleController()
    let outputSwitcher = AudioOutputSwitcher()
    controller.deviceInfo.name = "HDB 630"
    controller.batteryLevel = 75

    let shots: [(String, AnyView)] = [
        ("screenshot_popover.png",
         AnyView(panel(StatusBarView(controller: controller, bluetooth: bluetooth), height: 690))),
        ("screenshot_settings.png",
         AnyView(panel(ScrollView { SettingsView(controller: controller, bluetooth: bluetooth,
                                                 showSettings: .constant(true)).padding(16) },
                       height: 745))),
        ("screenshot_dongle.png",
         AnyView(panel(DongleView(dongle: dongle).environmentObject(outputSwitcher), height: 560))),
        ("screenshot_app_settings.png",
         AnyView(panel(AppSettingsView().environmentObject(outputSwitcher), height: 335))),
    ]
    for (filename, view) in shots {
        guard renderToPNG(view, width: 360, filename: filename, outputDir: outputDir) else {
            print("ERROR: Failed to render \(filename)")
            Foundation.exit(1)
        }
        print("Wrote \(outputDir)/\(filename)")
    }

    controller.ancEnabled = false
    controller.audioMode = .parametricEq
    let peq = panel(StatusBarView(controller: controller, bluetooth: bluetooth), height: 890)
    guard renderToPNG(peq, width: 360, filename: "screenshot_popover_peq.png", outputDir: outputDir) else {
        print("ERROR: Failed to render screenshot_popover_peq.png")
        Foundation.exit(1)
    }
    print("Wrote \(outputDir)/screenshot_popover_peq.png")
}

MainActor.assumeIsolated {
    main()
}
