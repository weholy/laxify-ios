import SwiftUI
import PhotosUI

struct EditProfileView: View {
    let profile: UserProfile
    var onClose: () -> Void

    @State private var name: String
    @State private var username: String
    @State private var includesBirthdate: Bool
    @State private var birthdate: Date
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?

    init(profile: UserProfile, onClose: @escaping () -> Void) {
        self.profile = profile
        self.onClose = onClose
        _name = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username)
        _includesBirthdate = State(initialValue: profile.birthdate != nil)
        _birthdate = State(initialValue: profile.birthdate ?? Calendar.current.date(byAdding: .year, value: -18, to: .now) ?? .now)
        _avatarData = State(initialValue: profile.avatarData)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedUsername.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: LaxifyMetrics.sectionSpacing) {
                header
                avatarPicker
                fields
                birthdateSection
                saveButton
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .task(id: avatarItem) {
            guard let avatarItem, let data = try? await avatarItem.loadTransferable(type: Data.self) else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                avatarData = data
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Профиль")
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.laxifyIcon)
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
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if let url = profile.googleAvatarURL {
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
                    .font(.system(size: 38))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
    }

    private var fields: some View {
        VStack(spacing: 12) {
            field(title: "Имя", text: $name, placeholder: "Имя")
            field(title: "Юзернейм", text: $username, placeholder: "username", prefix: "@")
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String, prefix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)

            HStack(spacing: 4) {
                if let prefix {
                    Text(prefix)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                TextField(placeholder, text: text)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .autocorrectionDisabled(prefix != nil)
                    .textInputAutocapitalization(prefix != nil ? .never : .words)
            }
            .font(LaxifyTypography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .laxGlassCapsule()
        }
    }

    private var birthdateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includesBirthdate.animation(.easeInOut(duration: 0.2))) {
                Text("Дата рождения")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textPrimary)
            }
            .tint(LaxifyPalette.accent)

            if includesBirthdate {
                DatePicker("", selection: $birthdate, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .laxGlassCard()
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("Сохранить")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.5)
    }

    private func save() {
        profile.displayName = trimmedName
        profile.username = trimmedUsername
        profile.birthdate = includesBirthdate ? birthdate : nil
        profile.avatarData = avatarData
        onClose()
    }
}
