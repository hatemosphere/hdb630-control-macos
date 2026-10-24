import Foundation
@preconcurrency import IOBluetooth
import Combine
import os.log

private let btLog = OSLog(subsystem: "com.hdb630.control", category: "bluetooth")

private func BTLog(_ format: String, _ args: CVarArg...) {
    let msg = String(format: format, arguments: args)
    os_log("%{private}s", log: btLog, type: .default, msg)
}

private func BTTrace(_ format: String, _ args: CVarArg...) {
    let msg = String(format: format, arguments: args)
    os_log("%{private}s", log: btLog, type: .debug, msg)
}

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var pairedDevices: [IOBluetoothDevice] = []
    @Published private(set) var userDisconnected = false
    var notificationHandler: ((GAIAProtocol.Response) -> Void)?

    private struct Attempt {
        let id: UUID
        let device: IOBluetoothDevice
        let delegate: BluetoothAttemptDelegate
    }

    private enum Lifecycle {
        case idle
        case scanning(UUID)
        case discovering(Attempt)
        case opening(Attempt, IOBluetoothRFCOMMChannel)
        case connected(Attempt, IOBluetoothRFCOMMChannel, GAIACommandSession)
        case restarting(Attempt)
        case failed(String)
    }

    private var lifecycle: Lifecycle = .idle
    private var generation = UUID()
    private var attemptDeadline: Task<Void, Never>?
    // The SDK exposes no SDP cancellation or target-retention guarantee. Retain at most one unresolved target.
    private var pendingSDP: Attempt?
    private let ioQueue = DispatchQueue(label: "bluetooth.gaia", qos: .userInitiated)
    private var sigTermSource: DispatchSourceSignal?

    override init() {
        super.init()
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
        source.resume()
        sigTermSource = source
    }

    private func transition(to next: Lifecycle) {
        lifecycle = next
        switch next {
        case .idle: state = .disconnected
        case .scanning: state = .scanning
        case .discovering, .opening, .restarting: state = .connecting
        case .connected: state = .connected
        case .failed(let message): state = .error(message)
        }
    }

    func scanForDevices() {
        guard state != .connected, state != .connecting else { return }
        let id = UUID()
        generation = id
        transition(to: .scanning(id))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, case .scanning(let currentID) = self.lifecycle,
                  currentID == id, self.generation == id else { return }
            self.transition(to: .failed("Bluetooth discovery timed out. You can still use the BTD 700 tab."))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
            let matching = devices?.filter { device in
                let name = device.name ?? ""
                return name.localizedCaseInsensitiveContains("HDB") ||
                    name.localizedCaseInsensitiveContains("Sennheiser") ||
                    name.localizedCaseInsensitiveContains("630")
            }
            DispatchQueue.main.async {
                guard let self, case .scanning(let currentID) = self.lifecycle,
                      currentID == id, self.generation == id else { return }
                guard let matching else {
                    self.transition(to: .failed("Cannot access paired devices. Check Bluetooth permission."))
                    return
                }
                self.pairedDevices = matching
                self.transition(to: .idle)
            }
        }
    }

    private func findGAIAChannel(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
            BTLog("[BT] No SDP service records available")
            return nil
        }

        // Known GAIA service UUIDs (standard Qualcomm + HDB 630 vendor-specific)
        let knownGAIAUUIDs: [IOBluetoothSDPUUID] = [
            IOBluetoothSDPUUID(data: Data(GAIAProtocol.serviceUUIDBytes)),
            IOBluetoothSDPUUID(data: Data([0x11, 0x07])),
            IOBluetoothSDPUUID(data: Data(GAIAProtocol.hdb630ServiceUUIDBytes)),
        ]

        // Known non-GAIA UUIDs to exclude
        let excludedUUIDs: [IOBluetoothSDPUUID] = [
            IOBluetoothSDPUUID(data: Data([0x11, 0x1E])),  // HFP
            IOBluetoothSDPUUID(data: Data([0x12, 0x03])),  // Generic Audio
            IOBluetoothSDPUUID(data: Data([               // Airoha RACE (DECA-FADE)
                0x00, 0x00, 0x00, 0x00, 0xDE, 0xCA, 0xFA, 0xDE,
                0xDE, 0xCA, 0xDE, 0xAF, 0xDE, 0xCA, 0xCA, 0xFF
            ])),
        ]

        BTLog("[BT] Searching %d SDP services for GAIA UUID...", services.count)

        var candidateChannel: BluetoothRFCOMMChannelID?

        for service in services {
            var channelID: BluetoothRFCOMMChannelID = 0
            guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }

            // Get ServiceClassIDList (attr 0x0001)
            // May be a single UUID or an array of UUIDs
            guard let serviceClassElem = service.getAttributeDataElement(0x0001) else {
                BTLog("[BT] SDP ch%d: no ServiceClassIDList", channelID)
                continue
            }

            // Collect UUIDs from this service record
            var uuids: [IOBluetoothSDPUUID] = []
            if let uuid = serviceClassElem.getUUIDValue() {
                uuids.append(uuid)
            } else if let elements = serviceClassElem.getArrayValue() {
                for elem in elements {
                    if let sdpElem = elem as? IOBluetoothSDPDataElement,
                       let uuid = sdpElem.getUUIDValue() {
                        uuids.append(uuid)
                    }
                }
            }

            for uuid in uuids {
                let uuidHex = (uuid as Data).map { String(format: "%02X", $0) }.joined()
                BTLog("[BT] SDP ch%d: UUID %@", channelID, uuidHex)

                // Check for known GAIA UUIDs
                for gaiaUUID in knownGAIAUUIDs {
                    if uuid.isEqual(to: gaiaUUID) {
                        BTLog("[BT] GAIA service matched on RFCOMM channel %d", channelID)
                        return channelID
                    }
                }

                // Track as candidate if not a known non-GAIA service
                let isExcluded = excludedUUIDs.contains { uuid.isEqual(to: $0) }
                if !isExcluded {
                    BTLog("[BT] SDP ch%d: unknown UUID, marking as candidate", channelID)
                    candidateChannel = channelID
                }
            }
        }

        // If no known GAIA UUID matched but we have a single unidentified RFCOMM service, use it
        if let ch = candidateChannel {
            BTLog("[BT] Using candidate RFCOMM channel %d (unrecognized UUID, likely GAIA)", ch)
            return ch
        }

        BTLog("[BT] GAIA service not found in any SDP record")
        return nil
    }

    func connect(to device: IOBluetoothDevice) {
        generation = UUID()
        userDisconnected = false
        endConnection(as: .idle)
        guard device.isConnected() else {
            transition(to: .failed("Headphones not connected. Connect them in Bluetooth settings first."))
            return
        }
        let attempt = Attempt(id: generation, device: device,
                              delegate: BluetoothAttemptDelegate(manager: self, id: generation))
        transition(to: .discovering(attempt))
        let expiresAt = ContinuousClock.now.advanced(by: .seconds(10))
        attemptDeadline = Task { [weak self] in
            do { try await Task.sleep(until: expiresAt, clock: .continuous) } catch { return }
            guard let self, self.generation == attempt.id else { return }
            switch self.lifecycle {
            case .discovering, .opening:
                self.endConnection(as: .failed("Connection timed out. Try power-cycling headphones."))
            default: break
            }
        }
        // Always re-query SDP: the headphones can move GAIA to another RFCOMM channel after a restart
        // (seen 15 -> 2), and opening a stale cached channel just times out. Fall back to the cache
        // only when a fresh query can't run.
        guard pendingSDP == nil, device.performSDPQuery(attempt.delegate) == kIOReturnSuccess else {
            guard let channelID = findGAIAChannel(device) else {
                endConnection(as: .failed("Bluetooth service discovery could not start. Try again shortly."))
                return
            }
            openRFCOMM(attempt: attempt, channelID: channelID)
            return
        }
        pendingSDP = attempt
    }

    fileprivate func sdpQueryComplete(id: UUID, device: IOBluetoothDevice, status: IOReturn) {
        guard let query = pendingSDP, query.id == id else { return }
        pendingSDP = nil
        guard generation == id, case .discovering(let attempt) = lifecycle,
              attempt.id == id, device === attempt.device else { return }
        // A failed query leaves the cached records in place, so findGAIAChannel falls back to them.
        guard let channelID = findGAIAChannel(device) else {
            endConnection(as: .failed("GAIA service not found. Try re-pairing headphones."))
            return
        }
        openRFCOMM(attempt: attempt, channelID: channelID)
    }

    private func openRFCOMM(attempt: Attempt, channelID: BluetoothRFCOMMChannelID) {
        // Native opens can reuse an existing channel. Finish its queued close before opening a replacement.
        ioQueue.async { [weak self] in
            DispatchQueue.main.async {
                self?.beginRFCOMMOpen(attempt: attempt, channelID: channelID)
            }
        }
    }

    private func beginRFCOMMOpen(attempt: Attempt, channelID: BluetoothRFCOMMChannelID) {
        guard generation == attempt.id, case .discovering = lifecycle else { return }
        var channel: IOBluetoothRFCOMMChannel?
        let result = attempt.device.openRFCOMMChannelAsync(&channel, withChannelID: channelID,
                                                          delegate: attempt.delegate)
        guard result == kIOReturnSuccess, let channel else {
            endConnection(as: .failed("Failed to open RFCOMM channel: \(result)"))
            return
        }
        transition(to: .opening(attempt, channel))
    }

    func disconnect(userInitiated: Bool = false) {
        generation = UUID()
        if userInitiated { userDisconnected = true }
        endConnection(as: .idle)
    }

    private func endConnection(as next: Lifecycle) {
        attemptDeadline?.cancel()
        attemptDeadline = nil
        switch lifecycle {
        case .connected(let attempt, let channel, let session):
            session.close()
            close(channel, retaining: attempt.delegate)
        case .opening(let attempt, let channel):
            close(channel, retaining: attempt.delegate)
        default: break
        }
        transition(to: next)
    }

    private func close(_ channel: IOBluetoothRFCOMMChannel, retaining delegate: BluetoothAttemptDelegate) {
        ioQueue.async {
            channel.setDelegate(nil)
            channel.close()
            withExtendedLifetime(delegate) {}
        }
    }

    func restartAndReconnect() async throws {
        guard case .connected(let attempt, _, _) = lifecycle else { throw BluetoothError.notConnected }
        let id = generation
        do {
            _ = try await sendCommand(vendor: GAIAProtocol.vendorSennheiser, command: GAIAProtocol.cmdReboot)
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            endConnection(as: .restarting(attempt))
            try await Task.sleep(for: .seconds(6))
            guard generation == id else { throw CancellationError() }
            let result: IOReturn = await withCheckedContinuation { continuation in
                let device = attempt.device
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: device.isConnected() ? kIOReturnSuccess : device.openConnection())
                }
            }
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            guard result == kIOReturnSuccess, attempt.device.isConnected() else {
                endConnection(as: .failed("Headphones restarted, but the Mac could not reconnect. Connect HDB 630 in Bluetooth settings."))
                throw BluetoothError.notConnected
            }
            connect(to: attempt.device)
        } catch {
            if generation == id, case .restarting = lifecycle { endConnection(as: .idle) }
            throw error
        }
    }

    func sendCommand(vendor: UInt16, command: UInt16, payload: [UInt8] = [],
                     timeout: TimeInterval = 5) async throws -> GAIAProtocol.Response {
        guard case .connected(_, _, let session) = lifecycle else { throw BluetoothError.notConnected }
        return try await session.send(vendor: vendor, command: command, payload: payload, timeout: timeout)
    }

    private func write(_ packet: Data, requestID: UUID, attemptID: UUID,
                       channel: IOBluetoothRFCOMMChannel, session: GAIACommandSession) {
        ioQueue.async { [weak self] in
            let admitted = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attemptID,
                          case .connected(let attempt, let currentChannel, let currentSession) = self.lifecycle,
                          attempt.id == attemptID, currentChannel === channel,
                          currentSession === session else { return false }
                    return session.beginWrite(id: requestID)
                }
            }
            guard admitted else { return }
            var bytes = [UInt8](packet)
            BTTrace("[BT] TX %d bytes: %@", bytes.count,
                    bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
            let status = channel.writeSync(&bytes, length: UInt16(bytes.count))
            guard status != kIOReturnSuccess else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == attemptID,
                      case .connected(_, let currentChannel, let currentSession) = self.lifecycle,
                      currentChannel === channel, currentSession === session else { return }
                session.writeFailed(id: requestID, status: status)
            }
        }
    }

    fileprivate func channelOpened(id: UUID, channel: IOBluetoothRFCOMMChannel, status: IOReturn) {
        guard generation == id, case .opening(let attempt, let expected) = lifecycle,
              attempt.id == id, expected === channel else { return }
        guard status == kIOReturnSuccess else {
            endConnection(as: .failed("RFCOMM channel open failed: \(status)"))
            return
        }
        attemptDeadline?.cancel()
        attemptDeadline = nil
        let session = GAIACommandSession(write: { [weak self, weak channel] requestID, packet in
            guard let self, let channel,
                  case .connected(_, let currentChannel, let session) = self.lifecycle,
                  self.generation == id, currentChannel === channel else { return }
            self.write(packet, requestID: requestID, attemptID: id, channel: channel, session: session)
        }, notification: { [weak self] response in
            guard let self, self.generation == id, case .connected = self.lifecycle else { return }
            self.notificationHandler?(response)
        })
        transition(to: .connected(attempt, channel, session))
    }

    fileprivate func channelReceived(id: UUID, channel: IOBluetoothRFCOMMChannel, data: Data) {
        guard generation == id, case .connected(_, let expected, let session) = lifecycle,
              expected === channel else { return }
        BTTrace("[BT] RX %d bytes: %@", data.count,
                data.map { String(format: "%02X", $0) }.joined(separator: " "))
        session.receive(data)
    }

    fileprivate func channelClosed(id: UUID, channel: IOBluetoothRFCOMMChannel) {
        guard generation == id else { return }
        switch lifecycle {
        case .connected(_, let expected, _), .opening(_, let expected):
            guard expected === channel else { return }
            endConnection(as: .idle)
        default: break
        }
    }
}

private final class BluetoothAttemptDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
    private weak var manager: BluetoothManager?
    private let id: UUID

    init(manager: BluetoothManager, id: UUID) {
        self.manager = manager
        self.id = id
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device else { return }
        let manager = manager
        let id = id
        DispatchQueue.main.async { manager?.sdpQueryComplete(id: id, device: device, status: status) }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let channel, let pointer, length > 0 else { return }
        let data = Data(bytes: pointer, count: length)
        let manager = manager
        let id = id
        DispatchQueue.main.async { manager?.channelReceived(id: id, channel: channel, data: data) }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard let channel else { return }
        let manager = manager
        let id = id
        DispatchQueue.main.async { manager?.channelOpened(id: id, channel: channel, status: status) }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard let channel else { return }
        let manager = manager
        let id = id
        DispatchQueue.main.async { manager?.channelClosed(id: id, channel: channel) }
    }
}
