import Cocoa
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let bluetooth = BluetoothManager()
    private let dongle = DongleController()
    let outputSwitcher = AudioOutputSwitcher()
    private var controller: HeadphoneController!
    private var cancellables = Set<AnyCancellable>()
    private var didInitialConnect = false
    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var diagnosticsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = HeadphoneController(bluetooth: bluetooth)

        NSApp.setActivationPolicy(.accessory)
        outputSwitcher.start()

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "HDB 630")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let hostingController = NSHostingController(rootView:
            ControlRootView(controller: controller, bluetooth: bluetooth, dongle: dongle,
                            openDiagnostics: { [weak self] in self?.showDiagnostics() })
                .environmentObject(outputSwitcher)
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        // Update menu bar with battery level
        controller.$batteryLevel
            .combineLatest(bluetooth.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] battery, state in
                guard let button = self?.statusItem.button else { return }
                if state == .connected && battery > 0 {
                    button.title = " \(battery)%"
                } else {
                    button.title = ""
                }
            }
            .store(in: &cancellables)

        // Set device name and restore the control channel when macOS reconnects the headphones.
        bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.updatePolling()
                if state == .connected {
                    let name = self.bluetooth.pairedDevices.first?.name ?? "HDB 630"
                    self.controller.deviceInfo.name = name
                } else if state == .disconnected && !self.didInitialConnect && !self.bluetooth.pairedDevices.isEmpty {
                    self.didInitialConnect = true
                    self.recoverHeadphones()
                }
            }
            .store(in: &cancellables)

        bluetooth.scanForDevices()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverHeadphones() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if self.bluetooth.state == .connected && !self.bluetooth.pairedDevices.contains(where: { $0.isConnected() }) {
                    self.bluetooth.disconnect()
                }
                self.recoverHeadphones()
                await self.dongle.recoverAfterWake()
                self.outputSwitcher.refresh()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconnectTimer?.invalidate()
                if let wakeObserver = self?.wakeObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
                }
                self?.bluetooth.disconnect()
            }
        }
    }

    private func recoverHeadphones() {
        guard !bluetooth.userDisconnected else { return }
        switch bluetooth.state {
        case .connected, .connecting, .scanning: return
        default: break
        }
        if bluetooth.pairedDevices.isEmpty {
            bluetooth.scanForDevices()
        } else if let device = bluetooth.pairedDevices.first(where: { $0.isConnected() }) {
            bluetooth.connect(to: device)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            updatePolling()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            if bluetooth.state == .connected {
                Task { await controller.pollState() }
            }
            updatePolling()
        }
    }

    private var needsPolling: Bool {
        popover.isShown
    }

    func popoverDidClose(_ notification: Notification) {
        stopPolling()
    }

    private func updatePolling() {
        if needsPolling && bluetooth.state == .connected {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.bluetooth.state == .connected else { return }
                await self.controller.pollState()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func showDiagnostics() {
        if let diagnosticsWindow {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Signal Lab"
            window.minSize = NSSize(width: 700, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView:
                DiagnosticsView(controller: controller, bluetooth: bluetooth, dongle: dongle)
                    .environmentObject(outputSwitcher)
            )
            diagnosticsWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === diagnosticsWindow else { return }
        window.contentView = nil
        diagnosticsWindow = nil
    }
}

private struct ControlRootView: View {
    @ObservedObject var controller: HeadphoneController
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var dongle: DongleController
    let openDiagnostics: () -> Void
    @State private var selectedTab = 0
    @State private var showAppSettings = false

    private var contentHeight: CGFloat {
        if selectedTab == 1 { return dongle.available ? 540 : 150 }
        return bluetooth.state == .connected ? 610 : 225
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("Headphones", icon: "headphones", index: 0)
                tab("BTD 700", icon: "waveform.path", index: 1)
                Button(action: openDiagnostics) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Open Signal Lab diagnostics")
                .accessibilityLabel("Open Signal Lab diagnostics")
                Button {
                    showAppSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(showAppSettings ? .white.opacity(0.13) : .clear, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("App settings")
                .accessibilityLabel("App settings")
                .accessibilityAddTraits(showAppSettings ? .isSelected : [])
            }
            .padding(4)
            .background(.white.opacity(0.055), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 2)

            if showAppSettings {
                AppSettingsView()
            } else {
                Group {
                    if selectedTab == 0 {
                        StatusBarView(controller: controller, bluetooth: bluetooth)
                    } else {
                        ScrollView(showsIndicators: false) {
                            DongleView(dongle: dongle)
                        }
                    }
                }
                .frame(height: contentHeight, alignment: .top)
            }
        }
        .frame(width: 360)
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

    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button {
            selectedTab = index
            showAppSettings = false
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selectedTab == index && !showAppSettings ? .white : .white.opacity(0.56))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectedTab == index && !showAppSettings ? .white.opacity(0.13) : .clear, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == index && !showAppSettings ? .isSelected : [])
    }
}
