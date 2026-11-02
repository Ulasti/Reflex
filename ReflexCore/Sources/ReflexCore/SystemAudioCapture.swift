#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Passive capture of the Mac's system audio output via a Core Audio process
/// tap (macOS 14.2+). No virtual audio driver required. The tap is private
/// and unmuted, so normal playback is unaffected.
///
/// Delivers 16 kHz mono Float32 sample batches via `start()`'s AsyncStream,
/// matching the microphone pipeline's format. Requires the "System Audio
/// Recording" TCC permission (prompted on first use).
@available(macOS 14.2, *)
public final class SystemAudioCapture: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case unsupportedOS
        case tapCreationFailed(OSStatus)
        case formatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case converterUnavailable

        public var errorDescription: String? {
            switch self {
            case .unsupportedOS: "System audio capture requires macOS 14.2+."
            case .tapCreationFailed(let s): "Tap creation failed: \(s)."
            case .formatUnreadable(let s): "Tap format unreadable: \(s)."
            case .aggregateCreationFailed(let s): "Aggregate device creation failed: \(s)."
            case .ioProcCreationFailed(let s): "IO proc creation failed: \(s)."
            case .deviceStartFailed(let s): "Device start failed: \(s)."
            case .converterUnavailable: "Audio format converter unavailable."
            }
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private let lock = NSLock()
    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    public init() {}

    /// Start capturing. Returns a stream of 16 kHz mono Float32 batches.
    /// The stream ends when `stop()` is called.
    public func start() throws -> AsyncStream<[Float]> {
        guard #available(macOS 14.2, *) else { throw CaptureError.unsupportedOS }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "ReflexSystemTap"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = newTap

        // Read tap format
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw CaptureError.formatUnreadable(fmtStatus)
        }
        tapFormat = fmt
        guard let conv = AVAudioConverter(from: fmt, to: targetFormat) else {
            cleanup()
            throw CaptureError.converterUnavailable
        }
        converter = conv

        // Read tap UID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var tapUID: CFString = "" as CFString
        AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUID)

        // Create private aggregate device containing only the tap
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReflexSystemAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var newAgg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard aggStatus == noErr else {
            cleanup()
            throw CaptureError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAgg

        let stream = AsyncStream<[Float]> { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
        }

        // Create IO proc
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(aggregateID, { (device, now, inputData, inputTime, outputData, outputTime, clientData) -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let self_ = Unmanaged<SystemAudioCapture>.fromOpaque(clientData).takeUnretainedValue()
            self_.handleIO(inputData)
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque(), &procID)
        guard ioStatus == noErr, let pid = procID else {
            cleanup()
            throw CaptureError.ioProcCreationFailed(ioStatus)
        }
        ioProcID = pid

        let startStatus = AudioDeviceStart(aggregateID, pid)
        guard startStatus == noErr else {
            cleanup()
            throw CaptureError.deviceStartFailed(startStatus)
        }

        return stream
    }

    private func handleIO(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let fmt = tapFormat, let conv = converter else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let ab = bufferList.first, let data = ab.mData, ab.mDataByteSize > 0 else { return }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inputData, deallocator: nil) else { return }
        pcm.frameLength = ab.mDataByteSize / UInt32(fmt.streamDescription.pointee.mBytesPerFrame)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * 16000.0 / fmt.sampleRate) + 1024) else { return }
        var error: NSError?
        let status = conv.convert(to: outBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, error == nil, outBuffer.frameLength > 0 else { return }
        guard let channelData = outBuffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
        lock.lock()
        continuation?.yield(samples)
        lock.unlock()
    }

    public func stop() {
        if let pid = ioProcID {
            AudioDeviceStop(aggregateID, pid)
            AudioDeviceDestroyIOProcID(aggregateID, pid)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { stop() }
}
#endif
