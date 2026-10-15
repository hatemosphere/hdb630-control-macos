import Foundation
import os

@MainActor
final class GAIACommandSession {
    private struct Key: Hashable {
        let vendor: UInt16
        let responseCommand: UInt16
    }

    private final class Request {
        let id: UUID
        let command: UInt16
        let packet: Data
        let expiresAt: ContinuousClock.Instant
        let cancellation: OSAllocatedUnfairLock<Bool>
        var continuation: CheckedContinuation<GAIAProtocol.Response, Error>?
        var deadline: Task<Void, Never>?

        var isCancelled: Bool { cancellation.withLock { $0 } }

        init(id: UUID, command: UInt16, packet: Data, expiresAt: ContinuousClock.Instant,
             cancellation: OSAllocatedUnfairLock<Bool>,
             continuation: CheckedContinuation<GAIAProtocol.Response, Error>) {
            self.id = id
            self.command = command
            self.packet = packet
            self.expiresAt = expiresAt
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }

    private final class Lane {
        var active: Request?
        var waiting: [Request] = []
    }

    private var lanes: [Key: Lane] = [:]
    private var receiveBuffer = Data()
    private var closed = false
    private let write: (UUID, Data) -> Void
    private let notification: (GAIAProtocol.Response) -> Void

    init(write: @escaping (UUID, Data) -> Void,
         notification: @escaping (GAIAProtocol.Response) -> Void) {
        self.write = write
        self.notification = notification
    }

    func send(vendor: UInt16, command: UInt16, payload: [UInt8] = [],
              timeout: TimeInterval = 5) async throws -> GAIAProtocol.Response {
        try Task.checkCancellation()
        guard !closed else { throw BluetoothError.notConnected }
        guard timeout.isFinite, timeout > 0 else { throw BluetoothError.timeout }
        guard payload.count <= Int(UInt16.max) - GAIAProtocol.headerSize else {
            throw BluetoothError.packetTooLarge
        }
        let id = UUID()
        let key = Key(vendor: vendor, responseCommand: GAIAProtocol.responseCommandId(for: command))
        let packet = GAIAProtocol.buildPacket(vendor: vendor, command: command, payload: payload)
        let expiresAt = ContinuousClock.now.advanced(by: .seconds(min(timeout, Double(Int32.max))))
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = Request(id: id, command: command, packet: packet,
                                      expiresAt: expiresAt, cancellation: cancellation,
                                      continuation: continuation)
                let lane = lanes[key] ?? Lane()
                lanes[key] = lane
                lane.waiting.append(request)
                request.deadline = Task { [weak self] in
                    do {
                        try await Task.sleep(until: expiresAt, clock: .continuous)
                    } catch { return }
                    self?.abandon(id: id, key: key, error: BluetoothError.timeout)
                }
                advance(key: key)
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
            Task { @MainActor [weak self] in
                self?.abandon(id: id, key: key, error: CancellationError())
            }
        }
    }

    func receive(_ data: Data) {
        guard !closed else { return }
        receiveBuffer.append(data)
        let bytes = [UInt8](receiveBuffer)
        var offset = 0
        while !closed, bytes.count - offset >= GAIAProtocol.headerSize {
            guard bytes[offset] == 0xFF, bytes[offset + 1] == 0x03 else {
                offset += 1
                continue
            }
            let length = GAIAProtocol.headerSize + Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            guard bytes.count - offset >= length else { break }
            let packet = Data(bytes[offset..<(offset + length)])
            offset += length
            guard let (response, _) = GAIAProtocol.parse(packet) else { continue }
            let normalCommand = response.commandId & 0x0180 == 0x0180
                ? response.commandId & ~UInt16(0x0080) : response.commandId
            let key = Key(vendor: response.vendorId, responseCommand: normalCommand)
            if let lane = lanes[key], let active = lane.active {
                lane.active = nil
                if active.isCancelled {
                    complete(active, result: .failure(CancellationError()))
                } else if active.expiresAt <= .now {
                    complete(active, result: .failure(BluetoothError.timeout))
                } else if response.isError {
                    complete(active, result: .failure(BluetoothError.commandError(active.command)))
                } else {
                    complete(active, result: .success(response))
                }
                advance(key: key)
            } else {
                notification(response)
            }
        }
        if !closed { receiveBuffer = Data(bytes[offset...]) }
    }

    func beginWrite(id: UUID) -> Bool {
        guard !closed,
              let (key, lane) = lanes.first(where: { $0.value.active?.id == id }),
              let request = lane.active else { return false }
        guard request.continuation != nil, !request.isCancelled, request.expiresAt > .now else {
            lane.active = nil
            let error: Error = request.isCancelled ? CancellationError() : BluetoothError.timeout
            complete(request, result: .failure(error))
            advance(key: key)
            return false
        }
        return true
    }

    func writeFailed(id: UUID, status: Int32) {
        guard !closed,
              let (key, lane) = lanes.first(where: { $0.value.active?.id == id }),
              let request = lane.active else { return }
        lane.active = nil
        complete(request, result: .failure(BluetoothError.writeFailed(status)))
        advance(key: key)
    }

    func close(with error: Error = BluetoothError.notConnected) {
        guard !closed else { return }
        closed = true
        receiveBuffer.removeAll()
        let previous = lanes
        lanes.removeAll()
        for lane in previous.values {
            if let active = lane.active { complete(active, result: .failure(error)) }
            for request in lane.waiting { complete(request, result: .failure(error)) }
        }
    }

    private func advance(key: Key) {
        guard let lane = lanes[key], lane.active == nil else { return }
        while let next = lane.waiting.first, next.isCancelled || next.expiresAt <= .now {
            lane.waiting.removeFirst()
            let error: Error = next.isCancelled ? CancellationError() : BluetoothError.timeout
            complete(next, result: .failure(error))
        }
        guard !lane.waiting.isEmpty else {
            lanes.removeValue(forKey: key)
            return
        }
        let next = lane.waiting.removeFirst()
        lane.active = next
        write(next.id, next.packet)
    }

    private func abandon(id: UUID, key: Key, error: Error) {
        guard let lane = lanes[key] else { return }
        if let active = lane.active, active.id == id {
            // GAIA has no transaction ID. Consume its late reply before sending another same-key request.
            complete(active, result: .failure(error))
        } else if let index = lane.waiting.firstIndex(where: { $0.id == id }) {
            complete(lane.waiting.remove(at: index), result: .failure(error))
        }
    }

    private func complete(_ request: Request, result: Result<GAIAProtocol.Response, Error>) {
        request.deadline?.cancel()
        request.deadline = nil
        let continuation = request.continuation
        request.continuation = nil
        continuation?.resume(with: result)
    }
}

enum BluetoothError: LocalizedError {
    case notConnected
    case writeFailed(Int32)
    case timeout
    case commandError(UInt16)
    case packetTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to headphones"
        case .writeFailed(let code): return "Bluetooth write failed: \(code)"
        case .timeout: return "Command timed out"
        case .commandError(let command): return "Headphones rejected command 0x\(String(format: "%04X", command))"
        case .packetTooLarge: return "Bluetooth command exceeds the packet size limit"
        }
    }
}
