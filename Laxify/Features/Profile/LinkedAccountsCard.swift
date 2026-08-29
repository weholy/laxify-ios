import SwiftUI

/// Settings → Аккаунт: attach the other sign-in method so both open the same
/// account. The one you first joined with can't be detached.
struct LinkedAccountsCard: View {
    @State private var linked: LaxifyAPI.LinkedMethodsDTO?
    @State private var busy = false
    @State private var error: String?
    @State private var isTelegramSheetPresented = false

    var body: some View {
        SettingsGroup(
            header: L("account.methods", "Способы входа"),
            footer: error ?? L("account.methods.sub", "Способ, которым вы вошли, отвязать нельзя")
        ) {
            row(
                title: "Google",
                logo: AnyView(GoogleLogoView(size: 20)),
                linked: linked?.googleLinked ?? false,
                isPrimary: linked?.primary == "google",
                onLink: linkGoogle
            )
            SettingsDivider()
            row(
                title: "Telegram",
                logo: AnyView(
                    TelegramLogoView(size: 22, color: Color(hex: 0x2AABEE))
                        .padding(1)
                ),
                linked: linked?.telegramLinked ?? false,
                isPrimary: linked?.primary == "telegram",
                onLink: { isTelegramSheetPresented = true }
            )
        }
        .task { await refresh() }
        .sheet(isPresented: $isTelegramSheetPresented) {
            TelegramLoginSheet(
                onResult: { params in
                    isTelegramSheetPresented = false
                    Task { await perform { try await LaxifyAPI.shared.linkTelegram(payload: params) } }
                },
                onCancel: { isTelegramSheetPresented = false }
            )
        }
    }

    @ViewBuilder
    private func row(
        title: String, logo: AnyView, linked isLinked: Bool,
        isPrimary: Bool, onLink: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            logo
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text(isLinked
                     ? (isPrimary ? L("account.methods.primary", "Основной способ входа")
                                  : L("account.methods.linked", "Привязан"))
                     : L("account.methods.notLinked", "Не привязан"))
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(isLinked ? LaxifyPalette.textSecondary : LaxifyPalette.textTertiary)
            }

            Spacer()

            if busy {
                ProgressView()
            } else if isLinked {
                if !isPrimary {
                    Button(L("account.methods.unlink", "Отвязать")) {
                        Task { await perform { try await LaxifyAPI.shared.unlink(provider: title.lowercased()) } }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(LaxifyPalette.accent)
                }
            } else {
                Button(L("account.methods.link", "Привязать"), action: onLink)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private func refresh() async {
        linked = try? await LaxifyAPI.shared.linkedMethods()
    }

    private func linkGoogle() {
        Task {
            guard let user = try? await AuthService.shared.signIn() else { return }
            await perform { try await LaxifyAPI.shared.linkGoogle(idToken: user.idToken) }
        }
    }

    private func perform(_ action: () async throws -> LaxifyAPI.LinkedMethodsDTO) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            linked = try await action()
        } catch APIError.server(_, let detail) {
            withAnimation { error = detail }
        } catch {
            withAnimation { self.error = L("account.methods.failed", "Не удалось. Попробуйте ещё раз") }
        }
    }
}
