import Foundation

// GAIA vendor 0x001D, statistics feature. See docs/08-statistics.md for evidence.
struct GAIAStatistic: Identifiable {
    let id: UInt8
    let flags: UInt8
    let bytes: [UInt8]

    var unsignedValue: UInt32? {
        guard flags == 0, (1...4).contains(bytes.count) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func unsignedValue(length: Int) -> UInt32? {
        bytes.count == length ? unsignedValue : nil
    }

    var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

struct GAIAStatisticsPage {
    let more: Bool
    let records: [GAIAStatistic]

    // Reject truncated records, wrong categories and non-progressing pagination.
    init?(_ payload: Data, category: UInt16, after lastID: UInt8 = 0) {
        let bytes = Array(payload)
        guard bytes.count >= 3, bytes[0] <= 1,
              UInt16(bytes[1]) << 8 | UInt16(bytes[2]) == category else { return nil }
        var records: [GAIAStatistic] = []
        var offset = 3
        var previous = lastID
        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { return nil }
            let id = bytes[offset], flags = bytes[offset + 1], length = Int(bytes[offset + 2])
            offset += 3
            guard id > previous, offset + length <= bytes.count else { return nil }
            records.append(GAIAStatistic(id: id, flags: flags, bytes: Array(bytes[offset..<(offset + length)])))
            offset += length
            previous = id
        }
        guard bytes[0] == 0 || (!records.isEmpty && previous < 255) else { return nil }
        self.more = bytes[0] == 1
        self.records = records
    }
}

struct HeadphoneStreamingStatistics {
    let records: [GAIAStatistic]
    let sampledAt: Date

    private func value(_ id: UInt8, length: Int) -> UInt32? {
        records.first { $0.id == id }?.unsignedValue(length: length)
    }

    var codec: String? {
        guard let value = value(1, length: 1) else { return nil }
        // Statistics IDs differ from the Sennheiser 0x0800 codec enum.
        return [1: "SBC", 2: "AAC", 3: "aptX", 4: "aptX HD", 5: "aptX Adaptive"][value]
            ?? "Unknown (\(value))"
    }
    var lossless: Bool? { value(2, length: 1).map { $0 != 0 } }
    var bitrate: UInt32? { value(3, length: 4) }
    var primaryRSSI: Int? { value(4, length: 2).map { Int(Int16(bitPattern: UInt16($0))) } }
    var primaryLinkQuality: Double? { value(5, length: 2).map { Double($0) / 65535 * 100 } }
}

// MARK: - Connection State

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case error(String)
}

// MARK: - Device Models

struct ANCState: Equatable {
    var antiWind: Int = 0    // 0=off, 1=max, 2=auto
    var comfort: Bool = false
    var adaptive: Bool = false
}

enum NoiseControlMode: Int, CaseIterable {
    case off
    case adaptive
    case custom

    var title: String {
        switch self {
        case .off: "Off"
        case .adaptive: "Adaptive"
        case .custom: "Manual"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Noise cancellation is off."
        case .adaptive: "The headphones adjust cancellation as background noise changes."
        case .custom: "Use the manual ANC and transparency balance below."
        }
    }
}

struct DeviceInfo: Equatable {
    var name: String = ""
    var serial: String = ""
    var firmwareVersion: String = ""
    var codec: String = ""
    var chargingStatus: ChargingStatus = .disconnected
}

enum EQPreset: String, Identifiable {
    case neutral = "Neutral"
    case rock = "Rock"
    case pop = "Pop"
    case dance = "Dance"
    case hipHop = "Hip-Hop"
    case classical = "Classical"
    case movie = "Movie"
    case jazz = "Jazz"
    case custom = "Custom"

    var id: String { rawValue }

    static let builtIn: [EQPreset] = [.neutral, .rock, .pop, .dance, .hipHop, .classical, .movie, .jazz]

    // Gains in dB × 10 (signed int8). Bands: 50Hz, 250Hz, 800Hz, 3kHz, 8kHz
    var gains: [Int8] {
        switch self {
        case .neutral:   return [0, 0, 0, 0, 0]
        case .rock:      return [0, 20, 25, 15, -20]
        case .pop:       return [0, -25, 0, 25, 0]
        case .dance:     return [35, 20, -15, 15, 30]
        case .hipHop:    return [30, 15, -15, 0, -15]
        case .classical: return [-20, -15, 0, 35, 40]
        case .movie:     return [0, 0, 20, 20, -20]
        case .jazz:      return [-32, 0, 22, 22, 0]
        case .custom:    return [0, 0, 0, 0, 0] // placeholder, actual gains tracked separately
        }
    }

