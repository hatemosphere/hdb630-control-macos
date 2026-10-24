import SwiftUI

struct DongleView: View {
    @ObservedObject var dongle: DongleController
    @EnvironmentObject private var outputSwitcher: AudioOutputSwitcher
    @State private var applyingMode = false
    @State private var formatError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(ControlStyle.accent)
                    .frame(width: 46, height: 46)
                    .background(ControlStyle.accent.opacity(0.12), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("BTD 700")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("USB audio transmitter")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await dongle.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(dongle.busy)
                .help("Refresh dongle status")
            }
            .padding(.horizontal, 2)

            if !dongle.available {
                CardSection("Connection") {
                    Label("Plug in your BTD 700. It will connect automatically.", systemImage: "cable.connector")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                CardSection("Connection") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(dongle.connectionState >= 2 ? ControlStyle.accent : .orange)
                            .frame(width: 7, height: 7)
                        Text(dongle.connectionDescription)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Spacer()
                        if !dongle.firmware.isEmpty {
                            Text("FW \(dongle.firmware)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 10) {
                        detail("CODEC", dongle.activeCodecDescription)
                        detail("QUALITY", dongle.qualityDescription)
                    }

                    Button {
                        Task { await dongle.setConnected(dongle.connectionState <= 1) }
                    } label: {
                        Text(dongle.connectionState <= 1 ? "Reconnect headphones" : "Disconnect headphones")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(dongle.busy)
                }

                CardSection("Listening Modes") {
                    HStack(spacing: 9) {
                        modeButton(.highQuality, icon: "waveform")
                        modeButton(.gaming, icon: "gamecontroller")
                    }

                    Text("Video favors low latency at 48 kHz. Music favors quality and sets the Mac’s USB output to 96 kHz.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        detail("MAC → USB", outputSwitcher.dongleRate.map(rateLabel) ?? "—")
                        detail("DONGLE → HEADPHONES", dongle.qualityDescription)
                    }

                    if !outputSwitcher.dongleRates.isEmpty {
                        HStack {
                            Text("Mac USB format")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu(outputSwitcher.dongleRate.map(rateLabel) ?? "Choose") {
                                ForEach(outputSwitcher.dongleRates, id: \.self) { rate in
                                    Button(rateLabel(rate)) { setRate(rate) }
                                }
                            }
                            .disabled(applyingMode)
                        }
                    }

                    if dongle.audioMode == .highQuality && dongle.connectionState >= 2 && dongle.sampleRate != 3 {
                        Text("For 96 kHz, enable High Resolution under Headphones → Settings → Wireless audio. That action restarts the headphones. The live link format above shows the negotiated rate.")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if dongle.audioMode == .broadcast {
                        Text("Auracast broadcast is active. Choose a mode above to return to headphone audio.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if availableCodecs.count > 1 {
                        HStack {
                            Text("Codec")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu(dongle.activeCodecDescription) {
                                ForEach(availableCodecs) { codec in
                                    Toggle(codec.title, isOn: Binding(
                                        get: { dongle.activeCodecMask == codec.rawValue },
                                        set: { _ in Task { await dongle.setCodec(codec) } }
                                    ))
                                }
                            }
                            .disabled(dongle.busy)
                        }
                    }

                    Text("Supported by these headphones: \(supportedCodecDescription)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let message = dongle.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let formatError {
                Text(formatError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .task {
            outputSwitcher.refresh()
            await dongle.refresh()
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
    }

    private func modeButton(_ mode: DongleController.AudioMode, icon: String) -> some View {
        let targetRate = mode == .gaming ? 48_000.0 : 96_000.0
        let selected = dongle.audioMode == mode && outputSwitcher.dongleRate == targetRate
        return Button {
            apply(mode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(mode == .gaming ? "Video" : "Music")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(selected ? ControlStyle.background : .white.opacity(0.7))
            .background(selected ? ControlStyle.accent : .white.opacity(0.07), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(dongle.busy || applyingMode || !outputSwitcher.dongleRates.contains(targetRate))
        .help(mode == .gaming ? "Low latency · 48 kHz USB" : "High quality · 96 kHz USB")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func apply(_ mode: DongleController.AudioMode) {
        applyingMode = true
        formatError = nil
        Task {
            defer { applyingMode = false }
            guard await dongle.setAudioMode(mode) else { return }
            do {
                try await outputSwitcher.setDongleRate(mode == .gaming ? 48_000 : 96_000)
            } catch {
                formatError = error.localizedDescription
            }
            await dongle.refresh()
        }
    }

    private func setRate(_ rate: Double) {
        applyingMode = true
        formatError = nil
        Task {
            defer { applyingMode = false }
            do {
                try await outputSwitcher.setDongleRate(rate)
            } catch {
                formatError = error.localizedDescription
            }
            await dongle.refresh()
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        String(format: "%g kHz", rate / 1_000)
    }

    private var supportedCodecDescription: String {
        let names = availableCodecs.map(\.title)
        return names.isEmpty ? "none reported" : names.joined(separator: ", ")
    }

    private var availableCodecs: [DongleController.Codec] {
        DongleController.Codec.allCases.filter {
            dongle.supportedCodecMask & $0.rawValue != 0
        }
    }
}
