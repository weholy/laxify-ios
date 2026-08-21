import Foundation
import SwiftData

@Model
final class DislikedTrack {
    @Attribute(.unique) var id: String
    var dislikedAt: Date

    init(id: String, dislikedAt: Date = .now) {
        self.id = id
        self.dislikedAt = dislikedAt
    }
}
