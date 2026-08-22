import SwiftUI

struct EditProfileView: View {
    var onClose: () -> Void

    private var session = SessionStore.shared
    private var downloads = DownloadManager.shared

    @State private var name: String
    @State private var username: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let user = SessionStore.shared.user
        _name = State(initialValue: user?.displayName ?? "")
        _username = State(initialValue: user?.username ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedUsername.count >= 2 && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 20) {
                    avatarSection
                    fields

                    if let errorMessage {
                        Text(errorMessage)
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    saveButton
                    downloadsSection
                    signOutButton
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack {
            Text("Профиль")
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            LaxifyCloseButton(style: .xmark, tinted: false, action: onClose)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var avatarSection: some View {
        VStack(spacing: 10) {
            avatarImage
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }

            Text("Фото берётся из аккаунта Google")
                .font(LaxifyTypography.caption)
                .foregroundStyle(LaxifyPalette.textTertiary)
        }
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = session.user?.avatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(LaxifyPalette.surface)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
    }

    private var fields: some View {
        VStack(spacing: 14) {
            field(title: "Имя", text: $name, placeholder: "Имя")
            field(title: "Юзернейм", text: $username, placeholder: "username", prefix: "@")
        }
    }

    private func field(
        title: String,
        text: Binding<String>,
        placeholder: String,
        prefix: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)

            HStack(spacing: 4) {
                if let prefix {
                    Text(prefix).foregroundStyle(LaxifyPalette.textTertiary)
                }
                TextField(placeholder, text: text)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .autocorrectionDisabled(prefix != nil)
                    .textInputAutocapitalization(prefix != nil ? .never : .words)
            }
            .font(LaxifyTypography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .laxGlassCapsule()
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if isSaving { ProgressView().tint(.white) }
                Text(isSaving ? "Сохраняем…" : "Сохранить")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.5)
    }

    @ViewBuilder
    private var downloadsSection: some View {
        if downloads.totalBytes > 0 {
            VStack(spacing: 10) {
                HStack {
                    Label("Загруженная музыка", systemImage: "arrow.down.circle")
                        .font(LaxifyTypography.body)
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Spacer()

                    Text(downloads.formattedSize)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Button {
                    withAnimation { downloads.removeAll() }
                } label: {
                    Text("Очистить загрузки")
                        .font(LaxifyTypography.subheadline)
                        .foregroundStyle(LaxifyPalette.accent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .laxGlassCard()
        }
    }

    private var signOutButton: some View {
        Button {
            Task {
                await session.signOut()
                onClose()
            }
        } label: {
            Text("Выйти из аккаунта")
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let failure = await session.updateProfile(
            displayName: trimmedName,
            username: trimmedUsername
        )

        if let failure {
            withAnimation { errorMessage = failure }
        } else {
            onClose()
        }
    }
}
