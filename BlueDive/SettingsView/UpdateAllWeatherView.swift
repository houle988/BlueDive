import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Settings → Online Services → Update Weather for All Dives: fetches the weather from
/// Open-Meteo for every dive with GPS coordinates, newest first, with the same rules as the
/// fetch after a Bluetooth download (see WeatherBatchFetcher).
///
/// By default only empty weather fields are filled, so a run that stops (offline, Open-Meteo's
/// hourly limit, Stop) continues where it left off the next time. Replace existing weather is
/// the user's explicit choice to overwrite stored values, confirmed in an alert.
struct UpdateAllWeatherView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs = UserPreferences.shared

    /// A dive with GPS coordinates. Persistent IDs only: @Model references must not be held
    /// in @State.
    nonisolated private struct Candidate: Equatable, Sendable {
        let id: PersistentIdentifier
        let hasEmptyField: Bool
    }

    /// Dives with GPS coordinates, newest first; nil while counting.
    @State private var candidates: [Candidate]?
    @State private var replaceExisting = false
    @State private var status: WeatherBatchFetchStatus?
    @State private var task: Task<Void, Never>?
    @State private var userStopped = false
    @State private var showingConfirmation = false

    private var isRunning: Bool { status?.isRunning ?? false }

    /// The dives a run would fetch: every candidate with Replace on, otherwise those with an
    /// empty weather field.
    private var targetIDs: [PersistentIdentifier] {
        guard let candidates else { return [] }
        return replaceExisting ? candidates.map(\.id) : candidates.filter(\.hasEmptyField).map(\.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                optionsCard
                fetchCard
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Update Weather", bundle: .forAppLanguage(), value: "Update Weather", comment: "Title of the Settings page that fetches the weather for all dives with GPS coordinates; short so it fits as a large title.")))
        .task { await countCandidates() }
        .alert(Text(verbatim: confirmationTitle), isPresented: $showingConfirmation) {
            if replaceExisting {
                Button(role: .destructive) { start() } label: { Text("Fetch Weather") }
            } else {
                Button { start() } label: { Text("Fetch Weather") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if replaceExisting {
                Text("Each dive's coordinates and date are sent to Open-Meteo. This can take several minutes.") + Text(verbatim: " ") + Text("Fetched values replace the weather of every dive with GPS coordinates, including values you entered.")
            } else {
                Text("Each dive's coordinates and date are sent to Open-Meteo. This can take several minutes.")
            }
        }
        .onDisappear {
            // Leaving the page stops the run; what was fetched is already saved.
            task?.cancel()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        // iOS suspends a backgrounded app, failing the request in flight: stop cleanly instead.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isRunning { task?.cancel() }
        }
        // An auto-lock would suspend the app the same way, so the screen stays awake meanwhile.
        .onChange(of: isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        #endif
    }

    // MARK: - Cards

    private var optionsCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let candidates {
                    countRow(NSLocalizedString("Dives with GPS coordinates", bundle: .forAppLanguage(), value: "Dives with GPS coordinates", comment: "Label in Settings → Online Services → Update Weather: number of dives that have GPS coordinates."),
                             count: candidates.count)
                    countRow(NSLocalizedString("With empty weather fields", bundle: .forAppLanguage(), value: "With empty weather fields", comment: "Label in Settings → Online Services → Update Weather: number of dives with GPS coordinates that still have an empty weather field."),
                             count: candidates.filter(\.hasEmptyField).count)
                } else {
                    // Counting takes a moment only on very large logbooks.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }

                Divider()

                Toggle(isOn: $replaceExisting) {
                    Label {
                        Text("Replace existing weather")
                    } icon: {
                        Image(systemName: "cloud.sun")
                            .foregroundStyle(.yellow)
                    }
                }
                .fullWidthSwitch()
                .disabled(isRunning)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

            Group {
                if replaceExisting {
                    Text("Fetched values replace the weather of every dive with GPS coordinates, including values you entered.")
                } else {
                    Text("Only empty weather fields are filled; the weather you already have is kept.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .settingsCard()
    }

    private var fetchCard: some View {
        VStack(spacing: 12) {
            if isRunning {
                Button {
                    userStopped = true
                    task?.cancel()
                } label: {
                    // Not the shared "Stop" key: that one is a decompression stop.
                    Text("Stop Fetching", comment: "Button that stops the weather fetch for all dives in Settings → Online Services → Update Weather.")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    showingConfirmation = true
                } label: {
                    Label("Fetch Weather", systemImage: "cloud.sun.rain")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(targetIDs.isEmpty || !prefs.fetchWeatherOnline)
            }

            if let status {
                WeatherBatchFetchStatusView(
                    status: status,
                    laterHint: Text("Run it again later to fill the remaining dives.")
                )
            }

            Text("The newest dives are fetched first. Stopping keeps the weather already fetched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .settingsCard()
    }

    private func countRow(_ title: String, count: Int) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            Text(verbatim: Double(count).localizedString(decimals: 0))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var confirmationTitle: String {
        let count = targetIDs.count
        return count == 1
            ? NSLocalizedString("Fetch the weather for 1 dive?", bundle: .forAppLanguage(), value: "Fetch the weather for 1 dive?", comment: "Confirmation title in Settings → Online Services → Update Weather for exactly one dive.")
            : String(format: NSLocalizedString("Fetch the weather for %@ dives?", bundle: .forAppLanguage(), value: "Fetch the weather for %@ dives?", comment: "Confirmation title in Settings → Online Services → Update Weather. %@ is the locale-formatted number of dives."), Double(count).localizedString(decimals: 0))
    }

    // MARK: - Actions

    /// Lists the dives with GPS coordinates, newest first, off the main thread so the page
    /// stays responsive on a large logbook (the spinner shows meanwhile).
    private func countCandidates() async {
        let container = modelContext.container
        candidates = await Task.detached(priority: .userInitiated) {
            Self.loadCandidates(container: container)
        }.value
    }

    /// Reads only the fields needed (never profiles or photos), in its own context, and returns
    /// identifiers only. A plain fetch, not a @Query (CLAUDE.md: ContentView is the only
    /// @Query Dive owner).
    nonisolated private static func loadCandidates(container: ModelContainer) -> [Candidate] {
        let context = ModelContext(container)
        context.author = "BlueDive.weather"
        var descriptor = FetchDescriptor<Dive>(
            predicate: #Predicate { $0.siteLatitude != nil || $0.exitLatitude != nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.timestamp, \.siteLatitude, \.siteLongitude, \.exitLatitude, \.exitLongitude,
                                        \.weather, \.airTemperature, \.wind, \.windDirection]
        let dives = (try? context.fetch(descriptor)) ?? []
        return dives.compactMap { dive in
            guard OpenMeteoWeatherService.coordinate(for: dive) != nil else { return nil }
            return Candidate(id: dive.persistentModelID, hasEmptyField: !dive.emptyWeatherFieldNames.isEmpty)
        }
    }

    private func start() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let replace = replaceExisting
        let container = modelContext.container
        userStopped = false
        task?.cancel()
        status = .running(done: 0, total: ids.count)
        task = Task { @MainActor in
            let result = await WeatherBatchFetcher.run(
                ids: ids,
                replaceExistingIDs: replace ? Set(ids) : [],
                container: container
            ) { status = $0 }
            if userStopped, case .interrupted(let filled) = result {
                status = .stopped(filled: filled)
            } else {
                status = result
            }
            task = nil
            await countCandidates()
        }
    }
}

private extension View {
    /// The rounded card used by the Settings pages.
    func settingsCard() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
    }
}
