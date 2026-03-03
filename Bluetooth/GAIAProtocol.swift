import Foundation

// MARK: - GAIA v3 Protocol
//
// Wire format: [FF] [03] [paramSize_BE 2B] [vendorId_BE 2B] [cmdId_BE 2B] [payload...]
// paramSize = payload byte count (excludes vendor + cmd)
// Total packet = 8 + paramSize
// Response cmd = request cmd | 0x0100
// Error cmd = request cmd | 0x0180

enum GAIAProtocol {

    static let headerSize = 8

    // Standard Qualcomm GAIA RFCOMM service UUID
    static let serviceUUIDBytes: [UInt8] = [
        0x00, 0x00, 0x11, 0x07, 0xD1, 0x02, 0x11, 0xE1,
        0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5
    ]

    // HDB 630 GAIA service UUID (vendor-specific, found in SDP ServiceClassIDList)
    static let hdb630ServiceUUIDBytes: [UInt8] = [
        0xA2, 0x12, 0x9F, 0xF3, 0x08, 0x1B, 0x4C, 0x45,
        0x8A, 0xFE, 0x46, 0x9D, 0x9C, 0x48, 0x42, 0xEC
    ]

    // Vendor IDs
    static let vendorQualcomm: UInt16 = 0x001D
    static let vendorSennheiser: UInt16 = 0x0495

    // Notification registration: vendor-specific cmd 0x0007, payload=[featureID]
    static let cmdRegisterNotification: UInt16 = 0x0007

    // Sennheiser feature IDs for notification registration
    static let featureCore: UInt8 = 0
    static let featureDevice: UInt8 = 2
    static let featureBattery: UInt8 = 3
    static let featureGenericAudio: UInt8 = 4  // codec, sidetone, smart pause, comfort call
    static let featureUserEQ: UInt8 = 8        // EQ, bass boost
    static let featureVersions: UInt8 = 9
    static let featureDeviceManagement: UInt8 = 10  // paired devices, connections
    static let featureMMI: UInt8 = 11
    static let featureTransparentHearing: UInt8 = 12
    static let featureANC: UInt8 = 13

    // Commands (request direction) — all vendor: Sennheiser unless noted
    static let cmdGetSerial: UInt16 = 0x0003         // vendor: Qualcomm
    static let cmdGetAPIVersion: UInt16 = 0x0040     // vendor: Qualcomm

    static let cmdSetOnHeadDetection: UInt16 = 0x0400
    static let cmdGetOnHeadDetection: UInt16 = 0x0401

    static let cmdSetTimer: UInt16 = 0x0600           // payload=[timerID, seconds_BE_16] (timerID 0=auto power off)
    static let cmdGetTimer: UInt16 = 0x0601           // payload=[timerID], response=[timerID, seconds_BE_16]
    static let cmdGetChargingStatus: UInt16 = 0x0602  // 0=disconnected, 1=charging, 2=complete
    static let cmdGetBattery: UInt16 = 0x0603

    static let cmdGetCodec: UInt16 = 0x0800          // response: 0=SBC,1=AAC,2=aptX,5=aptX-HD,8=aptX-Adaptive,10=LC3
    static let cmdSetAudioMode: UInt16 = 0x0803     // payload=[0x00, mode(0-5)]
    static let cmdGetAudioMode: UInt16 = 0x0804
    static let cmdSetSidetone: UInt16 = 0x0805       // payload=[level 0-4] (0=off, 1-4=levels)
    static let cmdGetSidetone: UInt16 = 0x0806
    static let cmdGetVoiceLanguage: UInt16 = 0x0807
    static let cmdSetAutoCall: UInt16 = 0x080A       // payload=[0=off, 1=on]
    static let cmdGetAutoCall: UInt16 = 0x080B
    static let cmdSetSmartPause: UInt16 = 0x080C     // payload=[0=off, 1=on]
    static let cmdGetSmartPause: UInt16 = 0x080D
    static let cmdSetAutoPause: UInt16 = 0x1800       // payload=[0=keep playing, 1=stop music] when sidetone/transparency enabled
    static let cmdGetAutoPause: UInt16 = 0x1801
    static let cmdSetComfortCall: UInt16 = 0x0814    // payload=[0=off, 1=on]
    static let cmdGetComfortCall: UInt16 = 0x0815

    static let cmdGetEQConfig: UInt16 = 0x1000       // response=[bands, minGain_signed, maxGain_signed, byte3, byte4]
    static let cmdSetEQBand: UInt16 = 0x1001        // payload=[band(0-4), gain(int8, dB×10)]
    static let cmdGetEQ: UInt16 = 0x1002            // payload=[band 0-4], response=[gain(int8)]
    static let cmdSetBassBoost: UInt16 = 0x1008     // payload=[0=off, 1=on]
    static let cmdGetBassBoost: UInt16 = 0x1009

    // PEQ stage commands (userEq feature, 5 stages 0-4)
    static let cmdSetStageFrequency: UInt16 = 0x100A  // payload=[stage, freq_hi, freq_lo]
    static let cmdGetStageFrequency: UInt16 = 0x100B
    static let cmdSetStageQ: UInt16 = 0x100C          // payload=[stage, q_hi, q_lo] (raw = Q × 4096)
    static let cmdGetStageQ: UInt16 = 0x100D
    static let cmdSetStageFilterType: UInt16 = 0x100E // payload=[stage, type(0-14)]
    static let cmdGetStageFilterType: UInt16 = 0x100F
    static let cmdSetStageGain: UInt16 = 0x1010       // payload=[stage, gain_hi, gain_lo] (raw = dB × 10, signed)
    static let cmdGetStageGain: UInt16 = 0x1011
    static let cmdSetPreGain: UInt16 = 0x1012         // payload=[gain_hi, gain_lo] (raw = dB × 10, signed)
    static let cmdGetPreGain: UInt16 = 0x1013
    static let cmdGetHeadroom: UInt16 = 0x1014        // response=[headroom_hi, headroom_lo] (raw ÷ 10 = dB)

