import AudioToolbox
import CoreAudio
import Foundation
import TransportCore

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let rates: [Int]
}
struct OutputVolumeStatus: Equatable {
    let volume: Float?
    let muted: Bool

    var needsAttention: Bool {
        muted || (volume.map { $0 < 0.999 } ?? false)
    }
}
struct AudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioError(message: "\(operation) failed (OSStatus \(status)).") }
}

final class AudioOutputEngine {
    private var unit: AudioUnit?
    private(set) var renderer: OpaquePointer?
    private(set) var device: AudioDeviceID = 0
    private(set) var sampleRate = 96000

    static func nominalRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0; var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
    static func outputVolumeStatus(_ device: AudioDeviceID) -> OutputVolumeStatus {
        func scalar(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }
        func flag(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        }

        let master = scalar(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)].compactMap {
            scalar(kAudioDevicePropertyVolumeScalar, element: $0)
        }
        let volume = master ?? channels.min()
        let muted = flag(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
            ?? [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)].contains {
                flag(kAudioDevicePropertyMute, element: $0) == true
            }
        return OutputVolumeStatus(volume: volume, muted: muted)
    }
    static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var config = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &config, 0, nil, &configSize) == noErr, configSize > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(id, &config, 0, nil, &configSize, memory) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + $1.mNumberChannels }) >= 2 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &nameRef) { AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, $0) }
            let name = nameRef?.takeRetainedValue() as String? ?? "Audio device"
            var ratesAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var ratesSize: UInt32 = 0
            _ = AudioObjectGetPropertyDataSize(id, &ratesAddress, 0, nil, &ratesSize)
            var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(ratesSize) / MemoryLayout<AudioValueRange>.size)
            if !ranges.isEmpty { _ = AudioObjectGetPropertyData(id, &ratesAddress, 0, nil, &ratesSize, &ranges) }
            let rates = [96000, 192000].filter { rate in ranges.contains { Double(rate) >= $0.mMinimum && Double(rate) <= $0.mMaximum } }
            return AudioDevice(id: id, name: name, rates: rates)
        }
    }
    static func defaultDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    func start(device: AudioDeviceID, rate: Int, amplitude: Float, reversed: Bool, idleBits: Int, messageIntervalMS: Double) throws {
        stop()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var desired = Double(rate)
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &desired), "Request \(rate) Hz")
        // Device changes may settle asynchronously; never render with an assumed rate.
        for _ in 0..<50 {
            if abs(Self.nominalRate(device) - desired) < 1 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard abs(Self.nominalRate(device) - desired) < 1 else {
            throw AudioError(message: "The device did not switch to \(rate) Hz. Select a supported device/rate in Audio MIDI Setup.")
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioError(message: "HAL output is unavailable.") }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "Create HAL output")
        guard let created else { throw AudioError(message: "HAL output creation returned no instance.") }
        unit = created
        do {
            var selected = device
            try check(AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select output device")
            var format = AudioStreamBasicDescription(mSampleRate: desired, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set stereo PCM format")
            var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
            guard let renderer = aj_create(UInt32(rate), 1e9 * Double(info.denom) / Double(info.numer)) else {
                throw AudioError(message: "Unable to allocate the audio renderer.")
            }
            self.renderer = renderer
            aj_configure(renderer, amplitude, reversed, UInt32(idleBits))
            aj_set_message_interval(renderer, messageIntervalMS)
            var callback = AURenderCallbackStruct(inputProc: aj_callback(), inputProcRefCon: UnsafeMutableRawPointer(renderer))
            try check(AudioUnitSetProperty(created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install renderer")
            try check(AudioUnitInitialize(created), "Initialize audio")
            try check(AudioOutputUnitStart(created), "Start audio")
            self.device = device; sampleRate = rate
        } catch { stop(); throw error }
    }
    func stop() {
        if let unit {
            AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        if let renderer { aj_destroy(renderer); self.renderer = nil }
        device = 0
    }
    deinit { stop() }
}
