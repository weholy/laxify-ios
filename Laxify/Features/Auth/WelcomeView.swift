import SwiftUI

/// The moment between signing in and the app appearing.
///
/// One breathing orb of light, a name, and a few words drifting up out of it.
/// Nothing to read and nothing to press — it exists to make the wait feel
/// intentional, so it commits to a single look (a warm dark field, whatever
/// the system theme) rather than trying to be two designs at once.
struct WelcomeView: View {
    let name: String
    var onFinished: () -> Void

    @State private var appeared = false
    @State private var isExiting = false
    @State private var wordsShown = 0

    private static let words = ["волна", "тексты", "плейлисты", "тишина"]

    var body: some View {
        ZStack {
            Self.ground.ignoresSafeArea()

            BreathingOrb(appeared: appeared)
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.82)
                .animation(.easeOut(duration: 1.6), value: appeared)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Text(greeting)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.ink.opacity(0.55))
                    .tracking(0.6)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.easeOut(duration: 0.7).delay(0.25), value: appeared)

                Text(displayName)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 2)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                    .blur(radius: appeared ? 0 : 8)
                    .animation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.35), value: appeared)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.words.enumerated()), id: \.offset) { index, word in
                        let shown = index < wordsShown
                        Text(word)
                            .font(.system(size: 30, weight: .light, design: .rounded))
                            // Each word a little fainter than the one above,
                            // so the stack reads as receding rather than as a
                            // list of equals.
                            .foregroundStyle(Self.ink.opacity(0.5 - Double(index) * 0.09))
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown ? 0 : 16)
                            .blur(radius: shown ? 0 : 4)
                            .animation(
                                .spring(response: 0.75, dampingFraction: 0.86),
                                value: shown
                            )
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 96)
        }
        .opacity(isExiting ? 0 : 1)
        .scaleEffect(isExiting ? 1.06 : 1)
        .blur(radius: isExiting ? 12 : 0)
        .task { await run() }
    }

    private func run() async {
        appeared = true
        for index in Self.words.indices {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 700 : 190))
            wordsShown = index + 1
        }
        try? await Task.sleep(for: .milliseconds(950))
        withAnimation(.easeInOut(duration: 0.7)) { isExiting = true }
        try? await Task.sleep(for: .milliseconds(700))
        onFinished()
    }

    private var greeting: String {
        L("welcome.greeting", "с возвращением")
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("welcome.friend", "рады видеть") : trimmed
    }

    // A single committed palette — a near-black field warmed slightly, and an
    // off-white ink that never sits on the orb's brightest part.
    private static let ground = Color(hex: 0x08070C)
    private static let ink = Color(hex: 0xF4F1FF)
}

/// A soft column of light that expands and contracts like a slow breath.
///
/// Concentric radial gradients rather than one blurred circle: layering them
/// gives the dense, glowing core and the long falloff that a single blur
/// cannot, and it costs nothing to animate.
private struct BreathingOrb: View {
    let appeared: Bool

    private let core = Color(hex: 0x2E6BFF)
    private let mid = Color(hex: 0x7B5CFF)
    private let halo = Color(hex: 0xFF6FB1)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // One breath every ~5.5s, plus a slower drift so it never repeats
            // exactly the same shape.
            let breath = 1 + 0.075 * sin(t * (2 * .pi / 5.5))
            let drift = CGSize(width: sin(t * 0.21) * 14, height: cos(t * 0.17) * 18)

            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)

                ZStack {
                    ring(halo.opacity(0.30), side: side * 2.05, blur: 70)
                    ring(mid.opacity(0.42), side: side * 1.45, blur: 44)
                    ring(core.opacity(0.62), side: side * 0.92, blur: 26)
                    ring(.white.opacity(0.30), side: side * 0.36, blur: 30)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(breath)
                .offset(drift)
                // Keeps the glow off the very edges so the text below always
                // has a dark ground to sit on.
                .position(x: geo.size.width * 0.52, y: geo.size.height * 0.38)
            }
        }
        .allowsHitTesting(false)
    }

    private func ring(_ color: Color, side: CGFloat, blur: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0.35), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: side / 2
                )
            )
            .frame(width: side, height: side)
            .blur(radius: blur)
            .blendMode(.plusLighter)
    }
}

#Preview {
    WelcomeView(name: "Алекс", onFinished: {})
}
