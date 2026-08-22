import Foundation

extension Int {
    /// Grouped with thin spaces, which is how large numbers are written in
    /// Russian — 9 218 rather than 9,218.
    ///
    /// A thin space rather than a full one: at the sizes these numbers are
    /// set, a normal space breaks the figure into two.
    var spaced: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{2009}"
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
