import SwiftUI

/// Builds a list of artists and hands it over as a file.
///
/// The work has to happen here rather than on the server: the catalogue being
/// read answers 451 to the server and only lets a device in Russia through.
/// So the phone collects it, writes a file, and the share sheet does the rest.
struct CatalogExportView: View {
    var onBack: () -> Void

    @State private var export = YandexCatalogExport.shared

    var body: some View {
        SettingsPage(title: "Выгрузка артистов", status: nil, onBack: onBack) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Собирает список исполнителей из справочного каталога и сохраняет его файлом.")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Занимает несколько минут. Не закрывайте экран, пока идёт сбор.")
                        .font(.system(size: 12))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }

            switch export.phase {
            case .idle:
                startButton

            case .running(let stage, let done, let total, let found):
                progress(stage: stage, done: done, total: total, found: found)
                cancelButton

            case .finished(let count, let file):
                result(count: count, file: file)

            case .failed(let message):
                failure(message)
            }
        }
    }

    private var startButton: some View {
        Button {
            export.start()
        } label: {
            Text("Начать сбор")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LaxifyPalette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LaxifyPalette.textPrimary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func progress(stage: String, done: Int, total: Int, found: Int) -> some View {
        SettingsCard {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(found)")
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .contentTransition(.numericText())

                    Text("исполнителей")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(LaxifyPalette.accent)

                Text("\(stage) · \(done) из \(total)")
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
            .padding(18)
            .animation(.easeOut(duration: 0.3), value: found)
        }
    }

    private var cancelButton: some View {
        Button {
            export.cancel()
        } label: {
            Text("Остановить")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .glassEffect(.regular.tint(.red.opacity(0.12)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func result(count: Int, file: URL) -> some View {
        VStack(spacing: 14) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Готово")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textPrimary)

                        Text("\(count.spaced) исполнителей в файле")
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(LaxifyPalette.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            ShareLink(item: file) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Отправить файл")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LaxifyPalette.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LaxifyPalette.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                export.cancel()
            } label: {
                Text("Собрать заново")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)

                    Text(message)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            startButton
        }
    }
}
