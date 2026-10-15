import Foundation

@MainActor
private final class RecordingSession {
    struct Write {
        let id: UUID
        let packet: Data
    }
    var writes: [Write] = []
    var queuedWrites: [Write] = []
    var holdWrites = false
    var notifications: [GAIAProtocol.Response] = []
    lazy var session: GAIACommandSession = GAIACommandSession(write: { [unowned self] id, packet in
        let write = Write(id: id, packet: packet)
        if holdWrites {
            queuedWrites.append(write)
        } else if session.beginWrite(id: id) {
            writes.append(write)
        }
    }, notification: { [unowned self] response in
        notifications.append(response)
    })

    func send(_ command: UInt16 = 0x1002, vendor: UInt16 = 0x0495,
              payload: [UInt8] = [], timeout: TimeInterval = 0.8) -> Task<GAIAProtocol.Response, Error> {
        Task { try await session.send(vendor: vendor, command: command, payload: payload, timeout: timeout) }
    }

    func releaseWrite() {
        let write = queuedWrites.removeFirst()
        if session.beginWrite(id: write.id) { writes.append(write) }
    }
}

@main
@MainActor
struct BluetoothSessionTests {
    static func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition() {
            precondition(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func payload(_ task: Task<GAIAProtocol.Response, Error>, _ expected: [UInt8]) async throws {
        let response = try await task.value
        precondition(Array(response.payload) == expected)
    }

    static func failure(_ task: Task<GAIAProtocol.Response, Error>, _ expected: String) async {
        switch await task.result {
        case .success: preconditionFailure("Expected \(expected)")
        case .failure(let error):
            switch (error, expected) {
            case (is CancellationError, "cancelled"): break
            case (BluetoothError.timeout, "timeout"): break
            case (BluetoothError.notConnected, "disconnected"): break
            case (BluetoothError.commandError(0x1002), "rejected"): break
            case (BluetoothError.writeFailed(-7), "write failed"): break
            default: preconditionFailure("Unexpected failure \(error), expected \(expected)")
            }
        }
    }

    static func fifo() async throws {
        let f = RecordingSession()
        let a = f.send(payload: [0])
        try await waitFor("first request written") { f.writes.count == 1 }
        let b = f.send(payload: [1])
        let c = f.send(payload: [2])
        try await Task.sleep(for: .milliseconds(5))
        precondition(f.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 00")])
        f.session.receive(data("FF 03 00 01 04 95 11 02 09"))
        try await payload(a, [9])
        try await waitFor("second request written") { f.writes.count == 2 }
        precondition(f.writes[1].packet == data("FF 03 00 01 04 95 10 02 01"))
        f.session.receive(data("FF 03 00 01 04 95 11 02 0A"))
        try await payload(b, [10])
        try await waitFor("third request written") { f.writes.count == 3 }
        precondition(f.writes[2].packet == data("FF 03 00 01 04 95 10 02 02"))
        f.session.receive(data("FF 03 00 01 04 95 11 02 0B"))
        try await payload(c, [11])
        precondition(Set(f.writes.map(\.id)).count == 3)
        f.session.close()
    }

    static func correlationAndFraming() async throws {
        let f = RecordingSession()
        let a = f.send(payload: [4])
        let b = f.send(vendor: 0x001D, payload: [2])
        let battery = f.send(0x0603)
        try await waitFor("independent requests written") { f.writes.count == 3 }
        precondition(Set(f.writes.map(\.packet)) == Set([
            data("FF 03 00 01 04 95 10 02 04"),
            data("FF 03 00 01 00 1D 10 02 02"),
            data("FF 03 00 00 04 95 06 03")
        ]))
        f.session.receive(data("00 12 FF 03 00 01 99 99 11 02 55 FF 03 00"))
        f.session.receive(data("01 04 95 07 03 64 FF 03 00 01 00 1D 11 02 0F FF"))
        f.session.receive(data("03 00 00 04 95 11 82"))
        try await payload(battery, [100])
        try await payload(b, [15])
        await failure(a, "rejected")
        precondition(f.notifications.count == 1)
        precondition(f.notifications[0].vendorId == 0x9999)
        precondition(f.notifications[0].commandId == 0x1102)
        precondition(Array(f.notifications[0].payload) == [0x55])
        f.session.receive(data("FF 03 00 01 04 95 10 82 05"))
        precondition(f.notifications.last?.commandId == 0x1082)
        precondition(f.notifications.last?.payload == Data([5]))
        f.session.close()
    }

    static func cancellation() async throws {
        let f = RecordingSession()
        let a = f.send(payload: [0])
        try await waitFor("active cancellation request written") { f.writes.count == 1 }
        let waiting = f.send(payload: [1])
        try await Task.sleep(for: .milliseconds(5))
        waiting.cancel()
        await failure(waiting, "cancelled")
        a.cancel()
        await failure(a, "cancelled")
        let next = f.send(payload: [2])
        try await Task.sleep(for: .milliseconds(5))
        precondition(f.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 00")])
        f.session.receive(data("FF 03 00 01 04 95 11 02 7F"))
        try await waitFor("late response drained before next send") { f.writes.count == 2 }
        precondition(f.writes[1].packet == data("FF 03 00 01 04 95 10 02 02"))
        f.session.receive(data("FF 03 00 01 04 95 11 02 0C"))
        try await payload(next, [12])
        precondition(f.notifications.isEmpty)
        let preCancelled = f.send(0x0603)
        preCancelled.cancel()
        await failure(preCancelled, "cancelled")
        precondition(f.writes.count == 2)
        f.session.close()
    }

    static func deadlines() async throws {
        let f = RecordingSession()
        let active = f.send(payload: [0], timeout: 0.04)
        try await waitFor("timed request written") { f.writes.count == 1 }
        let queued = f.send(payload: [1], timeout: 0.06)
        let surviving = f.send(payload: [2], timeout: 0.6)
        await failure(active, "timeout")
        await failure(queued, "timeout")
        precondition(f.writes.count == 1)
        let battery = f.send(0x0603)
        try await waitFor("other command survives unanswered getter") { f.writes.count == 2 }
        precondition(f.writes[1].packet == data("FF 03 00 00 04 95 06 03"))
        f.session.receive(data("FF 03 00 01 04 95 07 03 50"))
        try await payload(battery, [80])
        f.session.receive(data("FF 03 00 01 04 95 11 02 66"))
        try await waitFor("late timed-out response drained") { f.writes.count == 3 }
        precondition(f.writes[2].packet == data("FF 03 00 01 04 95 10 02 02"))
        f.session.receive(data("FF 03 00 01 04 95 11 02 03"))
        try await payload(surviving, [3])
        f.session.close()

        let g = RecordingSession()
        let first = g.send(payload: [0], timeout: 0.04)
        try await waitFor("first stale-timer request written") { g.writes.count == 1 }
        g.session.receive(data("FF 03 00 01 04 95 11 02 01"))
        try await payload(first, [1])
        let second = g.send(payload: [1], timeout: 0.3)
        try await waitFor("replacement request written") { g.writes.count == 2 }
        try await Task.sleep(for: .milliseconds(65))
        g.session.receive(data("FF 03 00 01 04 95 11 02 02"))
        try await payload(second, [2])
        g.session.close()
    }

    static func teardownAndWriteFailure() async throws {
        let old = RecordingSession()
        let a = old.send(payload: [0], timeout: 0.04)
        let b = old.send(payload: [1], timeout: 0.04)
        let c = old.send(0x0603, timeout: 0.04)
        try await waitFor("old session requests written") { old.writes.count == 2 }
        old.session.receive(data("FF 03 00 01 04"))
        old.session.close()
        old.session.close()
        await failure(a, "disconnected")
        await failure(b, "disconnected")
        await failure(c, "disconnected")
        let closed = old.send()
        await failure(closed, "disconnected")
        old.session.receive(data("95 11 02 55"))
        precondition(old.writes.count == 2 && old.notifications.isEmpty)

        let fresh = RecordingSession()
        let replacement = fresh.send(payload: [4])
        try await waitFor("new session independent of old fragments") { fresh.writes.count == 1 }
        try await Task.sleep(for: .milliseconds(65))
        old.session.receive(data("FF 03 00 01 04 95 11 02 77"))
        fresh.session.receive(data("FF 03 00 01 04 95 11 02 08"))
        try await payload(replacement, [8])

        let failed = fresh.send(payload: [0])
        try await waitFor("failing write recorded") { fresh.writes.count == 2 }
        let next = fresh.send(payload: [1])
        try await Task.sleep(for: .milliseconds(5))
        fresh.session.writeFailed(id: fresh.writes[1].id, status: -7)
        await failure(failed, "write failed")
        try await waitFor("known zero-byte failure advances lane") { fresh.writes.count == 3 }
        precondition(fresh.writes[2].packet == data("FF 03 00 01 04 95 10 02 01"))
        fresh.session.writeFailed(id: fresh.writes[1].id, status: -7)
        fresh.session.receive(data("FF 03 00 01 04 95 11 02 04"))
        try await payload(next, [4])
        fresh.session.close()
    }

    static func notificationTeardown() async throws {
        var received: [UInt8] = []
        var writeCount = 0
        var session: GAIACommandSession!
        session = GAIACommandSession(write: { _, _ in writeCount += 1 }, notification: { response in
            received += response.payload
            session.close()
        })
        let pending = Task { try await session.send(vendor: 0x0495, command: 0x0603, timeout: 0.3) }
        try await waitFor("request before notification-triggered close") { writeCount == 1 }
        session.receive(data("FF 03 00 01 04 95 10 82 01 FF 03 00 01 04 95 10 82 02 FF 03 00 01 04 95 07 03 64"))
        await failure(pending, "disconnected")
        precondition(received == [1])
        session.receive(data("FF 03 00 01 04 95 10 82 03"))
        precondition(received == [1])
    }

    static func cancellationBeforeActorHop() async throws {
        let f = RecordingSession()
        f.holdWrites = true
        let cancelled = f.send(payload: [0x7F])
        try await waitFor("native write queued before synchronous cancellation") { f.queuedWrites.count == 1 }
        cancelled.cancel()
        f.releaseWrite()
        precondition(f.writes.isEmpty, "Cancellation must block native admission before the actor cleanup runs")
        await failure(cancelled, "cancelled")
        let fresh = f.send(payload: [1])
        try await waitFor("fresh native request after immediate cancellation") { f.queuedWrites.count == 1 }
        f.releaseWrite()
        precondition(f.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 01")])
        fresh.cancel()
        f.session.receive(data("FF 03 00 01 04 95 11 02 08"))
        await failure(fresh, "cancelled")
        f.session.close()
    }

    static func queuedWriteAdmission() async throws {
        let cancelled = RecordingSession()
        cancelled.holdWrites = true
        let stale = cancelled.send(payload: [0x7F])
        try await waitFor("cancelled native write queued") { cancelled.queuedWrites.count == 1 }
        let staleID = cancelled.queuedWrites[0].id
        stale.cancel()
        await failure(stale, "cancelled")
        let replacement = cancelled.send(payload: [1])
        try await Task.sleep(for: .milliseconds(5))
        cancelled.releaseWrite()
        precondition(cancelled.writes.isEmpty)
        precondition(cancelled.queuedWrites.map(\.packet) == [data("FF 03 00 01 04 95 10 02 01")])
        precondition(!cancelled.session.beginWrite(id: staleID))
        cancelled.releaseWrite()
        precondition(cancelled.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 01")])
        let following = cancelled.send(payload: [2])
        try await Task.sleep(for: .milliseconds(5))
        cancelled.session.writeFailed(id: staleID, status: -7)
        precondition(!cancelled.session.beginWrite(id: staleID))
        precondition(cancelled.queuedWrites.isEmpty)
        cancelled.session.receive(data("FF 03 00 01 04 95 11 02 04"))
        try await payload(replacement, [4])
        precondition(cancelled.queuedWrites.map(\.packet) == [data("FF 03 00 01 04 95 10 02 02")])
        cancelled.releaseWrite()
        cancelled.session.receive(data("FF 03 00 01 04 95 11 02 05"))
        try await payload(following, [5])
        cancelled.session.close()

        let expired = RecordingSession()
        expired.holdWrites = true
        let timedOut = expired.send(payload: [0x7F], timeout: 0.03)
        try await waitFor("expired native write queued") { expired.queuedWrites.count == 1 }
        await failure(timedOut, "timeout")
        let fresh = expired.send(payload: [3])
        try await Task.sleep(for: .milliseconds(5))
        expired.releaseWrite()
        precondition(expired.writes.isEmpty)
        expired.releaseWrite()
        precondition(expired.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 03")])
        expired.session.receive(data("FF 03 00 01 04 95 11 02 06"))
        try await payload(fresh, [6])
        expired.session.close()

        let disconnected = RecordingSession()
        disconnected.holdWrites = true
        let old = disconnected.send(payload: [0x7F])
        try await waitFor("disconnected native write queued") { disconnected.queuedWrites.count == 1 }
        disconnected.session.close()
        await failure(old, "disconnected")
        disconnected.releaseWrite()
        precondition(disconnected.writes.isEmpty)

        let new = RecordingSession()
        new.holdWrites = true
        let current = new.send(payload: [4])
        try await waitFor("fresh session native write queued") { new.queuedWrites.count == 1 }
        new.releaseWrite()
        precondition(new.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 04")])
        new.session.receive(data("FF 03 00 01 04 95 11 02 07"))
        try await payload(current, [7])
        new.session.close()
    }

    static func queuedDeadlineBeforeTimerRuns() async throws {
        let f = RecordingSession()
        f.holdWrites = true
        let expired = f.send(payload: [0x7F], timeout: 0.03)
        try await waitFor("native write queued before deadline") { f.queuedWrites.count == 1 }
        let releaseAt = ContinuousClock.now.advanced(by: .milliseconds(40))
        while ContinuousClock.now < releaseAt {}
        f.releaseWrite()
        await failure(expired, "timeout")
        precondition(f.writes.isEmpty)
        let fresh = f.send(payload: [8])
        try await waitFor("fresh write after admission expires old request") { f.queuedWrites.count == 1 }
        f.releaseWrite()
        precondition(f.writes.map(\.packet) == [data("FF 03 00 01 04 95 10 02 08")])
        f.session.receive(data("FF 03 00 01 04 95 11 02 09"))
        try await payload(fresh, [9])
        f.session.close()
    }

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fputs("Bluetooth session tests exceeded the outer deadline\n", stderr)
            exit(1)
        }
        try await fifo()
        try await correlationAndFraming()
        try await cancellation()
        try await deadlines()
        try await teardownAndWriteFailure()
        try await notificationTeardown()
        try await cancellationBeforeActorHop()
        try await queuedWriteAdmission()
        try await queuedDeadlineBeforeTimerRuns()
        print("Bluetooth session tests passed. FIFO, correlation, framing, cancellation, deadlines, teardown, write identity, and queued write admission.")
    }
}
