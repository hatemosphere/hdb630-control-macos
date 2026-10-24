import CoreAudio
import IOBluetooth
import SwiftUI

private struct USBOutputSnapshot {
    var isDefault = false
    var nominalRate: Double?
    var actualRate: Double?
    var bufferFrames: UInt32?
    var latencyFrames: UInt32?
    var safetyFrames: UInt32?
    var isRunning: Bool?
    var virtualFormat: AudioStreamBasicDescription?
    var physicalFormat: AudioStreamBasicDescription?

    @MainActor static func read() -> USBOutputSnapshot? {
        guard let output = try? AudioOutputSwitcher.outputs().first(where: {
            $0.transport == kAudioDeviceTransportTypeUSB && $0.name == "BTD 700"
        }) else { return nil }

        var snapshot = USBOutputSnapshot()
        snapshot.isDefault = (try? AudioOutputSwitcher.defaultOutput()) == output.id
        snapshot.nominalRate = property(output.id, kAudioDevicePropertyNominalSampleRate)
        snapshot.actualRate = property(output.id, kAudioDevicePropertyActualSampleRate)
        snapshot.bufferFrames = property(output.id, kAudioDevicePropertyBufferFrameSize)
        snapshot.latencyFrames = property(output.id, kAudioDevicePropertyLatency,
                                          scope: kAudioDevicePropertyScopeOutput)
        snapshot.safetyFrames = property(output.id, kAudioDevicePropertySafetyOffset,
                                         scope: kAudioDevicePropertyScopeOutput)
        if let running: UInt32 = property(output.id, kAudioDevicePropertyDeviceIsRunningSomewhere) {
            snapshot.isRunning = running != 0
        }

        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(output.id, &address, 0, nil, &size) == noErr,
           size >= MemoryLayout<AudioStreamID>.size {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            let result = streams.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, $0.baseAddress!)
            }
            if result == noErr, let stream = streams.first {
                snapshot.virtualFormat = property(stream, kAudioStreamPropertyVirtualFormat)
                snapshot.physicalFormat = property(stream, kAudioStreamPropertyPhysicalFormat)
            }
        }
        return snapshot
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return value.pointee
    }

    var rate: Double? { actualRate ?? nominalRate }

    var bufferMilliseconds: Double? {
        guard let bufferFrames, let rate, rate > 0 else { return nil }
        return Double(bufferFrames) / rate * 1000
    }

    var latencyMilliseconds: Double? {
        guard let latencyFrames, let rate, rate > 0 else { return nil }
        return Double(latencyFrames) / rate * 1000
    }

    var safetyMilliseconds: Double? {
        guard let safetyFrames, let rate, rate > 0 else { return nil }
        return Double(safetyFrames) / rate * 1000
    }
}

struct DiagnosticsView: View {
    @ObservedObject var controller: HeadphoneController
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var dongle: DongleController
    @EnvironmentObject private var outputSwitcher: AudioOutputSwitcher
    @State private var usb: USBOutputSnapshot?
    @State private var controlRSSI: Int?
    @State private var rssiHistory: [Int] = []
    @State private var sampledAt: Date?

