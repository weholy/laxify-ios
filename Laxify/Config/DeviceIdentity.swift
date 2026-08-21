import Foundation

enum DeviceIdentity {
    private static let storageKey = "laxify.device.uuid"

    static var uuid: String {
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: storageKey)
        return generated
    }
}
