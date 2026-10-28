import AVFoundation
import CoreMedia
import Foundation
import Speech

// SpeechAnalyzer's names exist only in Xcode 26's SDK: an older toolchain builds the app without this transcriber
// (the compiler says which), and `Transcription.start` goes straight to the classic one.
#if compiler(>=6.2)
/// SpeechAnalyzer with SpeechTranscriber (macOS 26 and later): on-device transcription made for long
/// audio such as meetings and lectures. Each result it gives is a phrase with its time in the recording,
/// which becomes one line of the transcript.
@available(macOS 26.0, *)
final class AnalyzerTranscriber: Transcriber, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let results: Task<Void, Never>

    static func start(format inputFormat: AVAudioFormat, into collector: TranscriptCollector,
                      preparing: @escaping @Sendable (String?) -> Void) async throws -> AnalyzerTranscriber {
        // Asked for so the person's choice in System Settings is respected; recognition stays on the device.
        _ = await Permissions.speechRecognition()
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptionError.unsupportedLanguage
        }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults], attributeOptions: [])
        // The speech model for a language is downloaded once, the first time it's needed.
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            preparing("Getting transcription ready on this Mac…")
            try await download.downloadAndInstall()
            preparing(nil)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.unavailable
        }
        let results = Task {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = max(0, result.range.start.seconds.isFinite ? result.range.start.seconds : 0)
                    if result.isFinal {
                        collector.commit([TranscriptLine(start: start, text: text)], source: 0)
                    } else {
                        collector.setVolatile(text, start: start, source: 0)
                    }
                }
            } catch {
                print("Transcriber: transcription ended early: \(error)")
            }
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.start(inputSequence: stream)
        return AnalyzerTranscriber(analyzer: analyzer, input: input, format: format, inputFormat: inputFormat, results: results)
    }

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat,
                 inputFormat: AVAudioFormat, results: Task<Void, Never>) {
        self.analyzer = analyzer
        self.input = input
        self.format = format
        self.results = results
        if inputFormat == format {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // Without priming the converter would shift every timestamp a little.
            converter?.primeMethod = .none
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
        if status != .error, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }
}
#endif