    static let cmdGetFirmwareVersion: UInt16 = 0x1202

    // Paired device list
    static let cmdGetPairedDeviceListSize: UInt16 = 0x1400  // response: UINT16 count
    static let cmdGetDeviceInfo: UInt16 = 0x1401            // payload=[index], response: [index, priority, connStatus, name...]
    static let cmdGetConnectionStatus: UInt16 = 0x1404      // payload=[index], response: [index, status], notification: 0x1484
    static let cmdGetOwnDeviceIndex: UInt16 = 0x1407        // response: UINT8 index
    static let cmdGetMaxBTConnections: UInt16 = 0x1409      // response: UINT8 max

    static let cmdSetCrossfeed: UInt16 = 0x2E00     // payload=[0=low, 1=high, 2=off]
    static let cmdGetCrossfeed: UInt16 = 0x2E01

    static let cmdSetANCMode: UInt16 = 0x1A00
    static let cmdGetANCMode: UInt16 = 0x1A01
    static let cmdSetTransparency: UInt16 = 0x1A02
    static let cmdGetTransparency: UInt16 = 0x1A03
    static let cmdSetANCStatus: UInt16 = 0x1A04
    static let cmdGetANCStatus: UInt16 = 0x1A05

    // Notification & response command IDs (received from headphones)
    static let notifANCMode: UInt16 = 0x1A81
    static let respANCMode: UInt16 = 0x1B01
    static let notifANCStatus: UInt16 = 0x1A85
    static let respANCStatus: UInt16 = 0x1B05
    static let notifTransparency: UInt16 = 0x1A83
    static let respTransparency: UInt16 = 0x1B03
    static let respBattery: UInt16 = 0x0703
    static let notifSidetone: UInt16 = 0x0886
    static let respSidetone: UInt16 = 0x0906
    static let notifAudioMode: UInt16 = 0x0884
    static let respSetAudioMode: UInt16 = 0x0903
    static let respAudioMode: UInt16 = 0x0904
    static let notifCodec: UInt16 = 0x0880
    static let respCodec: UInt16 = 0x0900
    static let notifCharging: UInt16 = 0x0682
    static let notifEQ: UInt16 = 0x1082
    static let respEQ: UInt16 = 0x1102
    static let respEQBand: UInt16 = 0x1101
    static let notifBassBoost: UInt16 = 0x1089
    static let respBassBoostSet: UInt16 = 0x1108
    static let respBassBoostGet: UInt16 = 0x1109
    static let notifBassBoostAlt: UInt16 = 0x1088
    static let notifStageFrequency: UInt16 = 0x108B
    static let notifStageQ: UInt16 = 0x108D
    static let notifStageFilterType: UInt16 = 0x108F
    static let notifStageGain: UInt16 = 0x1091
    static let respPreGain: UInt16 = 0x1113
    static let notifSmartPause: UInt16 = 0x088D
    static let notifComfortCall: UInt16 = 0x0895
    static let notifConnection: UInt16 = 0x1484
    static let notifCrossfeed: UInt16 = 0x2E81
    static let respCrossfeed: UInt16 = 0x2F01

    static let codecNames: [UInt8: String] = [
        0: "SBC", 1: "AAC", 2: "aptX", 3: "aptX LL",
        5: "aptX HD", 8: "aptX Adaptive", 9: "aptX Lossless", 10: "LC3",
        255: ""
    ]

    // MARK: - Build packet

    static func buildPacket(vendor: UInt16, command: UInt16, payload: [UInt8] = []) -> Data {
        var pkt: [UInt8] = [0xFF, 0x03]
        let paramSize = UInt16(payload.count)
        pkt.append(UInt8((paramSize >> 8) & 0xFF))
        pkt.append(UInt8(paramSize & 0xFF))
        pkt.append(UInt8((vendor >> 8) & 0xFF))
        pkt.append(UInt8(vendor & 0xFF))
        pkt.append(UInt8((command >> 8) & 0xFF))
        pkt.append(UInt8(command & 0xFF))
        pkt.append(contentsOf: payload)
        return Data(pkt)
    }

    // MARK: - Parse response

    struct Response {
        let vendorId: UInt16
        let commandId: UInt16
        let payload: Data

        var isError: Bool { commandId & 0x0080 != 0 }
    }

    static func parse(_ data: Data) -> (response: Response, consumed: Int)? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xFF, bytes[1] == 0x03 else { return nil }

        let paramSize = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        let totalLen = headerSize + paramSize
        guard data.count >= totalLen else { return nil }

        let vendorId = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let commandId = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let payload = Data(data[headerSize..<totalLen])

        return (Response(vendorId: vendorId, commandId: commandId, payload: payload), totalLen)
    }

    // MARK: - Command helpers

    static func responseCommandId(for requestCmd: UInt16) -> UInt16 {
        requestCmd | 0x0100
    }

    static func callbackKey(vendor: UInt16, responseCmd: UInt16) -> String {
        "\(vendor)_\(responseCmd)"
    }
}
