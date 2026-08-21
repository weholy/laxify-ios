import Foundation
import SwiftData

@Model
final class UserProfile {
    @Attribute(.unique) var googleUserId: String
    var email: String
    var displayName: String
    var username: String
    var birthdate: Date?
    var avatarData: Data?
    var googleAvatarURLString: String?
    var hasCompletedOnboarding: Bool
    var createdAt: Date

    init(
        googleUserId: String,
        email: String,
        displayName: String,
        username: String = "",
        birthdate: Date? = nil,
        avatarData: Data? = nil,
        googleAvatarURLString: String? = nil,
        hasCompletedOnboarding: Bool = false,
        createdAt: Date = .now
    ) {
        self.googleUserId = googleUserId
        self.email = email
        self.displayName = displayName
        self.username = username
        self.birthdate = birthdate
        self.avatarData = avatarData
        self.googleAvatarURLString = googleAvatarURLString
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.createdAt = createdAt
    }

    var googleAvatarURL: URL? {
        googleAvatarURLString.flatMap(URL.init(string:))
    }
}
