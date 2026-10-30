import AVFoundation
import Foundation

/// One recording in progress: the microphone goes to an audio file in the app's data folder and to the
/// transcriber at the same time, and the level and words heard so far are published for the live view.
/// With call audio on, what plays through the speakers or headphones is recorded and transcribed alongside
/// it, separately, so lines can be told apart as You (the microphone) and Them (the call); the two are
/// mixed into one file when the recording stops.
@MainActor
final class RecordingSession: ObservableObject {
    enum Phase { case idle, starting, recording, finishing }

    /// What stops a recording from starting, shown in place of the Record button's hint.
    enum Problem: Equatable {
        case permission(Permissions.Kind)
        case noMicrophone
        case failed(String)
    }

    /// The setting (on the recorder) for recording the call's sound too.
    static let callAudioKey = "includeCallAudio"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// The last few seconds of loudness, 0…1, oldest first: drawn as the level meter.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: RecordingSession.meterLength)
    @Published private(set) var lines: [TranscriptLine] = []
    /// For each reading in `levels`, 0…1: how much of it was the call (Them) rather than the microphone (You).
    @Published private(set) var callShares: [Float] = Array(repeating: 0, count: RecordingSession.meterLength)
    @Published private(set) var volatileText = ""
    /// A one-time wait before recording, such as the speech model downloading.
    @Published private(set) var preparing: String?
    @Published var problem: Problem?
    /// Why this recording has no transcript (or stopped having one), when that happened.
    @Published private(set) var transcriptNote: String?
    /// Why the call's sound isn't being recorded though it was asked for.
    @Published private(set) var callNote: String?
    /// Whether the call's sound is being recorded right now.
    @Published private(set) var hearingCall = false

    static let meterLength = 140

    private var engine: AVAudioEngine?
    private var transcriber: Transcriber?
    private var collector: TranscriptCollector?
    private var writer: AudioWriter?
    private var fileName: String?

    private var callAudio: CallAudio?
    private var callTranscriber: Transcriber?
    private var callCollector: TranscriptCollector?
    private var callWriter: AudioWriter?
    private var callFileName: String?
    private var clock = StreamClock()
    /// Whether the call played where the microphone could hear it, at any point: only then are echoes looked for.
    private var mayEcho = false
    private var callLevel: Float = 0

    private var micLines: [TranscriptLine] = []
    private var micVolatile = ""
    private var callLines: [TranscriptLine] = []
    private var callVolatile = ""

    var isRecording: Bool { phase == .recording }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        problem = nil
        transcriptNote = nil
        callNote = nil
        hearingCall = false
        mayEcho = false
        micLines = []; micVolatile = ""; callLines = []; callVolatile = ""
        lines = []
        volatileText = ""
        levels = Array(repeating: 0, count: RecordingSession.meterLength)
        callShares = Array(repeating: 0, count: RecordingSession.meterLength)
        clock = StreamClock()

