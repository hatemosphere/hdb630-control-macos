import Foundation
import Combine

@MainActor
final class BluetoothManager: ObservableObject {
    struct Command: Equatable {
        let vendor: UInt16
        let command: UInt16
        let payload: [UInt8]
    }

    @Published var state: ConnectionState = .connected
    var notificationHandler: ((GAIAProtocol.Response) -> Void)?
    var sent: [Command] = []
    var pairedCount = 0
    var disconnectedDeviceIndices: Set<UInt8> = []
    var battery: UInt8 = 81
    var compatibility: UInt8 = 1
    var restartCount = 0
    var rejectNextEQWrite = false
    var holdNextCommand: UInt16?
    var heldResponse: CheckedContinuation<GAIAProtocol.Response, Error>?

    func sendCommand(vendor: UInt16, command: UInt16, payload: [UInt8] = [], timeout: TimeInterval = 5) async throws -> GAIAProtocol.Response {
        sent.append(Command(vendor: vendor, command: command, payload: payload))
        if command == GAIAProtocol.cmdSetEQBand && rejectNextEQWrite {
            rejectNextEQWrite = false
            throw NSError(domain: "EQ failed", code: 2)
        }
        if holdNextCommand == command {
            holdNextCommand = nil
            return try await withCheckedThrowingContinuation { heldResponse = $0 }
        }
        let bytes: [UInt8]
        switch command {
        case GAIAProtocol.cmdGetSerial: bytes = Array("NEW-SESSION".utf8)
        case GAIAProtocol.cmdGetBattery: bytes = [battery]
        case GAIAProtocol.cmdGetEQ: bytes = [0]
        case GAIAProtocol.cmdGetPairedDeviceListSize: bytes = [UInt8(pairedCount >> 8), UInt8(pairedCount & 0xFF)]
        case GAIAProtocol.cmdGetDeviceInfo:
            let connected: UInt8 = disconnectedDeviceIndices.contains(payload[0]) ? 0 : 1
            bytes = pairedCount > 256 ? [0xFF, 0, 0] : [payload[0], payload[0], connected] + Array("Device \(payload[0])".utf8)
        case GAIAProtocol.cmdSetBluetoothCompatibility:
            compatibility = payload[0]
            bytes = []
        case GAIAProtocol.cmdGetBluetoothCompatibility: bytes = [compatibility]
        default: bytes = []
        }
        return response(vendor: vendor, command: command, payload: bytes)
    }

    func response(vendor: UInt16 = GAIAProtocol.vendorSennheiser, command: UInt16, payload: [UInt8]) -> GAIAProtocol.Response {
        GAIAProtocol.Response(vendorId: vendor, commandId: GAIAProtocol.responseCommandId(for: command), payload: Data(payload))
    }

    func restartAndReconnect() async throws {
        restartCount += 1
        state = .disconnected
        state = .connected
    }

    func writes(_ command: UInt16) -> [[UInt8]] {
        sent.filter { $0.command == command }.map(\.payload)
    }
}

