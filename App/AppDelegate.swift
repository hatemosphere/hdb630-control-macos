import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let bluetooth = BluetoothManager()
    private var controller: HeadphoneController!
    private var cancellables = Set<AnyCancellable>()
    private var didAutoConnect = false
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = HeadphoneController(bluetooth: bluetooth)

        NSApp.setActivationPolicy(.accessory)

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
        let hostingController = NSHostingController(
            rootView: StatusBarView(controller: controller, bluetooth: bluetooth)
                .environmentObject(bluetooth)
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

        // Set device name + auto-connect on launch
        bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .connected {
                    let name = self.bluetooth.pairedDevices.first?.name ?? "HDB 630"
                    self.controller.deviceInfo.name = name
                } else if state == .disconnected && !self.didAutoConnect && !self.bluetooth.pairedDevices.isEmpty {
                    self.didAutoConnect = true
                    if let hdb = self.bluetooth.pairedDevices.first(where: {
                        ($0.name ?? "").localizedCaseInsensitiveContains("HDB") ||
                        ($0.name ?? "").localizedCaseInsensitiveContains("630")
                    }), hdb.isConnected() {
                        self.bluetooth.connect(to: hdb)
                    }
                }
            }
            .store(in: &cancellables)

        bluetooth.scanForDevices()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.bluetooth.disconnect()
        }

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
            guard let self, self.bluetooth.state == .connected else { return }
            Task { await self.controller.pollState() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
