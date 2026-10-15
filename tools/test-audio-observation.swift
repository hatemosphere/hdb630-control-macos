import AppKit
import Carbon
import CoreAudio

private struct ObservedProperty {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue?
    let block: AudioObjectPropertyListenerBlock
}

private var observations: [ObservedProperty] = []
private var dongleID: AudioDeviceID? = 42
private var defaultOutputID: AudioDeviceID = 2
private var nominalRate = 48_000.0
private var installAttempts = 0
private var failRateRegistration = false

func InstallEventHandler(_ target: EventTargetRef?, _ handler: EventHandlerUPP?, _ count: Int,
                         _ types: UnsafePointer<EventTypeSpec>?, _ context: UnsafeMutableRawPointer?,
                         _ result: UnsafeMutablePointer<EventHandlerRef?>?) -> OSStatus {
    installAttempts += 1
    return OSStatus(eventNotHandledErr)
}

func AudioObjectAddPropertyListenerBlock(_ object: AudioObjectID,
                                        _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                        _ queue: DispatchQueue?,
                                        _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    if address.pointee.mSelector == kAudioDevicePropertyNominalSampleRate && failRateRegistration {
        failRateRegistration = false
        return kAudioHardwareBadObjectError
    }
    observations.append(ObservedProperty(object: object, address: address.pointee, queue: queue, block: block))
    return noErr
}

@discardableResult
func AudioObjectRemovePropertyListenerBlock(_ object: AudioObjectID,
                                           _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                           _ queue: DispatchQueue?,
                                           _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    guard let index = observations.firstIndex(where: {
        $0.object == object && $0.address.mSelector == address.pointee.mSelector &&
        $0.address.mScope == address.pointee.mScope && $0.address.mElement == address.pointee.mElement &&
        $0.queue === queue
    }) else { preconditionFailure("Removed a listener without its matching registration") }
    observations.remove(at: index)
    return noErr
}

func AudioObjectGetPropertyDataSize(_ object: AudioObjectID,
                                   _ address: UnsafePointer<AudioObjectPropertyAddress>,
                                   _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                                   _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDevices:
        size.pointee = UInt32((dongleID == nil ? 1 : 2) * MemoryLayout<AudioDeviceID>.size)
    case kAudioDevicePropertyStreams:
        size.pointee = UInt32(MemoryLayout<AudioStreamID>.size)
    case kAudioDevicePropertyAvailableNominalSampleRates:
        size.pointee = UInt32(2 * MemoryLayout<AudioValueRange>.size)
    default:
        preconditionFailure("Unexpected property size query")
    }
    return noErr
}

func AudioObjectGetPropertyData(_ object: AudioObjectID,
                               _ address: UnsafePointer<AudioObjectPropertyAddress>,
                               _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                               _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    func copy<Value>(_ value: Value) {
        withUnsafeBytes(of: value) { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice:
        copy(defaultOutputID)
    case kAudioHardwarePropertyDevices:
        let ids = [AudioDeviceID(2)] + (dongleID.map { [$0] } ?? [])
        ids.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    case kAudioObjectPropertyName:
        copy(Unmanaged.passRetained((object == 2 ? "MacBook speakers" : "BTD 700") as CFString))
    case kAudioDevicePropertyDeviceUID:
        copy(Unmanaged.passRetained((object == 2 ? "BuiltInSpeakerDevice" : "TestDongle") as CFString))
    case kAudioDevicePropertyTransportType:
        copy(object == 2 ? kAudioDeviceTransportTypeBuiltIn : kAudioDeviceTransportTypeUSB)
    case kAudioDevicePropertyNominalSampleRate:
        copy(nominalRate)
    case kAudioDevicePropertyAvailableNominalSampleRates:
        let ranges = [AudioValueRange(mMinimum: 48_000, mMaximum: 48_000),
                      AudioValueRange(mMinimum: 96_000, mMaximum: 96_000)]
        ranges.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    default:
        preconditionFailure("Unexpected property read")
    }
    return noErr
}

func AudioObjectSetPropertyData(_ object: AudioObjectID,
                               _ address: UnsafePointer<AudioObjectPropertyAddress>,
                               _ qualifierSize: UInt32, _ qualifier: UnsafeRawPointer?,
                               _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    preconditionFailure("Observation must not change the audio route or sample rate")
}

@main
struct AudioObservationTests {
    @MainActor
    static func notify(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) async {
        for observation in observations.filter({ $0.object == object && $0.address.mSelector == selector }) {
            var address = observation.address
            withUnsafePointer(to: &address) { observation.block(1, $0) }
        }
        try! await Task.sleep(nanoseconds: 10_000_000)
    }

    @MainActor
    static func main() async {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var audio: AudioOutputSwitcher? = AudioOutputSwitcher()
        weak var released = audio
        audio!.start()
        audio!.start()
        audio!.refresh()
        precondition(installAttempts == 1, "start must be idempotent when the shortcut handler fails")
        precondition(observations.count == 3, "Expected two system listeners and one dongle rate listener")
        precondition(audio!.outputName == "MacBook speakers")
        precondition(audio!.dongleRate == 48_000 && audio!.dongleRates == [48_000, 96_000])

        defaultOutputID = 42
        await notify(system, kAudioHardwarePropertyDefaultOutputDevice)
        precondition(audio!.outputName == "BTD 700", "An external output change must still refresh its name")
        defaultOutputID = 2
        await notify(system, kAudioHardwarePropertyDefaultOutputDevice)
        precondition(audio!.outputName == "MacBook speakers")

        nominalRate = 96_000
        await notify(42, kAudioDevicePropertyNominalSampleRate)
        precondition(audio!.dongleRate == 96_000, "An external sample rate change must refresh the UI model")
        precondition(observations.count == 3, "Refreshing an existing dongle must not duplicate listeners")

        dongleID = nil
        await notify(system, kAudioHardwarePropertyDevices)
        precondition(audio!.dongleRate == nil && audio!.dongleRates.isEmpty, "Unplugging must clear rate controls")
        precondition(observations.count == 2 && observations.allSatisfy { $0.object == system })

        dongleID = 43
        nominalRate = 48_000
        failRateRegistration = true
        await notify(system, kAudioHardwarePropertyDevices)
        precondition(audio!.dongleRate == 48_000 && observations.count == 2)
        audio!.refresh()
        precondition(observations.count == 3 && observations.contains { $0.object == 43 })
        nominalRate = 96_000
        await notify(43, kAudioDevicePropertyNominalSampleRate)
        precondition(audio!.dongleRate == 96_000, "Replugging with a new device ID must observe the new device")

        audio = nil
        precondition(released == nil, "CoreAudio callbacks must not retain the switcher")
        released = nil
        precondition(observations.isEmpty, "Deinit must remove every successfully registered listener")
        print("Audio observation tests passed. External rate changes, unplug/replug, idempotent start, retry, and cleanup.")
    }
}
