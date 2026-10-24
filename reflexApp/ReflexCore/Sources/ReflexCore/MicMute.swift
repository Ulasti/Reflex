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
    /// Mutes `deviceID` (nil = the system default input) and returns the input
    /// level that was in use, so `restoreInput` can put it back. Reading the
    /// real scalar matters: restoring a hardcoded 1.0 silently resets the
    /// user's mic gain on every command (audit M5).
    @discardableResult
    public static func muteInput(_ deviceID: UInt32? = nil) -> Float32? {
        let saved = inputVolume(deviceID)
        setInputVolume(0, deviceID: deviceID)
        return saved
    }

    /// Re-arms the input at the level `muteInput` found. Falls back to 1.0 when
    /// the device would not report a level, so the mic is never left silent.
    public static func restoreInput(_ deviceID: UInt32? = nil, to level: Float32?) {
        setInputVolume(level ?? 1.0, deviceID: deviceID)
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func inputVolume(_ deviceID: UInt32?) -> Float32? {
        guard let target = deviceID ?? defaultInputDeviceID() else { return nil }
        var address = volumeAddress()
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        guard AudioObjectGetPropertyData(
            AudioObjectID(target), &address, 0, nil, &size, &value
        ) == noErr else { return nil }
        return value
    }

    private static func setInputVolume(_ volume: Float32, deviceID: UInt32?) {
        guard let target = deviceID ?? defaultInputDeviceID() else { return }
        var address = volumeAddress()
        var value = volume
        _ = AudioObjectSetPropertyData(
            AudioObjectID(target), &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
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
}

#endif
