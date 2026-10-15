import Foundation

@main @MainActor struct DongleTests {
    enum ReadError: Error { case unavailable }

    static let commands: [UInt8] = [0x12, 0x06, 0x01, 0x03, 0x05, 0x08, 0x07, 0x15]
    static let replies: [UInt8: [UInt8]] = [
        0x12: [3, 11, 0], 0x06: [3], 0x01: [1, 1],
        0x03: [0x3F, 0x01], 0x05: [4], 0x08: [2, 3], 0x07: [1], 0x15: [1]
    ]

    static func main() async throws {
        var requests: [UInt8] = []
        let snapshot = try await DongleController.StatusSnapshot.read { id in
            requests.append(id)
            return replies[id]!
        }
        let expected = DongleController.StatusSnapshot(
            firmware: "3.11.0", connectionState: 3, audioMode: .gaming, transport: 1,
            supportedCodecMask: 0x013F, activeCodecMask: 4, bitDepth: 2, sampleRate: 3,
            leAudioState: 1, sinkTransport: 1)
        precondition(snapshot == expected, "Every status field must decode from its response")
        precondition(requests == commands, "A refresh reads the documented command sequence")

        for (id, minimum) in [(UInt8(0x12), 3), (0x06, 1), (0x01, 2), (0x03, 1), (0x05, 1), (0x08, 2)] {
            for count in 0..<minimum {
                requests = []
                do {
                    _ = try await DongleController.StatusSnapshot.read { request in
                        requests.append(request)
                        return request == id ? Array(replies[request]!.prefix(count)) : replies[request]!
                    }
                    preconditionFailure("Short mandatory response \(id) must fail")
                } catch {
                    precondition(error.localizedDescription == "The dongle returned an incomplete response.")
                    precondition(requests == Array(commands.prefix(through: commands.firstIndex(of: id)!)),
                                 "No later command may run after mandatory validation fails")
                }
            }
        }

        for rawMode in [UInt8(3), 255] {
            requests = []
            do {
                _ = try await DongleController.StatusSnapshot.read { id in
                    requests.append(id)
                    return id == 0x01 ? [rawMode, 1] : replies[id]!
                }
                preconditionFailure("Unknown modes must not become High Quality")
            } catch {
                precondition(error.localizedDescription == "The dongle reported an unsupported audio mode (code \(rawMode)).")
                precondition(requests == [0x12, 0x06, 0x01])
            }
        }

        for rawMode in [UInt8(0), 1, 2] {
            let status = try await DongleController.StatusSnapshot.read { id in
                id == 0x01 ? [rawMode, 1] : replies[id]!
            }
            precondition(status.audioMode.rawValue == rawMode, "Every known audio mode must retain its identity")
        }

        for id in [UInt8(0x07), 0x15] {
            let status = try await DongleController.StatusSnapshot.read { request in
                if request == id { throw ReadError.unavailable }
                return replies[request]!
            }
            precondition(status.firmware == "3.11.0" && status.audioMode == .gaming)
            precondition(status.leAudioState == (id == 0x07 ? nil : 1))
            precondition(status.sinkTransport == (id == 0x15 ? nil : 1))
        }

        for invalid in [[], [UInt8(255)]] {
            let status = try await DongleController.StatusSnapshot.read { id in
                id == 0x07 || id == 0x15 ? invalid : replies[id]!
            }
            precondition(status.leAudioState == nil && status.sinkTransport == nil)
            precondition(status.activeCodecMask == 4 && status.sampleRate == 3)
        }

        let oneByteMask = try await DongleController.StatusSnapshot.read { id in
            id == 0x03 ? [0x3F] : replies[id]!
        }
        precondition(oneByteMask.supportedCodecMask == 0x003F && oneByteMask.activeCodecMask == 4)

        for id in commands {
            requests = []
            do {
                _ = try await DongleController.StatusSnapshot.read { request in
                    requests.append(request)
                    if request == id { throw CancellationError() }
                    return replies[request]!
                }
                preconditionFailure("Cancellation must propagate, including optional reads")
            } catch is CancellationError {
                precondition(requests == Array(commands.prefix(through: commands.firstIndex(of: id)!)))
            }
        }

        var cancelledRequests: [UInt8] = []
        let cancelled = Task { @MainActor in
            try await DongleController.StatusSnapshot.read { id in
                cancelledRequests.append(id)
                return replies[id]!
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("An already cancelled refresh must not issue commands")
        } catch is CancellationError {
            precondition(cancelledRequests == [])
        }

        var inFlightRequests: [UInt8] = []
        let inFlight = Task { @MainActor in
            try await DongleController.StatusSnapshot.read { id in
                inFlightRequests.append(id)
                withUnsafeCurrentTask { $0?.cancel() }
                return replies[id]!
            }
        }
        do {
            _ = try await inFlight.value
            preconditionFailure("A refresh cancelled during a command must not continue")
        } catch is CancellationError {
            precondition(inFlightRequests == [0x12])
        }

        print("Dongle tests passed. Status decoding, mandatory lengths, known modes, optional failures, masks and cancellation.")
    }
}
