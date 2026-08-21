import Foundation

enum AppSecrets {
    static var accessKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LaxifyAccessKey") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }
}
