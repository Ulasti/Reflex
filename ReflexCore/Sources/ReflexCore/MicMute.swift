#if os(macOS)
import AVFoundation
import CoreAudio

/// Hardware-level muting of the active input device around sounds the app
/// itself produces (feedback dings, TTS). A software cooldown can only go so
/// far: the feedback bell is loud enough to trip the energy-based VAD even
/// with the cooldown, and a long cooldown makes the app feel sluggish. Setting
/// the input device's hardware volume to zero for the duration of the playback
/// is the only thing that actually removes the sound from the microphone path.
///
/// All calls are best-effort: if CoreAudio or the device is unavailable we
/// simply skip the mute and rely on the cooldown.
public enum MicMute {
    public static func muteInput(_ deviceID: UInt32? = nil, _ on: Bool) {
        let target = deviceID ?? defaultInputDeviceID()
        guard let target else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = on ? 0.0 : 1.0
        _ = AudioObjectSetPropertyData(
            AudioObjectID(target), &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
    }

    public static func withInputMuted<T>(_ deviceID: UInt32?, _ work: () throws -> T) rethrows -> T {
        muteInput(deviceID, true)
        defer { muteInput(deviceID, false) }
        return try work()
    }

    private static func defaultInputDeviceID() -> UInt32? {
        var deviceID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func setGlobalInputVolume(_ volume: Float32) -> OSStatus { noErr }
}

#endif
