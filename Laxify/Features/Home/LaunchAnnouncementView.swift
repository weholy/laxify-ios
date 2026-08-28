import SwiftUI

/// The "what's new" card shown once per version on launch. A sheet the way
/// system apps do it — a title, a paragraph, one button.
struct LaunchAnnouncementView: View {
    let announcement: Announcement
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(LaxifyPalette.separator)
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 20)

            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(LaxifyPalette.accent)
                .padding(.bottom, 14)

            Text(announcement.title)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            ScrollView {
                Text(announcement.body)
                    .font(.system(size: 15))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
            }

            Button {
                onDismiss()
            } label: {
                Text(announcement.cta)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 14)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(LaxifyPalette.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}
