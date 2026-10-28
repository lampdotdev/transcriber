import Foundation
import SwiftUI

/// Every recording, the one selected, and the work done on them (saving, deleting, summarizing).
/// One shared instance, so the window and the menu commands act on the same thing.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var recordings: [Recording] = []
    /// The recording shown on the right; nil shows the recorder.
    @Published var selection: Recording.ID?
    @Published private(set) var summarizing: Set<Recording.ID> = []
    @Published private(set) var summaryProblems: [Recording.ID: String] = [:]
    /// Whether the person's AI can answer; nil until Lamp has said.
    @Published private(set) var aiAvailable: Bool?

    let session = RecordingSession()
    let player = Player()

    /// Audio files live beside the app's database, in its own data folder.
    static let audioFolder: URL = {
        let url = LampStore.folder.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let store = LampStore.collection("recordings", of: Recording.self)

    private init() {
        Examples.addOnFirstLaunch(to: store)
        reload()
        Task { aiAvailable = await LampAI.isAvailable(.text) }
    }

    var selected: Recording? { recordings.first { $0.id == selection } }
    var hasExamples: Bool { recordings.contains { $0.isExample } }

    func audioURL(for recording: Recording) -> URL? {
        recording.audioFileName.map { Self.audioFolder.appendingPathComponent($0) }
    }

    // MARK: Changes

    func add(_ recording: Recording) {
        store.put(recording)
        reload()
        selection = recording.id
        if !recording.lines.isEmpty { summarize(recording.id) }
    }

    func update(_ recording: Recording) {
        store.put(recording)
        reload()
    }

    func rename(_ id: Recording.ID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var recording = store.get(id), !title.isEmpty, title != recording.title else { return }
        recording.title = title
        recording.hasCustomTitle = true
        update(recording)
    }

    func toggleActionItem(_ itemID: ActionItem.ID, in id: Recording.ID) {
        guard var recording = store.get(id), var summary = recording.summary,
              let index = summary.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
        summary.actionItems[index].done.toggle()
        recording.summary = summary
        update(recording)
    }

    func delete(_ id: Recording.ID) {
        guard let recording = store.get(id) else { return }
        if player.recordingID == id { player.stop() }
        if let url = audioURL(for: recording) { try? FileManager.default.removeItem(at: url) }
        if let call = recording.callAudioFileName {
            try? FileManager.default.removeItem(at: Self.audioFolder.appendingPathComponent(call))
        }
        store.delete(id)
        if selection == id { selection = nil }
        reload()
    }

    /// Removes only the sample recordings; nothing the person recorded.
    func clearExamples() {
        recordings.filter(\.isExample).forEach { delete($0.id) }
    }

    // MARK: Summaries

    /// Asks the person's AI for a summary. The transcript is kept either way: a failure is a quiet line
    /// under the Summary heading, with a button to try again.
    func summarize(_ id: Recording.ID) {
        guard !summarizing.contains(id), let recording = store.get(id), !recording.lines.isEmpty else { return }
        summarizing.insert(id)
        summaryProblems[id] = nil
        Task {
            defer { summarizing.remove(id) }
            if aiAvailable != true { aiAvailable = await LampAI.isAvailable(.text) }
            guard aiAvailable == true else { return }
            do {
                let result = try await Summarizer.summarize(recording)
                // Read it again: the person may have renamed it or ticked an item while the AI worked.
                guard var latest = store.get(id) else { return }
                latest.summary = result.summary
                if !latest.hasCustomTitle, let title = result.title { latest.title = title }
                update(latest)
            } catch {
                summaryProblems[id] = error.localizedDescription
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        switch session.phase {
        case .idle:
            selection = nil
            player.stop()
            Task { await session.start() }
        case .recording:
            Task { if let recording = await session.stop() { add(recording) } }
        case .starting, .finishing:
            break
        }
    }

    private func reload() {
        recordings = store.all().sorted { $0.date > $1.date }
    }
}
