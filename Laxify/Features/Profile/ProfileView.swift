import SwiftUI

struct ProfileView: View {
    @State private var logText = AppLogger.readAll()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                Text("Профиль")
                    .font(LaxifyTypography.largeTitle)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .padding(.horizontal, LaxifyMetrics.screenPadding)

                diagnosticsSection
            }
            .padding(.top, 12)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)
        }
        .background(LaxifyPalette.background)
        .onAppear {
            logText = AppLogger.readAll()
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Диагностика")
                    .font(LaxifyTypography.title)
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Spacer()

                Button {
                    logText = AppLogger.readAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.laxifyIcon)

                Button {
                    AppLogger.clear()
                    logText = AppLogger.readAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.laxifyIcon)
            }

            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 320)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: LaxifyMetrics.smallCornerRadius, style: .continuous))

            Button {
                UIPasteboard.general.string = logText
            } label: {
                Label("Скопировать логи", systemImage: "doc.on.doc")
            }
            .buttonStyle(.laxifySecondary)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }
}

#Preview {
    ProfileView()
}
