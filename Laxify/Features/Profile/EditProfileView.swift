import SwiftUI
import PhotosUI

struct EditProfileView: View {
    var onClose: () -> Void

    @State private var session = SessionStore.shared

    @State private var name: String
    @State private var username: String
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false

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
            PhotosPicker(selection: $avatarItem, matching: .images) {
                avatarImage
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white, LaxifyPalette.accent)
                            .offset(x: 2, y: 2)
                    }
                    .overlay {
                        if isUploadingAvatar {
                            Circle().fill(.black.opacity(0.45))
                            ProgressView().tint(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isUploadingAvatar)

            Text(L("profile.photo.hint", "Нажмите, чтобы сменить фото"))
                .font(LaxifyTypography.caption)
                .foregroundStyle(LaxifyPalette.textTertiary)
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        errorMessage = nil
        defer { isUploadingAvatar = false; avatarItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            withAnimation { errorMessage = "Не удалось прочитать фото" }
            return
        }
        do {
            let url = try await LaxifyAPI.shared.uploadMedia(
                data, filename: "avatar.jpg", mimeType: "image/jpeg"
            )
            if let failure = await session.updateProfile(avatarURL: url.absoluteString) {
                withAnimation { errorMessage = failure }
            }
        } catch {
            withAnimation { errorMessage = "Не удалось загрузить фото" }
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
