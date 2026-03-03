import SwiftUI

// MARK: - Tooltip (NSView-backed, works in NSPopover)

private class PassthroughTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct Tooltip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughTooltipView()
        view.toolTip = text
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

private extension View {
    func tooltip(_ text: String) -> some View {
        overlay(Tooltip(text: text))
    }
}

struct StatusBarView: View {
    @ObservedObject var controller: HeadphoneController
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch bluetooth.state {
            case .connected:
                ConnectedView(controller: controller, bluetooth: bluetooth)
            case .error(let message):
                ErrorView(message: message) {
                    bluetooth.scanForDevices()
                }
            default:
                DeviceListView(bluetooth: bluetooth) { device in
                    bluetooth.connect(to: device)
                }
            }
        }
        .frame(width: 300)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .tint(.blue)
    }
}

// MARK: - Connected View

private struct ConnectedView: View {
    @ObservedObject var controller: HeadphoneController
    let bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "headphones")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.deviceInfo.name.isEmpty ? "HDB 630" : controller.deviceInfo.name)
                        .font(.headline)
                    if !controller.deviceInfo.codec.isEmpty {
                        Text("Codec: \(controller.deviceInfo.codec)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                BatteryBadge(
                    level: controller.batteryLevel,
                    chargingStatus: controller.deviceInfo.chargingStatus
                )
            }
            .padding(.horizontal, 16)

            Divider()

            // ANC Section
            ANCSection(controller: controller)

            // Transparent Hearing (requires ANC on, Adaptive off)
            if controller.ancEnabled && !controller.ancState.adaptive {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Transparent Hearing")
                            .font(.callout)
                        Spacer()
                        Text("\(controller.transparencyLevel)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(controller.transparencyLevel) },
                            set: { val in
                                let level = Int(val)
                                controller.transparencyLevel = level
                                controller.setTransparency(level)
                            }
                        ),
                        in: 0...100,
                        step: 1
                    )
                }
                .tooltip("Lets outside sounds through while ANC is active")
                .padding(.horizontal, 16)
            }

            // EQ & Crossfeed
            EQSection(controller: controller)

            Divider()

            // Footer
            FooterView(controller: controller, bluetooth: bluetooth)
        }
    }
}

// MARK: - ANC Section

private struct ANCSection: View {
    @ObservedObject var controller: HeadphoneController

