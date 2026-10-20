import SwiftUI
import SwiftData

// MARK: - Dive Data Feeder

/// The app's only `@Query Dive` (and `@Query MarineSight`) owner. Attached once with
/// `.background(DiveDataFeeder())` to the `TabView` in `MainTabView`, next to
/// `DiverSourcesFeeder` and `RemoteChangeFeeder`, so it stays mounted whatever tab is shown:
/// DiveStore's caches (`dives`, summaries, filters, badges, widget data) follow every change in
/// dive membership — a dive added, deleted or merged here or on another device — even while
/// the Dives tab is not shown. A background view, not queries on `MainTabView` itself, so a
/// delivery re-evaluates only this view, not every tab.
struct DiveDataFeeder: View {
    @Environment(DiveStore.self) private var store
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @Query(sort: \MarineSight.name) private var allMarineSights: [MarineSight]
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @State private var prefs = UserPreferences.shared

    /// Saves (by any model context) that inserted a dive. The check runs on the posting thread,
    /// so the non-Sendable Notification never leaves it.
    private nonisolated static func diveInsertions() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: nil, queue: nil
            ) { note in
                if insertedDives(note) { continuation.yield() }
            }
            let token = ObserverToken(observer)
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.observer) }
        }
    }

    private nonisolated static func insertedDives(_ note: Notification) -> Bool {
        let value = note.userInfo?[ModelContext.NotificationKey.insertedIdentifiers.rawValue]
        let ids = (value as? [PersistentIdentifier]) ?? (value as? Set<PersistentIdentifier>).map(Array.init) ?? []
        return ids.contains { $0.entityName == "Dive" }
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear {
                if !store.hasCacheBuilt {
                    // Cold launch: build the caches at once.
                    store.rebuildDerivedDiveState(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
                } else {
                    // A new window or a scene re-activation: the membership-guarded debounced
                    // path skips the rebuild when nothing changed.
                    store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
                }
                store.updateWidgetDiveData(dives: dives)
            }
            .onChange(of: dives) { _, _ in
                store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
            }
            // Depths are shown (and written to the widget) in the display unit.
            .onChange(of: prefs.depthUnit) { _, _ in
                store.updateWidgetDiveData(dives: dives)
                store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver)
            }
            // Settings → Dive Profile → Search dive notes: an applied search filters again.
            .onChange(of: prefs.searchDiveNotes) { _, _ in
                store.searchDiveNotesChanged()
            }
            // The notes search asks the store, which sees imported dives only once they are saved
            // (an import may list them before saving): while the setting is on, a save inserting
            // dives schedules a re-read (nothing happens without an active search). Notes edits
            // tell the store themselves (the Dive Information sheet), so other saves are ignored.
            .task(id: prefs.searchDiveNotes) {
                guard prefs.searchDiveNotes else { return }
                for await _ in Self.diveInsertions() {
                    store.notesMayHaveChanged()
                }
            }
    }
}

/// Carries a NotificationCenter observer into the stream's termination handler (removing an
/// observer is thread-safe).
private nonisolated final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol
    init(_ observer: any NSObjectProtocol) { self.observer = observer }
}
