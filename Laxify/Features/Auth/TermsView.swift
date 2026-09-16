import SwiftUI

/// What someone agrees to by signing in.
///
/// The site's page first, opened in the in-app browser, so the terms can be
/// updated without shipping a build. The text below is kept as the fallback:
/// this is read at the moment of signing in, which is exactly when someone
/// may have no connection — or, until the domain is live, no page to load.
struct TermsView: View {
    var onClose: () -> Void
    /// Which of the two documents to open with.
    var initialSection: Section = .terms

    @State private var section: Section = .terms
    /// Whether the web page failed to load, and the built-in text is shown.
    @State private var showsBuiltIn = false

    var body: some View {
        Group {
            if showsBuiltIn {
                builtIn
                    .transition(.opacity)
            } else {
                InAppBrowser(
                    url: initialSection == .terms ? AppLinks.terms : AppLinks.privacy,
                    onFinish: onClose,
                    onInitialLoad: { loaded in
                        guard !loaded else { return }
                        section = initialSection
                        withAnimation(.easeOut(duration: 0.2)) { showsBuiltIn = true }
                    }
                )
                .ignoresSafeArea()
            }
        }
    }

    enum Section: String, CaseIterable, Identifiable {
        case terms
        case privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terms: "Условия"
            case .privacy: "Данные"
            }
        }
    }

    private var builtIn: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Picker("", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(paragraphs, id: \.heading) { block in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(block.heading)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(LaxifyPalette.textPrimary)

                                Text(block.body)
                                    .font(.system(size: 15))
                                    .foregroundStyle(LaxifyPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Text("Полная версия — laxify.cc/terms")
                            .font(.system(size: 13))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 60)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            LaxifyCloseButton(style: .xmark, tinted: false, action: onClose)

            Spacer()

            Text("Условия использования")
                .font(LaxifyTypography.headline)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            Color.clear.frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.vertical, 14)
    }

    private var paragraphs: [(heading: String, body: String)] {
        switch section {
        case .terms:
            [
                ("Что такое Laxify",
                 "Laxify — приложение для прослушивания музыки. Мы не размещаем музыку сами: приложение показывает и воспроизводит то, что опубликовано на открытых музыкальных платформах, и права на неё принадлежат их авторам и правообладателям."),
                ("Ваш аккаунт",
                 "Аккаунт нужен, чтобы избранное, плейлисты и статистика были одинаковыми на всех ваших устройствах. Отвечайте за сохранность пароля: любой, кто его знает, получит доступ к вашей библиотеке."),
                ("Как пользоваться",
                 "Слушайте сколько угодно и для себя. Не используйте приложение для перепродажи музыки, массового скачивания или обхода ограничений правообладателей."),
                ("Если что-то не работает",
                 "Приложение зависит от внешних источников музыки. Иногда трек становится недоступен не по нашей вине — мы стараемся такие случаи замечать и обходить, но гарантировать доступность каждой записи не можем."),
                ("Изменения",
                 "Условия могут меняться. О существенных изменениях мы сообщим в приложении до того, как они вступят в силу.")
            ]
        case .privacy:
            [
                ("Что мы храним",
                 "Почту, имя и то, что вы сами добавили в профиль. Избранное, плейлисты и историю прослушиваний — чтобы они были на всех ваших устройствах и чтобы работала «Моя волна»."),
                ("Статистика",
                 "Мы записываем, что и сколько вы слушали. Это нужно для экрана статистики и для подбора музыки. По умолчанию её видите только вы — открыть её другим можно в настройках."),
                ("Диагностика",
                 "Приложение отправляет технические записи о своей работе: сколько занял запуск трека, какие ошибки произошли. Это нужно, чтобы находить и чинить проблемы. Содержимое вашей библиотеки в них не попадает."),
                ("Чего мы не делаем",
                 "Не продаём ваши данные, не передаём их рекламным сетям и не читаем вашу переписку — приложение к ней и не имеет доступа."),
                ("Удаление",
                 "Вы можете выйти из аккаунта в любой момент. Чтобы удалить аккаунт вместе со всеми данными, напишите нам — сделаем это без вопросов.")
            ]
        }
    }
}
