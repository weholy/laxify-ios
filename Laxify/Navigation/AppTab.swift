import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case myWave
    case favorites
    case profile
    case search

    /// The four that sit in the main tab strip; `search` is the trailing
    /// search-role tab.
    static var main: [AppTab] { [.home, .myWave, .favorites, .profile] }

    /// Localization key; `title` is the Russian fallback.
    var titleKey: String {
        switch self {
        case .home: "tab.home"
        case .myWave: "tab.wave"
        case .favorites: "tab.favorites"
        case .profile: "tab.profile"
        case .search: "search.title"
        }
    }

    var title: String {
        switch self {
        case .home: "Главная"
        case .myWave: "Моя волна"
        case .favorites: "Избранное"
        case .profile: "Профиль"
        case .search: "Поиск"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .myWave: "dot.radiowaves.left.and.right"
        case .favorites: "heart.fill"
        case .profile: "person.fill"
        case .search: "magnifyingglass"
        }
    }
}
