#!/usr/bin/env swift
// Probe GAIA v3 command IDs — systematically send Get commands and record responses
// Uses the same connection logic as the main HDB630Control app
import Cocoa
import IOBluetooth

func hex(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func log(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    fputs("[\(ts)] \(msg)\n", stderr)
    fflush(stderr)
}

func gaiaPacket(vendor: UInt16, cmd: UInt16, payload: [UInt8] = []) -> Data {
    var pkt: [UInt8] = [0xFF, 0x03]
    let paramSize = UInt16(payload.count)
    pkt.append(UInt8((paramSize >> 8) & 0xFF))
    pkt.append(UInt8(paramSize & 0xFF))
    pkt.append(UInt8((vendor >> 8) & 0xFF))
    pkt.append(UInt8(vendor & 0xFF))
    pkt.append(UInt8((cmd >> 8) & 0xFF))
    pkt.append(UInt8(cmd & 0xFF))
    pkt.append(contentsOf: payload)
    return Data(pkt)
}

// Known GAIA UUIDs (same as BluetoothManager / GAIAProtocol)
let knownGAIAUUIDs: [IOBluetoothSDPUUID] = [
    IOBluetoothSDPUUID(data: Data([0x00,0x00,0x11,0x07,0xD1,0x02,0x11,0xE1,0x9B,0x23,0x00,0x02,0x5B,0x00,0xA5,0xA5])),
    IOBluetoothSDPUUID(data: Data([0x11,0x07])),
    IOBluetoothSDPUUID(data: Data([0xA2,0x12,0x9F,0xF3,0x08,0x1B,0x4C,0x45,0x8A,0xFE,0x46,0x9D,0x9C,0x48,0x42,0xEC])),
]

let excludedUUIDs: [IOBluetoothSDPUUID] = [
    IOBluetoothSDPUUID(data: Data([0x11,0x1E])),
    IOBluetoothSDPUUID(data: Data([0x12,0x03])),
    IOBluetoothSDPUUID(data: Data([0x00,0x00,0x00,0x00,0xDE,0xCA,0xFA,0xDE,0xDE,0xCA,0xDE,0xAF,0xDE,0xCA,0xCA,0xFF])),
]

// SDP channel discovery — same logic as BluetoothManager.findGAIAChannel
func findGAIAChannel(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
    guard let services = device.services as? [IOBluetoothSDPServiceRecord] else {
        log("SDP: no service records")
        return nil
    }
    log("SDP: \(services.count) services")
    var candidateChannel: BluetoothRFCOMMChannelID?
    for service in services {
        var channelID: BluetoothRFCOMMChannelID = 0
        guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { continue }
        guard let serviceClassElem = service.getAttributeDataElement(0x0001) else { continue }
        var uuids: [IOBluetoothSDPUUID] = []
        if let uuid = serviceClassElem.getUUIDValue() {
            uuids.append(uuid)
        } else if let elements = serviceClassElem.getArrayValue() {
            for elem in elements {
                if let sdpElem = elem as? IOBluetoothSDPDataElement, let uuid = sdpElem.getUUIDValue() {
                    uuids.append(uuid)
                }
            }
        }
        for uuid in uuids {
            let uuidHex = (uuid as Data).map { String(format: "%02X", $0) }.joined()
            log("SDP: ch\(channelID) UUID=\(uuidHex)")
            for gaiaUUID in knownGAIAUUIDs {
                if uuid.isEqual(to: gaiaUUID) {
                    log("SDP: ✓ GAIA match on ch\(channelID)")
                    return channelID
                }
            }
            let isExcluded = excludedUUIDs.contains { uuid.isEqual(to: $0) }
            if !isExcluded && candidateChannel == nil {
                candidateChannel = channelID
                log("SDP: ch\(channelID) unknown, candidate")
            }
        }
    }
    if let ch = candidateChannel {
        log("SDP: using candidate ch\(ch)")
        return ch
    }
    return nil
}

class Prober: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var connected = false
    var responses: [(vendor: UInt16, cmd: UInt16, respCmd: UInt16, payload: [UInt8])] = []
    var pendingCmd: UInt16 = 0
    var gotResponse = false
    var receiveBuffer = Data()

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            log("Channel opened (MTU=\(ch.getMTU()))")
            connected = true
        } else {
            log("Channel open FAILED: \(error)")
        }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        log("Channel closed")
        connected = false
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        let newData = Data(bytes: ptr, count: len)
        receiveBuffer.append(newData)

        // Parse GAIA packets from buffer (handles fragmentation)
        while receiveBuffer.count >= 8 {
            guard receiveBuffer[receiveBuffer.startIndex] == 0xFF,
                  receiveBuffer[receiveBuffer.startIndex + 1] == 0x03 else {
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                continue
            }

            let paramSize = Int(UInt16(receiveBuffer[receiveBuffer.startIndex + 2]) << 8 |
                                UInt16(receiveBuffer[receiveBuffer.startIndex + 3]))
            let totalSize = 8 + paramSize
            guard receiveBuffer.count >= totalSize else { break }

            let vendor = UInt16(receiveBuffer[receiveBuffer.startIndex + 4]) << 8 |
                         UInt16(receiveBuffer[receiveBuffer.startIndex + 5])
            let respCmd = UInt16(receiveBuffer[receiveBuffer.startIndex + 6]) << 8 |
                          UInt16(receiveBuffer[receiveBuffer.startIndex + 7])
            let payload = paramSize > 0 ? Array(receiveBuffer[(receiveBuffer.startIndex + 8)..<(receiveBuffer.startIndex + totalSize)]) : []

            receiveBuffer = Data(receiveBuffer.dropFirst(totalSize))

            let isError = respCmd & 0x0080 != 0
            if isError {
                let errPayHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                log("  ✗ vendor=0x\(String(format:"%04X",vendor)) err=0x\(String(format:"%04X",respCmd)) [\(errPayHex)]")
            } else {
                let payHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                log("  ✓ vendor=0x\(String(format:"%04X",vendor)) resp=0x\(String(format:"%04X",respCmd)) payload=[\(payHex)]")
                responses.append((vendor: vendor, cmd: pendingCmd, respCmd: respCmd, payload: payload))
            }
            gotResponse = true
        }
    }

    func send(_ data: Data) {
        guard let ch = channel, connected else { return }
        var bytes = [UInt8](data)
        ch.writeSync(&bytes, length: UInt16(bytes.count))
    }

    func probe(vendor: UInt16, cmdRange: ClosedRange<UInt16>, delay: TimeInterval = 0.3) {
        log("=== Probing vendor 0x\(String(format:"%04X",vendor)), commands 0x\(String(format:"%04X",cmdRange.lowerBound))..0x\(String(format:"%04X",cmdRange.upperBound)) ===")

        var idx = 0
        let cmds = Array(cmdRange)

        func next() {
            guard idx < cmds.count, connected else {
                log("=== Probe complete. \(responses.count) valid responses ===")
                return
            }
            let cmd = cmds[idx]
            pendingCmd = cmd
            gotResponse = false
            send(gaiaPacket(vendor: vendor, cmd: cmd))
            idx += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
        }
        next()
    }
}

