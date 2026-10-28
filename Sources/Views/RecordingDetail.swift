import AppKit
import SwiftUI

/// A finished recording: its title (click to rename), the summary, and the transcript with times.
struct RecordingDetail: View {
    let recording: Recording
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Library.shared.player
    @State private var title = ""
    @FocusState private var editingTitle: Bool

    private var isOpenInPlayer: Bool { player.recordingID == recording.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                SummarySection(recording: recording)
                TranscriptSection(recording: recording)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(recording.title)
        .toolbar {
            if recording.canPlay {
                Button {
                    player.toggle(recording)
                } label: {
                    Label(isOpenInPlayer && player.isPlaying ? "Pause" : "Play",
                          systemImage: isOpenInPlayer && player.isPlaying ? "pause.fill" : "play.fill")
                }
                .help("Play or pause the recording")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recording.transcriptText, forType: .string)
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(recording.lines.isEmpty)
            .help("Copy the transcript with its times (⇧⌘C)")
        }
        .onAppear { title = recording.title }
        .onChange(of: recording.title) { _, new in if !editingTitle { title = new } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .focused($editingTitle)
                .onSubmit { library.rename(recording.id, to: title) }
                .onChange(of: editingTitle) { _, editing in
                    guard !editing else { return }
                    library.rename(recording.id, to: title)
                    // An empty title isn't kept: the field goes back to the one it had.
                    if title.trimmingCharacters(in: .whitespaces).isEmpty { title = recording.title }
                }
                .accessibilityLabel("Title")
            HStack(spacing: 6) {
                Text(recording.date, format: .dateTime.weekday(.wide).month().day().hour().minute())
                Text("·")
                Text(recording.duration.clock).monospacedDigit()
                if isOpenInPlayer {
                    Text("·")
                    Text("Playing at \(player.time.clock)").monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if recording.isExample {
                Label("An example, with no audio to play. Recording ▸ Clear Examples removes it.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let call = recording.callAudioFileName {
                HStack(spacing: 6) {
                    Label("The call's side couldn't be mixed in, so it plays only your side. It's kept as its own file.",
                          systemImage: "exclamationmark.triangle")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Library.audioFolder.appendingPathComponent(call)])
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The transcript, one line per phrase with the time it was said; a click plays from there.
private struct TranscriptSection: View {
    let recording: Recording
    @ObservedObject private var player = Library.shared.player

    /// The line being played: the last one that started before the player's time.
    private var currentLineID: TranscriptLine.ID? {
        guard player.recordingID == recording.id else { return nil }
        return recording.lines.last { $0.start <= player.time + 0.3 }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript").font(.headline)
            if let note = recording.transcriptNote, recording.lines.isEmpty {
                Text(note).foregroundStyle(.secondary)
            }
            ForEach(recording.lines) { line in
                TranscriptRow(line: line, isCurrent: line.id == currentLineID, canPlay: recording.canPlay) {
                    player.play(recording, from: line.start)
                }
            }
        }
    }
}

/// One line of a transcript: its time, then what was said.
struct TranscriptRow: View {
    let line: TranscriptLine
    let isCurrent: Bool
    let canPlay: Bool
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.start.clock)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 46, alignment: .trailing)
            if let speaker = line.speaker {
                Text(speaker.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(speaker == .me ? Color(red: 0.95, green: 0.4, blue: 0.2) : Color(red: 0.4, green: 0.4, blue: 0.95))
                    .frame(width: 44, alignment: .leading)
            }
            Text(line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : hovering && canPlay ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if canPlay { play() } }
        .help(canPlay ? "Play from \(line.start.clock)" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canPlay ? .isButton : [])
        .accessibilityAction { if canPlay { play() } }
    }
}
