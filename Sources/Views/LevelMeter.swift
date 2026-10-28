import SwiftUI

/// The waveform under the Record button: a close row of thin vertical bars rising from the foot of the
/// recorder, each a gradient that's strongest at its base and fades toward its tip, warm for You and cool for Them. It's a timeline: the newest
/// loudness comes in on the right and drifts left as it ages; idle, it rests low and pale.
struct LevelMeter: View {
    let levels: [Float]
    let isActive: Bool
    /// For each reading, how much was the call (Them) rather than the microphone (You), 0…1.
    var callShares: [Float] = []

    /// From one bar to the next, and how wide each is, in points.
    private static let pitch: CGFloat = 5.7
    private static let barWidth: CGFloat = 3.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                // Only the most recent half of what's kept, so bars travel left twice as fast.
                let envelope = Self.smoothed(Array(levels.suffix(max(2, levels.count / 2))))
                let base = size.height
                let strength = isActive ? 1.0 : 0.35
                let shares = Self.smoothed(Array(callShares.suffix(max(2, callShares.count / 2))))
                let count = Int(size.width / Self.pitch)
                for bar in 0...count {
                    let x = (CGFloat(bar) + 0.5) * Self.pitch
                    let along = Double(x / size.width)
                    // Pointed at both ends, with only a short point on the right so what was just heard shows at once.
                    let taper = Self.ease(min(1, along / 0.2)) * Self.ease(min(1, (1 - along) / 0.06))
                    // A slow swell runs through it even in silence, so it always reads as a wave.
                    let swell = 0.7 + 0.3 * sin(along * 5.5 - time * 0.5)
                    let loudness = (isActive ? 0.25 + Self.sample(envelope, at: along).squareRoot() * 0.75 : 0.24) * swell
                    let height = CGFloat(loudness * max(taper, 0.03)) * (base - 2) * 0.65
                        * CGFloat(0.92 + 0.08 * sin(along * 23 + time * 1.3))
                    let bar = Path(roundedRect: CGRect(x: x - Self.barWidth / 2, y: base - height,
                                                       width: Self.barWidth, height: height + Self.barWidth),
                                   cornerRadius: Self.barWidth / 2)
                    let them = shares.isEmpty ? 0 : Self.sample(shares, at: along)
                    canvas.fill(bar, with: .linearGradient(Self.gradient(them: them, strength: strength), startPoint: CGPoint(x: x, y: base - height),
                                                           endPoint: CGPoint(x: x, y: base)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(isActive ? "\(Int((levels.last ?? 0) * 100)) percent" : "Not recording")
    }

    /// The levels softened, so the wave swells and falls rather than jumping bar to bar.
    private static func smoothed(_ levels: [Float]) -> [Double] {
        let values = levels.map(Double.init)
        guard values.count > 2 else { return values }
        return values.indices.map { index in
            let window = max(0, index - 2)...min(values.count - 1, index + 2)
            return window.map { values[$0] }.reduce(0, +) / Double(window.count)
        }
    }

    /// Warm for You, cool for Them, blended by how much of that moment was the call; faded toward the tip.
    static func gradient(them: Double, strength: Double) -> Gradient {
        func mix(_ you: (Double, Double, Double), _ call: (Double, Double, Double), _ opacity: Double) -> Color {
            let t = min(1, max(0, them))
            return Color(red: you.0 + (call.0 - you.0) * t, green: you.1 + (call.1 - you.1) * t,
                         blue: you.2 + (call.2 - you.2) * t).opacity(opacity)
        }
        let tip = mix((1, 0.6, 0.1), (0.35, 0.6, 1), 0)
        let middle = mix((1, 0.6, 0.1), (0.35, 0.6, 1), 0.75 * strength)
        let foot = mix((1, 0.27, 0.35), (0.45, 0.3, 1), strength)
        return Gradient(colors: [tip, middle, foot])
    }

    /// 0…1 eased in and out.
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The envelope at a point across the width, 0…1, eased between neighbors.
    private static func sample(_ envelope: [Double], at x: Double) -> Double {
        guard envelope.count > 1 else { return envelope.first ?? 0 }
        // The last bar can sit a little past the width, so the point is kept on the envelope.
        let position = min(max(x, 0), 1) * Double(envelope.count - 1)
        let low = min(Int(position.rounded(.down)), envelope.count - 1), high = min(low + 1, envelope.count - 1)
        let t = (1 - cos((position - Double(low)) * .pi)) / 2
        return envelope[low] * (1 - t) + envelope[high] * t
    }
}
