import SwiftUI
import UIKit

/// The screen a retired build gets instead of the app.
///
/// No close button, no swipe, no environment dismiss — this replaces the
/// whole root rather than presenting over it, because a blocking screen that
/// can be dismissed by accident is not a blocking screen. "Готово" ends the
/// process outright: there is nothing this build should still be doing.
struct UpdateRequiredView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(LaxifyPalette.brandGradient)
                        .frame(width: 92, height: 92)
                        .opacity(0.18)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.brandGradient)
                }

                VStack(spacing: 10) {
                    Text(L("update.title", "Вышло обновление"))
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(L(
                        "update.body",
                        "Скачайте новую версию, чтобы продолжить — эта больше не поддерживается"
                    ))
                    .font(.system(size: 15))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        openURL(AppLinks.contact)
                    } label: {
                        Text(L("update.download", "Скачать"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)

                    Button {
                        // There is no supported way to ask iOS to close an
                        // app, and none is needed here: this build has
                        // nothing left to do but end the process, which is
                        // what was asked for. Sideloaded outside the App
                        // Store, where this rule does not apply.
                        exit(0)
                    } label: {
                        Text(L("common.done", "Готово"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled()
    }
}
