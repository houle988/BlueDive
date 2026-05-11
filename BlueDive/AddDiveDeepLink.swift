import Foundation

/// Deep-link routing for the "Add a Dive" widget.
///
/// The widget opens URLs of the form `bluedive://add/manual` or
/// `bluedive://add/bluetooth`. `BlueDiveApp` receives those via
/// `.onOpenURL` and posts one of the notifications below. `MainTabView`
/// switches to the Logbook tab, and `ContentView` performs the action
/// (presenting the manual-date sheet or the Bluetooth scanner sheet).
enum AddDiveDeepLink {
    static let scheme = "bluedive"

    /// Returns the matching action for a deep-link URL, or nil if unrecognized.
    static func action(for url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // Accept either `bluedive://add/manual` (host=add, path=/manual)
        // or `bluedive://add/bluetooth`.
        guard url.host?.lowercased() == "add" else { return nil }
        switch url.lastPathComponent.lowercased() {
        case "manual":    return .manual
        case "bluetooth": return .bluetooth
        default:          return nil
        }
    }

    enum Action {
        case manual
        case bluetooth
    }
}

extension Notification.Name {
    /// Posted when the widget (or any deep-link) requests a manual dive entry.
    static let addDiveManual    = Notification.Name("AddDiveDeepLink.manual")
    /// Posted when the widget (or any deep-link) requests the Bluetooth scanner.
    static let addDiveBluetooth = Notification.Name("AddDiveDeepLink.bluetooth")
}
