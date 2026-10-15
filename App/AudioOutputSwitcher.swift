import AppKit
import Carbon
import CoreAudio
import SwiftUI

/// Personal shortcut: Control–Option–S switches the Mac's media output.
@MainActor
final class AudioOutputSwitcher: ObservableObject {
    @Published private(set) var outputName = ""
    @Published private(set) var shortcutError: String?
    @Published private(set) var switching = false
    @Published private(set) var dongleRate: Double?
    @Published private(set) var dongleRates: [Double] = []

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var started = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var outputListenerProperties: [(object: AudioObjectID, selector: AudioObjectPropertySelector)] = []
    private var toast: NSPanel?
    private var hideToast: DispatchWorkItem?
    private static let signature: OSType = 0x48444253 // HDBS
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    struct Output {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let transport: UInt32
    }

    private enum SwitchError: LocalizedError {
        case coreAudio(OSStatus)
        case speakersMissing
        case notConfirmed
        case dongleMissing
        case unsupportedRate(Double)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let code): return "macOS audio error (\(code))."
            case .speakersMissing: return "MacBook speakers are unavailable."
            case .notConfirmed: return "macOS did not confirm the output change. Try again."
            case .dongleMissing: return "BTD 700 USB audio output is unavailable."
            case .unsupportedRate(let rate): return "BTD 700 does not offer \(Int(rate / 1_000)) kHz output on this Mac."
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // Act on release so holding the shortcut cannot repeatedly flip the output.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x48444253, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AudioOutputSwitcher>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in await owner.toggle() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        if installed == noErr {
            let registered = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey),
                                                EventHotKeyID(signature: Self.signature, id: 1),
                                                GetApplicationEventTarget(), 0, &hotKey)
            if registered != noErr {
                shortcutError = "Control–Option–S could not be registered (\(registered)). Another app may be using it."
            }
        } else {
            shortcutError = "Could not listen for the audio shortcut (\(installed))."
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        outputListener = listener
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var property = Self.address(selector)
            if AudioObjectAddPropertyListenerBlock(Self.system, &property, .main, listener) == noErr {
                outputListenerProperties.append((Self.system, selector))
            }
        }
        refresh()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let outputListener {
            for observed in outputListenerProperties {
                var property = AudioObjectPropertyAddress(mSelector: observed.selector,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(observed.object, &property, .main, outputListener)
            }
        }
        hideToast?.cancel()
    }

    func refresh() {
        do {
            let current = try Self.defaultOutput()
            outputName = try Self.string(current, kAudioObjectPropertyName)
        } catch {
            outputName = "Output unavailable"
        }
        let dongle = try? Self.dongleOutput()
        observeDongleRate(dongle?.id)
        if let dongle {
            dongleRate = try? Self.double(dongle.id, kAudioDevicePropertyNominalSampleRate)
            dongleRates = (try? Self.rates(dongle.id)) ?? []
        } else {
            dongleRate = nil
            dongleRates = []
        }
    }

    private func observeDongleRate(_ device: AudioDeviceID?) {
        guard let outputListener else { return }
        let selector = kAudioDevicePropertyNominalSampleRate
        var property = Self.address(selector)
        if let index = outputListenerProperties.firstIndex(where: { $0.selector == selector }) {
            let observed = outputListenerProperties[index]
            guard observed.object != device else { return }
            AudioObjectRemovePropertyListenerBlock(observed.object, &property, .main, outputListener)
            outputListenerProperties.remove(at: index)
        }
        if let device, AudioObjectAddPropertyListenerBlock(device, &property, .main, outputListener) == noErr {
            outputListenerProperties.append((device, selector))
        }
    }

    func setDongleRate(_ rate: Double) async throws {
        guard let dongle = try Self.dongleOutput() else { throw SwitchError.dongleMissing }
        guard try Self.rates(dongle.id).contains(where: { abs($0 - rate) < 1 }) else {
            throw SwitchError.unsupportedRate(rate)
        }
        var value = rate
        var property = Self.address(kAudioDevicePropertyNominalSampleRate)
        let result = AudioObjectSetPropertyData(dongle.id, &property, 0, nil,
                                                UInt32(MemoryLayout<Double>.size), &value)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        for _ in 0..<20 {
            if let actual = try? Self.double(dongle.id, kAudioDevicePropertyNominalSampleRate),
               abs(actual - rate) < 1 {
                refresh()
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        refresh()
        throw SwitchError.notConfirmed
    }

    func toggle() async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        do {
            // Enumerate on every press: device IDs can change after unplugging or sleep.
            let outputs = try Self.outputs()
            guard let speakers = outputs.first(where: {
                $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.uid == "BuiltInSpeakerDevice"
            }) else { throw SwitchError.speakersMissing }
            let dongle = outputs.first { $0.transport == kAudioDeviceTransportTypeUSB && $0.name == "BTD 700" }
            let current = try Self.defaultOutput()
            let target = current == speakers.id ? (dongle ?? speakers) : speakers
            var targetID = target.id
            var property = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            let result = AudioObjectSetPropertyData(Self.system, &property, 0, nil,
                                                   UInt32(MemoryLayout<AudioDeviceID>.size), &targetID)
            guard result == noErr else { throw SwitchError.coreAudio(result) }

            // Core Audio changes may complete asynchronously. Only confirm after readback.
            for _ in 0..<20 {
                if try Self.defaultOutput() == target.id {
                    refresh()
                    showToast(target.id == speakers.id ? "MacBook speakers" : "BTD 700",
                              subtitle: dongle == nil ? "Sound output · dongle unplugged" : "Sound output",
                              icon: target.id == speakers.id ? "speaker.wave.2.fill" : "headphones")
                    return
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw SwitchError.notConfirmed
        } catch {
            showToast("Couldn’t switch audio", subtitle: error.localizedDescription, icon: "exclamationmark.triangle")
        }
    }

    static func defaultOutput() throws -> AudioDeviceID {
        try uint32(system, kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func outputs() throws -> [Output] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        result = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let name = try? string(id, kAudioObjectPropertyName),
                  let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  let transport = try? uint32(id, kAudioDevicePropertyTransportType) else { return nil }
            return Output(id: id, name: name, uid: uid, transport: transport)
        }
    }

    private static func dongleOutput() throws -> Output? {
        try outputs().first { $0.transport == kAudioDeviceTransportTypeUSB && $0.name == "BTD 700" }
    }

    private static func rates(_ device: AudioDeviceID) throws -> [Double] {
        var property = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        guard size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
                                       count: Int(size) / MemoryLayout<AudioValueRange>.size)
        result = ranges.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        return ranges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        return value
    }

    private static func double(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> Double {
        var property = address(selector)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let result = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        guard result == noErr else { throw SwitchError.coreAudio(result) }
        guard let value else { throw SwitchError.coreAudio(kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    private func showToast(_ title: String, subtitle: String, icon: String) {
        hideToast?.cancel()
        let panel = toast ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 84),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(ControlStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 340, height: 84)
            .background(ControlStyle.background.opacity(0.96), in: .rect(cornerRadius: 18))
            .preferredColorScheme(.dark)
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.maxY - 108))
        }
        panel.orderFrontRegardless()
        toast = panel
        let hide = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideToast = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: hide)
    }
}
