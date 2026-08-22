import SwiftUI

/// Confirming an address, or moving the account to a different one.
///
/// This is where the four-digit code lives. It is deliberately not on the way
/// in: a code that fails to arrive should cost someone a badge in settings,
/// not the ability to listen to anything.
struct EmailBindingSheet: View {
    var onFinished: (String) -> Void

    @State private var session = SessionStore.shared
    @State private var email = ""
    @State private var code = ""
    @State private var isBusy = false
    @State private var codeSent = false
    @State private var resendAfter = 0
    @State private var errorMessage: String?

    @FocusState private var isEditingEmail: Bool

    var body: some View {
        SheetShell(title: codeSent ? "Введите код" : "Почта") {
            VStack(spacing: 20) {
                Text(codeSent
                     ? "Отправили код на \(email)"
                     : "Подтвердите адрес, чтобы восстановить доступ, если забудете пароль")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)

                if codeSent {
                    CodeEntryField(code: $code) { confirm() }
                } else {
                    TextField("почта@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isEditingEmail)
                        .fieldStyle()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: codeSent ? confirm : requestCode) {
                    HStack(spacing: 8) {
                        if isBusy { ProgressView().tint(LaxifyPalette.background) }
                        Text(codeSent ? "Подтвердить" : "Отправить код")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(LaxifyPalette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LaxifyPalette.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isBusy || !isReady)
                .opacity(isReady ? 1 : 0.45)

                if codeSent {
                    Button {
                        requestCode()
                    } label: {
                        Text(resendAfter > 0
                             ? "Отправить снова через \(resendAfter) с"
                             : "Отправить ещё раз")
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(
                                resendAfter > 0 ? LaxifyPalette.textTertiary : LaxifyPalette.accent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(resendAfter > 0 || isBusy)
                }
            }
        }
        .onAppear {
            email = session.user?.email ?? ""
            isEditingEmail = true
        }
        .task(id: resendAfter) {
            guard resendAfter > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            resendAfter -= 1
        }
    }

    private var isReady: Bool {
        codeSent ? code.count == 4 : (email.contains("@") && email.contains("."))
    }

    private func requestCode() {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let response = try await LaxifyAPI.shared.requestEmailCode(
                    email: email, purpose: "change"
                )
                resendAfter = response.resendAfterSeconds
                withAnimation(.snappy(duration: 0.25)) { codeSent = true }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось отправить код"
            }
            isBusy = false
        }
    }

    private func confirm() {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let result = try await LaxifyAPI.shared.changeEmail(to: email, code: code)
                await session.refreshUser()
                onFinished(result.detail)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Неверный код"
                code = ""
            }
            isBusy = false
        }
    }
}

/// Setting or changing the password used for signing in by email.
struct PasswordChangeSheet: View {
    var onFinished: (String) -> Void

    @State private var session = SessionStore.shared
    @State private var current = ""
    @State private var updated = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    /// A Google account has no password until one is set, so asking for the
    /// current one would be asking for something that does not exist.
    private var hasPassword: Bool { session.user?.hasPassword ?? false }

    var body: some View {
        SheetShell(title: hasPassword ? "Смена пароля" : "Пароль") {
            VStack(spacing: 20) {
                Text(hasPassword
                     ? "Введите текущий пароль и новый"
                     : "Задайте пароль, чтобы входить по почте без Google")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)

                if hasPassword {
                    SecureField("Текущий пароль", text: $current)
                        .textContentType(.password)
                        .fieldStyle()
                }

                SecureField("Новый пароль", text: $updated)
                    .textContentType(.newPassword)
                    .fieldStyle()

                Text("Не короче 8 символов, с буквой и цифрой")
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if isBusy { ProgressView().tint(LaxifyPalette.background) }
                        Text(hasPassword ? "Сменить пароль" : "Задать пароль")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(LaxifyPalette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LaxifyPalette.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isBusy || updated.count < 8)
                .opacity(updated.count >= 8 ? 1 : 0.45)
            }
        }
    }

    private func submit() {
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let result = try await LaxifyAPI.shared.changePassword(
                    current: hasPassword ? current : nil,
                    new: updated
                )
                await session.refreshUser()
                onFinished(result.detail)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось сменить пароль"
            }
            isBusy = false
        }
    }
}

// MARK: - Shared pieces

/// The frame every account sheet shares.
struct SheetShell<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(LaxifyPalette.separator)
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            content()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaxifyPalette.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

/// Four boxes that read as one field.
///
/// A single text field is what actually receives the keystrokes; the boxes
/// are drawn on top of it. Four real fields would mean managing focus between
/// them, which breaks paste and the one-time code the keyboard offers.
struct CodeEntryField: View {
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
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(LaxifyPalette.accent, lineWidth: isNext ? 2 : 0)
            }
            .animation(.snappy(duration: 0.18), value: isFilled)
            .animation(.snappy(duration: 0.18), value: isNext)
    }
}