        if LampShowcase.isOn {
            startedAt = Date()
            phase = .recording
            Task { await playScript() }
            return
        }
        guard await Permissions.microphone() else { return fail(.permission(.microphone)) }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return fail(.noMicrophone) }

        let wantsCall = UserDefaults.standard.bool(forKey: Self.callAudioKey)
        let canHearCall = wantsCall && LampPermissions.has(.screenRecording)
        if wantsCall && !canHearCall {
            callNote = "Call audio is off until Screen & System Audio Recording is allowed for Transcriber."
        }

        let name = "\(UUID().uuidString).m4a"
        let writer: AudioWriter
        do {
            writer = try AudioWriter(url: Library.audioFolder.appendingPathComponent(name), format: format)
        } catch {
            return fail(.failed("The recording couldn't be saved: \(error.localizedDescription)"))
        }

        let collector = TranscriptCollector(speaker: canHearCall ? .me : nil) { [weak self] lines, volatile in
            Task { @MainActor in self?.heardMicrophone(lines, volatile) }
        }
        do {
            transcriber = try await Transcription.start(format: format, into: collector) { [weak self] message in
                Task { @MainActor in self?.preparing = message }
            }
        } catch {
            // Recording goes on without a transcript: the audio is still worth keeping.
            transcriptNote = error.localizedDescription
            preparing = nil
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format,
                                    block: Self.tap(writer: writer, transcriber: transcriber, clock: clock) { [weak self] level in
            Task { @MainActor in self?.addLevel(level) }
        })
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            await transcriber?.finish()
            transcriber = nil
            writer.close()
            try? FileManager.default.removeItem(at: Library.audioFolder.appendingPathComponent(name))
            return fail(.failed("The microphone couldn't start: \(error.localizedDescription)"))
        }
        self.engine = engine
        self.collector = collector
        self.writer = writer
        fileName = name
        if canHearCall { await startCall() }
        startedAt = Date()
        phase = .recording
    }

    /// Starts hearing the call. If it can't, the recording goes on with the microphone alone.
    private func startCall() async {
        let format = CallAudio.format
        let name = "\(UUID().uuidString)-call.m4a"
        let url = Library.audioFolder.appendingPathComponent(name)
        guard let writer = try? AudioWriter(url: url, format: format) else {
            callNote = "The call's sound couldn't be saved, so only the microphone is recorded."
            return
        }
        let collector = TranscriptCollector(speaker: .them) { [weak self] lines, volatile in
            Task { @MainActor in self?.heardCall(lines, volatile) }
        }
        let transcriber = try? await Transcription.start(format: format, into: collector) { _ in }
        let audio = CallAudio(
            received: Self.callSink(writer: writer, transcriber: transcriber, clock: clock) { [weak self] level in
                Task { @MainActor in self?.callLevel = max(self?.callLevel ?? 0, level) }
            },
            ended: { [weak self] message in
                Task { @MainActor in
                    self?.callNote = message
                    self?.hearingCall = false
                }
            })
        do {
            try await audio.start()
        } catch {
            await transcriber?.finish()
            writer.close()
            try? FileManager.default.removeItem(at: url)
            callNote = "The call's sound couldn't be recorded (\(error.localizedDescription)), so only the microphone is."
            print("Transcriber: call audio couldn't start: \(error)")
            return
        }
        callAudio = audio
        callTranscriber = transcriber
        callCollector = collector
        callWriter = writer
        callFileName = name
        mayEcho = OutputDevice.mayEcho
        hearingCall = true
    }

    /// Stops, waits for the last words, and returns the finished recording for the library to keep.
    func stop() async -> Recording? {
        if LampShowcase.isOn, phase == .recording, let startedAt {
            let recording = Recording(title: "Recording, " + startedAt.formatted(date: .abbreviated, time: .shortened),
                                      date: startedAt, duration: Date().timeIntervalSince(startedAt), lines: micLines)
            hearingCall = false
            volatileText = ""
            self.startedAt = nil
            phase = .idle
            return recording
        }
        guard phase == .recording, let engine, let startedAt, let fileName else { return nil }
        phase = .finishing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await callAudio?.stop()
        await transcriber?.finish()
        await callTranscriber?.finish()
        writer?.close()
        callWriter?.close()

        var audioFileName = fileName
        var callAudioFileName: String?
        var heard: [TranscriptLine]
        if let callCollector, let callFileName {
            mayEcho = mayEcho || OutputDevice.mayEcho
            heard = Self.merge(microphone: collector?.finished() ?? micLines, call: callCollector.finished(),
                               callOffset: clock.callOffset, mayEcho: mayEcho)
            let callURL = Library.audioFolder.appendingPathComponent(callFileName)
            if callWriter?.wroteAny == true {
                let mixedName = "\(UUID().uuidString).m4a"
                let micURL = Library.audioFolder.appendingPathComponent(fileName)
                if await Mixdown.mix(microphone: micURL, call: callURL, callOffset: clock.callOffset,
                                     into: Library.audioFolder.appendingPathComponent(mixedName)) {
                    try? FileManager.default.removeItem(at: micURL)
                    try? FileManager.default.removeItem(at: callURL)
                    audioFileName = mixedName
                } else {
                    // The only copy of the other side: kept beside the recording rather than lost.
                    callAudioFileName = callFileName
                }
            } else {
                try? FileManager.default.removeItem(at: callURL)
            }
        } else {
            // Without the call there's no one to tell apart.
            heard = (collector?.finished() ?? micLines).map { line in
                var line = line
                line.speaker = nil
                return line
            }
        }

        let recording = Recording(
            title: "Recording, " + startedAt.formatted(date: .abbreviated, time: .shortened),
            date: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            lines: heard,
            audioFileName: audioFileName,
            callAudioFileName: callAudioFileName,
            transcriptNote: heard.isEmpty ? (transcriptNote ?? "No speech was heard.") : transcriptNote)
        self.engine = nil
        transcriber = nil
        collector = nil
        writer = nil
        self.fileName = nil
        callAudio = nil
        callTranscriber = nil
        self.callCollector = nil
        callWriter = nil
        self.callFileName = nil
        hearingCall = false
        self.startedAt = nil
        phase = .idle
        return recording
    }

    /// A reel's take (`LampShowcase`): the script's `lines.transcript` heard word by word in place of the microphone
    /// and the call, each from You or Them by its `speaker`, with the meter moving in that side's color.
    private func playScript() async {
        let script = (LampShowcase.script["lines"] as? [String: Any])?["transcript"] as? [[String: Any]] ?? []
        for entry in script {
            guard phase == .recording, let startedAt, let text = entry["text"] as? String else { return }
            let speaker: Speaker = entry["speaker"] as? String == "them" ? .them : .me
            let start = Date().timeIntervalSince(startedAt)
            var words: [Substring] = []
            for word in text.split(separator: " ") {
                words.append(word)
                volatileText = words.joined(separator: " ")
                for _ in 0..<3 {
                    guard phase == .recording else { return }
                    hearingCall = true
                    callLevel = speaker == .them ? Float.random(in: 0.35...0.85) : 0
                    addLevel(speaker == .me ? Float.random(in: 0.35...0.85) : 0)
                    try? await Task.sleep(for: .seconds(LampShowcase.wordTime / 3))
                }
            }
            micLines.append(TranscriptLine(start: start, text: text, speaker: speaker))
            lines = micLines
            volatileText = ""
            for _ in 0..<4 {
                guard phase == .recording else { return }
                addLevel(0)
                try? await Task.sleep(for: .seconds(0.1))
            }
        }
    }

    private func fail(_ problem: Problem) {
        self.problem = problem
        phase = .idle
    }

    func heardMicrophone(_ lines: [TranscriptLine], _ volatile: String) {
        micLines = lines
        micVolatile = volatile
        publishLines()
    }

    func heardCall(_ lines: [TranscriptLine], _ volatile: String) {
        callLines = lines
        callVolatile = volatile
        publishLines()
    }

    func publishLines() {
        lines = callCollector == nil && callLines.isEmpty
            ? micLines
            : Self.merge(microphone: micLines, call: callLines, callOffset: clock.callOffset, mayEcho: mayEcho)
        volatileText = [micVolatile, callVolatile].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func addLevel(_ level: Float) {
        guard phase == .recording else { return }
        levels.removeFirst()
        levels.append(max(level, callLevel))
        // How much of this moment was the call rather than the microphone, for coloring the bars by speaker.
        let total = level + callLevel
        if callShares.count != levels.count { callShares = Array(repeating: 0, count: levels.count) }
        callShares.removeFirst()
        callShares.append(hearingCall && total > 0.05 ? callLevel / total : 0)
        callLevel *= 0.85
    }

    /// Both sides in the order they were said. The call's times move onto the microphone's timeline, and, only when
    /// the call played through speakers (`mayEcho`), a microphone line that repeats what the call said moments
    /// before is dropped, since the call's own copy is the clean one. With headphones nothing of yours is dropped:
    /// a reply can share nearly every word with what it answers ("we should not approve the final budget").
    nonisolated static func merge(microphone: [TranscriptLine], call: [TranscriptLine], callOffset: Double,
                                  mayEcho: Bool) -> [TranscriptLine] {
        let them = call.map { line in
            var line = line
            line.start = max(0, line.start + callOffset)
            return line
        }
        let theirWords = them.map { (start: $0.start, words: words(in: $0.text)) }
        let me = microphone.filter { line in
            let mine = words(in: line.text)
            guard !mine.isEmpty else { return false }
            // Only the call's line said again, word for word, within two seconds, is dropped: that loses nothing.
            // Any difference, even one word left out or added ("we should not approve…" and "we should approve…"),
            // can change what was meant, so the line stays; an echo heard a little wrong stays as a repeat. A short
            // line ("yes", "I agree") is as likely to be the person answering in the same words, so it always stays.
            guard mayEcho, mine.count >= 4 else { return true }
            return !theirWords.contains { other in
                line.start >= other.start - 1 && line.start - other.start < 2 && mine == other.words
            }
        }
        return (me + them).sorted { $0.start < $1.start }
    }

    /// The words of a line in order, without case or punctuation.
    private nonisolated static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The microphone's tap, made outside the main actor because it runs on the audio thread.
    private nonisolated static func tap(writer: AudioWriter, transcriber: Transcriber?, clock: StreamClock,
                                        level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, when in
            if when.isHostTimeValid { clock.markMicrophone(AVAudioTime.seconds(forHostTime: when.hostTime)) }
            writer.write(buffer)
            transcriber?.append(buffer)
            level(Self.loudness(of: buffer))
        }
    }

    /// Where the call's sound goes, on the capture queue.
    private nonisolated static func callSink(writer: AudioWriter, transcriber: Transcriber?, clock: StreamClock,
                                             level: @escaping @Sendable (Float) -> Void) -> @Sendable (AVAudioPCMBuffer, Double) -> Void {
        { buffer, start in
            clock.markCall(start)
            writer.write(buffer)
            transcriber?.append(buffer)
            level(Self.loudness(of: buffer))
        }
    }

    /// How loud a buffer is, 0…1, on a decibel scale so quiet speech still moves the meter.
    private nonisolated static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 55) / 50))
    }
}

/// Writes buffers to an audio file from the audio thread, and closes it (finishing the file) on request,
/// so it can be mixed straight after recording stops.
final class AudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var wrote = false

    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var wroteAny: Bool { lock.withLock { wrote } }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if (try? file?.write(from: buffer)) != nil { wrote = true }
        }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

/// When the microphone and the call each sent their first sound, on the same host clock, so the call's
/// lines and audio can be placed where they belong in the recording.
final class StreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var microphone: Double?
    private var call: Double?

    func markMicrophone(_ seconds: Double) { lock.withLock { if microphone == nil { microphone = seconds } } }
    func markCall(_ seconds: Double) { lock.withLock { if call == nil { call = seconds } } }

    /// Seconds from the microphone's first sound to the call's; 0 when unknown. The call may start long after the
    /// recording does (it was started before joining), and that wait is only known from here, so any later start is
    /// kept; one far before the microphone's isn't possible on one clock and is taken as unknown.
    var callOffset: Double {
        lock.withLock {
            guard let microphone, let call else { return 0 }
            let offset = call - microphone
            return offset.isFinite && offset > -5 ? offset : 0
        }
    }
}
