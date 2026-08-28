import SwiftUI

struct WelcomeView: View {
    let name: String
    var onFinished: () -> Void

    @State private var textAppear = false
    @State private var isExiting = false

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            AuroraBackdrop()
                .ignoresSafeArea()
                .opacity(textAppear ? 1 : 0)
                .animation(.easeOut(duration: 1.1), value: textAppear)

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate

                VStack(alignment: .leading, spacing: 8) {
                    Text("Добро пожаловать,")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    ShimmerName(text: displayName, time: t)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                // A slow, shallow drift — the text never settles, so it reads
                // as alive rather than placed.
                .offset(y: sin(t * 0.9) * 6)
                .rotationEffect(.degrees(sin(t * 0.5) * 0.6))
                .scaleEffect(textAppear ? 1 : 0.92)
                .opacity(textAppear ? 1 : 0)
                .blur(radius: textAppear ? 0 : 10)
            }

            VStack {
                Spacer()
                ProgressView()
                    .tint(LaxifyPalette.textSecondary)
                    .padding(.bottom, 60)
                    .opacity(textAppear ? 1 : 0)
            }
        }
        .opacity(isExiting ? 0 : 1)
        .scaleEffect(isExiting ? 1.04 : 1)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.15)) {
                textAppear = true
            }
            Task {
                try? await Task.sleep(for: .seconds(2.1))
                withAnimation(.easeInOut(duration: 0.55)) { isExiting = true }
                try? await Task.sleep(for: .seconds(0.55))
                onFinished()
            }
        }
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "друг" : trimmed
    }
}

/// A slow wash of the brand colours behind the greeting.
///
/// Built from a mesh whose interior points wander on offset sine waves, plus
/// two blurred blobs drifting across it. The corners stay clear so it sits on
/// the page's own background — pastel over white, neon over black — without
/// ever fighting the text for contrast.
private struct AuroraBackdrop: View {
    private let pink = Color(hex: 0xFF5FA2)
    private let purple = Color(hex: 0xA855F7)
    private let blue = Color(hex: 0x5B7CFA)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5],
                        [Float(0.5 + 0.16 * sin(t * 0.42)), Float(0.5 + 0.16 * cos(t * 0.37))],
                        [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ],
                    colors: [
                        .clear, pink.opacity(0.16), .clear,
                        purple.opacity(0.28), blue.opacity(0.34), purple.opacity(0.22),
                        .clear, pink.opacity(0.20), .clear
                    ]
                )

                blob(color: purple, at: CGPoint(x: 0.28 + 0.10 * sin(t * 0.31),
                                                y: 0.34 + 0.08 * cos(t * 0.27)))
                blob(color: blue, at: CGPoint(x: 0.74 + 0.09 * cos(t * 0.23),
                                              y: 0.62 + 0.10 * sin(t * 0.29)))
            }
            .blur(radius: 46)
        }
    }

    private func blob(color: Color, at unit: CGPoint) -> some View {
        GeometryReader { geo in
            Circle()
                .fill(color.opacity(0.30))
                .frame(width: geo.size.width * 0.6)
                .position(x: geo.size.width * unit.x, y: geo.size.height * unit.y)
        }
    }
}

/// The name, filled with the brand gradient, with a soft highlight that
/// sweeps across it on a loop.
private struct ShimmerName: View {
    let text: String
    let time: Double

    var body: some View {
        // One pass every three seconds.
        let phase = (time.truncatingRemainder(dividingBy: 3)) / 3

        Text(text)
            .font(.system(size: 40, weight: .heavy))
            .foregroundStyle(LaxifyPalette.brandGradient)
            .overlay {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.45)
                    .offset(x: -w * 0.45 + (w * 1.45) * phase)
                    .blendMode(.plusLighter)
                }
                .mask {
                    Text(text).font(.system(size: 40, weight: .heavy))
                }
            }
            .fixedSize()
    }
}

#Preview {
    WelcomeView(name: "Алекс", onFinished: {})
}