    static func matching(gains: [Int8]) -> EQPreset {
        builtIn.first { $0.gains == gains } ?? .custom
    }
}

enum ChargingStatus: Int, Equatable {
    case disconnected = 0
    case charging = 1
    case complete = 2

    var label: String {
        switch self {
        case .disconnected: return ""
        case .charging: return "Charging"
        case .complete: return "Charged"
        }
    }
}

enum AudioMode: Int, CaseIterable, Identifiable {
    case off = 0
    case userEq = 1
    case podcastMode = 2
    case personalizedSound = 3
    case parametricEq = 4
    case hearingEnhancement = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .userEq: return "EQ"
        case .podcastMode: return "Podcast"
        case .personalizedSound: return "Personalized"
        case .parametricEq: return "PEQ"
        case .hearingEnhancement: return "Hearing"
        }
    }

    /// Modes the user can select in the app
    static let selectable: [AudioMode] = [.off, .userEq, .podcastMode, .parametricEq]
}

enum PEQFilterType: Int, CaseIterable, Identifiable {
    case gain = 0
    case lowPassFirstOrder = 1
    case highPassFirstOrder = 2
    case allPassFirstOrder = 3
    case lowShelfFirstOrder = 4
    case highShelfFirstOrder = 5
    case tiltFirstOrder = 6
    case lowPassSecondOrder = 7
    case highPassSecondOrder = 8
    case allPassSecondOrder = 9
    case highShelfSecondOrder = 10
    case lowShelfSecondOrder = 11
    case tiltSecondOrder = 12
    case peq = 13
    case bypass = 14

    var id: Int { rawValue }

    /// Filters Sennheiser's app offers for HDB 630; the rest of the firmware enum is untested.
    static let selectable: [PEQFilterType] = [.peq, .lowShelfSecondOrder, .highShelfSecondOrder, .bypass]

    /// Q limits from the HDB 630 PEQ config (q_min, q_max, high_low_shelf_q_max).
    var qRange: ClosedRange<Double> {
        switch self {
        case .lowShelfFirstOrder, .highShelfFirstOrder, .lowShelfSecondOrder, .highShelfSecondOrder: 0.25...0.71
        default: 0.25...8
        }
    }

    var label: String {
        switch self {
        case .gain: return "Gain"
        case .lowPassFirstOrder: return "LP 1st"
        case .highPassFirstOrder: return "HP 1st"
        case .allPassFirstOrder: return "AP 1st"
        case .lowShelfFirstOrder: return "LS 1st"
        case .highShelfFirstOrder: return "HS 1st"
        case .tiltFirstOrder: return "Tilt 1st"
        case .lowPassSecondOrder: return "LP 2nd"
        case .highPassSecondOrder: return "HP 2nd"
        case .allPassSecondOrder: return "AP 2nd"
        case .highShelfSecondOrder: return "HS 2nd"
        case .lowShelfSecondOrder: return "LS 2nd"
        case .tiltSecondOrder: return "Tilt 2nd"
        case .peq: return "Bell"
        case .bypass: return "Bypass"
        }
    }
}

struct PEQStage: Equatable {
    var frequency: Int = 1000       // Hz (20–20000)
    var q: Double = 0.707           // Q factor (raw ÷ 4096)
    var gain: Double = 0.0          // dB (raw ÷ 10, signed)
    var filterType: PEQFilterType = .bypass
}

struct EQConfig: Equatable {
    var bands: Int = 5
    var minGainDB: Double = -6.0    // dB (signed byte ÷ 10)
    var maxGainDB: Double = 6.0     // dB (signed byte ÷ 10)
    static let preGainRange: ClosedRange<Double> = -12...0 // min_master_gain; pre-gain only cuts
}

enum PairedDeviceAction {
    case connect, disconnect, remove
}

struct PairedDevice: Identifiable, Equatable {
    let index: Int
    var name: String
    var priority: Int
    var isConnected: Bool

    var id: Int { index }
}
