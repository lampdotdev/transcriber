import Foundation

/// Turns a transcript into a short summary, the decisions made and the action items, with the AI the
/// person set up in Lamp. The transcription itself never leaves the Mac; only this step uses their AI.
enum Summarizer {
    /// The JSON the AI is asked for.
    private struct Draft: Decodable {
        var title: String?
        var summary: String
        var decisions: [String]?
        var actionItems: [String]?
    }

    static func summarize(_ recording: Recording) async throws -> (summary: Summary, title: String?) {
        // What was said in the room is someone else's words, so it goes in as data, never as instructions.
        let draft = try await LampAI.ask("""
            This is the transcript of a recording (a meeting, a lecture or a voice memo), with timestamps. \
            Lines marked "You:" were said by the person who recorded it and "Them:" by others on a call. \
            Return JSON: {"title": a short title of 2 to 6 words naming what it was about, \
            "summary": 2 to 4 plain sentences, \
            "decisions": what was decided, one short sentence each (empty when nothing was), \
            "actionItems": things someone said they or others would do, each starting with a verb and naming \
            who when the transcript says (empty when there are none)}. \
            Use only what the transcript says; speech recognition makes mistakes, so don't repeat obvious misheard words.
            """, data: recording.transcriptText, as: Draft.self)
        let summary = Summary(
            overview: draft.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: (draft.decisions ?? []).filter { !$0.isEmpty },
            actionItems: (draft.actionItems ?? []).filter { !$0.isEmpty }.map { ActionItem(text: $0) })
        let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, title?.isEmpty == false ? title : nil)
    }
}