    private var headsetConnected: Bool { bluetooth.state == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                signalPath

                HStack(alignment: .top, spacing: 16) {
                    controlCard
                    bluetoothCard
                }

                HStack(alignment: .top, spacing: 16) {
                    usbCard
                    headsetCard
                }

                streamingCard
                usageCard
                sensorCard

                HStack {
                    Text("Mac: 2 s · device / stream: 10 s · usage: 60 s")
                    Spacer()
                    if let sampledAt {
                        Text("Last sample \(sampledAt.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.16),
                                    Color(red: 0.03, green: 0.06, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .preferredColorScheme(.dark)
        .task(id: headsetConnected) {
            var cycle = 0
            while !Task.isCancelled {
                sample()
                if cycle % 5 == 0 {
                    if headsetConnected {
                        await controller.pollState()
                        await controller.fetchStreamingStatistics()
                    }
                    if dongle.available && !dongle.busy { await dongle.refresh() }
                }
                if cycle % 30 == 0, headsetConnected { await controller.fetchUsageStatistics() }
                cycle += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIGNAL LAB  /  HDB 630 + BTD 700")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(ControlStyle.accent)
                Text("Inside the signal")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Real device reports from the Mac, USB dongle, and headphones.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(ControlStyle.accent).frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(ControlStyle.accent.opacity(0.12), in: Capsule())
        }
    }

    private var signalPath: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("AUDIO PATH")
                HStack(spacing: 8) {
                    hop("laptopcomputer", "MAC", outputSwitcher.outputName.isEmpty ? "Output unknown" : outputSwitcher.outputName)
                    Image(systemName: "arrow.right").foregroundStyle(ControlStyle.accent.opacity(0.65))
                    hop("cable.connector", "USB / BTD 700", usb?.rate.map(rateLabel) ?? "No USB audio")
                    Image(systemName: "arrow.right").foregroundStyle(ControlStyle.accent.opacity(0.65))
                    hop("waveform", "BLUETOOTH", dongle.connectionState >= 2 ? dongle.activeCodecDescription : "No link")
                    Image(systemName: "arrow.right").foregroundStyle(ControlStyle.accent.opacity(0.65))
                    hop("headphones", "HDB 630", headsetConnected ? "Control connected" : "Control offline")
                }
                if let usbRate = usb?.rate, let btRate = bluetoothRate, abs(usbRate - btRate) > 1 {
                    Text("USB reports \(rateLabel(usbRate)); the dongle reports \(rateLabel(btRate)) over Bluetooth. The conversion point is not exposed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private var controlCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("MAC ↔ HEADPHONES CONTROL LINK")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(controlRSSI.map { "\($0)" } ?? "—")
                        .font(.system(size: 41, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ControlStyle.accent)
                    Text("dBm")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(headsetConnected ? "RFCOMM OPEN" : "OFFLINE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(headsetConnected ? ControlStyle.accent : .orange)
                }
                RSSITrace(samples: rssiHistory)
                    .stroke(ControlStyle.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 70)
                    .background(.white.opacity(0.035), in: .rect(cornerRadius: 9))
                Text("Mac Bluetooth RSSI for the direct control connection. This is not the BTD 700 radio signal.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bluetoothCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 13) {
                sectionLabel("BTD 700 RADIO LINK")
                row("State", dongle.available ? dongle.connectionDescription : "Dongle unplugged")
                row("Codec", dongle.connectionState >= 2 ? dongle.activeCodecDescription : "—")
                row("Link format", dongle.qualityDescription)
                row("Transmission", dongle.available ? dongle.audioMode.title : "—")
                row("Sink transport", dongle.sinkTransport.map(sinkTransportLabel) ?? "—")
                row("LE Audio", dongle.leAudioState.map(leAudioLabel) ?? "—")
                row("Supported codecs", supportedCodecs)
                row("Firmware", dongle.firmware.isEmpty ? "—" : dongle.firmware)
                Text("Codec and link format come from the dongle’s USB HID reports. RF packet loss, transmit power and BTD RSSI are not exposed by the verified commands.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usbCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 13) {
                sectionLabel("MAC → USB AUDIO")
                row("Output", usb == nil ? "BTD 700 unavailable" : (usb!.isDefault ? "BTD 700 · selected" : "BTD 700 · idle"))
                row("Device rate", usb?.rate.map(rateLabel) ?? "—")
                row("USB stream", usb?.physicalFormat.map(formatLabel) ?? "—")
                row("Core Audio stream", usb?.virtualFormat.map(formatLabel) ?? "—")
                row("Buffer", frameDuration(usb?.bufferFrames, usb?.bufferMilliseconds))
                row("Device latency", frameDuration(usb?.latencyFrames, usb?.latencyMilliseconds))
                row("Safety offset", frameDuration(usb?.safetyFrames, usb?.safetyMilliseconds))
                row("Device running", usb?.isRunning.map { $0 ? "Yes" : "No" } ?? "—")
                Text("Buffer and device timing are Core Audio values, not measured end-to-end wireless latency.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
    }

    private var headsetCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 13) {
                sectionLabel("HDB 630 STATE")
                row("Control", headsetConnected ? "Connected to Mac" : "Unavailable")
                row("Battery", headsetConnected ? "\(controller.batteryLevel)%" : "—")
                row("Charging", headsetConnected ? (controller.deviceInfo.chargingStatus.label.isEmpty ? "No" : controller.deviceInfo.chargingStatus.label) : "—")
                row("Headphone codec", headsetConnected ? (controller.deviceInfo.codec.isEmpty ? "—" : controller.deviceInfo.codec) : "—")
                row("Headphone stream", headsetConnected ? controller.streamSampleRate.map { rateLabel(Double($0)) } ?? "No stream" : "—")
                row("High Resolution", controller.highResolutionEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "—")
                row("ANC", headsetConnected ? (controller.ancEnabled ? "On" : "Off") : "—")
                row("Wind reduction", headsetConnected ? windLabel : "—")
                row("Adaptive ANC", headsetConnected ? (controller.ancState.adaptive ? "On" : "Off") : "—")
                row("Audio mode", headsetConnected ? controller.audioMode.label : "—")
                row("Firmware", headsetConnected && !controller.deviceInfo.firmwareVersion.isEmpty ? controller.deviceInfo.firmwareVersion : "—")
            }
        }
    }

    private var sensorCard: some View {
        panel {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("SENSOR ACCESS")
                    Text("Wear sensing is real. Raw samples are not exposed.")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("The headphones report an on-head/off-head state, but their capability file marks raw wear sensor samples unsupported. No verified raw ANC microphone, motion, temperature, or battery-health stream is available.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 9) {
                    row("Wear detection", headsetConnected ? (controller.onHeadDetectionEnabled ? "Enabled" : "Disabled") : "—")
                    row("Current wear state", headsetConnected ? physicalStateLabel : "—")
                    row("Raw wear samples", "Unsupported")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var streamingCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("HEADPHONE STREAMING STATISTICS")
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Primary RSSI", controller.streamingStatistics?.primaryRSSI.map(String.init) ?? "—")
                        row("Primary link quality", controller.streamingStatistics?.primaryLinkQuality.map {
                            String(format: "%.2f%%", $0)
                        } ?? "—")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        row("Streaming codec", controller.streamingStatistics?.codec ?? "—")
                        row("Lossless flag", controller.streamingStatistics?.lossless.map { $0 ? "Enabled" : "Disabled" } ?? "—")
                        row("Bitrate", controller.streamingStatistics?.bitrate.map {
                            String(format: "%.1f kbps", Double($0) / 1000)
                        } ?? (controller.streamingStatistics == nil ? "—" : "Not reported"))
                    }
                }
                Text("Read from the headphones using Qualcomm’s statistics schema. “Primary” does not identify the peer in a multipoint connection. Link quality is a normalized device score, not a measured packet-delivery percentage. An empty bitrate field means unavailable.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usageCard: some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("ACCUMULATED USAGE  /  DEVICE COUNTERS")
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 10) {
                        row("Startup count", usageValue(0x01))
                        row("Powered-on time", usageDuration(0x02))
                        row("Playback starts", usageValue(0x03))
                        row("Playback time", usageDuration(0x04))
                        row("Noise-control activations", usageValue(0x08))
                        row("Noise-control time", usageDuration(0x09))
                    }
                    VStack(spacing: 10) {
                        row("Charging sessions", usageValue(0x0A))
                        row("Charging time", usageDuration(0x0B))
                        row("AAC playback", usageDuration(0x0F))
                        row("aptX Adaptive playback", usageDuration(0x11))
                    }
                }
                Text("Mappings observed in controlled tests on firmware 3.33.3. Counters update about once a minute; their reset conditions are not fully known. Charging sessions are cable connections, not battery wear cycles. Noise-control time includes Manual transparency.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("All 19 vendor records · raw values") {
                    VStack(spacing: 8) {
                        ForEach(controller.usageStatistics) { record in
                            row(String(format: "0100:%02X", record.id),
                                "\(record.unsignedValue.map(String.init) ?? "—")   [\(record.hex)]"
                                + (record.flags == 0 ? "" : String(format: " flags:%02X", record.flags)))
                        }
                    }
                    .fontDesign(.monospaced)
                    .padding(.top, 8)
                }
                .font(.system(size: 11))
                .tint(ControlStyle.accent)
            }
        }
    }

    private func usageValue(_ id: UInt8) -> String {
        controller.usageStatistics.first { $0.id == id }?.unsignedValue(length: 2).map(String.init) ?? "—"
    }

    private func usageDuration(_ id: UInt8) -> String {
        guard let minutes = controller.usageStatistics.first(where: { $0.id == id })?.unsignedValue(length: 4) else { return "—" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private var supportedCodecs: String {
        guard dongle.available else { return "—" }
        let names = DongleController.Codec.allCases
            .filter { dongle.supportedCodecMask & $0.rawValue != 0 }
            .map(\.title)
        return names.isEmpty ? "None reported" : names.joined(separator: ", ")
    }

    private var physicalStateLabel: String {
        switch controller.physicalDeviceState {
        case 1: "In case"
        case 2: "Off head"
        case 3: "On head"
        case .some(let value): "Unknown (\(value))"
        case nil: "—"
        }
    }

    private func sinkTransportLabel(_ value: UInt8) -> String {
        switch value {
        case 0: "Unavailable"
        case 1: "Classic Bluetooth"
        case 2: "LE Audio"
        case 3: "Dual"
        default: "Unknown (\(value))"
        }
    }

    private func leAudioLabel(_ value: UInt8) -> String {
        switch value {
        case 0: "None"
        case 1: "Disconnected"
        case 2: "Connected"
        case 3: "Streaming unicast"
        case 4: "Streaming broadcast"
        default: "Unknown (\(value))"
        }
    }

    private var bluetoothRate: Double? {
        guard dongle.available, dongle.connectionState >= 2 else { return nil }
        return switch dongle.sampleRate {
        case 1: 44_100
        case 2: 48_000
        case 3: 96_000
        default: nil
        }
    }

    private var windLabel: String {
        switch controller.ancState.antiWind {
        case 1: "Max"
        case 2: "Auto"
        default: "Off"
        }
    }

    private func sample() {
        usb = USBOutputSnapshot.read()
        if headsetConnected, let device = bluetooth.pairedDevices.first(where: { $0.isConnected() }) {
            let value = Int(device.rawRSSI())
            controlRSSI = value == 127 ? nil : value
            if let controlRSSI {
                rssiHistory.append(controlRSSI)
                if rssiHistory.count > 45 { rssiHistory.removeFirst(rssiHistory.count - 45) }
            }
        } else {
            controlRSSI = nil
            rssiHistory.removeAll()
        }
        sampledAt = Date()
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white.opacity(0.055), in: .rect(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.095)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(ControlStyle.accent.opacity(0.8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.52))
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
    }

    private func hop(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(ControlStyle.accent)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 73, alignment: .leading)
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f kHz", rate / 1000)
    }

    private func formatLabel(_ format: AudioStreamBasicDescription) -> String {
        "\(rateLabel(format.mSampleRate)) · \(format.mBitsPerChannel) bit · \(format.mChannelsPerFrame) ch"
    }

    private func frameDuration(_ frames: UInt32?, _ milliseconds: Double?) -> String {
        guard let frames else { return "—" }
        guard let milliseconds else { return "\(frames) frames" }
        return String(format: "%d frames · %.1f ms", frames, milliseconds)
    }
}

private struct RSSITrace: Shape {
    let samples: [Int]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let count = max(samples.count - 1, 1)
        for (index, sample) in samples.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(count)
            let normalized = min(max((Double(sample) + 95) / 75, 0), 1)
            let y = rect.maxY - rect.height * CGFloat(normalized)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
