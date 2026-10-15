import Foundation

@main
struct GAIATests {
    static func main() {
        func check(_ condition: Bool, _ name: String) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                exit(1)
            }
        }

        let packet = GAIAProtocol.buildPacket(vendor: 0x0495, command: 0x0703, payload: [40])
        check(Array(packet) == [0xFF, 0x03, 0, 1, 4, 0x95, 7, 3, 40], "battery wire bytes")
        let parsed = GAIAProtocol.parse(packet)
        check(parsed?.response.vendorId == 0x0495 && parsed?.response.commandId == 0x0703,
              "response identity")
        check(parsed?.response.payload == Data([40]) && parsed?.consumed == 9, "battery payload")

        let prefixed = Data([0, 0, 0]) + packet
        let slice = prefixed.dropFirst(3)
        check(GAIAProtocol.parse(slice)?.response.payload == Data([40]), "nonzero Data slice payload")
        for length in 0..<packet.count {
            check(GAIAProtocol.parse(Data(packet.prefix(length))) == nil, "fragment length \(length)")
        }
        check(GAIAProtocol.parse(Data([0, 3, 0, 0, 4, 0x95, 7, 3])) == nil, "invalid header")

        let second = GAIAProtocol.buildPacket(vendor: 0x0495, command: 0x0900, payload: [8])
        let stream = packet + second
        if let first = GAIAProtocol.parse(stream) {
            check(first.consumed == 9 && first.response.payload == Data([40]), "first concatenated frame")
            let remaining = stream.dropFirst(first.consumed)
            check(GAIAProtocol.parse(remaining)?.response.payload == Data([8]), "second sliced frame")
        } else {
            check(false, "concatenated frames")
        }
        check(GAIAProtocol.responseCommandId(for: 0x1001) == 0x1101, "request correlation")
        print("GAIA tests passed: wire bytes, sliced payloads, fragments, headers and concatenated frames")
    }
}
