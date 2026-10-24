#if os(macOS)
import AVFoundation
import CoreAudio

public struct MicDevice: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public enum MicPicker {
    public static func list() -> [MicDevice] {
        var devices: [MicDevice] = []
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return devices }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return devices }
        for id in ids {
            var nameSize: UInt32 = 0
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
            guard AudioObjectGetPropertyDataSize(id, &nameAddr, 0, nil, &nameSize) == noErr else { continue }
            // CoreAudio writes a +1 CFStringRef into this slot. Reading it back
            // through a raw pointer keeps the compiler from warning about
            // forming a pointer to an object reference.
            var nameRef: UnsafeMutableRawPointer?
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr else { continue }
            let name = nameRef.map { Unmanaged<CFString>.fromOpaque($0).takeRetainedValue() as String } ?? ""
            devices.append(MicDevice(id: String(id), name: name, isDefault: false))
        }
        return devices
    }
}
#endif
