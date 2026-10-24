import AppKit
import Foundation
import IOBluetooth

@main
struct EQPersistenceCheck {
    struct Transition: Encodable {
        let elapsedSeconds: TimeInterval
        let connected: Bool
    }

    struct Report: Encodable {
        var before: [String: [UInt8]] = [:]
        var after: [String: [UInt8]]?
        var transitions: [Transition] = []
        var changedKeys: [String] = []
        var error: String?
        var passed = false
    }

    enum CheckError: Error {
        case connectionTimeout, restartNotObserved, settingsChanged, malformedSnapshot
    }

    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let restart = args.first == "--restart"
        guard args.count == (restart ? 2 : 1), let path = args.last, !path.hasPrefix("--") else {
            fputs("Usage: check-eq-persistence.sh [--restart] new-report.json\nQuit HDB 630 Control first. --restart reboots the headphones.\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else {
            fputs("Refusing to replace an existing report.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let bluetooth = BluetoothManager()
        signal(SIGTERM, SIG_DFL)
        var connecting = false
        var started = false
        let deadline = Date().addingTimeInterval(30)
        bluetooth.scanForDevices()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !started else { return }
                if bluetooth.state == .connected {
                    started = true
                    timer.invalidate()
                    Task { await check(bluetooth, restarting: restart, output: output) }
                } else if Date() > deadline {
                    timer.invalidate()
                    finish(bluetooth, report: Report(error: "Connection timed out"), output: output)
                } else if case .error(let message) = bluetooth.state {
                    timer.invalidate()
                    finish(bluetooth, report: Report(error: message), output: output)
                } else if bluetooth.state == .disconnected && !connecting {
                    guard bluetooth.pairedDevices.count == 1, let device = bluetooth.pairedDevices.first else {
                        timer.invalidate()
                        finish(bluetooth, report: Report(error: "Expected exactly one paired HDB 630"), output: output)
                        return
                    }
                    connecting = true
                    bluetooth.connect(to: device)
                }
            }
        }
        app.run()
    }

    @MainActor
    static func snapshot(_ bluetooth: BluetoothManager) async throws -> [String: [UInt8]] {
        var values: [String: [UInt8]] = [:]
        for command: UInt16 in [0x0804, 0x1000, 0x1009, 0x1013, 0x1014] {
            let response = try await bluetooth.sendCommand(vendor: 0x0495, command: command)
            let expectedLength = command == 0x1000 ? 5 : command == 0x1009 ? 1 : 2
            guard response.payload.count == expectedLength else { throw CheckError.malformedSnapshot }
            values[String(format: "%04X", command)] = Array(response.payload)
        }
        for stage: UInt8 in 0..<5 {
            for command: UInt16 in [0x1002, 0x100B, 0x100D, 0x100F, 0x1011] {
                let response = try await bluetooth.sendCommand(vendor: 0x0495, command: command, payload: [stage])
                let expectedLength = command == 0x1002 ? 1 : command == 0x100F ? 2 : 3
                guard response.payload.count == expectedLength,
                      command == 0x1002 || response.payload.first == stage else { throw CheckError.malformedSnapshot }
                values[String(format: "%04X:%d", command, stage)] = Array(response.payload)
            }
        }
        return values
    }

    @MainActor
    static func check(_ bluetooth: BluetoothManager, restarting: Bool, output: URL) async {
        var report = Report()
        do {
            report.before = try await snapshot(bluetooth)
            if restarting {
                guard let device = bluetooth.pairedDevices.first else { throw CheckError.connectionTimeout }
                let started = ProcessInfo.processInfo.systemUptime
                var transitions: [Transition] = [Transition(elapsedSeconds: 0, connected: device.isConnected())]
                let monitor = Timer(timeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let observedDevice = bluetooth.pairedDevices.first else { return }
                        let connected = observedDevice.isConnected()
                        if connected != transitions.last?.connected {
                            transitions.append(Transition(elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                                          connected: connected))
                        }
                    }
                }
                RunLoop.main.add(monitor, forMode: .common)
                defer {
                    monitor.invalidate()
                    report.transitions = transitions
                }
                try await bluetooth.restartAndReconnect()
                let deadline = Date().addingTimeInterval(25)
                while bluetooth.state != .connected {
                    guard Date() < deadline else { throw CheckError.connectionTimeout }
                    if case .error = bluetooth.state { throw CheckError.connectionTimeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let after = try await snapshot(bluetooth)
                report.after = after
                report.changedKeys = report.before.keys.filter { report.before[$0] != after[$0] }.sorted()
                let connected = device.isConnected()
                if connected != transitions.last?.connected {
                    transitions.append(Transition(elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                                  connected: connected))
                }
                guard transitions.first?.connected == true,
                      transitions.contains(where: { !$0.connected }),
                      transitions.last?.connected == true else { throw CheckError.restartNotObserved }
                guard report.changedKeys.isEmpty else { throw CheckError.settingsChanged }
            }
            report.passed = true
        } catch {
            report.error = String(describing: error)
        }
        finish(bluetooth, report: report, output: output)
    }

    @MainActor
    static func finish(_ bluetooth: BluetoothManager, report: Report, output: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
            print(report.passed ? "PASS" : "FAIL", output.path, report.changedKeys, report.error ?? "")
        } catch {
            fputs("Could not save report: \(error)\n", stderr)
            exit(1)
        }
        bluetooth.disconnect()
        fflush(stdout)
        exit(report.passed ? 0 : 1)
    }
}
