import SwiftUI

enum AppTab: CaseIterable {
    case home
    case myWave
    case favorites
    case profile

    /// Localization key; `title` is the Russian fallback.
    var titleKey: String {
        switch self {
        case .home: "tab.home"
        case .myWave: "tab.wave"
        case .favorites: "tab.favorites"
        case .profile: "tab.profile"
        }
    }

    var title: String {
        switch self {
        case .home: "Главная"
        case .myWave: "Моя волна"
        case .favorites: "Избранное"
        case .profile: "Профиль"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .myWave: "dot.radiowaves.left.and.right"
        case .favorites: "heart.fill"
        case .profile: "person.fill"
        }
    }
}
