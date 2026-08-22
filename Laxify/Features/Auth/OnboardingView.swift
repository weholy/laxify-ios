import SwiftUI
import PhotosUI

struct OnboardingView: View {
    let suggestedName: String
    let suggestedUsername: String
    let googleAvatarURL: URL?

    @State private var name: String
    @State private var username: String
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?

    @State private var usernameStatus: UsernameStatus = .idle
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var appear = false

    private var session = SessionStore.shared

    private enum UsernameStatus: Equatable {
        case idle
        case checking
        case available
        case taken(reason: String, suggestions: [String])
    }

    init(suggestedName: String, suggestedUsername: String, googleAvatarURL: URL?) {
        self.suggestedName = suggestedName
        self.suggestedUsername = suggestedUsername
        self.googleAvatarURL = googleAvatarURL
        _name = State(initialValue: suggestedName)
        _username = State(initialValue: suggestedUsername)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canContinue: Bool {
        !trimmedName.isEmpty
            && trimmedUsername.count >= 2
            && usernameStatus != .checking
            && !isSaving
            && !isUsernameTaken
    }

    private var isUsernameTaken: Bool {
        if case .taken = usernameStatus { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                header
                avatarPicker
                fields

                if let errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                continueButton
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 16)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appear = true }
        }
        .task(id: avatarItem) {
            guard let avatarItem,
                  let data = try? await avatarItem.loadTransferable(type: Data.self) else { return }
            withAnimation(.easeInOut(duration: 0.25)) { avatarData = data }
        }
        .task(id: trimmedUsername) {
            await checkUsername()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Almost done")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.accent)
                .textCase(.uppercase)
                .kerning(1.2)
                .hidden()

            Text("Расскажите о себе")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            Text("Это займёт меньше минуты")
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $avatarItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                avatarImage
                    .frame(width: 112, height: 112)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }

                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LaxifyPalette.accent, in: Circle())
                    .overlay(Circle().stroke(LaxifyPalette.background, lineWidth: 3))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let avatarData, let uiImage = UIImage(data: avatarData) {
            Image(uiImage: uiImage).resizable().scaledToFill()
        } else if let googleAvatarURL {
            AsyncImage(url: googleAvatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(LaxifyPalette.surface)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
    }

    private var fields: some View {
        VStack(spacing: 16) {
            field(title: "Имя", text: $name, placeholder: "Как вас зовут")

            VStack(alignment: .leading, spacing: 8) {
                field(title: "Юзернейм", text: $username, placeholder: "username", prefix: "@")
                usernameFeedback
            }
        }
    }

    @ViewBuilder
    private var usernameFeedback: some View {
        switch usernameStatus {
        case .idle:
            EmptyView()

        case .checking:
            Text("Проверяем…")
                .font(LaxifyTypography.caption)
                .foregroundStyle(LaxifyPalette.textTertiary)

        case .available:
            Label("Свободен", systemImage: "checkmark.circle.fill")
                .font(LaxifyTypography.caption)
                .foregroundStyle(.green)

        case .taken(let reason, let suggestions):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(.orange)

                if !suggestions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(3), id: \.self) { suggestion in
                            Button {
                                username = suggestion
                            } label: {
                                Text("@\(suggestion)")
                                    .font(LaxifyTypography.caption)
                                    .foregroundStyle(LaxifyPalette.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(LaxifyPalette.accentMuted, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .transition(.opacity)
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

    private var continueButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                }
                Text(isSaving ? "Сохраняем…" : "Продолжить")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.5)
    }

    /// Checks the handle as it is typed, debounced so a burst of keystrokes
    /// doesn't turn into a burst of requests.
    private func checkUsername() async {
        guard trimmedUsername.count >= 2 else {
            usernameStatus = .idle
            return
        }

        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }

        usernameStatus = .checking

        guard let result = try? await LaxifyAPI.shared.checkUsername(trimmedUsername) else {
            usernameStatus = .idle
            return
        }
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            usernameStatus = result.available
                ? .available
                : .taken(
                    reason: result.reason ?? "Этот юзернейм занят",
                    suggestions: result.suggestions
                )
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // The avatar image itself needs an upload endpoint that does not exist
        // yet, so only the Google picture URL is carried over for now.
        let failure = await session.completeOnboarding(
            displayName: trimmedName,
            username: trimmedUsername,
            birthdate: nil,
            avatarURL: googleAvatarURL?.absoluteString
        )

        if let failure {
            withAnimation { errorMessage = failure }
        }
    }
}
