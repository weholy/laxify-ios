import SwiftUI

struct WelcomeView: View {
    let name: String
    var onFinished: () -> Void

    @State private var textAppear = false
    @State private var glowAppear = false

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            glow

            VStack(alignment: .leading, spacing: 4) {
                Text("Добро пожаловать,")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text(displayName)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LaxifyPalette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .opacity(textAppear ? 1 : 0)
            .offset(y: textAppear ? 0 : 12)

            VStack {
                Spacer()
                ProgressView()
                    .tint(LaxifyPalette.textSecondary)
                    .padding(.bottom, 60)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                glowAppear = true
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.15)) {
                textAppear = true
            }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                onFinished()
            }
        }
    }

    private var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "друг" : name
    }

    private var glow: some View {
        VStack {
            Spacer()
            RadialGradient(
                colors: [LaxifyPalette.accent.opacity(glowAppear ? 0.5 : 0), .clear],
                center: .bottom,
                startRadius: 10,
                endRadius: 320
            )
            .frame(height: 420)
            .blur(radius: 40)
        }
        .ignoresSafeArea()
    }
}

#Preview {
    WelcomeView(name: "Алекс", onFinished: {})
}
