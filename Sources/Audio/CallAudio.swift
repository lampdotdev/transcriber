import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What this Mac plays through its speakers or headphones (the other side of a Zoom or Meet call), heard
/// with ScreenCaptureKit's audio capture. Only sound is used; the screen is asked for at the smallest size
/// and slowest rate it allows and thrown away. This app's own sound (playing back a recording) is left out.
final class CallAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Every buffer handed on is in this format, so a file and a transcriber can be set up before any arrive.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// Called on the capture queue with each buffer, in order, and the host-clock time of its first sample.
    private let received: @Sendable (AVAudioPCMBuffer, Double) -> Void
    /// Called if macOS stops the capture partway (the permission was turned off, the display went away).
    private let ended: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "Transcriber.callAudio")
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    /// Where the next buffer should start; a later one means the system sent nothing for a while (silence).
    private var expected: Double?

    init(received: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void, ended: @escaping @Sendable (String) -> Void) {
        self.received = received
        self.ended = ended
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CallAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(Self.format.sampleRate)
        configuration.channelCount = Int(Self.format.channelCount)
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // Frames come whether wanted or not; without somewhere to go, each one is logged as dropped.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let raw = Self.pcm(from: sampleBuffer),
              let buffer = conform(raw) else { return }
        let start = sampleBuffer.presentationTimeStamp.seconds
        guard start.isFinite else { return }
        let rate = Self.format.sampleRate
        // Keep the call's audio in step with the microphone: fill a stretch nothing was sent for with silence.
        if let expected, start - expected > 0.05 {
            var gap = min(start - expected, 3600)
            var at = expected
            while gap > 0.001 {
                let seconds = min(gap, 10)
                let frames = AVAudioFrameCount(seconds * rate)
                guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames) else { break }
                silence.frameLength = frames   // a new buffer is zeroed
                received(silence, at)
                at += seconds
                gap -= seconds
            }
        }
        expected = start + Double(buffer.frameLength) / rate
        received(buffer, start)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ended("The call audio stopped partway: \(error.localizedDescription)")
    }

    /// The sample buffer's audio as a PCM buffer in whatever format the system sent.
    private static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// The buffer in `format`, converting only when the system sent something else.
    private func conform(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == Self.format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && converted.frameLength > 0 ? converted : nil
    }
}

enum CallAudioError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "No display was found to capture the call's sound from." }
}

/// Puts the microphone and the call into the one audio file a recording plays back, each at the right moment.
enum Mixdown {
    /// `callOffset` is how many seconds after the microphone's first sound the call's first sound came
    /// (negative when the call started first, which trims that much off its beginning).
    static func mix(microphone: URL, call: URL, callOffset: Double, into output: URL) async -> Bool {
        let composition = AVMutableComposition()
        do {
            let parts: [(URL, skip: Double, at: Double)] = [
                (microphone, 0, 0),
                (call, max(0, -callOffset), max(0, callOffset)),
            ]
            for part in parts {
                let asset = AVURLAsset(url: part.0)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                let skip = CMTime(seconds: part.skip, preferredTimescale: 48_000)
                guard duration > skip,
                      let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(CMTimeRange(start: skip, end: duration), of: source,
                                          at: CMTime(seconds: part.at, preferredTimescale: 48_000))
            }
        } catch {
            print("Transcriber: couldn't mix the call into the recording: \(error)")
            return false
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return false }
        export.outputURL = output
        export.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            print("Transcriber: mixing the call into the recording failed: \(String(describing: export.error))")
        }
        return export.status == .completed
    }
}

/// Whether what the Mac plays could reach its microphone: only then can the microphone hear the call, so only then
/// is a line of yours that repeats the call's taken for an echo. Headphones (the Mac's own headphone jack, or a
/// Bluetooth headset) can't be heard; anything else may be a speaker.
enum OutputDevice {
    static var mayEcho: Bool {
        guard let device = defaultOutput else { return true }
        let transport = value(kAudioDevicePropertyTransportType, of: device, scope: kAudioObjectPropertyScopeGlobal)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return false }
        if transport == kAudioDeviceTransportTypeBuiltIn {
            // The built-in output says which of its sources plays: the speakers ('ispk') or the headphone jack ('hdpn').
            let source = value(kAudioDevicePropertyDataSource, of: device, scope: kAudioDevicePropertyScopeOutput)
            return source != 0x6864_706E   // 'hdpn'
        }
        return true
    }

    private static var defaultOutput: AudioObjectID? {
        let id = value(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject),
                       scope: kAudioObjectPropertyScopeGlobal)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : AudioObjectID($0) }
    }

    private static func value(_ selector: AudioObjectPropertySelector, of object: AudioObjectID,
                              scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
