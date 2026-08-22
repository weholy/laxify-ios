import SwiftUI

/// What the app is doing, shown on the device.
///
/// Diagnostics normally go to the server, which is useless here: the only
/// networks worth diagnosing are the ones where the server cannot be reached.
/// So the log is kept on the phone, shown here, and can be handed over as a
/// file — the one route that works when nothing else does.
struct DiagnosticsView: View {
    var onBack: () -> Void

    @State private var routes: [String: Bool] = [:]
    @State private var sourceCheck: SourceCheck = .pending
    @State private var entries: [RemoteLog.Entry] = []
    @State private var exported: URL?

    enum SourceCheck: Equatable {
        case pending
        case ok(key: String)
        case failed(String)
    }

    var body: some View {
        SettingsPage(title: "Диагностика", status: nil, onBack: onBack) {
            sourceCard
            routesCard
            actions
            logCard
        }
        .task { await refresh() }
    }

    // MARK: - Source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Источник музыки")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.leading, 4)

            SettingsCard {
                HStack(spacing: 14) {
                    statusDot(for: sourceCheck == .pending ? nil : isSourceOK)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sourceTitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(LaxifyPalette.textPrimary)

                        Text(sourceDetail)
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
        }
    }

    private var isSourceOK: Bool {
        if case .ok = sourceCheck { return true }
        return false
    }

    private var sourceTitle: String {
        switch sourceCheck {
        case .pending: "Проверяем…"
        case .ok: "Музыка доступна"
        case .failed: "Музыка недоступна"
        }
    }

    private var sourceDetail: String {
        switch sourceCheck {
        case .pending:
            "Идёт проверка соединения"
        case .ok(let key):
            "Ключ получен: \(key.prefix(8))…"
        case .failed(let reason):
            reason
        }
    }

    // MARK: - Routes

    private var routesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Наш сервер")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.leading, 4)

            SettingsCard {
                if routes.isEmpty {
                    HStack(spacing: 14) {
                        ProgressView().tint(LaxifyPalette.textTertiary)
                        Text("Проверяем маршруты…")
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(LaxifyPalette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                } else {
                    ForEach(routes.keys.sorted(), id: \.self) { route in
                        if route != routes.keys.sorted().first {
                            SettingsDivider()
                        }

                        HStack(spacing: 12) {
                            statusDot(for: routes[route] ?? false)

                            Text(shortened(route))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 4)

                            Text(routes[route] == true ? "есть" : "нет")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    routes[route] == true ? .green : LaxifyPalette.textTertiary
                                )
                        }
                        .padding(14)
                    }
                }
            }

            if !routes.isEmpty, routes.values.allSatisfy({ !$0 }) {
                Text("Ни один адрес не отвечает. Музыка работает напрямую от источника, а профиль и синхронизация — нет.")
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Drops the scheme and the path, which are the same on every row and
    /// take the space the host needs.
    private func shortened(_ route: String) -> String {
        route
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "/api/v1", with: "")
    }

    private func statusDot(for ok: Bool?) -> some View {
        Circle()
            .fill(ok == nil ? LaxifyPalette.textTertiary : (ok! ? .green : .red))
            .frame(width: 10, height: 10)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await refresh() }
            } label: {
                Text("Проверить заново")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(LaxifyPalette.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain)

            if let exported {
                ShareLink(item: exported) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Отправить журнал")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Последние записи")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .textCase(.uppercase)
                .kerning(0.5)
                .padding(.leading, 4)

            SettingsCard {
                if entries.isEmpty {
                    Text("Пока пусто. Включите трек и вернитесь сюда.")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        // Newest first: the interesting line is the last one
                        // that happened, and scrolling to find it is work.
                        ForEach(Array(entries.reversed().prefix(60).enumerated()), id: \.offset) { _, entry in
                            row(entry)
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: RemoteLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(colour(for: entry.level))
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let details = detail(for: entry) {
                    Text(details)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            if let ms = entry.durationMs {
                Text("\(ms) мс")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ms > 3000 ? .orange : LaxifyPalette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func detail(for entry: RemoteLog.Entry) -> String? {
        guard !entry.context.isEmpty else { return nil }
        return entry.context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
    }

    private func colour(for level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        default: LaxifyPalette.textTertiary
        }
    }

    // MARK: - Checking

    private func refresh() async {
        sourceCheck = .pending
        routes = [:]

        // Whatever the log already holds, immediately. The checks below take
        // seconds, and a screen that shows nothing while it works looks
        // broken — which on the networks it is meant to diagnose is exactly
        // the wrong impression.
        entries = await RemoteLog.shared.recent()

        // The two checks are independent, so neither waits for the other.
        async let source: Void = checkSource()
        async let server: Void = checkRoutes()
        _ = await (source, server)

        // Re-read at the end: the checks themselves wrote to the log, and
        // those lines are the interesting ones.
        entries = await RemoteLog.shared.recent()
        exported = try? await RemoteLog.shared.exportFile()
    }

    private func checkSource() async {
        do {
            let key = try await SoundCloudDirect.shared.diagnosticKey()
            withAnimation(.easeOut(duration: 0.25)) { sourceCheck = .ok(key: key) }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            withAnimation(.easeOut(duration: 0.25)) { sourceCheck = .failed(reason) }
        }

        entries = await RemoteLog.shared.recent()
    }

    private func checkRoutes() async {
        await APIRouter.shared.discover(force: true)
        let found = await APIRouter.shared.lastProbeResults
        withAnimation(.easeOut(duration: 0.25)) { routes = found }
    }
}
