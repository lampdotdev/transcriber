import SwiftUI

/// The AI's summary of a recording: a few sentences, what was decided, and action items to tick off.
/// Without AI set up in Lamp it says so quietly; the transcript above it works either way.
struct SummarySection: View {
    let recording: Recording
    @ObservedObject private var library = Library.shared

    private var isWorking: Bool { library.summarizing.contains(recording.id) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = recording.summary {
                    Text(summary.overview)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !summary.decisions.isEmpty {
                        part("Decisions") {
                            ForEach(summary.decisions, id: \.self) { decision in
                                Label(decision, systemImage: "checkmark.seal")
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        part("Action Items") {
                            ForEach(summary.actionItems) { item in
                                Toggle(isOn: Binding(
                                    get: { item.done },
                                    set: { _ in library.toggleActionItem(item.id, in: recording.id) }
                                )) {
                                    Text(item.text)
                                        .strikethrough(item.done)
                                        .foregroundStyle(item.done ? .secondary : .primary)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("Summary", systemImage: "sparkles").font(.headline)
        }
    }

    @ViewBuilder private var footer: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").foregroundStyle(.secondary)
            }
        } else if let problem = library.summaryProblems[recording.id] {
            HStack {
                Text(problem).foregroundStyle(.secondary)
                Button("Try Again") { library.summarize(recording.id) }
            }
        } else if recording.summary == nil {
            if recording.lines.isEmpty {
                Text("There's nothing to summarize without a transcript.").foregroundStyle(.secondary)
            } else if library.aiAvailable == false {
                Text("Summaries need AI set up in Lamp.").foregroundStyle(.secondary)
            } else {
                Button("Summarize") { library.summarize(recording.id) }
            }
        } else if !recording.isExample && library.aiAvailable == true {
            Button("Summarize Again") { library.summarize(recording.id) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A list item with its symbol small and aligned to the first line of text.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.secondary).font(.callout)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
