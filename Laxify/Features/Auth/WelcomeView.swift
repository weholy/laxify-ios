import SwiftUI

/// The first thing a new install shows: the mark, the name, and one button.
///
/// Shown once, before sign-in, and never again — the flag lives in
/// `hasSeenWelcomeKey`. Its whole job is to be the app introducing itself, so
/// it holds nothing but the logo, the two links a first launch is obliged to
/// put in front of someone, and the way forward.
///
/// Black rather than the light ground of the reference it follows: the app is
/// dark everywhere else, and a white first screen would flash and then vanish.
/// The button inverts with it — white on black rather than black on white.
struct WelcomeView: View {
    var onContinue: () -> Void

    @State private var showsTerms = false
    /// The mark settles in rather than appearing outright — a second of
    /// motion on the one screen that has nothing else to do.
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            LaxifyPalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                mark
                wordmark

                Spacer()

                legal
                    .padding(.horizontal, 40)
                    .padding(.bottom, 18)

                continueButton
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showsTerms) {
            TermsView { showsTerms = false }
        }
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) {
                hasAppeared = true
            }
        }
    }

    /// The logo over its own glow. The reference sits a soft blue cloud on a
    /// pale ground; on black the same shape needs the light to come off it
    /// instead, or it reads as a sticker.
    private var mark: some View {
        Image("LaxifyLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 128, height: 128)
            .background {
                Circle()
                    .fill(LaxifyPalette.accent)
                    .blur(radius: 60)
                    .opacity(0.45)
                    .scaleEffect(1.25)
            }
            .scaleEffect(hasAppeared ? 1 : 0.86)
            .opacity(hasAppeared ? 1 : 0)
    }

    private var wordmark: some View {
        Text(verbatim: "Laxify")
            // Heavy and rounded, set tight: the reference's wordmark is one
            // dense shape rather than six letters, and tracking is most of
            // what does that.
            .font(.system(size: 46, weight: .black, design: .rounded))
            .tracking(-1.5)
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.top, 18)
            .opacity(hasAppeared ? 1 : 0)
    }

    /// The two links a first launch has to show, in the sentence that names
    /// what pressing the button means.
    private var legal: some View {
        VStack(spacing: 3) {
            Text(L("welcome.legal.lead", "Нажимая «Продолжить», вы принимаете"))
                .foregroundStyle(LaxifyPalette.textTertiary)

            HStack(spacing: 4) {
                Button(L("welcome.legal.privacy", "Политику конфиденциальности")) {
                    showsTerms = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(LaxifyPalette.textSecondary)

                Text(verbatim: "&")
                    .foregroundStyle(LaxifyPalette.textTertiary)

                Button(L("welcome.legal.terms", "Условия использования")) {
                    showsTerms = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(LaxifyPalette.textSecondary)
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text(L("welcome.continue", "Продолжить"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LaxifyPalette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(LaxifyPalette.textPrimary, in: Capsule())
        }
        .buttonStyle(SquashButtonStyle())
    }
}

extension WelcomeView {
    static let hasSeenWelcomeKey = "laxify.welcome.seen"

    /// Whether the introduction still has to be shown.
    ///
    /// Deliberately not one of the keys cleared on sign-out: it is a fact
    /// about this install having been introduced to the app, not about whose
    /// account is signed into it.
    static var isPending: Bool {
        !UserDefaults.standard.bool(forKey: hasSeenWelcomeKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: hasSeenWelcomeKey)
    }
}

#Preview {
    WelcomeView {}
}
