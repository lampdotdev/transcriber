import Foundation

/// The two finished recordings a new person finds on first launch, so the app shows what it makes before
/// anything is recorded. They are text only (no audio), marked `isExample`, and written once: a flag in
/// LampStore keeps them from coming back after Clear Examples.
enum Examples {
    static func addOnFirstLaunch(to store: LampStore.Collection<Recording>) {
        guard LampStore.load(Bool.self, from: "examplesAdded") != true else { return }
        LampStore.save(true, to: "examplesAdded")
        guard store.count == 0 else { return }
        store.put([weeklySync, lecture])
    }

    /// A line every few seconds: the times only need to read as believable.
    private static func lines(_ timed: [(Int, String)]) -> [TranscriptLine] {
        timed.map { TranscriptLine(start: TimeInterval($0.0), text: $0.1) }
    }

    private static let day: TimeInterval = 86_400

    static var weeklySync: Recording {
        Recording(
            title: "Team Weekly Sync",
            date: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date().addingTimeInterval(-day)) ?? Date(),
            duration: 14 * 60 + 32,
            lines: lines([
                (2, "Okay, let's get started. Three things today: the launch date, the onboarding survey, and hiring."),
                (11, "Launch first. Design is done with the new checkout and QA found two small bugs, both fixed yesterday."),
                (24, "So are we still good for the twenty-first?"),
                (28, "I think so. The only open question is whether the email goes out the same morning or a day later."),
                (41, "Same morning. Support wants a day of quiet before, not after."),
                (55, "Fine by me. Let's lock the twenty-first and send the email at nine."),
                (132, "Onboarding survey. We got a hundred and forty answers, and the top complaint is the import step."),
                (149, "People don't realize they can bring in a spreadsheet. They start typing everything by hand."),
                (163, "Could we put the import button on the empty screen instead of in the menu?"),
                (171, "That's a small change. Priya, can you mock it up by Thursday?"),
                (176, "Yes, I'll have something Thursday."),
                (312, "Hiring. We have two finalists for the support role and both interviews went well."),
                (327, "Sam, could you send the take-home task to both of them today?"),
                (334, "Will do, and I'll set up the follow-ups for early next week."),
                (518, "Anything else before we wrap? No? Then same time next week. Thanks, everyone."),
            ]),
            summary: Summary(
                overview: "The team confirmed the launch for the 21st and looked at the onboarding survey, where the import step was the top complaint. The two support finalists move on to a take-home task.",
                decisions: [
                    "Launch on the 21st, with the announcement email at 9 a.m. the same morning.",
                    "Move the import button onto the empty screen.",
                ],
                actionItems: [
                    ActionItem(text: "Priya: mock up the import button on the empty screen by Thursday", done: true),
                    ActionItem(text: "Sam: send the take-home task to both finalists today"),
                    ActionItem(text: "Sam: schedule follow-up interviews for early next week"),
                ]),
            isExample: true,
            hasCustomTitle: true)
    }

    static var lecture: Recording {
        Recording(
            title: "Lecture: Sleep and Memory",
            date: Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date().addingTimeInterval(-3 * day)) ?? Date(),
            duration: 48 * 60 + 5,
            lines: lines([
                (4, "Last week we looked at how memories are formed. Today is about what happens to them while you sleep."),
                (17, "The key idea is consolidation: a new memory starts out fragile and becomes stable over time."),
                (31, "During deep sleep, the hippocampus replays what happened during the day, often many times faster."),
                (46, "That replay seems to move memories into the cortex, where they last longer."),
                (402, "There's a classic study where students learned word pairs and were tested the next morning."),
                (415, "The ones who slept recalled about twenty percent more than the ones who stayed awake for the same hours."),
                (1210, "REM sleep looks different. It seems to matter more for skills and for connecting ideas."),
                (1228, "So a night of sleep isn't just rest. Different stages do different jobs."),
                (2050, "Practical takeaway for your own studying: spread it out, and sleep between sessions."),
                (2064, "Cramming the night before cuts exactly the sleep that would have helped you keep it."),
                (2810, "For next week, read chapter seven, and the short paper on naps I'll post tonight."),
            ]),
            summary: Summary(
                overview: "Sleep consolidates new memories: deep sleep replays the day and moves memories into the cortex, while REM sleep helps with skills and connecting ideas. Studying in spaced sessions with sleep between them works better than cramming.",
                decisions: [],
                actionItems: [
                    ActionItem(text: "Read chapter seven before next week"),
                    ActionItem(text: "Read the short paper on naps once it's posted"),
                ]),
            isExample: true,
            hasCustomTitle: true)
    }
}
