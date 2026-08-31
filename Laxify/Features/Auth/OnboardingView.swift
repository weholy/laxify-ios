import SwiftUI

/// Two questions, one at a time.
///
/// The old version asked for a name, a handle and a photograph on one screen,
/// which is three decisions before anyone has heard a note. A picture can be
/// set later from the profile and nothing depends on it, so it is not asked
/// for at all; what is left is a name and a handle, and each gets the screen
/// to itself.
struct OnboardingView: View {
    let suggestedName: String
    let suggestedUsername: String
    let googleAvatarURL: URL?

    private enum Step: Int {
        case name
        case username
    }

    @State private var step: Step = .name
    @State private var name: String
    @State private var username: String

    @State private var usernameStatus: UsernameStatus = .idle
    @State private var errorMessage: String?
    @State private var isSaving = false

    @FocusState private var isFocused: Bool

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

    private var isUsernameTaken: Bool {
        if case .taken = usernameStatus { return true }
        return false
    }

    private var canContinue: Bool {
        switch step {
        case .name:
            !trimmedName.isEmpty
        case .username:
            trimmedUsername.count >= 2
                && usernameStatus != .checking
                && !isUsernameTaken
                && !isSaving
        }
    }

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                backRow

                Spacer(minLength: 0)

                VStack(spacing: 30) {
                    heading
                    field
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)

                Spacer(minLength: 0)

                if let errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                        .padding(.bottom, 12)
                }

                continueButton
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 20)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: step) {
            // A beat, so the keyboard rises after the screen has settled
            // rather than racing the transition.
            try? await Task.sleep(for: .milliseconds(280))
            isFocused = true
        }
        .task(id: trimmedUsername) {
            guard step == .username else { return }
            await checkUsername()
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var backRow: some View {
        HStack {
            if step == .username {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { step = .name }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Spacer()

            // Two dots, so the second screen is not a surprise.
            HStack(spacing: 6) {
                ForEach([Step.name, Step.username], id: \.rawValue) { entry in
                    Capsule()
                        .fill(entry == step ? LaxifyPalette.accent : LaxifyPalette.separator)
                        .frame(width: entry == step ? 20 : 7, height: 7)
                }
            }
            .animation(.snappy(duration: 0.3), value: step)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 8)
    }

    private var heading: some View {
        VStack(spacing: 8) {
            Text(step == .name
                 ? L("onboarding.name.title", "Как вас зовут?")
                 : L("onboarding.username.title", "Придумайте юзернейм"))
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)

            Text(step == .name
                 ? L("onboarding.name.sub", "Так вас увидят на вашей странице")
                 : L("onboarding.username.sub", "По нему вас найдут в поиске"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .id(step)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    @ViewBuilder
    private var field: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                if step == .username {
                    Text("@").foregroundStyle(LaxifyPalette.textTertiary)
                }

                TextField(
                    step == .name
                        ? L("onboarding.name.placeholder", "Имя")
                        : "username",
                    text: step == .name ? $name : $username
                )
                .foregroundStyle(LaxifyPalette.textPrimary)
                .autocorrectionDisabled(step == .username)
                .textInputAutocapitalization(step == .username ? .never : .words)
                .submitLabel(step == .name ? .next : .done)
                .focused($isFocused)
                .onSubmit(advance)
            }
            .font(.system(size: 19, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .laxGlassCapsule()

            if step == .username {
                usernameNotice
            }
        }
    }

    @ViewBuilder
    private var usernameNotice: some View {
        switch usernameStatus {
        case .idle:
            Color.clear.frame(height: 20)

        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("onboarding.username.checking", "Проверяем…"))
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .frame(height: 20)

        case .available:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LaxifyPalette.accent)
                Text(L("onboarding.username.free", "Свободен"))
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .font(LaxifyTypography.caption)
            .frame(height: 20)

        case .taken(let reason, let suggestions):
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .foregroundStyle(.orange)
                }
                .font(LaxifyTypography.caption)

                if !suggestions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(3), id: \.self) { suggestion in
                            Button {
                                username = suggestion
                            } label: {
                                Text("@\(suggestion)")
                                    .font(LaxifyTypography.caption)
                                    .foregroundStyle(LaxifyPalette.accent)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(LaxifyPalette.accentMuted, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var continueButton: some View {
        Button(action: advance) {
            HStack(spacing: 8) {
                if isSaving { ProgressView().tint(.white) }
                Text(isSaving
                     ? L("onboarding.saving", "Сохраняем…")
                     : L("onboarding.continue", "Продолжить"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.5)
    }

    // MARK: - Flow

    private func advance() {
        guard canContinue else { return }

        switch step {
        case .name:
            withAnimation(.snappy(duration: 0.3)) { step = .username }
        case .username:
            Task { await save() }
        }
    }

    /// Checks the handle as it is typed, debounced so a burst of keystrokes
    /// doesn't turn into a burst of requests.
    private func checkUsername() async {
        let wanted = trimmedUsername
        guard wanted.count >= 2 else {
            usernameStatus = .idle
            return
        }

        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        usernameStatus = .checking

        guard let result = try? await LaxifyAPI.shared.checkUsername(wanted) else {
            usernameStatus = .idle
            return
        }
        // The field may have moved on while the answer was in flight; an
        // answer about a handle nobody is typing any more must not be shown.
        guard !Task.isCancelled, wanted == trimmedUsername else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            usernameStatus = result.available
                ? .available
                : .taken(
                    reason: result.reason ?? L("onboarding.username.taken", "Этот юзернейм уже занят"),
                    suggestions: result.suggestions
                )
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let failure = await session.completeOnboarding(
            displayName: trimmedName,
            username: trimmedUsername,
            avatarURL: googleAvatarURL?.absoluteString
        )

        if let failure {
            withAnimation { errorMessage = failure }
        }
    }
}
