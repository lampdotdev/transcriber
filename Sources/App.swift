import SwiftUI

@main
struct MainApp: SwiftUI.App {
    var body: some SwiftUI.Scene {
        WindowGroup("Transcriber") {
            ContentView()
        }
        .defaultSize(width: 880, height: 580)
        .commands {
            LampCommands()
            RecordingCommands(library: Library.shared, session: Library.shared.session)
        }
    }
}

/// The Recording menu: the same actions as the toolbar, with their shortcuts.
struct RecordingCommands: Commands {
    @ObservedObject var library: Library
    @ObservedObject var session: RecordingSession

    var body: some Commands {
        CommandMenu("Recording") {
            Button(session.isRecording ? "Stop Recording" : "Start Recording") { library.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.phase == .starting || session.phase == .finishing)
            Button("Show Recorder") { library.selection = nil }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Clear Examples") { library.clearExamples() }
                .disabled(!library.hasExamples)
        }
    }
}
