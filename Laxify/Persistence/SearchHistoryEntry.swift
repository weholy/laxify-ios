import Foundation
import SwiftData

enum SearchHistoryKind: String, Codable {
    case track
    case artist
}

@Model
final class SearchHistoryEntry {
    @Attribute(.unique) var id: String
    var title: String
    var subtitle: String?
    var coverURLString: String?
    var kindRawValue: String
    var searchedAt: Date

    init(id: String, title: String, subtitle: String?, coverURLString: String?, kind: SearchHistoryKind, searchedAt: Date = .now) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverURLString = coverURLString
        self.kindRawValue = kind.rawValue
        self.searchedAt = searchedAt
    }

    var kind: SearchHistoryKind {
        SearchHistoryKind(rawValue: kindRawValue) ?? .track
    }

    var coverURL: URL? {
        coverURLString.flatMap(URL.init(string:))
    }
}
