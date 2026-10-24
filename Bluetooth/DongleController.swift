import Foundation
import IOKit.hid
import Combine

// BTD 700 vendor HID report 0x34. Command IDs and packet layout were documented
// by btd700ctl (https://github.com/sobalap/btd700ctl); this is a native IOKit implementation.
@MainActor
final class DongleController: ObservableObject {
    enum AudioMode: UInt8, CaseIterable, Identifiable {
        case highQuality = 0
        case gaming = 1
        case broadcast = 2

        var id: UInt8 { rawValue }
        var title: String {
            switch self {
            case .highQuality: "High Quality"
            case .gaming: "Gaming / Low Latency"
            case .broadcast: "Auracast Broadcast"
            }
        }
    }

    enum Codec: UInt16, CaseIterable, Identifiable {
        case automatic = 0x003F
        case sbc = 0x0001
        case aptX = 0x0002
        case aptXAdaptive = 0x0004
        case aptXLossless = 0x0008
        case aptXLite = 0x0010
        case lc3 = 0x0020

        var id: UInt16 { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .sbc: "SBC"
            case .aptX: "aptX"
            case .aptXAdaptive: "aptX Adaptive"
            case .aptXLossless: "aptX Lossless"
            case .aptXLite: "aptX Lite"
            case .lc3: "LC3"
            }
        }
    }

    struct StatusSnapshot: Equatable {
        let firmware: String
        let connectionState: UInt8
        let audioMode: AudioMode
        let transport: UInt8
        let supportedCodecMask: UInt16
        let activeCodecMask: UInt16
        let bitDepth: UInt8
        let sampleRate: UInt8
        let leAudioState: UInt8?
        let sinkTransport: UInt8?

        @MainActor static func read(using command: (UInt8) async throws -> [UInt8]) async throws -> Self {
            func read(_ id: UInt8, minimum: Int) async throws -> [UInt8] {
                try Task.checkCancellation()
                let bytes = try await command(id)
                try Task.checkCancellation()
                guard bytes.count >= minimum else { throw DongleError.malformedResponse }
                return bytes
            }

            func optionalState(_ id: UInt8, maximum: UInt8) async throws -> UInt8? {
                do {
                    let bytes = try await read(id, minimum: 1)
                    return bytes[0] <= maximum ? bytes[0] : nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    return nil
                }
            }

            func mask(_ bytes: [UInt8]) -> UInt16 {
                UInt16(bytes[0]) | (bytes.count > 1 ? UInt16(bytes[1]) << 8 : 0)
            }

            let version = try await read(0x12, minimum: 3)
            let state = try await read(0x06, minimum: 1)
            let mode = try await read(0x01, minimum: 2)
            guard let audioMode = AudioMode(rawValue: mode[0]) else {
                throw DongleError.unsupportedAudioMode(mode[0])
            }
            let selected = try await read(0x03, minimum: 1)
            let active = try await read(0x05, minimum: 1)
            let quality = try await read(0x08, minimum: 2)
            let leAudioState = try await optionalState(0x07, maximum: 4)
            let sinkTransport = try await optionalState(0x15, maximum: 3)
            // Build number is little-endian 16-bit when the dongle sends the second byte (btd700ctl).
            let build = UInt16(version[2]) | (version.count > 3 ? UInt16(version[3]) << 8 : 0)
            return Self(firmware: "\(version[0]).\(version[1]).\(build)",
                        connectionState: state[0], audioMode: audioMode, transport: mode[1],
                        supportedCodecMask: mask(selected), activeCodecMask: mask(active),
                        bitDepth: quality[0], sampleRate: quality[1],
                        leAudioState: leAudioState, sinkTransport: sinkTransport)
        }
    }

    @Published private(set) var available = false
    @Published private(set) var busy = false
    private var activeOperations = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var firmware = ""
    @Published private(set) var connectionState: UInt8 = 0
    @Published private(set) var audioMode: AudioMode = .highQuality
    @Published private(set) var transport: UInt8 = 1
    @Published private(set) var supportedCodecMask: UInt16 = 0
    @Published private(set) var activeCodecMask: UInt16 = 0
    @Published private(set) var bitDepth: UInt8 = 0
    @Published private(set) var sampleRate: UInt8 = 0
    @Published private(set) var leAudioState: UInt8?
    @Published private(set) var sinkTransport: UInt8?

    var connectionDescription: String {
        switch connectionState {
        case 0, 1: "Disconnected"
        case 2: "Connected"
        case 3: "Streaming audio"
        case 4: "Streaming voice"
        default: "Unknown"
        }
    }

    var qualityDescription: String {
        guard connectionState >= 2 else { return "—" }
        let bits = bitDepth == 2 ? "24 bit" : bitDepth == 1 ? "16 bit" : "unknown depth"
        let rate: String
        switch sampleRate {
        case 1: rate = "44.1 kHz"
        case 2: rate = "48 kHz"
        case 3: rate = "96 kHz"
        default: rate = "unknown rate"
        }
        return "\(bits) / \(rate)"
    }

    var activeCodecDescription: String {
        guard connectionState >= 2, activeCodecMask != 0 else { return "None" }
        return Codec.allCases.first(where: { $0 != .automatic && $0.rawValue == activeCodecMask })?.title
            ?? String(format: "0x%04X", activeCodecMask)
    }

    private struct Pending {
        let id: UUID
        let command: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    private enum DongleError: LocalizedError {
        case unavailable
        case timeout
        case malformedResponse
        case unsupportedAudioMode(UInt8)
        case io(IOReturn)
        case rejected(UInt8)

        var errorDescription: String? {
            switch self {
            case .unavailable: "BTD 700 is not available. Check its USB connection."
            case .timeout: "The dongle did not respond. Close Sennheiser Dongle Control and retry."
            case .malformedResponse: "The dongle returned an incomplete response."
            case .unsupportedAudioMode(let mode): "The dongle reported an unsupported audio mode (code \(mode))."
            case .io(let code): "USB control failed (\(code))."
            case .rejected(let code): "The dongle rejected that setting (code \(code))."
            }
        }
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private var deviceGeneration = UUID()
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var pending: Pending?
    private var eventRefreshTask: Task<Void, Never>?

    init() {
        reportBuffer.initialize(repeating: 0, count: 64)
        let matching = [kIOHIDVendorIDKey: 0x3542, kIOHIDProductIDKey: 0x3001] as NSDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                let wasAvailable = owner.available
                owner.connect()
                if !wasAvailable && owner.available { Task { _ = await owner.refresh() } }
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, removed in
            guard let context else { return }
            let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let current = owner.device, CFEqual(current, removed) {
                    owner.detach()
                }
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(manager, 0)
        connect()
        Task { _ = await refresh() }
    }

    deinit {
        if let device {
            IOHIDDeviceClose(device, 0)
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, 0)
        reportBuffer.deinitialize(count: 64)
        reportBuffer.deallocate()
    }

    private func connect() {
        guard device == nil, let devices = IOHIDManagerCopyDevices(manager) else { return }
        let count = CFSetGetCount(devices)
        guard count > 0 else { return }
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer { values.deallocate() }
        CFSetGetValues(devices, values)

        for index in 0..<count {
            guard let value = values[index] else { continue }
            let candidate = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
            let pairs = IOHIDDeviceGetProperty(candidate, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
            guard pairs.contains(where: {
                ($0["DeviceUsagePage"] as? Int) == 0xFFA2 && ($0["DeviceUsage"] as? Int) == 1
            }) else { continue }
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }

            device = candidate
            deviceGeneration = UUID()
            IOHIDDeviceRegisterInputReportCallback(candidate, reportBuffer, 64, { context, _, sender, _, _, report, length in
                guard let context, length >= 0 else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: min(length, 64)))
                let owner = Unmanaged<DongleController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    guard let current = owner.device,
                          sender == Unmanaged.passUnretained(current).toOpaque() else { return }
                    owner.receive(bytes)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
            available = true
            errorMessage = nil
            return
        }
        available = false
    }

    private func detach() {
        deviceGeneration = UUID()
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: DongleError.unavailable)
        }
        if let device { IOHIDDeviceClose(device, 0) }
        device = nil
        available = false
        firmware = ""
        connectionState = 0
        activeCodecMask = 0
        supportedCodecMask = 0
        bitDepth = 0
        sampleRate = 0
        leAudioState = nil
        sinkTransport = nil
        errorMessage = nil
    }

    func recoverAfterWake() async {
        if available, await refresh() { return }
        guard !Task.isCancelled else { return }
        detach()
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return }
            connect()
            if available {
                if await refresh() { return }
                guard !Task.isCancelled else { return }
                detach()
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] == 0x34 else { return }
        if bytes[1] == 0xFC {
            handleEvent(bytes[2], Array(bytes[4..<min(4 + Int(bytes[3]), bytes.count)]))
            return
        }
        guard bytes[1] == 0xFF, let pending, bytes[2] == pending.command else { return }
        self.pending = nil
        let length = Int(bytes[3])
        guard length <= 60, bytes.count >= 4 + length else {
            pending.continuation.resume(throwing: DongleError.malformedResponse)
            return
        }
        pending.continuation.resume(returning: Array(bytes[4..<(4 + length)]))
    }

    private func command(_ id: UInt8, payload: [UInt8] = []) async throws -> [UInt8] {
        try Task.checkCancellation()
        if device == nil { connect() }
        let generation = deviceGeneration
        while pending != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard let device, available, deviceGeneration == generation else { throw DongleError.unavailable }
        let response: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            let requestID = UUID()
            pending = Pending(id: requestID, command: id, continuation: continuation)
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 0x34
            report[1] = 0xFE
            report[2] = id
            report[3] = UInt8(payload.count)
            for (index, byte) in payload.enumerated() { report[4 + index] = byte }
            let result = report.withUnsafeBytes { data in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x34,
                                     data.baseAddress!.assumingMemoryBound(to: UInt8.self), 64)
            }
            if result != kIOReturnSuccess {
                pending = nil
                continuation.resume(throwing: DongleError.io(result))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.pending?.id == requestID else { return }
                self.pending = nil
                continuation.resume(throwing: DongleError.timeout)
            }
        }
        try Task.checkCancellation()
        guard available, deviceGeneration == generation else { throw DongleError.unavailable }
        return response
    }

    // Event payloads use the same layout as the matching status reply (captured on firmware 3.11.0).
    private static let eventStatus: [UInt8: UInt8] = [
        0x02: 0x01, 0x03: 0x03, 0x04: 0x05, 0x0F: 0x06, 0x10: 0x07, 0x11: 0x08, 0x16: 0x15
    ]

    private func handleEvent(_ id: UInt8, _ payload: [UInt8]) {
        guard id != 0x17 else { return } // gaming availability is not shown
        do {
            guard let status = Self.eventStatus[id] else { throw DongleError.malformedResponse }
            try applyStatus(status, payload)
            if id == 0x0F {
                // No codec event arrives when the link drops, so re-read the active codec.
                let generation = deviceGeneration
                Task { [weak self] in
                    guard let self, let bytes = try? await self.command(0x05),
                          self.available, self.deviceGeneration == generation else { return }
                    try? self.applyStatus(0x05, bytes)
                }
            }
        } catch {
            eventRefreshTask?.cancel()
            eventRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                _ = await self?.refresh()
            }
        }
    }

    private func applyStatus(_ id: UInt8, _ bytes: [UInt8]) throws {
        func mask() throws -> UInt16 {
            guard let first = bytes.first else { throw DongleError.malformedResponse }
            return UInt16(first) | (bytes.count > 1 ? UInt16(bytes[1]) << 8 : 0)
        }
        switch id {
        case 0x06:
            guard let first = bytes.first else { throw DongleError.malformedResponse }
            connectionState = first
        case 0x01:
            guard bytes.count >= 2 else { throw DongleError.malformedResponse }
            guard let mode = AudioMode(rawValue: bytes[0]) else { throw DongleError.unsupportedAudioMode(bytes[0]) }
            audioMode = mode
            transport = bytes[1]
        case 0x03: supportedCodecMask = try mask()
        case 0x05: activeCodecMask = try mask()
        case 0x07: leAudioState = bytes.first.flatMap { $0 <= 4 ? $0 : nil }
        case 0x08:
            guard bytes.count >= 2 else { throw DongleError.malformedResponse }
            bitDepth = bytes[0]
            sampleRate = bytes[1]
        case 0x15: sinkTransport = bytes.first.flatMap { $0 <= 3 ? $0 : nil }
        default: break
        }
    }

    @discardableResult func refresh() async -> Bool {
        if device == nil { connect() }
        guard available, !Task.isCancelled else { return false }
        let generation = deviceGeneration
        beginOperation()
        defer { endOperation() }
        do {
            let snapshot = try await StatusSnapshot.read { id in
                guard available, deviceGeneration == generation else { throw DongleError.unavailable }
                return try await command(id)
            }
            try Task.checkCancellation()
            guard available, deviceGeneration == generation else { return false }
            firmware = snapshot.firmware
            connectionState = snapshot.connectionState
            audioMode = snapshot.audioMode
            transport = snapshot.transport
            supportedCodecMask = snapshot.supportedCodecMask
            activeCodecMask = snapshot.activeCodecMask
            bitDepth = snapshot.bitDepth
            sampleRate = snapshot.sampleRate
            leAudioState = snapshot.leAudioState
            sinkTransport = snapshot.sinkTransport
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if available, deviceGeneration == generation { errorMessage = error.localizedDescription }
            return false
        }
    }

    @discardableResult func setAudioMode(_ mode: AudioMode) async -> Bool {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x02, payload: [mode.rawValue, transport])
            try checkAck(response)
            guard await refresh() else { return false }
            if audioMode != mode {
                errorMessage = "The dongle did not switch to \(mode.title)."
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setCodec(_ codec: Codec) async {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x04, payload: [UInt8(codec.rawValue & 0xFF), UInt8(codec.rawValue >> 8)])
            try checkAck(response)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func setConnected(_ connected: Bool) async {
        beginOperation()
        defer { endOperation() }
        do {
            let response = try await command(0x14, payload: [connected ? 1 : 0])
            try checkAck(response)
            for attempt in 0...10 {
                guard await refresh() else { return }
                if connected ? connectionState >= 2 : connectionState <= 1 { return }
                if attempt < 10 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
            errorMessage = connected ? "The headphones did not reconnect within 20 seconds."
                                     : "The headphones did not disconnect."
        } catch { errorMessage = error.localizedDescription }
    }

    private func checkAck(_ response: [UInt8]) throws {
        guard let status = response.first else { throw DongleError.malformedResponse }
        guard status == 0 else { throw DongleError.rejected(status) }
    }

    private func beginOperation() {
        activeOperations += 1
        busy = true
    }

    private func endOperation() {
        activeOperations -= 1
        busy = activeOperations > 0
    }
}
