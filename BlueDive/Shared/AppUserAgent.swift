import Foundation

/// The `User-Agent` header sent to the online services BlueDive calls (Open-Meteo,
/// iNaturalist): the app name, its version and the project's public URL, so a service can
/// identify the app and reach its developer. It carries no user or device information.
enum AppUserAgent {

    /// "BlueDive/<CFBundleShortVersionString> (<project URL>)", computed once.
    static let value: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        return "BlueDive/\(version) (https://github.com/houle988/BlueDive)"
    }()
}