// Also act as SDP query delegate
class SDPDelegate: NSObject {
    var device: IOBluetoothDevice?
    var completion: ((BluetoothRFCOMMChannelID?) -> Void)?

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        if status == kIOReturnSuccess {
            log("SDP query complete, re-scanning...")
            completion?(findGAIAChannel(device))
        } else {
            log("SDP query failed: \(status)")
            completion?(nil)
        }
    }
}

// Parse args
let args = CommandLine.arguments
let rangeArg = args.count > 1 ? args[1] : "0x2000-0x20FF"
let vendorArg: UInt16 = args.count > 2 ? UInt16(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x0495 : 0x0495

let parts = rangeArg.replacingOccurrences(of: "0x", with: "").split(separator: "-")
guard parts.count == 2,
      let lo = UInt16(parts[0], radix: 16),
      let hi = UInt16(parts[1], radix: 16) else {
    log("Usage: probe <startCmd-endCmd> [vendor]")
    exit(1)
}

log("Probe range: 0x\(String(format:"%04X",lo))-0x\(String(format:"%04X",hi)), vendor: 0x\(String(format:"%04X",vendorArg))")

let prober = Prober()
let sdpDel = SDPDelegate()
signal(SIGINT, SIG_DFL)
signal(SIGTERM, SIG_DFL)

let app = NSApplication.shared

func startProbe(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
    log("Opening RFCOMM ch\(channelID)...")
    var rfch: IOBluetoothRFCOMMChannel?
    let r = device.openRFCOMMChannelAsync(&rfch, withChannelID: channelID, delegate: prober)
    if r == kIOReturnSuccess, let c = rfch {
        prober.channel = c
    } else {
        log("Failed to open channel: \(r)")
        exit(1)
    }

    // Wait for connection then probe
    func waitAndProbe(_ n: Int) {
        if prober.connected {
            prober.probe(vendor: vendorArg, cmdRange: lo...hi, delay: 0.25)
            let totalTime = Double(hi - lo + 1) * 0.25 + 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + totalTime) {
                log("")
                log("=== RESULTS ===")
                for r in prober.responses {
                    let payHex = r.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                    log("  vendor=0x\(String(format:"%04X",r.vendor)) cmd=0x\(String(format:"%04X",r.cmd)) → resp=0x\(String(format:"%04X",r.respCmd)) [\(payHex)]")
                }
                if prober.responses.isEmpty {
                    log("  (no valid responses)")
                }
                prober.channel?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
            }
            return
        }
        if n > 40 { log("Connection timeout after 20s"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitAndProbe(n + 1) }
    }
    waitAndProbe(0)
}

DispatchQueue.main.async {
    guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
          let hdb = devices.first(where: {
              let n = ($0.name ?? "").lowercased()
              return n.contains("hdb") || n.contains("630") || n.contains("sennheiser")
          }) else {
        log("HDB 630 not found in paired devices")
        exit(1)
    }
    log("Found: \(hdb.name ?? "?"), connected=\(hdb.isConnected())")

    guard hdb.isConnected() else {
        log("Headphones not connected. Connect them in Bluetooth settings first.")
        exit(1)
    }

    // Try cached SDP first, then fresh query (same as BluetoothManager)
    if let channelID = findGAIAChannel(hdb) {
        log("Found GAIA on cached SDP ch\(channelID)")
        startProbe(device: hdb, channelID: channelID)
    } else {
        log("GAIA not in cached SDP, doing fresh query...")
        sdpDel.device = hdb
        sdpDel.completion = { channelID in
            if let ch = channelID {
                startProbe(device: hdb, channelID: ch)
            } else {
                log("GAIA service not found after SDP query")
                exit(1)
            }
        }
        hdb.performSDPQuery(sdpDel)
    }

    // Global timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { log("Global timeout"); exit(1) }
}

app.run()
