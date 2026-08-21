import SwiftUI

struct SignInView: View {
    var onSignedIn: (AuthenticatedGoogleUser) -> Void

    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var appear = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                        .frame(width: 88, height: 88)
                        .laxGlassCircle()

                    Text("Laxify")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Text("Твоя музыка, всегда под рукой")
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 16)

                Spacer()

                VStack(spacing: 14) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, LaxifyMetrics.screenPadding)
                    }

                    Button {
                        signIn()
                    } label: {
                        HStack(spacing: 10) {
                            if isSigningIn {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "g.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            Text("Продолжить через Google")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.laxifyPrimary)
                    .disabled(isSigningIn)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)

                    Text("Вход по почте появится позже")
                        .font(LaxifyTypography.caption)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 16)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                appear = true
            }
        }
    }

    private var background: some View {
        ZStack {
            LaxifyPalette.background

            RadialGradient(
                colors: [LaxifyPalette.accent.opacity(0.28), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }

    private func signIn() {
        errorMessage = nil
        isSigningIn = true
        Task {
            do {
                let user = try await AuthService.shared.signIn()
                isSigningIn = false
                onSignedIn(user)
            } catch AuthError.cancelled {
                isSigningIn = false
            } catch {
                isSigningIn = false
                errorMessage = "Не удалось войти. Попробуйте снова"
                AppLogger.log("auth: sign-in failed \(error)")
            }
        }
    }
}

#Preview {
    SignInView(onSignedIn: { _ in })
}
