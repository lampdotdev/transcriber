import AVFoundation
import Foundation
import Speech

/// SFSpeechRecognizer, on the device only, for Macs before macOS 26. One recognition request is meant for
/// about a minute of speech, so a long recording is sent as a run of requests, a new one every
/// `stretch` seconds, each placed at its offset in the recording.
final class ClassicTranscriber: Transcriber, @unchecked Sendable {
    private static let stretch: TimeInterval = 50
    /// A pause this long starts a new line in the transcript.
    private static let pause: TimeInterval = 0.9
    private static let wordsPerLine = 28

    private let recognizer: SFSpeechRecognizer
    private let collector: TranscriptCollector
    private let sampleRate: Double
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var requestStart: TimeInterval = 0
    private var heard: TimeInterval = 0
    private var stretches = 0
    private let pending = DispatchGroup()

    static func start(format: AVAudioFormat, into collector: TranscriptCollector) async throws -> ClassicTranscriber {
        guard await Permissions.speechRecognition() else { throw TranscriptionError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unsupportedLanguage
        }
        guard recognizer.isAvailable else { throw TranscriptionError.unavailable }
        let transcriber = ClassicTranscriber(recognizer: recognizer, collector: collector, sampleRate: format.sampleRate)
        transcriber.lock.withLock { transcriber.beginStretch() }
        return transcriber
    }

    private init(recognizer: SFSpeechRecognizer, collector: TranscriptCollector, sampleRate: Double) {
        self.recognizer = recognizer
        self.collector = collector
        self.sampleRate = sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if heard - requestStart >= Self.stretch {
                request?.endAudio()
                beginStretch()
            }
            request?.append(buffer)
            heard += Double(buffer.frameLength) / sampleRate
        }
    }

    func finish() async {
        lock.withLock {
            request?.endAudio()
            request = nil
        }
        // Recognition of the last stretch ends on its own; don't hold the recording up long for it.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            pending.notify(queue: .global()) { once.run { continuation.resume() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.run { continuation.resume() } }
        }
    }

    /// Called with the lock held.
    private func beginStretch() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        requestStart = heard
        stretches += 1
        let offset = heard, source = stretches, collector = collector
        let ended = Once()
        pending.enter()
        recognizer.recognitionTask(with: request) { [pending] result, error in
            if let result {
                let lines = Self.lines(from: result.bestTranscription, offset: offset)
                if result.isFinal {
                    collector.commit(lines, source: source)
                } else {
                    collector.setVolatile(result.bestTranscription.formattedString,
                                          start: lines.first?.start ?? offset, source: source)
                }
            }
            if result?.isFinal == true || error != nil { ended.run { pending.leave() } }
        }
    }

    /// Splits what was heard into lines at pauses, so each line can be played from where it starts.
    private static func lines(from transcription: SFTranscription, offset: TimeInterval) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var words: [String] = []
        var start = offset, lastEnd = offset
        for segment in transcription.segments {
            let at = offset + segment.timestamp
            if !words.isEmpty, at - lastEnd > pause || words.count >= wordsPerLine {
                lines.append(TranscriptLine(start: start, text: words.joined(separator: " ")))
                words = []
            }
            if words.isEmpty { start = at }
            words.append(segment.substring)
            lastEnd = at + segment.duration
        }
        if !words.isEmpty { lines.append(TranscriptLine(start: start, text: words.joined(separator: " "))) }
        return lines
    }
}

/// Runs its closure the first time only, whichever thread gets there first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ work: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { work() }
    }
}
