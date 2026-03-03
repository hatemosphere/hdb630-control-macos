import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: HeadphoneController
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Call section
            SectionHeader("Call")

            SettingRow("Call Transparency") {
                Toggle("", isOn: Binding(
                    get: { controller.sidetoneLevel > 0 },
                    set: { on in
                        let level = on ? 2 : 0
                        controller.sidetoneLevel = level
                        controller.setSidetone(level)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if controller.sidetoneLevel > 0 {
                HStack {
                    Text("Level")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    Picker("", selection: Binding(
                        get: { controller.sidetoneLevel },
                        set: { level in
                            controller.sidetoneLevel = level
                            controller.setSidetone(level)
                        }
                    )) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                SettingRow("Auto-Pause") {
                    Toggle("", isOn: Binding(
                        get: { controller.autoPauseEnabled },
                        set: { on in Task { await controller.setAutoPause(on) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            SettingRow("Comfort Call") {
                Toggle("", isOn: Binding(
                    get: { controller.comfortCallEnabled },
                    set: { on in Task { await controller.setComfortCall(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().padding(.vertical, 8)

            // Settings section
            SectionHeader("Settings")

            SettingRow("Podcast Mode") {
                Toggle("", isOn: Binding(
                    get: { controller.audioMode == .podcastMode },
                    set: { on in Task {
                        if on {
                            await controller.setAudioMode(.podcastMode)
                        } else {
                            await controller.setAudioMode(.userEq)
                            controller.lockEQ(preset: controller.eqPreset)
                            await controller.sendEQBands(controller.eqPreset)
                        }
                    }}
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow("On-Head Detection") {
                Toggle("", isOn: Binding(
                    get: { controller.onHeadDetectionEnabled },
                    set: { on in Task { await controller.setOnHeadDetection(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            SettingRow("Smart Pause") {
                Toggle("", isOn: Binding(
                    get: { controller.smartPauseEnabled },
                    set: { on in Task { await controller.setSmartPause(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!controller.onHeadDetectionEnabled)
            }
            .opacity(controller.onHeadDetectionEnabled ? 1 : 0.5)

            SettingRow("Auto-Answer Calls") {
                Toggle("", isOn: Binding(
                    get: { controller.autoCallEnabled },
                    set: { on in Task { await controller.setAutoCall(on) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!controller.onHeadDetectionEnabled)
            }
            .opacity(controller.onHeadDetectionEnabled ? 1 : 0.5)

            SettingRow("Auto Power Off") {
                Picker("", selection: Binding(
                    get: { controller.autoPowerOffMinutes },
                    set: { mins in Task { await controller.setAutoPowerOff(minutes: mins) } }
                )) {
                    Text("Off").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
                .disabled(!controller.onHeadDetectionEnabled)
            }
            .opacity(controller.onHeadDetectionEnabled ? 1 : 0.5)

            Divider().padding(.vertical, 8)

            // Device section
            SectionHeader("Device")

            if !controller.pairedDevices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Connections")
                            .font(.callout)
                        Spacer()
                        if controller.maxBTConnections > 1 {
                            Text("Multipoint")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ForEach(controller.pairedDevices) { device in
                        HStack(spacing: 6) {
                            Image(systemName: device.index == controller.ownDeviceIndex
                                  ? "desktopcomputer" : "iphone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(device.name.isEmpty ? "Device \(device.index)" : device.name)
                                .font(.callout)
                            if device.index == controller.ownDeviceIndex {
                                Text("This device")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if device.isConnected {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            HStack {
                if !controller.deviceInfo.serial.isEmpty {
                    Text("S/N \(controller.deviceInfo.serial)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !controller.deviceInfo.firmwareVersion.isEmpty {
                    Text("FW \(controller.deviceInfo.firmwareVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(width: 320)
    }
}

// MARK: - Helpers

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
}

private struct SettingRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
