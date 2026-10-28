import Foundation

/// One recording: its audio file, what was said in it, and the summary made from that.
/// Saved whole in LampStore's "recordings" collection, so a property added later must be optional
/// (or have a default when decoding) for older recordings to keep loading.
struct Recording: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval
    var lines: [TranscriptLine] = []
    var summary: Summary?
    /// The audio's file name in `Library.audioFolder`. Examples have none, so they can't be played.
    var audioFileName: String?
    /// The other side of a call, kept on its own only when it couldn't be mixed into `audioFileName`.
    var callAudioFileName: String?
    /// Sample content written on first launch; Clear Examples removes exactly these.
    var isExample = false
    /// Set once the person renames it, so a summary's suggested title never replaces theirs.
    var hasCustomTitle = false
    /// Why the transcript stopped or never started (the language isn't supported, permission was denied).
    var transcriptNote: String?

    var transcriptText: String {
        lines.map { line in
            let who = line.speaker.map { "\($0.name): " } ?? ""
            return "[\(line.start.clock)] \(who)\(line.text)"
        }.joined(separator: "\n")
    }

    var canPlay: Bool { audioFileName != nil }
}

/// A stretch of speech and when in the recording it began, so a click can play from there.
struct TranscriptLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: TimeInterval
    var text: String
    /// Who said it, when the recording heard the call apart from the microphone; nil otherwise.
    var speaker: Speaker?
}

/// The microphone is the person at this Mac; what came out of its speakers or headphones is everyone else.
enum Speaker: String, Codable, Hashable {
    case me, them

    var name: String { self == .me ? "You" : "Them" }
}

/// What the person's AI made of the transcript.
struct Summary: Codable, Hashable {
    var overview: String
    var decisions: [String]
    var actionItems: [ActionItem]
}

struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var done = false
}

extension TimeInterval {
    /// "4:05", or "1:02:03" past the hour: how a player shows time.
    var clock: String {
        let total = Int(self.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// "14 min", "45 sec": a recording's length in a list.
    var spoken: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = self >= 3600 ? [.hour, .minute] : self >= 60 ? [.minute] : [.second]
        return formatter.string(from: max(self, 1)) ?? clock
    }
}
