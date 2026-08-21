import SwiftUI

enum AppTab: CaseIterable {
    case home
    case favorites
    case profile

    var title: String {
        switch self {
        case .home: "Главная"
        case .favorites: "Избранное"
        case .profile: "Профиль"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .favorites: "heart.fill"
        case .profile: "person.fill"
        }
    }
}
