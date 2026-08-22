import SwiftUI

/// Signing in with an address instead of Google.
///
/// Google's sign-in is not reachable everywhere Laxify is, and an account
/// nobody can get into is worse than one with an extra step.
///
/// Two fields, in sequence: the address, then a password. Whether that
/// password signs in or creates an account is worked out from the address —
/// asking which one someone meant is a question they should not have to
/// answer. Confirming the address happens later, in settings, so a code that
/// fails to arrive never blocks anyone from listening.
struct EmailSignInView: View {
    /// Called once a session exists, with the response that created it —
    /// the caller needs to know whether the account is brand new.
    var onSignedIn: (BackendSessionResponse) async -> Void
    var onCancel: () -> Void

    private enum Step {
        case email
        /// New account: a password is being chosen.
        case password
        /// Existing account: the password is being entered.
        case existingPassword
    }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var appear = false

    @FocusState private var focus: Field?
    private enum Field { case email, password }

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 24) {
                        title

                        switch step {
                        case .email:
                            emailField
                        case .password, .existingPassword:
                            passwordField
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        primaryButton

                        if step != .email {
                            switchModeButton
                        }
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 16)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { appear = true }
            focus = .email
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button {
                back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 12)
    }

    private var title: some View {
        VStack(spacing: 8) {
            Text(headline)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)

            Text(subheadline)
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }

    private var headline: String {
        switch step {
        case .email: "Вход по почте"
        case .password: "Придумайте пароль"
        case .existingPassword: "Введите пароль"
        }
    }

    private var subheadline: String {
        switch step {
        case .email: "Войдём или создадим аккаунт"
        case .password: "Не короче 8 символов, с буквой и цифрой"
        case .existingPassword: email
        }
    }

    private var emailField: some View {
        TextField("почта@example.com", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .email)
            .submitLabel(.continue)
            .onSubmit(advance)
            .fieldStyle()
    }

    private var passwordField: some View {
        SecureField("Пароль", text: $password)
            .textContentType(step == .password ? .newPassword : .password)
            .focused($focus, equals: .password)
            .submitLabel(.done)
            .onSubmit(advance)
            .fieldStyle()
    }

    private var primaryButton: some View {
        Button(action: advance) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(LaxifyPalette.background)
                }
                Text(buttonTitle)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(LaxifyPalette.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LaxifyPalette.textPrimary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !isStepComplete)
        .opacity(isStepComplete ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: isStepComplete)
    }

    private var buttonTitle: String {
        switch step {
        case .email: "Продолжить"
        case .password: "Создать аккаунт"
        case .existingPassword: "Войти"
        }
    }

    private var isStepComplete: Bool {
        switch step {
        case .email: email.contains("@") && email.contains(".")
        case .password, .existingPassword: password.count >= 8
        }
    }

    /// Lets someone correct the guess — they have an account and the app
    /// assumed otherwise, or the other way round.
    private var switchModeButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                step = step == .password ? .existingPassword : .password
                errorMessage = nil
            }
        } label: {
            Text(step == .password ? "У меня уже есть аккаунт" : "Создать новый аккаунт")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.accent)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: - Flow

    private func back() {
        switch step {
        case .email:
            onCancel()
        case .password, .existingPassword:
            withAnimation(.snappy(duration: 0.25)) { step = .email }
            password = ""
        }
    }

    private func advance() {
        guard isStepComplete, !isBusy else { return }

        switch step {
        case .email:
            // Assume an existing account and ask for the password. If there
            // is none, signing in falls through to creating one — which is
            // one fewer question than asking up front which was meant.
            withAnimation(.snappy(duration: 0.25)) {
                step = .existingPassword
                errorMessage = nil
            }
            focus = .password
        case .password:
            createAccount()
        case .existingPassword:
            signInWithPassword()
        }
    }

    private func createAccount() {
        run { [email, password] in
            let created = try await LaxifyAPI.shared.registerWithEmail(
                email: email, password: password
            )
            await onSignedIn(created)
        }
    }

    private func signInWithPassword() {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let created = try await LaxifyAPI.shared.signInWithEmail(
                    email: email, password: password
                )
                await onSignedIn(created)
                isBusy = false
            } catch {
                isBusy = false

                // No account with this address yet — move to creating one
                // rather than showing a dead end.
                if case APIError.server(let status, _) = error, status == 401 {
                    withAnimation(.snappy(duration: 0.25)) {
                        step = .password
                        password = ""
                        errorMessage = nil
                    }
                    focus = .password
                } else {
                    show(error)
                }
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                try await work()
            } catch {
                show(error)
            }
            isBusy = false
        }
    }

    private func show(_ error: Error) {
        withAnimation(.easeOut(duration: 0.2)) {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Что-то пошло не так. Попробуйте ещё раз"
        }
    }
}

// MARK: - Field styling

extension View {
    func fieldStyle() -> some View {
        font(.system(size: 17))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}
