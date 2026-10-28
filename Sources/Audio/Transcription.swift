import AVFoundation
import Foundation
import Speech

/// Speech to text while recording, always on this Mac: nothing is sent anywhere to be transcribed.
/// macOS 26 and later use SpeechAnalyzer, which is made for long recordings; earlier ones, or a Mac or
/// language it doesn't cover, use SFSpeechRecognizer with on-device recognition required.
protocol Transcriber: AnyObject {
    /// Called on the audio thread with each buffer the microphone gives, in order.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio: waits (briefly) for the last words to be recognized.
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case notAllowed
    case unsupportedLanguage
    case unavailable

    var errorDescription: String? {
        let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "") ?? "this language"
        switch self {
        case .notAllowed: return "Speech Recognition is off for this app in System Settings, so only the audio was kept."
        case .unsupportedLanguage: return "This Mac can't transcribe \(language) on the device, so only the audio was kept."
        case .unavailable: return "Transcription isn't available right now, so only the audio was kept."
        }
    }
}

enum Transcription {
    /// Starts the best transcriber this Mac has for audio in `format`. `preparing` reports a one-time
    /// download of the speech model (nil once it's done).
    static func start(format: AVAudioFormat, into collector: TranscriptCollector,
                      preparing: @escaping @Sendable (String?) -> Void) async throws -> Transcriber {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            do {
                return try await AnalyzerTranscriber.start(format: format, into: collector, preparing: preparing)
            } catch {
                preparing(nil)
                print("Transcriber: SpeechAnalyzer couldn't start (\(error)); trying SFSpeechRecognizer")
            }
        }
        #endif
        return try await ClassicTranscriber.start(format: format, into: collector)
    }
}

/// Gathers what the transcribers hear, from whichever thread they report on, and passes each change on
/// for the live view. Lines that are final are kept; the words still being recognized are `volatile`.
final class TranscriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [TranscriptLine] = []
    private var volatile: (text: String, start: TimeInterval, source: Int)?
    private let changed: @Sendable ([TranscriptLine], String) -> Void
    /// Who every line gathered here was said by, when the recording tells the microphone and the call apart.
    private let speaker: Speaker?

    init(speaker: Speaker? = nil, changed: @escaping @Sendable ([TranscriptLine], String) -> Void) {
        self.speaker = speaker
        self.changed = changed
    }

    /// `source` tells apart the stretches of audio one transcriber sends separately, so finishing one
    /// stretch doesn't clear words still being recognized in the next.
    func commit(_ new: [TranscriptLine], source: Int) {
        update {
            lines.append(contentsOf: new.filter { !$0.text.isEmpty }.map { line in
                var line = line
                line.speaker = speaker
                return line
            })
            lines.sort { $0.start < $1.start }
            if volatile?.source == source { volatile = nil }
        }
    }

    func setVolatile(_ text: String, start: TimeInterval, source: Int) {
        update { volatile = text.isEmpty ? nil : (text, start, source) }
    }

    /// Everything heard, with words never confirmed as final kept as a last line rather than lost.
    func finished() -> [TranscriptLine] {
        lock.withLock {
            guard let volatile else { return lines }
            return lines + [TranscriptLine(start: volatile.start, text: volatile.text, speaker: speaker)]
        }
    }

    private func update(_ change: () -> Void) {
        let snapshot: ([TranscriptLine], String) = lock.withLock {
            change()
            return (lines, volatile?.text ?? "")
        }
        changed(snapshot.0, snapshot.1)
    }
}
