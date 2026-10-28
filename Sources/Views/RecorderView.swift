import SwiftUI

/// The recorder: a big Record button with the waveform under it, and the transcript
/// appearing as it's heard.
struct RecorderView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var session = Library.shared.session

    static let waveHeight: CGFloat = 134
    static let waveInset: CGFloat = 16
    /// How much of the panel's width the waveform spans, centered.
    static let waveShare: CGFloat = 0.6
    /// How far the button's foot sits above the line: low enough that the bars rise behind the glass, and
    /// in the middle of what shows between the toolbar and the line.
    static let buttonLift: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            // The waveform stands on the line between recorder and transcript; the glass button floats in
            // the middle of it, bending the bars that pass behind.
            GeometryReader { panel in
                ZStack {
                    LevelMeter(levels: session.levels, isActive: session.isRecording, callShares: session.callShares)
                        .frame(width: panel.size.width * Self.waveShare, height: Self.waveHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    // Centered on the waveform's height, so bars pass behind the whole disc.
                    RecordButton(phase: session.phase, levels: session.levels, isActive: session.isRecording,
                                 waveSize: CGSize(width: panel.size.width * Self.waveShare, height: Self.waveHeight),
                                 callShares: session.callShares,
                                 lensOffset: Self.waveHeight / 2 - Self.buttonLift - RecordButton.size / 2) {
                        library.toggleRecording()
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Self.buttonLift)
                    status
                        .padding(.horizontal, 24)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                }
                .frame(width: panel.size.width, height: panel.size.height)
            }
            .frame(height: 140)
            .padding(.bottom, 5)

            Divider()
            if session.phase != .idle {
                LiveTranscript(lines: session.lines, volatile: session.volatileText, note: session.transcriptNote)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationTitle("New Recording")
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .recording:
            // The running time is on the Stop button in the toolbar.
            if let note = session.callNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .starting:
            // The spinner is in the button; only a one-time wait (the speech model downloading) is spelled out.
            if let preparing = session.preparing {
                Text(preparing).font(.caption).foregroundStyle(.secondary)
            }
        case .finishing:
            EmptyView()
        case .idle:
            if let problem = session.problem {
                ProblemView(problem: problem)
            }
        }
    }
}

/// A disc of Liquid Glass with the red record mark inside, floating in the waveform, so the bars passing
/// behind it are bent and lit by the glass.
private struct RecordButton: View {
    let phase: RecordingSession.Phase
    /// The waveform's levels and size, so the glass can show the bars behind it, magnified like a lens.
    let levels: [Float]
    let isActive: Bool
    let waveSize: CGSize
    var callShares: [Float] = []
    /// How far the waveform's middle is above the button's middle.
    var lensOffset: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    static let size: CGFloat = 84
    /// How the reflected bars are squeezed: a little narrower, and about half as tall, as on a curved surface.
    private static let reflection = CGSize(width: 0.85, height: 0.45)
    private static let red = Color(red: 1, green: 0.27, blue: 0.35)

    var body: some View {
        Button(action: action) {
            ZStack {
                if phase == .starting || phase == .finishing {
                    GlassSpinner(colors: [Color.orange, Self.red])
                } else {
                    // A dot to record, a square to stop, as on every recorder.
                    RoundedRectangle(cornerRadius: phase == .recording ? 6 : 15)
                        .fill(LinearGradient(colors: [Color.orange, Self.red], startPoint: .top, endPoint: .bottom))
                        .frame(width: phase == .recording ? 26 : 30, height: phase == .recording ? 26 : 30)
                        .shadow(color: Self.red.opacity(0.45), radius: phase == .recording ? 8 : 4)
                }
            }
            .frame(width: Self.size, height: Self.size)
            // Apple's own Liquid Glass: the clear kind, which shows and bends what's behind it.
            .modifier(LiquidGlass())
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(duration: 0.3), value: phase)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focusable(false)
        .onHover { hovering = $0 }
        .disabled(phase == .starting || phase == .finishing)
        .accessibilityLabel(phase == .recording ? "Stop Recording" : "Start Recording")
        .help(phase == .recording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }
}

/// Why a recording couldn't start, and the one thing that fixes it.
private struct ProblemView: View {
    let problem: RecordingSession.Problem

    var body: some View {
        VStack(spacing: 8) {
            switch problem {
            case .permission(let kind):
                Text("Transcriber needs \(kind.name) access, which is off in System Settings.")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { Permissions.openSettings(for: kind) }
            case .noMicrophone:
                Text("No microphone was found. Connect one, then press Record.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// What's been heard so far, following the newest words.
private struct LiveTranscript: View {
    let lines: [TranscriptLine]
    let volatile: String
    let note: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let note {
                        Label(note, systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.secondary)
                    } else if lines.isEmpty && volatile.isEmpty {
                        Text("Listening…").foregroundStyle(.tertiary)
                    }
                    ForEach(lines) { line in
                        TranscriptRow(line: line, isCurrent: false, canPlay: false) {}
                    }
                    if !volatile.isEmpty {
                        Text(volatile)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 58)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: volatile) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// macOS 26's Liquid Glass, clear with a light gray tint so the disc reads on white, in a circle; a frosted material on earlier macOS.
private struct LiquidGlass: ViewModifier {
    func body(content: Content) -> some View {
        // Glass is named only in Xcode 26's SDK: an older toolchain builds the frosted material on every macOS.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear.tint(Color.gray.opacity(0.22)).interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #else
        content.background(.ultraThinMaterial, in: Circle())
        #endif
    }
}

/// A turning arc in the record mark's orange-to-red, shown in the button while recording starts or finishes.
private struct GlassSpinner: View {
    let colors: [Color]
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(AngularGradient(colors: [colors[0].opacity(0.1)] + colors, center: .center),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Working")
    }
}
