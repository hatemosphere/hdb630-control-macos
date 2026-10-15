import Foundation
import Combine

// MARK: - Headphone Controller

@MainActor
final class HeadphoneController: ObservableObject {
    let bluetooth: BluetoothManager

    @Published var deviceInfo = DeviceInfo()
    @Published var batteryLevel: Int = 0
    @Published var streamSampleRate: Int?
    @Published private(set) var highResolutionEnabled: Bool?
    @Published private(set) var changingHighResolution = false
    @Published private(set) var streamingStatistics: HeadphoneStreamingStatistics?
    @Published private(set) var usageStatistics: [GAIAStatistic] = []
    private var fetchingStatistics = false
    private var connectionGeneration = 0
    private var initializationTask: Task<Void, Never>?
    @Published var controlError: String?
    @Published var ancEnabled: Bool = false
    @Published var ancState = ANCState()
    @Published var transparencyLevel: Int = 0
    @Published var sidetoneLevel: Int = 0
    @Published var autoPauseEnabled: Bool = false
    @Published var onHeadDetectionEnabled: Bool = true
    @Published var physicalDeviceState: UInt8?
    @Published var smartPauseEnabled: Bool = false
    @Published var autoCallEnabled: Bool = false
    @Published var comfortCallEnabled: Bool = false
    @Published var autoPowerOffMinutes: Int = 0  // 0 = disabled
    @Published var eqPreset: EQPreset = .neutral
    @Published var eqGains: [Double] = [0, 0, 0, 0, 0]  // dB, range -6.0 to +6.0
    var eqLocked: Bool { Date() < eqLockUntil }
    private var eqLockUntil: Date = .distantPast
    private var eqDebounceTask: Task<Void, Never>?
    private var bandDebounceTasks: [Int: Task<Void, Never>] = [:]
    @Published var bassBoostEnabled: Bool = false
    @Published var audioMode: AudioMode = .userEq
    @Published var peqStages: [PEQStage] = Array(repeating: PEQStage(), count: 5)
    @Published var preGainDB: Double = 0.0
    @Published var headroomDB: Double = 0.0
    @Published var eqConfig = EQConfig()
    @Published var crossfeedLevel: Int = 2  // raw: 0=low, 1=high, 2=off
    @Published var pairedDevices: [PairedDevice] = []
    @Published var maxBTConnections: Int = 1
    @Published var ownDeviceIndex: Int = -1

