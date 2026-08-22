import SwiftUI

/// Signing in with an address instead of Google.
///
/// Google's sign-in is not reachable everywhere Laxify is, and an account
/// nobody can get into is worse than one with an extra step. Three steps —
/// address, the code that lands in the inbox, then a password — with each one
/// replacing the last rather than stacking, so the screen never grows.
struct EmailSignInView: View {
    /// Called once a session exists; the caller decides where to go next.
    var onSignedIn: () async -> Void
    var onCancel: () -> Void

    private enum Step {
        case email
        case code
        case password
        /// Existing account: the address is known and only the password is
        /// missing, so the code step is skipped entirely.
        case existingPassword
    }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var resendAfter = 0
    @State private var appear = false

    @FocusState private var focus: Field?
    private enum Field { case email, code, password }

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
                        case .code:
                            codeField
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

                        if step == .code {
                            resendButton
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
        .task(id: resendAfter) {
            guard resendAfter > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            resendAfter -= 1
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
        case .code: "Введите код"
        case .password: "Придумайте пароль"
        case .existingPassword: "Введите пароль"
        }
    }

    private var subheadline: String {
        switch step {
        case .email: "Пришлём код подтверждения"
        case .code: "Отправили на \(email)"
        case .password: "Не короче 8 символов, с буквой и цифрой"
        case .existingPassword: "Для \(email)"
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

    private var codeField: some View {
        CodeEntryField(code: $code, onComplete: advance)
            .focused($focus, equals: .code)
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
        case .email: "Получить код"
        case .code: "Подтвердить"
        case .password: "Создать аккаунт"
        case .existingPassword: "Войти"
        }
    }

    private var isStepComplete: Bool {
        switch step {
        case .email: email.contains("@") && email.contains(".")
        case .code: code.count == 4
        case .password, .existingPassword: password.count >= 8
        }
    }

    private var resendButton: some View {
        Button {
            requestCode(resend: true)
        } label: {
            Text(resendAfter > 0 ? "Отправить снова через \(resendAfter) с" : "Отправить код ещё раз")
                .font(LaxifyTypography.footnote)
                .foregroundStyle(
                    resendAfter > 0 ? LaxifyPalette.textTertiary : LaxifyPalette.accent
                )
        }
        .buttonStyle(.plain)
        .disabled(resendAfter > 0 || isBusy)
    }

    // MARK: - Flow

    private func back() {
        switch step {
        case .email:
            onCancel()
        case .code:
            withAnimation(.snappy(duration: 0.25)) { step = .email }
            code = ""
        case .password, .existingPassword:
            withAnimation(.snappy(duration: 0.25)) { step = .email }
            password = ""
        }
    }

    private func advance() {
        guard isStepComplete, !isBusy else { return }

        switch step {
        case .email:
            // An address that already has a password only needs the password,
            // so try that route before sending anyone a code they don't need.
            attemptExistingAccount()
        case .code:
            verifyCode()
        case .password:
            completeRegistration()
        case .existingPassword:
            signInWithPassword()
        }
    }

    private func attemptExistingAccount() {
        withAnimation(.snappy(duration: 0.25)) {
            step = .existingPassword
            errorMessage = nil
        }
        focus = .password
    }

    private func requestCode(resend: Bool = false) {
        run { [email] in
            let response = try await LaxifyAPI.shared.requestEmailCode(email: email, purpose: "bind")
            await MainActor.run {
                resendAfter = response.resendAfterSeconds
                if !resend {
                    withAnimation(.snappy(duration: 0.25)) { step = .code }
                    focus = .code
                }
                code = ""
            }
        }
    }

    private func verifyCode() {
        run { [email, code] in
            let result = try await LaxifyAPI.shared.verifyEmailCode(
                email: email, code: code, purpose: "bind"
            )
            await MainActor.run {
                withAnimation(.snappy(duration: 0.25)) {
                    step = result.needsPassword ? .password : .existingPassword
                }
                focus = .password
            }
        }
    }

    private func completeRegistration() {
        run { [email, code, password] in
            try await LaxifyAPI.shared.setEmailPassword(
                email: email, code: code, password: password
            )
            await onSignedIn()
        }
    }

    private func signInWithPassword() {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                try await LaxifyAPI.shared.signInWithEmail(email: email, password: password)
                await onSignedIn()
                isBusy = false
            } catch {
                isBusy = false
                // No account with this address yet — send a code and register
                // instead of showing a dead end.
                if case APIError.server(let status, _) = error, status == 401 {
                    requestCode()
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

private extension View {
    func fieldStyle() -> some View {
        font(.system(size: 17))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Four boxes that read as one field.
///
/// A single text field is what actually receives the keystrokes; the boxes
/// are drawn on top of it. Four real fields would mean managing focus between
/// them, which breaks paste and the autofill code the keyboard offers.
private struct CodeEntryField: View {
    @Binding var code: String
    var onComplete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0.001)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(4))
                    if digits != value { code = digits }
                    if digits.count == 4 { onComplete() }
                }

            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    box(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func box(at index: Int) -> some View {
        let characters = Array(code)
        let isFilled = index < characters.count
        let isNext = index == characters.count && isFocused

        return Text(isFilled ? String(characters[index]) : "")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .foregroundStyle(LaxifyPalette.textPrimary)
            .frame(width: 62, height: 72)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(LaxifyPalette.accent, lineWidth: isNext ? 2 : 0)
            }
            .animation(.snappy(duration: 0.18), value: isFilled)
            .animation(.snappy(duration: 0.18), value: isNext)
    }
}
