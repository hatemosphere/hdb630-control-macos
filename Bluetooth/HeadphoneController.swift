import Foundation
import Combine

// MARK: - Headphone Controller

@MainActor
final class HeadphoneController: ObservableObject {
    let bluetooth: BluetoothManager

    @Published var deviceInfo = DeviceInfo()
    @Published var batteryLevel: Int = 0
    @Published var ancEnabled: Bool = false
    @Published var ancState = ANCState()
    @Published var transparencyLevel: Int = 0
    @Published var sidetoneLevel: Int = 0
    @Published var autoPauseEnabled: Bool = false
    @Published var onHeadDetectionEnabled: Bool = true
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
    private var transparencyDebounce: DispatchWorkItem?
    private var sidetoneDebounce: DispatchWorkItem?
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
                if state == .connected {
                    Task { await self.fetchAll() }
                }
            }
            .store(in: &cancellables)
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
        async let sp: Void = fetchSmartPause()
        async let ac: Void = fetchAutoCall()
        async let cc: Void = fetchComfortCall()
        async let ap: Void = fetchAutoPowerOff()
        _ = await (b, eq, cf, st, aup, oh, sp, ac, cc, ap)
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
        async let cs: Void = fetchChargingStatus()
        async let oh: Void = fetchOnHeadDetection()
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
        _ = await (s, b, a, m, t, st, c, cs, oh, sp, ac, cc, ap, aup, fw, eq, bb, cf, am, ec, dl)
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
        ancEnabled = enabled
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetANCStatus, payload: payload)
    }

    // MARK: - ANC Mode (anti-wind, comfort, adaptive)

    func fetchANCMode() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetANCMode) else { return }
        parseANCMode(resp.payload)
    }

    private func parseANCMode(_ data: Data) {
        guard data.count >= 6 else { return }
        let bytes = [UInt8](data)
        // [mode1, state1, mode2, state2, mode3, state3]
        // mode 1=anti-wind, 2=comfort, 3=adaptive
        ancState.antiWind = Int(bytes[1])        // 0=off, 1=on, 2=auto
        ancState.comfort = bytes[3] == 1
        ancState.adaptive = bytes[5] == 1
    }

    func setAntiWind(_ value: Int) async {
        ancState.antiWind = value
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetANCMode, payload: [0x01, UInt8(value)])
    }

    func setComfort(_ enabled: Bool) async {
        ancState.comfort = enabled
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetANCMode, payload: [0x02, enabled ? 0x01 : 0x00])
    }

    func setAdaptive(_ enabled: Bool) async {
        ancState.adaptive = enabled
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetANCMode, payload: [0x03, enabled ? 0x01 : 0x00])
    }

    // MARK: - Transparency

    func fetchTransparency() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetTransparency) else { return }
        if resp.payload.count >= 1 {
            transparencyLevel = Int(resp.payload[0])
        }
    }

    func setTransparency(_ level: Int) {
        transparencyDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let payload: [UInt8] = [UInt8(level)]
                _ = await self.send(vendor: .sennheiser, command: GAIAProtocol.cmdSetTransparency, payload: payload)
            }
        }
        transparencyDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Sidetone

    func fetchSidetone() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetSidetone) else { return }
        if resp.payload.count >= 1 {
            sidetoneLevel = Int(resp.payload[0])
        }
    }

    func setSidetone(_ level: Int) {
        sidetoneDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let payload: [UInt8] = [UInt8(level)]
                _ = await self.send(vendor: .sennheiser, command: GAIAProtocol.cmdSetSidetone, payload: payload)
            }
        }
        sidetoneDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Auto-Pause (pause audio when sidetone/transparency enabled)

    func fetchAutoPause() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetAutoPause) else { return }
        if resp.payload.count >= 1 {
            autoPauseEnabled = resp.payload[0] == 0x01
        }
    }

    func setAutoPause(_ enabled: Bool) async {
        autoPauseEnabled = enabled
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetAutoPause, payload: [enabled ? 0x01 : 0x00])
    }

    // MARK: - Codec

    func fetchCodec() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetCodec) else { return }
        if resp.payload.count >= 1 {
            deviceInfo.codec = GAIAProtocol.codecNames[resp.payload[0]] ?? "Unknown (\(resp.payload[0]))"
        }
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

    func setOnHeadDetection(_ enabled: Bool) async {
        onHeadDetectionEnabled = enabled
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetOnHeadDetection, payload: payload)
    }

    // MARK: - Smart Pause

    func fetchSmartPause() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetSmartPause) else { return }
        if resp.payload.count >= 1 {
            smartPauseEnabled = resp.payload[0] == 0x01
        }
    }

    func setSmartPause(_ enabled: Bool) async {
        smartPauseEnabled = enabled
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetSmartPause, payload: payload)
    }

    // MARK: - Auto-Answer Calls

    func fetchAutoCall() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetAutoCall) else { return }
        if resp.payload.count >= 1 {
            autoCallEnabled = resp.payload[0] == 0x01
        }
    }

    func setAutoCall(_ enabled: Bool) async {
        autoCallEnabled = enabled
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetAutoCall, payload: payload)
    }

    // MARK: - Comfort Call

    func fetchComfortCall() async {
        guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetComfortCall) else { return }
        if resp.payload.count >= 1 {
            comfortCallEnabled = resp.payload[0] == 0x01
        }
    }

    func setComfortCall(_ enabled: Bool) async {
        comfortCallEnabled = enabled
        let payload: [UInt8] = [enabled ? 0x01 : 0x00]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetComfortCall, payload: payload)
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
        autoPowerOffMinutes = minutes
        let seconds = UInt16(minutes * 60)
        let payload: [UInt8] = [0x00, UInt8((seconds >> 8) & 0xFF), UInt8(seconds & 0xFF)]
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetTimer, payload: payload)
    }

    // MARK: - EQ

    func fetchEQ() async {
        guard !eqLocked else { return }
        var gains = [Int8](repeating: 0, count: 5)
        for band in 0..<5 {
            guard let resp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetEQ, payload: [UInt8(band)]) else { continue }
            if resp.payload.count >= 1 {
                gains[band] = Int8(bitPattern: resp.payload[0])
            }
        }
        guard !eqLocked else { return }
        eqGains = gains.map { Double($0) / 10.0 }
        eqPreset = EQPreset.matching(gains: gains)
    }

    /// Call synchronously before the async Task to prevent notification races.
    func lockEQ(preset: EQPreset) {
        eqPreset = preset
        eqGains = preset.gains.map { Double($0) / 10.0 }
        eqLockUntil = Date().addingTimeInterval(5)
    }

    func sendEQBands(_ preset: EQPreset) async {
        for (band, gain) in preset.gains.enumerated() {
            let payload: [UInt8] = [UInt8(band), UInt8(bitPattern: gain)]
            _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetEQBand, payload: payload)
        }
        eqLockUntil = Date().addingTimeInterval(1) // brief buffer for in-flight notifications
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
            let raw = Int8(clamping: Int(gain * 10))
            _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetEQBand, payload: [UInt8(band), UInt8(bitPattern: raw)])
            eqLockUntil = Date().addingTimeInterval(1)
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
        bassBoostEnabled = enabled
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetBassBoost, payload: [enabled ? 0x01 : 0x00])
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
        let prev = audioMode
        audioMode = mode
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetAudioMode, payload: [0x00, UInt8(mode.rawValue)])

        switch mode {
        case .userEq where prev != .userEq:
            // Re-apply graphic EQ: gains → bass boost (sound zone apply order)
            lockEQ(preset: eqPreset)
            await sendEQBands(eqPreset)
            await setBassBoost(bassBoostEnabled)
        case .parametricEq:
            // Sound zone apply order: stage frequencies → stage gains → stage Qs → stage filter types → pre-gain
            await applyPEQState()
        default:
            break
        }
    }

    /// Apply full PEQ state in sound zone order (used when switching to PEQ mode).
    private func applyPEQState() async {
        // Fetch current device state first (may differ from our local state on first switch)
        await fetchPEQ()
    }

    // MARK: - Parametric EQ

    func fetchPEQ() async {
        async let pg: Void = fetchPreGain()
        async let hr: Void = fetchHeadroom()
        _ = await (pg, hr)

        for stage in 0..<5 {
            let s = UInt8(stage)
            async let f = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageFrequency, payload: [s])
            async let q = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageQ, payload: [s])
            async let g = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageGain, payload: [s])
            async let t = send(vendor: .sennheiser, command: GAIAProtocol.cmdGetStageFilterType, payload: [s])
            let (fResp, qResp, gResp, tResp) = await (f, q, g, t)

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
            _ = await self.send(vendor: .sennheiser, command: GAIAProtocol.cmdSetStageFrequency,
                                payload: [UInt8(stage), UInt8(raw >> 8), UInt8(raw & 0xFF)])
        }
    }

    func setPEQQ(_ stage: Int, q: Double) {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].q = q
        let raw = UInt16(clamping: Int(round(q * 4096.0)))
        debouncePEQ(key: "q\(stage)") {
            _ = await self.send(vendor: .sennheiser, command: GAIAProtocol.cmdSetStageQ,
                                payload: [UInt8(stage), UInt8(raw >> 8), UInt8(raw & 0xFF)])
        }
    }

    func setPEQGain(_ stage: Int, db: Double) {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].gain = db
        let raw = Int16(clamping: Int(round(db * 10.0)))
        let unsigned = UInt16(bitPattern: raw)
        debouncePEQ(key: "gain\(stage)") {
            _ = await self.send(vendor: .sennheiser, command: GAIAProtocol.cmdSetStageGain,
                                payload: [UInt8(stage), UInt8(unsigned >> 8), UInt8(unsigned & 0xFF)])
        }
    }

    func setPEQFilterType(_ stage: Int, type: PEQFilterType) async {
        guard stage >= 0, stage < 5 else { return }
        peqStages[stage].filterType = type
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetStageFilterType,
                       payload: [UInt8(stage), UInt8(type.rawValue)])
    }

    func setPreGain(_ db: Double) {
        preGainDB = db
        let raw = Int16(clamping: Int(round(db * 10.0)))
        let unsigned = UInt16(bitPattern: raw)
        preGainDebounceTask?.cancel()
        preGainDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetPreGain,
                           payload: [UInt8(unsigned >> 8), UInt8(unsigned & 0xFF)])
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
        crossfeedLevel = level
        _ = await send(vendor: .sennheiser, command: GAIAProtocol.cmdSetCrossfeed, payload: [UInt8(level)])
    }

    // MARK: - Paired Device List

    func fetchDeviceList() async {
        // Fetch max connections and own index in parallel
        async let mc: Void = fetchMaxBTConnections()
        async let oi: Void = fetchOwnDeviceIndex()
        _ = await (mc, oi)

        // Get list size
        guard let sizeResp = await send(vendor: .sennheiser, command: GAIAProtocol.cmdGetPairedDeviceListSize) else { return }
        let count: Int
        if sizeResp.payload.count >= 2 {
            count = Int(UInt16(sizeResp.payload[0]) << 8 | UInt16(sizeResp.payload[1]))
        } else {
            return
        }

        // Fetch info for each device
        var devices: [PairedDevice] = []
        for i in 0..<count {
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
            Task { @MainActor in
                self?.handleNotification(response)
            }
        }
    }

    private func handleNotification(_ response: GAIAProtocol.Response) {
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
        case GAIAProtocol.notifCharging:
            if response.payload.count >= 1 {
                deviceInfo.chargingStatus = ChargingStatus(rawValue: Int(response.payload[0])) ?? .disconnected
            }
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
            if response.payload.count >= 3 {
                let stage = Int(response.payload[0])
                guard stage >= 0, stage < 5 else { break }
                peqStages[stage].frequency = Int(UInt16(response.payload[1]) << 8 | UInt16(response.payload[2]))
            }
        case GAIAProtocol.notifStageQ:
            if response.payload.count >= 3 {
                let stage = Int(response.payload[0])
                guard stage >= 0, stage < 5 else { break }
                let raw = UInt16(response.payload[1]) << 8 | UInt16(response.payload[2])
                peqStages[stage].q = Double(raw) / 4096.0
            }
        case GAIAProtocol.notifStageGain:
            if response.payload.count >= 3 {
                let stage = Int(response.payload[0])
                guard stage >= 0, stage < 5 else { break }
                let raw = Int16(bitPattern: UInt16(response.payload[1]) << 8 | UInt16(response.payload[2]))
                peqStages[stage].gain = Double(raw) / 10.0
            }
        case GAIAProtocol.notifStageFilterType:
            if response.payload.count >= 2 {
                let stage = Int(response.payload[0])
                guard stage >= 0, stage < 5 else { break }
                peqStages[stage].filterType = PEQFilterType(rawValue: Int(response.payload[1])) ?? .bypass
            }
        case GAIAProtocol.respPreGain:
            if response.payload.count >= 2 {
                let raw = Int16(bitPattern: UInt16(response.payload[0]) << 8 | UInt16(response.payload[1]))
                preGainDB = Double(raw) / 10.0
            }
        default:
            break
        }
    }

    // MARK: - Helpers

    private func send(vendor: VendorID, command: UInt16, payload: [UInt8] = []) async -> GAIAProtocol.Response? {
        let vendorValue: UInt16 = (vendor == .qualcomm) ? GAIAProtocol.vendorQualcomm : GAIAProtocol.vendorSennheiser
        do {
            return try await bluetooth.sendCommand(vendor: vendorValue, command: command, payload: payload)
        } catch {
            NSLog("[HP] Command 0x%04X failed: %@", command, error.localizedDescription)
            return nil
        }
    }

    private enum VendorID {
        case qualcomm, sennheiser
    }
}
