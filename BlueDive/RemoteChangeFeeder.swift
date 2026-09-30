import SwiftUI
import SwiftData
import CoreData

// MARK: - Remote Change Feeder

/// Keeps DiveStore current with edits other devices make to existing dives (via iCloud).
/// Renders nothing.
///
/// Attached once, behind MainTabView's TabView next to DiverSourcesFeeder, so it runs whatever
/// tab is selected. It observes the system's `.NSPersistentStoreRemoteChange` notification —
/// posted for iCloud imports, for this app's own saves and for CloudKit bookkeeping — and,
/// 1.5 s after the last one of a burst, asks the store to apply the new history
/// (`DiveStore.applyRemoteHistory(container:)`), which ignores this app's own saves.
/// All state (the history position) lives in the store, so recreating this view — e.g. when
/// a macOS window is closed and reopened — loses nothing.
struct RemoteChangeFeeder: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task {
                // With iCloud sync off (read once at launch, like the model container) no other
                // device can change the store.
                guard UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey) else { return }
                let container = modelContext.container
                // Catch up on changes that arrived while this view was not mounted. Started as a
                // separate task so the loop below subscribes right away (its observer registers
                // before this task can run) and no notification is missed meanwhile.
                Task { await store.applyRemoteHistory(container: container) }

                var debounce: Task<Void, Never>?
                defer { debounce?.cancel() }
                // `_` discards the (non-Sendable) Notification; only its arrival matters.
                for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                    // Only the wait is cancellable. An apply already running must never be
                    // cancelled: its merge wait would end at once and patch old values. The
                    // store turns an overlapping call into one more run. The inner task may
                    // outlive this view; that is harmless, as the store lives as long as the app.
                    debounce?.cancel()
                    debounce = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        Task { await store.applyRemoteHistory(container: container) }
                    }
                }
            }
    }
}