    private var peqDebounceTasks: [String: Task<Void, Never>] = [:]
    private var preGainDebounceTask: Task<Void, Never>?
    private var transparencyDebounce: Task<Void, Never>?
    private var sidetoneDebounce: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
        setupNotificationHandler()
        setupConnectionObserver()
    }

    // MARK: - Lifecycle

    private func setupConnectionObserver() {
        bluetooth.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.connectionGeneration += 1
                self.cancelConnectionWork()
                if state == .connected {
                    self.initializationTask = Task { await self.fetchAll() }
                } else {
                    self.streamSampleRate = nil
                    self.highResolutionEnabled = nil
                    self.physicalDeviceState = nil
                    self.streamingStatistics = nil
                    self.usageStatistics = []
                }
            }
            .store(in: &cancellables)
    }

    private func cancelConnectionWork() {
        initializationTask?.cancel()
        initializationTask = nil
        eqDebounceTask?.cancel()
        eqDebounceTask = nil
        bandDebounceTasks.values.forEach { $0.cancel() }
        bandDebounceTasks.removeAll()
        peqDebounceTasks.values.forEach { $0.cancel() }
        peqDebounceTasks.removeAll()
        preGainDebounceTask?.cancel()
        preGainDebounceTask = nil
        transparencyDebounce?.cancel()
        transparencyDebounce = nil
        sidetoneDebounce?.cancel()
        sidetoneDebounce = nil
        eqLockUntil = .distantPast
    }

    /// Poll settings that lack push notifications.
    /// Everything else (ANC, transparency, codec, bass boost, podcast, connections)
    /// updates via push notifications registered in registerNotifications().
    func pollState() async {
        async let b: Void = fetchBattery()
        async let eq: Void = fetchEQ()
        async let cf: Void = fetchCrossfeed()
        async let st: Void = fetchSidetone()
        async let aup: Void = fetchAutoPause()
        async let oh: Void = fetchOnHeadDetection()
        async let ph: Void = fetchPhysicalDeviceState()
        async let sp: Void = fetchSmartPause()
        async let ac: Void = fetchAutoCall()
        async let cc: Void = fetchComfortCall()
        async let ap: Void = fetchAutoPowerOff()
        _ = await (b, eq, cf, st, aup, oh, ph, sp, ac, cc, ap)
    }

    // MARK: - Diagnostics Statistics

    /// Read the five streaming statistics only while Signal Lab is visible.
    func fetchStreamingStatistics() async {
        guard !fetchingStatistics, bluetooth.state == .connected else { return }
        fetchingStatistics = true
        defer { fetchingStatistics = false }
        let generation = connectionGeneration
        guard let response = await send(vendor: .qualcomm, command: 0x1801, payload: [0, 1, 0]),
              let page = GAIAStatisticsPage(response.payload, category: 1), !page.more,
              !Task.isCancelled, bluetooth.state == .connected, generation == connectionGeneration else {
            streamingStatistics = nil
            return
        }
        streamingStatistics = HeadphoneStreamingStatistics(records: page.records, sampledAt: Date())
    }

    /// The cumulative counters change slowly; Signal Lab requests them once a minute.
    func fetchUsageStatistics() async {
        guard !fetchingStatistics, bluetooth.state == .connected else { return }
        fetchingStatistics = true
        defer { fetchingStatistics = false }
        let generation = connectionGeneration
        var records: [GAIAStatistic] = []
        var last: UInt8 = 0
        for _ in 0..<32 {
            guard !Task.isCancelled, bluetooth.state == .connected, generation == connectionGeneration,
                  let response = await send(vendor: .qualcomm, command: 0x1801, payload: [1, 0, last]),
                  let page = GAIAStatisticsPage(response.payload, category: 256, after: last),
                  !Task.isCancelled, bluetooth.state == .connected, generation == connectionGeneration else {
                usageStatistics = []
                return
            }
            records += page.records
            if !page.more {
                usageStatistics = records
                return
            }
            last = page.records.last!.id // A continuation page must advance, checked by the parser.
        }
        usageStatistics = []
    }

    // MARK: - Notification Registration

    /// Register for push notifications so headphones notify us when settings change externally
    private func registerNotifications() async {
        // Only register feature IDs confirmed supported by HDB 630 (probed 2026-02-27)
        let sennheiserFeatures: [UInt8] = [
            GAIAProtocol.featureCore,               // 0
            GAIAProtocol.featureDevice,              // 2
            GAIAProtocol.featureBattery,             // 3
            GAIAProtocol.featureGenericAudio,        // 4 — codec, sidetone, smart pause, comfort call
            GAIAProtocol.featureUserEQ,              // 8 — EQ, bass boost
            GAIAProtocol.featureVersions,            // 9
            GAIAProtocol.featureDeviceManagement,    // 10 — paired devices, connections
            GAIAProtocol.featureMMI,                 // 11
            GAIAProtocol.featureTransparentHearing,  // 12
            GAIAProtocol.featureANC,                 // 13
        ]
        for feature in sennheiserFeatures {
            _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdRegisterNotification, payload: [feature])
        }
        // Qualcomm: only feature 0 (core) is supported
        _ = await send(vendor: .qualcomm, command: GAIAProtocol.cmdRegisterNotification, payload: [0])
    }

    // MARK: - Fetch All State

    func fetchAll() async {
        await registerNotifications()
        async let s: Void = fetchSerial()
        async let b: Void = fetchBattery()
        async let a: Void = fetchANCStatus()
        async let m: Void = fetchANCMode()
        async let t: Void = fetchTransparency()
        async let st: Void = fetchSidetone()
        async let c: Void = fetchCodec()
        async let sr: Void = fetchStreamSampleRate()
        async let hr: Void = fetchHighResolution()
        async let cs: Void = fetchChargingStatus()
        async let oh: Void = fetchOnHeadDetection()
        async let ph: Void = fetchPhysicalDeviceState()
        async let sp: Void = fetchSmartPause()
        async let ac: Void = fetchAutoCall()
        async let cc: Void = fetchComfortCall()
        async let ap: Void = fetchAutoPowerOff()
        async let fw: Void = fetchFirmwareVersion()
        async let eq: Void = fetchEQ()
        async let bb: Void = fetchBassBoost()
        async let cf: Void = fetchCrossfeed()
        async let aup: Void = fetchAutoPause()
        async let am: Void = fetchAudioMode()
        async let ec: Void = fetchEQConfig()
        async let dl: Void = fetchDeviceList()
        _ = await (s, b, a, m, t, st, c, sr, hr, cs, oh, ph, sp, ac, cc, ap, aup, fw, eq, bb, cf, am, ec, dl)
    }

    // MARK: - Wireless Resolution

    func fetchHighResolution() async {
        let generation = connectionGeneration
        guard let response = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetBluetoothCompatibility),
              generation == connectionGeneration, bluetooth.state == .connected else { return }
        switch Array(response.payload) {
        case [0]: highResolutionEnabled = true
        case [1]: highResolutionEnabled = false
        default: highResolutionEnabled = nil
        }
    }

    func setHighResolution(_ enabled: Bool) async {
        guard !changingHighResolution, highResolutionEnabled != nil,
              bluetooth.state == .connected else { return }
        changingHighResolution = true
        defer { changingHighResolution = false }
        let generation = connectionGeneration
        guard await writeSetting(GAIAProtocol.cmdSetBluetoothCompatibility, payload: [enabled ? 0 : 1]) else { return }
        await fetchHighResolution()
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        guard highResolutionEnabled == enabled else {
            controlError = "The headphones did not confirm the resolution setting. Try again."
            return
        }
        do {
            try await bluetooth.restartAndReconnect()
        } catch {
            controlError = "Resolution setting saved. Restart or reconnect the headphones to apply it: \(error.localizedDescription)"
        }
    }

    // MARK: - Serial

    func fetchSerial() async {
        guard let resp = await send(vendor: .qualcomm, command: GAIAProtocol.cmdGetSerial) else { return }
        if let str = String(data: resp.payload, encoding: .utf8) {
            deviceInfo.serial = str
        }
    }

    // MARK: - Battery

    func fetchBattery() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetBattery) else { return }
        if resp.payload.count >= 1 {
            batteryLevel = Int(resp.payload[0])
        }
    }

    // MARK: - ANC Status (global on/off)

    func fetchANCStatus() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetANCStatus) else { return }
        if resp.payload.count >= 1 {
            ancEnabled = resp.payload[0] == 0x01
        }
    }

    func setANCEnabled(_ enabled: Bool) async {
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await writeSetting(GAIAProtocol.cmdSetANCStatus, payload: payload)
        await fetchANCStatus()
    }

    var noiseControlMode: NoiseControlMode {
        guard ancEnabled else { return .off }
        return ancState.adaptive ? .adaptive : .custom
    }

    func setNoiseControlMode(_ mode: NoiseControlMode) async {
        let generation = connectionGeneration
        switch mode {
        case .off:
            await setANCEnabled(false)
        case .adaptive, .custom:
            if !ancEnabled { await setANCEnabled(true) }
            guard ancEnabled, !Task.isCancelled, generation == connectionGeneration else { return }
            await setAdaptive(mode == .adaptive)
        }
    }

    // MARK: - ANC Mode (anti-wind, comfort, adaptive)

    func fetchANCMode() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetANCMode) else { return }
        parseANCMode(resp.payload)
    }

    private func parseANCMode(_ data: Data) {
        guard data.count >= 6 else { return }
        let bytes = [UInt8](data)
        for index in stride(from: 0, through: 4, by: 2) {
            switch bytes[index] {
            case 1: ancState.antiWind = Int(bytes[index + 1]) // 0=off, 1=max, 2=auto
            case 2: ancState.comfort = bytes[index + 1] == 1
            case 3: ancState.adaptive = bytes[index + 1] == 1
            default: break
            }
        }
    }

    func setAntiWind(_ value: Int) async {
        guard (0...2).contains(value) else { return }
        _ = await writeSetting(GAIAProtocol.cmdSetANCMode, payload: [0x01, UInt8(value)])
        await fetchANCMode()
    }

    func setComfort(_ enabled: Bool) async {
        _ = await writeSetting(GAIAProtocol.cmdSetANCMode, payload: [0x02, enabled ? 0x01 : 0x00])
        await fetchANCMode()
    }

    func setAdaptive(_ enabled: Bool) async {
        _ = await writeSetting(GAIAProtocol.cmdSetANCMode, payload: [0x03, enabled ? 0x01 : 0x00])
        await fetchANCMode()
    }

    // MARK: - Transparency

    func fetchTransparency() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetTransparency) else { return }
        if resp.payload.count >= 1 {
            transparencyLevel = Int(resp.payload[0])
        }
    }

    func setTransparency(_ level: Int) {
        guard (0...100).contains(level) else { return }
        transparencyDebounce?.cancel()
        transparencyDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            _ = await self.writeSetting(GAIAProtocol.cmdSetTransparency, payload: [UInt8(level)])
            await self.fetchTransparency()
        }
    }

    // MARK: - Sidetone

    func fetchSidetone() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetSidetone) else { return }
        if resp.payload.count >= 1 {
            sidetoneLevel = Int(resp.payload[0])
        }
    }

    func setSidetone(_ level: Int) {
        guard (0...4).contains(level) else { return }
        sidetoneDebounce?.cancel()
        sidetoneDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            _ = await self.writeSetting(GAIAProtocol.cmdSetSidetone, payload: [UInt8(level)])
            await self.fetchSidetone()
        }
    }

    // MARK: - Auto-Pause (pause audio when sidetone/transparency enabled)

    func fetchAutoPause() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetAutoPause) else { return }
        if resp.payload.count >= 1 {
            autoPauseEnabled = resp.payload[0] == 0x01
        }
    }

    func setAutoPause(_ enabled: Bool) async {
        _ = await writeSetting(GAIAProtocol.cmdSetAutoPause, payload: [enabled ? 0x01 : 0x00])
        await fetchAutoPause()
    }

    // MARK: - Codec

    func fetchCodec() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetCodec) else { return }
        if resp.payload.count >= 1 {
            deviceInfo.codec = GAIAProtocol.codecNames[resp.payload[0]] ?? "Unknown (\(resp.payload[0]))"
        }
    }

    func fetchStreamSampleRate() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStreamSampleRate) else { return }
        parseStreamSampleRate(resp.payload)
    }

    private func parseStreamSampleRate(_ data: Data) {
        guard data.count >= 4 else { return }
        let rate = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        streamSampleRate = rate > 0 ? rate : nil
    }

    // MARK: - Charging Status

    func fetchChargingStatus() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetChargingStatus) else { return }
        if resp.payload.count >= 1 {
            deviceInfo.chargingStatus = ChargingStatus(rawValue: Int(resp.payload[0])) ?? .disconnected
        }
    }

    // MARK: - On-Head Detection

    func fetchOnHeadDetection() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetOnHeadDetection) else { return }
        if resp.payload.count >= 1 {
            onHeadDetectionEnabled = resp.payload[0] == 0x01
        }
    }

    func fetchPhysicalDeviceState() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetPhysicalDeviceState),
              let first = resp.payload.first else { return }
        physicalDeviceState = first
    }

    func setOnHeadDetection(_ enabled: Bool) async {
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await writeSetting(GAIAProtocol.cmdSetOnHeadDetection, payload: payload)
        await fetchOnHeadDetection()
        await fetchSmartPause()
        await fetchAutoCall()
        await fetchAutoPowerOff()
    }

    // MARK: - Smart Pause

    func fetchSmartPause() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetSmartPause) else { return }
        if resp.payload.count >= 1 {
            smartPauseEnabled = resp.payload[0] == 0x01
        }
    }

    func setSmartPause(_ enabled: Bool) async {
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await writeSetting(GAIAProtocol.cmdSetSmartPause, payload: payload)
        await fetchSmartPause()
    }

    // MARK: - Auto-Answer Calls

    func fetchAutoCall() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetAutoCall) else { return }
        if resp.payload.count >= 1 {
            autoCallEnabled = resp.payload[0] == 0x01
        }
    }

    func setAutoCall(_ enabled: Bool) async {
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await writeSetting(GAIAProtocol.cmdSetAutoCall, payload: payload)
        await fetchAutoCall()
    }

    // MARK: - Comfort Call

    func fetchComfortCall() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetComfortCall) else { return }
        if resp.payload.count >= 1 {
            comfortCallEnabled = resp.payload[0] == 0x01
        }
    }

    func setComfortCall(_ enabled: Bool) async {
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await writeSetting(GAIAProtocol.cmdSetComfortCall, payload: payload)
        await fetchComfortCall()
    }

    // MARK: - Auto Power Off

    func fetchAutoPowerOff() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetTimer, payload: [0x00]) else { return }
        if resp.payload.count >= 3 {
            let seconds = Int(UInt16(resp.payload[1]) << 8 | UInt16(resp.payload[2]))
            autoPowerOffMinutes = seconds / 60
        }
    }

    func setAutoPowerOff(minutes: Int) async {
        guard [0, 15, 30, 60].contains(minutes) else { return }
        let seconds = UInt16(minutes * 60)
        let payload: [UInt8] = [0x00, UInt8((seconds >> 8) & 0xFF), UInt8(seconds & 0xFF)]
        _ = await writeSetting(GAIAProtocol.cmdSetTimer, payload: payload)
        await fetchAutoPowerOff()
    }

    // MARK: - EQ

    func fetchEQ() async {
        guard !eqLocked else { return }
        let generation = connectionGeneration
        var gains = [Int8](repeating: 0, count: 5)
        for band in 0..<5 {
            guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetEQ,
                                        payload: [UInt8(band)]), let first = resp.payload.first,
                  !Task.isCancelled, generation == connectionGeneration else { return }
            gains[band] = Int8(bitPattern: first)
        }
        guard !eqLocked, !Task.isCancelled, generation == connectionGeneration else { return }
        eqGains = gains.map { Double($0) / 10.0 }
        eqPreset = EQPreset.matching(gains: gains)
    }

    /// Call synchronously before the async Task to prevent notification races.
    func lockEQ(preset: EQPreset) {
        guard preset != .custom else { return }
        eqPreset = preset
        eqGains = preset.gains.map { Double($0) / 10.0 }
        eqLockUntil = Date().addingTimeInterval(5)
    }

    func sendEQBands(_ preset: EQPreset) async {
        let gains = preset == .custom ? eqGains : preset.gains.map { Double($0) / 10.0 }
        await sendEQGains(gains)
    }

    @discardableResult
    private func sendEQGains(_ gains: [Double]) async -> Bool {
        let generation = connectionGeneration
        var succeeded = true
        for (band, gain) in gains.enumerated() {
            let raw = Int8(clamping: Int(round(gain * 10)))
            let payload: [UInt8] = [UInt8(band), UInt8(bitPattern: raw)]
            if !(await writeSetting(GAIAProtocol.cmdSetEQBand, payload: payload)) {
                succeeded = false
            }
            guard !Task.isCancelled, generation == connectionGeneration else { return false }
        }
        eqLockUntil = succeeded ? Date().addingTimeInterval(1) : .distantPast
        if !succeeded {
            controlError = "One or more EQ bands could not be applied."
            await fetchEQ()
        }
        return succeeded
    }

    func setEQBand(_ band: Int, gain: Double) {
        guard band >= 0, band < 5 else { return }
        eqGains[band] = gain
        eqPreset = .custom
        eqLockUntil = Date().addingTimeInterval(2)

        bandDebounceTasks[band]?.cancel()
        bandDebounceTasks[band] = Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }
            let raw = Int8(clamping: Int(round(gain * 10)))
            let succeeded = await writeSetting(GAIAProtocol.cmdSetEQBand,
                                               payload: [UInt8(band), UInt8(bitPattern: raw)])
            guard !Task.isCancelled else { return }
            eqLockUntil = succeeded ? Date().addingTimeInterval(1) : .distantPast
            if !succeeded { await fetchEQ() }
        }
    }

    // MARK: - EQ Config

    func fetchEQConfig() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetEQConfig) else { return }
        if resp.payload.count >= 3 {
            eqConfig.bands = Int(resp.payload[0])
            eqConfig.minGainDB = Double(Int8(bitPattern: resp.payload[1])) / 10.0
            eqConfig.maxGainDB = Double(Int8(bitPattern: resp.payload[2])) / 10.0
        }
    }

    // MARK: - Bass Boost

    func fetchBassBoost() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetBassBoost) else { return }
        if resp.payload.count >= 1 {
            bassBoostEnabled = resp.payload[0] == 0x01
        }
    }

    func setBassBoost(_ enabled: Bool) async {
        _ = await writeSetting(GAIAProtocol.cmdSetBassBoost, payload: [enabled ? 0x01 : 0x00])
        await fetchBassBoost()
    }

    // MARK: - Audio Mode

    func fetchAudioMode() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetAudioMode) else { return }
        if resp.payload.count >= 2 {
            audioMode = AudioMode(rawValue: Int(resp.payload[1])) ?? .off
        }
        if audioMode == .parametricEq {
            await fetchPEQ()
        }
    }

    func setAudioMode(_ mode: AudioMode) async {
        let generation = connectionGeneration
        let prev = audioMode
        guard await writeSetting(GAIAProtocol.cmdSetAudioMode, payload: [0x00, UInt8(mode.rawValue)]) else {
            await fetchAudioMode()
            return
        }
        audioMode = mode

        switch mode {
        case .userEq where prev != .userEq:
            // Re-apply graphic EQ: gains → bass boost (sound zone apply order)
            eqLockUntil = Date().addingTimeInterval(5)
            let gainsApplied = await sendEQGains(eqGains)
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            await setBassBoost(bassBoostEnabled)
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            if !gainsApplied { controlError = "One or more EQ bands could not be applied." }
        default:
            break
        }
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        await fetchAudioMode()
    }

    // MARK: - Parametric EQ

    func fetchPEQ() async {
        let generation = connectionGeneration
        async let pg: Void = fetchPreGain()
        async let hr: Void = fetchHeadroom()
        _ = await (pg, hr)
        guard !Task.isCancelled, generation == connectionGeneration else { return }

        for stage in 0..<5 {
            let s = UInt8(stage)
            async let f = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageFrequency, payload: [s])
            async let q = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageQ, payload: [s])
            async let g = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageGain, payload: [s])
            async let t = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageFilterType, payload: [s])
            let (fResp, qResp, gResp, tResp) = await (f, q, g, t)
            guard !Task.isCancelled, generation == connectionGeneration else { return }

            if let r = fResp, r.payload.count >= 3 {
                peqStages[stage].frequency = Int(UInt16(r.payload[1]) << 8 | UInt16(r.payload[2]))
            }
            if let r = qResp, r.payload.count >= 3 {
                let raw = UInt16(r.payload[1]) << 8 | UInt16(r.payload[2])
                peqStages[stage].q = Double(raw) / 4096.0
            }
            if let r = gResp, r.payload.count >= 3 {
                let raw = Int16(bitPattern: UInt16(r.payload[1]) << 8 | UInt16(r.payload[2]))
                peqStages[stage].gain = Double(raw) / 10.0
            }
            if let r = tResp, r.payload.count >= 2 {
                peqStages[stage].filterType = PEQFilterType(rawValue: Int(r.payload[1])) ?? .bypass
            }
        }
    }

    private func fetchPreGain() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetPreGain) else { return }
        if resp.payload.count >= 2 {
            let raw = Int16(bitPattern: UInt16(resp.payload[0]) << 8 | UInt16(resp.payload[1]))
            preGainDB = Double(raw) / 10.0
        }
    }

    private func fetchHeadroom() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetHeadroom) else { return }
        if resp.payload.count >= 2 {
            let raw = UInt16(resp.payload[0]) << 8 | UInt16(resp.payload[1])
            headroomDB = Double(raw) / 10.0
        }
    }

    func setPEQFrequency(_ stage: Int, hz: Int) {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].frequency = hz
        let raw = UInt16(clamping: hz)
        debouncePEQ(key: "freq\(stage)") {
            let succeeded = await self.writeSetting(GAIAProtocol.cmdSetStageFrequency,
                                                    payload: [UInt8(stage), UInt8(raw >> 8), UInt8(raw & 0xFF)])
            if !succeeded { await self.fetchPEQ() }
        }
    }

    func setPEQQ(_ stage: Int, q: Double) {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].q = q
        let raw = UInt16(clamping: Int(round(q * 4096.0)))
        debouncePEQ(key: "q\(stage)") {
            let succeeded = await self.writeSetting(GAIAProtocol.cmdSetStageQ,
                                                    payload: [UInt8(stage), UInt8(raw >> 8), UInt8(raw & 0xFF)])
            if !succeeded { await self.fetchPEQ() }
        }
    }

    func setPEQGain(_ stage: Int, db: Double) {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].gain = db
        let raw = Int16(clamping: Int(round(db * 10.0)))
        let unsigned = UInt16(bitPattern: raw)
        debouncePEQ(key: "gain\(stage)") {
            let succeeded = await self.writeSetting(GAIAProtocol.cmdSetStageGain,
                                                    payload: [UInt8(stage), UInt8(unsigned >> 8), UInt8(unsigned & 0xFF)])
            if !succeeded { await self.fetchPEQ() }
        }
    }

    func setPEQFilterType(_ stage: Int, type: PEQFilterType) async {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].filterType = type
        let succeeded = await writeSetting(GAIAProtocol.cmdSetStageFilterType,
                                           payload: [UInt8(stage), UInt8(type.rawValue)])
        if !succeeded { await fetchPEQ() }
    }

    func setPreGain(_ db: Double) {
        preGainDB = db
        let raw = Int16(clamping: Int(round(db * 10.0)))
        let unsigned = UInt16(bitPattern: raw)
        preGainDebounceTask?.cancel()
        preGainDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let succeeded = await writeSetting(GAIAProtocol.cmdSetPreGain,
                                               payload: [UInt8(unsigned >> 8), UInt8(unsigned & 0xFF)])
            if !succeeded { await fetchPreGain() }
        }
    }

    private func debouncePEQ(key: String, action: @escaping @Sendable () async -> Void) {
        peqDebounceTasks[key]?.cancel()
        peqDebounceTasks[key] = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    // MARK: - Crossfeed

    func fetchCrossfeed() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetCrossfeed) else { return }
        if resp.payload.count >= 1 {
            crossfeedLevel = Int(resp.payload[0])
        }
    }

    func setCrossfeed(_ level: Int) async {
        guard (0...2).contains(level) else { return }
        _ = await writeSetting(GAIAProtocol.cmdSetCrossfeed, payload: [UInt8(level)])
        await fetchCrossfeed()
    }

    // MARK: - Paired Device List

    func fetchDeviceList() async {
        let generation = connectionGeneration
        // Fetch max connections and own index in parallel
        async let mc: Void = fetchMaxBTConnections()
        async let oi: Void = fetchOwnDeviceIndex()
        _ = await (mc, oi)
        guard !Task.isCancelled, generation == connectionGeneration else { return }

        // Get list size
        guard let sizeResp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetPairedDeviceListSize),
              !Task.isCancelled, generation == connectionGeneration else { return }
        let count: Int
        if sizeResp.payload.count >= 2 {
            count = Int(UInt16(sizeResp.payload[0]) << 8 | UInt16(sizeResp.payload[1]))
        } else {
            return
        }
        guard count <= Int(UInt8.max) + 1 else {
            controlError = "The headphones reported an invalid paired-device count (\(count))."
            return
        }

        // Fetch info for each device
        var devices: [PairedDevice] = []
        for i in 0..<count {
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetDeviceInfo, payload: [UInt8(i)]) else { continue }
            if resp.payload.count >= 3 {
                let bytes = [UInt8](resp.payload)
                let index = Int(bytes[0])
                guard index != 0xFF else { continue }  // empty slot
                let priority = Int(bytes[1])
                let connStatus = Int(bytes[2])
                var name = ""
                if resp.payload.count > 3 {
                    name = String(data: resp.payload[3...], encoding: .utf8)?
                        .replacingOccurrences(of: "\0", with: "") ?? ""
                }
                devices.append(PairedDevice(
                    index: index,
                    name: name,
                    priority: priority,
                    isConnected: connStatus == 1
                ))
            }
        }
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        pairedDevices = devices
    }

    private func fetchMaxBTConnections() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetMaxBTConnections) else { return }
        if resp.payload.count >= 1 {
            maxBTConnections = Int(resp.payload[0])
        }
    }

    private func fetchOwnDeviceIndex() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetOwnDeviceIndex) else { return }
        if resp.payload.count >= 1 {
            ownDeviceIndex = Int(resp.payload[0])
        }
    }

    // MARK: - Firmware Version

    func fetchFirmwareVersion() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetFirmwareVersion) else { return }
        if resp.payload.count >= 3 {
            let bytes = [UInt8](resp.payload)
            deviceInfo.firmwareVersion = "\(bytes[0]).\(bytes[1]).\(bytes[2])"
        }
    }

    // MARK: - Notification Handler

    private func setupNotificationHandler() {
        bluetooth.notificationHandler = { [weak self] response in
            self?.handleNotification(response)
        }
    }

    private func handleNotification(_ response: GAIAProtocol.Response) {
        guard bluetooth.state == .connected else { return }
        NSLog("[HP] Notification: vendor=0x%04X cmd=0x%04X payload=%d bytes",
              response.vendorId, response.commandId, response.payload.count)

        guard response.vendorId == GAIAProtocol.vendorSennheiser else { return }

        switch response.commandId {
        case GAIAProtocol.respANCMode, GAIAProtocol.notifANCMode:
            parseANCMode(response.payload)
        case GAIAProtocol.respANCStatus, GAIAProtocol.notifANCStatus:
            if response.payload.count >= 1 { ancEnabled = response.payload[0] == 0x01 }
        case GAIAProtocol.respTransparency, GAIAProtocol.notifTransparency:
            if response.payload.count >= 1 { transparencyLevel = Int(response.payload[0]) }
        case GAIAProtocol.respBattery:
            if response.payload.count >= 1 { batteryLevel = Int(response.payload[0]) }
        case GAIAProtocol.respSidetone, GAIAProtocol.notifSidetone:
            if response.payload.count >= 1 { sidetoneLevel = Int(response.payload[0]) }
        case GAIAProtocol.respAudioMode, GAIAProtocol.notifAudioMode, GAIAProtocol.respSetAudioMode:
            if response.payload.count >= 2 {
                audioMode = AudioMode(rawValue: Int(response.payload[1])) ?? .off
            } else if response.payload.count >= 1 {
                audioMode = AudioMode(rawValue: Int(response.payload[0])) ?? .off
            }
        case GAIAProtocol.notifCodec, GAIAProtocol.respCodec:
            if response.payload.count >= 1 {
                deviceInfo.codec = GAIAProtocol.codecNames[response.payload[0]] ?? "Unknown"
            }
        case GAIAProtocol.notifStreamSampleRate:
            parseStreamSampleRate(response.payload)
        case GAIAProtocol.notifCharging:
            if response.payload.count >= 1 {
                deviceInfo.chargingStatus = ChargingStatus(rawValue: Int(response.payload[0])) ?? .disconnected
            }
        case GAIAProtocol.notifPhysicalDeviceState:
            physicalDeviceState = response.payload.first
        case GAIAProtocol.notifEQ:
            if !eqLocked, response.payload.count >= 5 {
                let gains = (0..<5).map { Int8(bitPattern: response.payload[$0]) }
                eqDebounceTask?.cancel()
                eqDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, !eqLocked else { return }
                    eqGains = gains.map { Double($0) / 10.0 }
                    eqPreset = EQPreset.matching(gains: gains)
                }
            }
        case GAIAProtocol.respEQBand:
            break // ACK for our own SetEQBand, ignore
        case GAIAProtocol.respBassBoostSet, GAIAProtocol.respBassBoostGet,
             GAIAProtocol.notifBassBoostAlt, GAIAProtocol.notifBassBoost:
            if response.payload.count >= 1 { bassBoostEnabled = response.payload[0] == 0x01 }
        case GAIAProtocol.notifSmartPause:
            if response.payload.count >= 1 { smartPauseEnabled = response.payload[0] == 0x01 }
        case GAIAProtocol.notifComfortCall:
            if response.payload.count >= 1 { comfortCallEnabled = response.payload[0] == 0x01 }
        case GAIAProtocol.notifConnection:
            if response.payload.count >= 2 {
                let idx = Int(response.payload[0])
                let connected = response.payload[1] == 1
                if let i = pairedDevices.firstIndex(where: { $0.index == idx }) {
                    pairedDevices[i].isConnected = connected
                } else {
                    Task { await fetchDeviceList() }
                }
            }
        case GAIAProtocol.respCrossfeed, GAIAProtocol.notifCrossfeed:
            if response.payload.count >= 1 { crossfeedLevel = Int(response.payload[0]) }
        case GAIAProtocol.notifStageFrequency:
            let bytes = [UInt8](response.payload)
            for offset in stride(from: 0, to: bytes.count - bytes.count % 3, by: 3) {
                let stage = Int(bytes[offset])
                guard stage < 5 else { continue }
                peqStages[stage].frequency = Int(UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2]))
            }
        case GAIAProtocol.notifStageQ:
            let bytes = [UInt8](response.payload)
            for offset in stride(from: 0, to: bytes.count - bytes.count % 3, by: 3) {
                let stage = Int(bytes[offset])
                guard stage < 5 else { continue }
                let raw = UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2])
                peqStages[stage].q = Double(raw) / 4096.0
            }
        case GAIAProtocol.notifStageGain:
            let bytes = [UInt8](response.payload)
            for offset in stride(from: 0, to: bytes.count - bytes.count % 3, by: 3) {
                let stage = Int(bytes[offset])
                guard stage < 5 else { continue }
                let raw = Int16(bitPattern: UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset + 2]))
                peqStages[stage].gain = Double(raw) / 10.0
            }
        case GAIAProtocol.notifStageFilterType:
            let bytes = [UInt8](response.payload)
            for offset in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
                let stage = Int(bytes[offset])
                guard stage < 5 else { continue }
                peqStages[stage].filterType = PEQFilterType(rawValue: Int(bytes[offset + 1])) ?? .bypass
            }
        case GAIAProtocol.respPreGain, GAIAProtocol.notifPreGain:
            if response.payload.count >= 2 {
                let raw = Int16(bitPattern: UInt16(response.payload[0]) << 8 | UInt16(response.payload[1]))
                preGainDB = Double(raw) / 10.0
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func writeSetting(_ command: UInt16, payload: [UInt8]) async -> Bool {
        guard !Task.isCancelled, bluetooth.state == .connected else { return false }
        let generation = connectionGeneration
        do {
            _ = try await bluetooth.sendCommand(vendor: GAIAProtocol.vendorSennheiser,
                                                command: command, payload: payload)
            guard !Task.isCancelled, generation == connectionGeneration,
                  bluetooth.state == .connected else { return false }
            controlError = nil
            return true
        } catch {
            guard !Task.isCancelled, generation == connectionGeneration,
                  bluetooth.state == .connected else { return false }
            controlError = error.localizedDescription
            NSLog("[HP] Write 0x%04X failed: %@", command, error.localizedDescription)
            return false
        }
    }

    private func send(vendor: VendorID, command: UInt16, payload: [UInt8] = []) async -> GAIAProtocol.Response? {
        guard !Task.isCancelled, bluetooth.state == .connected else { return nil }
        let generation = connectionGeneration
        let vendorValue: UInt16 = (vendor == .qualcomm) ? GAIAProtocol.vendorQualcomm : GAIAProtocol.vendorSennheiser
        do {
            let response = try await bluetooth.sendCommand(vendor: vendorValue, command: command, payload: payload)
            guard !Task.isCancelled, generation == connectionGeneration,
                  bluetooth.state == .connected else { return nil }
            return response
        } catch {
            guard !Task.isCancelled, generation == connectionGeneration,
                  bluetooth.state == .connected else { return nil }
            NSLog("[HP] Command 0x%04X failed: %@", command, error.localizedDescription)
            return nil
        }
    }

    private enum VendorID {
        case qualcomm, sennheiser
    }
}
