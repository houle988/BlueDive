import SwiftUI

enum DiveIntroConfig {
    static let versionStorageKey = "lastIntroShownVersion"
    static let currentVersion: String = appVersionBuild()
    static let replayValue = ""
}

// MARK: - Environment key

private struct IntroVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the intro animation overlay is on screen.
    /// `RootLaunchContainer` sets this; consumers (e.g. `MainTabView`) read it
    /// to gate presentations that must appear only after the intro is gone.
    var introVisible: Bool {
        get { self[IntroVisibleKey.self] }
        set { self[IntroVisibleKey.self] = newValue }
    }
}
