import SwiftUI

/// The window: recordings in the sidebar; on the right the one selected, or the recorder when none is.
struct ContentView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var session = Library.shared.session
    /// The selected recording, kept across launches and across changes to the app.
    @SceneStorage("selection") private var savedSelection = ""
    /// The first time the window opens it shows a finished transcript, so what the app makes is seen before
    /// anything is recorded; after that it opens on what was last chosen, or the recorder.
    @AppStorage("openedBefore") private var openedBefore = false

    var body: some View {
        NavigationSplitView {
            RecordingList()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if let recording = library.selected {
                RecordingDetail(recording: recording)
                    .id(recording.id)
            } else {
                RecorderView()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordToolbarButton()
            }
        }
        .onAppear {
            if library.selection == nil, let id = UUID(uuidString: savedSelection),
               library.recordings.contains(where: { $0.id == id }) {
                library.selection = id
            }
            if !openedBefore {
                openedBefore = true
                if library.selection == nil { library.selection = library.recordings.first?.id }
            }
        }
        .onChange(of: library.selection) { _, id in savedSelection = id?.uuidString ?? "" }
    }
}

/// Record when idle, Stop with the running time while recording: the one button that's always there.
private struct RecordToolbarButton: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var session = Library.shared.session

    var body: some View {
        Button {
            library.toggleRecording()
        } label: {
            if session.isRecording, let startedAt = session.startedAt {
                Label {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Stop · " + context.date.timeIntervalSince(startedAt).clock).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .disabled(session.phase == .starting || session.phase == .finishing)
        .help(session.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }
}
