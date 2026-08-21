import Foundation
import SwiftData

@Model
final class SearchHistoryEntry {
    @Attribute(.unique) var id: String
    var title: String
    var subtitle: String?
    var coverURLString: String?
    var searchedAt: Date

    init(id: String, title: String, subtitle: String?, coverURLString: String?, searchedAt: Date = .now) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverURLString = coverURLString
        self.searchedAt = searchedAt
    }

    var coverURL: URL? {
        coverURLString.flatMap(URL.init(string:))
    }
}
