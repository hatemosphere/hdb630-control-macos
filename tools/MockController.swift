// Mock stubs for HeadphoneController and BluetoothManager.
// Same class names + @Published properties as production, but no-op methods.
// Used by the ScreenshotMock target to render real UI views with mock data.

import Foundation
import IOBluetooth

// MARK: - Mock BluetoothManager

final class BluetoothManager: NSObject, ObservableObject {
    @Published var state: ConnectionState = .connected
    @Published var pairedDevices: [IOBluetoothDevice] = []

    func scanForDevices() {}
    func connect(to device: IOBluetoothDevice) {}
    func disconnect() {}
}

// MARK: - Mock HeadphoneController

@MainActor
final class HeadphoneController: ObservableObject {
    @Published var deviceInfo = DeviceInfo(
        name: "Sennheiser HDB 630",
        serial: "SN1234567890",
        firmwareVersion: "1.8.0",
        codec: "aptX Adaptive",
        chargingStatus: .disconnected
    )
    @Published var batteryLevel: Int = 72
    @Published var ancEnabled: Bool = true
    @Published var ancState = ANCState(antiWind: 2, comfort: false, adaptive: false)
    @Published var transparencyLevel: Int = 45
    @Published var sidetoneLevel: Int = 2
    @Published var autoPauseEnabled: Bool = true
    @Published var onHeadDetectionEnabled: Bool = true
    @Published var smartPauseEnabled: Bool = true
    @Published var autoCallEnabled: Bool = false
    @Published var comfortCallEnabled: Bool = false
    @Published var autoPowerOffMinutes: Int = 30
    @Published var eqPreset: EQPreset = .rock
    @Published var eqGains: [Double] = [0, 2.0, 2.5, 1.5, -2.0]
    @Published var bassBoostEnabled: Bool = false
    @Published var audioMode: AudioMode = .userEq
    @Published var peqStages: [PEQStage] = [
        PEQStage(frequency: 80, q: 0.71, gain: 3.0, filterType: .highShelfSecondOrder),
        PEQStage(frequency: 250, q: 1.41, gain: -1.5, filterType: .peq),
        PEQStage(frequency: 1000, q: 0.71, gain: 0.0, filterType: .peq),
        PEQStage(frequency: 4000, q: 2.0, gain: 2.0, filterType: .peq),
        PEQStage(frequency: 10000, q: 0.71, gain: -0.5, filterType: .lowShelfSecondOrder),
    ]
    @Published var preGainDB: Double = -1.5
    @Published var headroomDB: Double = 3.2
    @Published var eqConfig = EQConfig()
    @Published var crossfeedLevel: Int = 2
    @Published var pairedDevices: [PairedDevice] = [
        PairedDevice(index: 0, name: "MacBook Pro", priority: 0, isConnected: true),
        PairedDevice(index: 1, name: "iPhone 15 Pro", priority: 1, isConnected: true),
    ]
    @Published var maxBTConnections: Int = 2
    @Published var ownDeviceIndex: Int = 0

    // No-op stubs for methods called by views
    func setANCEnabled(_ on: Bool) async {}
    func setAntiWind(_ val: Int) async {}
    func setComfort(_ on: Bool) async {}
    func setAdaptive(_ on: Bool) async {}
    func setTransparency(_ level: Int) {}
    func setAudioMode(_ mode: AudioMode) async {}
    func lockEQ(preset: EQPreset) {}
    func sendEQBands(_ preset: EQPreset) async {}
    func setEQBand(_ band: Int, gain: Double) {}
    func setPEQFilterType(_ stage: Int, type: PEQFilterType) async {}
    func setPEQFrequency(_ stage: Int, hz: Int) {}
    func setPEQQ(_ stage: Int, q: Double) {}
    func setPEQGain(_ stage: Int, db: Double) {}
    func setPreGain(_ db: Double) {}
    func setBassBoost(_ on: Bool) async {}
    func setCrossfeed(_ level: Int) async {}
    func setSidetone(_ level: Int) {}
    func setAutoPause(_ on: Bool) async {}
    func setComfortCall(_ on: Bool) async {}
    func setOnHeadDetection(_ on: Bool) async {}
    func setSmartPause(_ on: Bool) async {}
    func setAutoCall(_ on: Bool) async {}
    func setAutoPowerOff(minutes: Int) async {}
}