    var body: some View {
        HStack {
            Text("Active Noise Cancelling")
                .font(.callout)
            Spacer()
            Toggle("", isOn: Binding(
                get: { controller.ancEnabled },
                set: { on in Task { await controller.setANCEnabled(on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .tooltip("Reduces ambient noise using built-in microphones")
        .padding(.horizontal, 16)

        if controller.ancEnabled {
            VStack(alignment: .leading, spacing: 4) {
                Text("Anti-Wind")
                    .font(.callout)
                Picker("", selection: Binding(
                    get: { controller.ancState.antiWind },
                    set: { val in Task { await controller.setAntiWind(val) } }
                )) {
                    Text("Off").tag(0)
                    Text("Auto").tag(2)
                    Text("Max").tag(1)
                }
                .pickerStyle(.segmented)
            }
            .tooltip("Reduces wind noise — Auto adjusts based on conditions")
            .padding(.horizontal, 16)

            HStack {
                Text("Comfort")
                    .font(.callout)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.ancState.comfort },
                    set: { on in Task { await controller.setComfort(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .tooltip("Reduced ANC strength for less ear pressure")
            .padding(.horizontal, 16)

            HStack {
                Text("Adaptive ANC")
                    .font(.callout)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.ancState.adaptive },
                    set: { on in Task { await controller.setAdaptive(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .tooltip("Automatically adjusts ANC level based on environment")
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - EQ Section

private struct EQSection: View {
    @ObservedObject var controller: HeadphoneController

    var body: some View {
        // Audio mode picker
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio Mode")
                .font(.callout)
            Picker("", selection: Binding(
                get: { controller.audioMode },
                set: { mode in Task { await controller.setAudioMode(mode) } }
            )) {
                ForEach(AudioMode.selectable) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)

        switch controller.audioMode {
        case .userEq:
            GraphicEQControls(controller: controller)
        case .parametricEq:
            PEQControls(controller: controller)
        case .podcastMode:
            Text("Podcast mode optimizes audio for voice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        default:
            EmptyView()
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Crossfeed")
                .font(.callout)
            Picker("", selection: Binding(
                get: { controller.crossfeedLevel },
                set: { level in Task { await controller.setCrossfeed(level) } }
            )) {
                Text("Off").tag(2)
                Text("Low").tag(0)
                Text("High").tag(1)
            }
            .pickerStyle(.segmented)
        }
        .tooltip("Blends stereo channels for more natural, speaker-like sound")
        .padding(.horizontal, 16)
    }
}

// MARK: - Graphic EQ Controls

private struct GraphicEQControls: View {
    @ObservedObject var controller: HeadphoneController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset")
                .font(.callout)
            Picker("", selection: Binding(
                get: { controller.eqPreset },
                set: { preset in
                    guard preset != .custom else { return }
                    controller.lockEQ(preset: preset)
                    Task { await controller.sendEQBands(preset) }
                }
            )) {
                if controller.eqPreset == .custom {
                    Text("Custom").tag(EQPreset.custom)
                }
                ForEach(EQPreset.builtIn) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.horizontal, 16)

        EQBandSliders(controller: controller)
            .padding(.horizontal, 16)

        HStack {
            Text("Bass Boost")
                .font(.callout)
            Spacer()
            Toggle("", isOn: Binding(
                get: { controller.bassBoostEnabled },
                set: { on in Task { await controller.setBassBoost(on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .tooltip("Enhanced low-frequency response")
        .padding(.horizontal, 16)
    }
}

// MARK: - Parametric EQ Controls

private struct PEQControls: View {
    @ObservedObject var controller: HeadphoneController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pre-gain
            HStack {
                Text("Pre-Gain")
                    .font(.callout)
                Spacer()
                Text(formatDB(controller.preGainDB))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { controller.preGainDB },
                    set: { controller.setPreGain($0) }
                ),
                in: controller.eqConfig.minGainDB...controller.eqConfig.maxGainDB,
                step: 0.5
            )

            // Headroom
            HStack {
                Text("Headroom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatDB(controller.headroomDB))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Per-stage controls
            ForEach(0..<5, id: \.self) { stage in
                PEQStageRow(controller: controller, stage: stage)
                if stage < 4 { Divider() }
            }
        }
        .padding(.horizontal, 16)
    }

    private func formatDB(_ db: Double) -> String {
        if db == 0 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }
}

private struct PEQStageRow: View {
    @ObservedObject var controller: HeadphoneController
    let stage: Int

    private var stageBinding: PEQStage {
        controller.peqStages[stage]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: stage number + filter type
            HStack {
                Text("Band \(stage + 1)")
                    .font(.callout.bold())
                Spacer()
                Picker("", selection: Binding(
                    get: { stageBinding.filterType },
                    set: { type in Task { await controller.setPEQFilterType(stage, type: type) } }
                )) {
                    ForEach(PEQFilterType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
            }

            if stageBinding.filterType != .bypass {
                // Frequency
                HStack(spacing: 4) {
                    Text("Freq")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    LogSlider(
                        value: Binding(
                            get: { Double(stageBinding.frequency) },
                            set: { controller.setPEQFrequency(stage, hz: Int(round($0))) }
                        ),
                        range: 20...20000
                    )
                    Text(formatFreq(stageBinding.frequency))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                // Q
                HStack(spacing: 4) {
                    Text("Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { stageBinding.q },
                            set: { controller.setPEQQ(stage, q: $0) }
                        ),
                        in: 0.1...10.0
                    )
                    Text(String(format: "%.2f", stageBinding.q))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                // Gain
                HStack(spacing: 4) {
                    Text("Gain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { stageBinding.gain },
                            set: { controller.setPEQGain(stage, db: $0) }
                        ),
                        in: controller.eqConfig.minGainDB...controller.eqConfig.maxGainDB,
                        step: 0.5
                    )
                    Text(formatGain(stageBinding.gain))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    private func formatFreq(_ hz: Int) -> String {
        if hz >= 1000 {
            let k = Double(hz) / 1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fk Hz", k)
                : String(format: "%.1fk Hz", k)
        }
        return "\(hz) Hz"
    }

    private func formatGain(_ db: Double) -> String {
        if db == 0 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }
}

// MARK: - Logarithmic Slider

private struct LogSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var logMin: Double { log10(range.lowerBound) }
    private var logMax: Double { log10(range.upperBound) }

    private var normalizedPosition: Double {
        get { (log10(max(value, range.lowerBound)) - logMin) / (logMax - logMin) }
    }

    var body: some View {
        Slider(
            value: Binding(
                get: { normalizedPosition },
                set: { pos in
                    let logVal = logMin + pos * (logMax - logMin)
                    value = round(pow(10, logVal))
                }
            ),
            in: 0...1
        )
    }
}

// MARK: - EQ Band Sliders

private struct EQBandSliders: View {
    @ObservedObject var controller: HeadphoneController

    private static let bandLabels = ["50", "250", "800", "3k", "8k"]

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<5, id: \.self) { band in
                VStack(spacing: 2) {
                    Text(formatGain(controller.eqGains[band]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36)

                    VerticalSlider(
                        value: Binding(
                            get: { controller.eqGains[band] },
                            set: { controller.setEQBand(band, gain: $0) }
                        ),
                        range: -6.0...6.0
                    )
                    .frame(height: 100)

                    Text(Self.bandLabels[band])
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatGain(_ db: Double) -> String {
        if db == 0 { return "0" }
        return String(format: "%+.1f", db)
    }
}

private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let normalized = (value - range.lowerBound) / span
            let y = height * (1 - normalized)

            ZStack(alignment: .bottom) {
                // Track
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.quaternary)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)

                // Center line
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(.tertiary)
                    .frame(width: 9, height: 1)
                    .offset(y: -height / 2)

                // Filled portion from center
                let centerY = height / 2
                let fillHeight = abs(y - centerY)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.blue)
                    .frame(width: 3, height: fillHeight)
                    .offset(y: value >= 0 ? -(centerY) : -(y))

                // Thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(width: 14, height: 14)
                    .offset(y: -(height - y))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = 1 - (drag.location.y / height)
                        let clamped = min(max(fraction, 0), 1)
                        let raw = range.lowerBound + span * clamped
                        // Snap to 0.5 dB steps
                        value = (raw * 2).rounded() / 2
                    }
            )
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    @ObservedObject var controller: HeadphoneController
    let bluetooth: BluetoothManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                if !controller.deviceInfo.serial.isEmpty {
                    Text("S/N \(controller.deviceInfo.serial)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !controller.deviceInfo.firmwareVersion.isEmpty {
                    Text("FW \(controller.deviceInfo.firmwareVersion)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            Button("Disconnect") {
                bluetooth.disconnect()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            QuitButton()
        }
        .padding(.horizontal, 16)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

// MARK: - Battery Badge

private struct BatteryBadge: View {
    let level: Int
    let chargingStatus: ChargingStatus

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: batteryIcon)
                .foregroundStyle(level <= 15 ? .red : .primary)
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(level)%")
                    .font(.caption)
                    .monospacedDigit()
                if !chargingStatus.label.isEmpty {
                    Text(chargingStatus.label)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var batteryIcon: String {
        if chargingStatus == .charging {
            return "battery.100percent.bolt"
        }
        switch level {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Device List View

private struct DeviceListView: View {
    @ObservedObject var bluetooth: BluetoothManager
    let onSelect: (IOBluetoothDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Select Device")
                    .font(.headline)
                Spacer()
                Button {
                    bluetooth.scanForDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)

            if bluetooth.state == .scanning {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if bluetooth.pairedDevices.isEmpty {
                Text("No paired Bluetooth devices found.\nPair your HDB 630 in System Settings first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ForEach(bluetooth.pairedDevices, id: \.addressString) { device in
                    Button {
                        onSelect(device)
                    } label: {
                        HStack {
                            Image(systemName: "headphones")
                            Text(device.name ?? device.addressString ?? "Unknown")
                            Spacer()
                            if bluetooth.state == .connecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Spacer()
                QuitButton()
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Error View

private struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
            QuitButton()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Quit Button

private struct QuitButton: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        Button("Quit") {
            bluetooth.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
    }
}