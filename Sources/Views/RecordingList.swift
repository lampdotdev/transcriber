import SwiftUI

/// The sidebar: every recording, newest first, searchable by title and by what was said.
struct RecordingList: View {
    @ObservedObject private var library = Library.shared
    @State private var search = ""
    @State private var pendingDelete: Recording?

    private var shown: [Recording] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.recordings }
        return library.recordings.filter { recording in
            recording.title.localizedCaseInsensitiveContains(query)
                || recording.lines.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List(selection: $library.selection) {
            ForEach(shown) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .contextMenu {
                        Button("Delete…", role: .destructive) { pendingDelete = recording }
                    }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search transcripts")
        .overlay {
            if library.recordings.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "waveform",
                                       description: Text("Press Record to start one."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .bottom) { CallAudioSetting() }
        .onDeleteCommand { pendingDelete = library.selected }
        .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { recording in
            Button("Delete", role: .destructive) { library.delete(recording.id) }
        } message: { recording in
            Text(recording.canPlay ? "Its audio and transcript will be deleted." : "Its transcript will be deleted.")
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(recording.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(recording.duration.spoken)
                if recording.isExample {
                    Text("·")
                    Text("Example")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// At the foot of the sidebar: whether recordings also hear what plays through the speakers or headphones
/// (the other side of a call), so both sides are transcribed and told apart as You and Them. Off at first.
private struct CallAudioSetting: View {
    @ObservedObject private var session = Library.shared.session
    @AppStorage(RecordingSession.callAudioKey) private var includeCallAudio = false
    @State private var askForPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { includeCallAudio },
                set: { on in
                    if on && !LampPermissions.has(.screenRecording) { askForPermission = true } else { includeCallAudio = on }
                })) {
                Label("Include call audio", systemImage: "person.2.wave.2")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(session.phase != .idle)
            .help("Also record what plays through your speakers or headphones, like the other side of a Zoom call, and label who said what")

            if includeCallAudio {
                Label("Make sure the other people are OK with transcribing.", systemImage: "hand.wave")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: includeCallAudio)
        .sheet(isPresented: $askForPermission) {
            LampPermissionView(.screenRecording, reason: "To hear the other side of a call, macOS asks Transcriber for Screen & System Audio Recording. Only the sound is kept, never the screen.") {
                askForPermission = false
                includeCallAudio = true
            }
            .frame(minWidth: 460, minHeight: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { askForPermission = false } }
            }
        }
    }
}
