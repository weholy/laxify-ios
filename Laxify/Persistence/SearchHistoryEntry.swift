import Foundation
import SwiftData

@Model
final class SearchHistoryEntry {
    @Attribute(.unique) var query: String
    var searchedAt: Date

    init(query: String, searchedAt: Date = .now) {
        self.query = query
        self.searchedAt = searchedAt
    }
}