@main
struct HeadphoneControllerTests {
    @MainActor
    static func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for \(message)")
    }

    @MainActor
    static func ready() async -> (BluetoothManager, HeadphoneController) {
        let manager = BluetoothManager()
        let controller = HeadphoneController(bluetooth: manager)
        await waitFor("initial state fetch") {
            manager.writes(GAIAProtocol.cmdGetEQ).count == 5 &&
                !manager.writes(GAIAProtocol.cmdGetPairedDeviceListSize).isEmpty
        }
        return (manager, controller)
    }

    @MainActor
    static func malformedCount() async {
        let (manager, controller) = await ready()
        manager.pairedCount = 257
        manager.sent = []
        await controller.fetchDeviceList()
        precondition(controller.controlError == "The headphones reported an invalid paired-device count (257).")
        precondition(manager.writes(GAIAProtocol.cmdGetDeviceInfo) == [])
        manager.pairedCount = 2
        await controller.fetchDeviceList()
        precondition(manager.writes(GAIAProtocol.cmdGetDeviceInfo) == [[0], [1]])
        precondition(controller.pairedDevices.map(\.name) == ["Device 0", "Device 1"])
        print("PASS malformed paired count is rejected and valid devices retain byte indices")
    }

    @MainActor
    static func missedConnectionNotifications() async {
        let (manager, controller) = await ready()
        manager.pairedCount = 2
        manager.disconnectedDeviceIndices = [0]
        manager.state = .disconnected
        manager.state = .connected
        await waitFor("paired devices after reconnect") { controller.pairedDevices.count == 2 }
        precondition(controller.pairedDevices.map(\.isConnected) == [false, true])

        manager.disconnectedDeviceIndices.remove(0)
        await controller.pollState()
        precondition(controller.pairedDevices.map(\.isConnected) == [true, true],
                     "A missed connection notification left the paired-device checkmark stale")

        manager.disconnectedDeviceIndices.insert(0)
        await controller.pollState()
        precondition(controller.pairedDevices.map(\.isConnected) == [false, true],
                     "A missed disconnection notification left the paired-device checkmark stale")
        print("PASS polling refreshes paired-device checkmarks when connection notifications are missed")
    }

    @MainActor
    static func lateRead() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdGetBattery
        let oldRead = Task { await controller.fetchBattery() }
        await waitFor("held old battery read") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.battery = 94
        manager.state = .connected
        await waitFor("new battery read") { controller.batteryLevel == 94 }
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdGetBattery, payload: [7]))
        manager.heldResponse = nil
        await oldRead.value
        precondition(controller.batteryLevel == 94)
        precondition(manager.writes(GAIAProtocol.cmdGetBattery).count == 3)
        print("PASS late old-session reply cannot overwrite the new battery reading")
    }

    @MainActor
    static func lateWriteError() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdSetCrossfeed
        let oldWrite = Task { await controller.setCrossfeed(1) }
        await waitFor("held old crossfeed write") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        controller.controlError = "Current session error"
        manager.heldResponse?.resume(throwing: NSError(domain: "Old session", code: 1))
        manager.heldResponse = nil
        await oldWrite.value
        precondition(controller.controlError == "Current session error")
        precondition(manager.writes(GAIAProtocol.cmdSetCrossfeed) == [[1]])
        print("PASS late old-session write error cannot replace the current error")
    }

    @MainActor
    static func eqWriteSession() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdSetEQBand
        let oldWrite = Task { await controller.sendEQBands(.rock) }
        await waitFor("held old EQ band write") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        controller.controlError = "Current session error"
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdSetEQBand, payload: []))
        manager.heldResponse = nil
        await oldWrite.value
        precondition(manager.writes(GAIAProtocol.cmdSetEQBand) == [[0, 0]])
        precondition(controller.controlError == "Current session error")
        await controller.sendEQBands(.pop)
        precondition(manager.writes(GAIAProtocol.cmdSetEQBand) == [[0, 0], [0, 0], [1, 231], [2, 0], [3, 25], [4, 0]])
        precondition(controller.controlError == nil)
        print("PASS old EQ operation stops at reconnect and a fresh preset sends all five literal bands")
    }

    @MainActor
    static func peqReadSession() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdGetHeadroom
        let oldRead = Task { await controller.fetchPEQ() }
        await waitFor("held old PEQ headroom read") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdGetHeadroom, payload: [0, 10]))
        manager.heldResponse = nil
        await oldRead.value
        precondition(manager.writes(GAIAProtocol.cmdGetStageFrequency) == [])
        await controller.fetchPEQ()
        precondition(manager.writes(GAIAProtocol.cmdGetStageFrequency) == [[0], [1], [2], [3], [4]])
        precondition(manager.writes(GAIAProtocol.cmdGetStageQ) == [[0], [1], [2], [3], [4]])
        print("PASS old PEQ read stops before issuing next-session stage queries and a fresh read visits all stages")
    }

    @MainActor
    static func initializationCancellation() async {
        let manager = BluetoothManager()
        manager.holdNextCommand = GAIAProtocol.cmdRegisterNotification
        let controller = HeadphoneController(bluetooth: manager)
        await waitFor("held old initialization") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        await waitFor("fresh initialization serial") { controller.deviceInfo.serial == "NEW-SESSION" }
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdRegisterNotification, payload: []))
        manager.heldResponse = nil
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(manager.writes(GAIAProtocol.cmdRegisterNotification).count == 12)
        precondition(manager.writes(GAIAProtocol.cmdGetSerial).count == 1)
        print("PASS reconnect cancels old initialization and completes the fresh settings fetch")
    }

    @MainActor
    static func debounceCancellation() async {
        let (manager, controller) = await ready()
        controller.setTransparency(17)
        controller.setSidetone(1)
        controller.setEQBand(0, gain: 1)
        controller.setPEQFrequency(0, hz: 100)
        controller.setPreGain(-1)
        manager.state = .disconnected
        manager.state = .connected
        try? await Task.sleep(nanoseconds: 200_000_000)
        let setters = [GAIAProtocol.cmdSetTransparency, GAIAProtocol.cmdSetSidetone,
                       GAIAProtocol.cmdSetEQBand, GAIAProtocol.cmdSetStageFrequency, GAIAProtocol.cmdSetPreGain]
        precondition(manager.sent.filter { setters.contains($0.command) } == [])
        controller.setTransparency(54)
        controller.setSidetone(3)
        controller.setEQBand(0, gain: 2)
        controller.setPEQFrequency(0, hz: 250)
        controller.setPreGain(-2)
        try? await Task.sleep(nanoseconds: 200_000_000)
        precondition(manager.writes(GAIAProtocol.cmdSetTransparency) == [[54]])
        precondition(manager.writes(GAIAProtocol.cmdSetSidetone) == [[3]])
        precondition(manager.writes(GAIAProtocol.cmdSetEQBand) == [[0, 20]])
        precondition(manager.writes(GAIAProtocol.cmdSetStageFrequency) == [[0, 0, 250]])
        precondition(manager.writes(GAIAProtocol.cmdSetPreGain) == [[255, 236]])
        print("PASS disconnect cancels old debounces and new-session edits send their exact payloads")
    }

    @MainActor
    static func activeDebounceCancellation() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdSetTransparency
        controller.setTransparency(17)
        await waitFor("active transparency write") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        await waitFor("fresh transparency read") {
            manager.writes(GAIAProtocol.cmdGetTransparency).count == 2
        }
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdSetTransparency, payload: []))
        manager.heldResponse = nil
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(manager.writes(GAIAProtocol.cmdGetTransparency).count == 2)
        controller.setTransparency(54)
        await waitFor("current transparency write") {
            manager.writes(GAIAProtocol.cmdSetTransparency) == [[17], [54]]
        }
        print("PASS teardown cancels an already-running debounce before it can read the next session")
    }

    @MainActor
    static func notificationDebounceCancellation() async {
        let (manager, controller) = await ready()
        manager.notificationHandler?(GAIAProtocol.Response(vendorId: GAIAProtocol.vendorSennheiser,
                                                          commandId: GAIAProtocol.notifEQ, payload: Data([10, 0, 0, 0, 0])))
        try? await Task.sleep(nanoseconds: 20_000_000)
        manager.state = .disconnected
        manager.state = .connected
        try? await Task.sleep(nanoseconds: 350_000_000)
        precondition(controller.eqGains == [0, 0, 0, 0, 0])
        manager.notificationHandler?(GAIAProtocol.Response(vendorId: GAIAProtocol.vendorSennheiser,
                                                          commandId: GAIAProtocol.notifEQ, payload: Data([20, 0, 0, 0, 0])))
        try? await Task.sleep(nanoseconds: 350_000_000)
        precondition(controller.eqGains == [2, 0, 0, 0, 0])
        print("PASS old EQ notifications cannot overwrite current settings and fresh notifications apply")
    }

    @MainActor
    static func canceledRead() async {
        let (manager, controller) = await ready()
        manager.holdNextCommand = GAIAProtocol.cmdGetBattery
        let read = Task { await controller.fetchBattery() }
        await waitFor("held canceled battery read") { manager.heldResponse != nil }
        read.cancel()
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdGetBattery, payload: [2]))
        manager.heldResponse = nil
        await read.value
        precondition(controller.batteryLevel == 81)
        manager.battery = 96
        await controller.fetchBattery()
        precondition(controller.batteryLevel == 96)
        print("PASS canceled read ignores its reply while a subsequent read updates battery")
    }

    @MainActor
    static func resolutionRestart() async {
        let (manager, controller) = await ready()
        await waitFor("initial resolution") { controller.highResolutionEnabled == false }
        await controller.setHighResolution(true)
        await waitFor("resolution after explicit restart") { controller.highResolutionEnabled == true }
        precondition(manager.restartCount == 1)
        precondition(manager.writes(GAIAProtocol.cmdSetBluetoothCompatibility) == [[0]])
        precondition(controller.controlError == nil)
        print("PASS verified resolution setting still performs the explicit restart flow")
    }

    @MainActor
    static func staleAudioModeError() async {
        let (manager, controller) = await ready()
        controller.audioMode = .off
        manager.rejectNextEQWrite = true
        manager.holdNextCommand = GAIAProtocol.cmdSetBassBoost
        let oldOperation = Task { await controller.setAudioMode(.userEq) }
        await waitFor("held old bass boost write") { manager.heldResponse != nil }
        manager.state = .disconnected
        manager.state = .connected
        controller.controlError = "Current session error"
        manager.heldResponse?.resume(returning: manager.response(command: GAIAProtocol.cmdSetBassBoost, payload: []))
        manager.heldResponse = nil
        await oldOperation.value
        precondition(controller.controlError == "Current session error", "The old audio-mode operation overwrote the new session's error")
        print("PASS old audio-mode follow-up cannot overwrite a new connection error")
    }

    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--malformed-count") {
            await malformedCount()
            return
        }
        await malformedCount()
        await missedConnectionNotifications()
        await lateRead()
        await lateWriteError()
        await eqWriteSession()
        await peqReadSession()
        await initializationCancellation()
        await debounceCancellation()
        await activeDebounceCancellation()
        await notificationDebounceCancellation()
        await canceledRead()
        await resolutionRestart()
        await staleAudioModeError()
        print("Headphone controller tests passed")
    }
}
