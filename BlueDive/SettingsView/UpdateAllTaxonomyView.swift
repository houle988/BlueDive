import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Settings → Online Services → Update Species from iNaturalist: looks up every catalogue
/// species that has a scientific name and no iNaturalist taxon yet (exact name match only),
/// one per second. A run that stops continues where it left off the next time.
struct UpdateAllTaxonomyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: INaturalistUpdater.BatchStatus?
    @State private var task: Task<Void, Never>?
    @State private var pendingCount: Int?
    /// Fetching common names in the common-names language for already linked species.
    @State private var namesStatus: INaturalistUpdater.BatchStatus?
    @State private var namesTask: Task<Void, Never>?
    @State private var namesPendingCount: Int?

    private var isFetchingNames: Bool { namesStatus?.isRunning ?? false }

    /// The common-names language's name in that language, e.g. "Deutsch".
    private var languageName: String {
        let code = INaturalistService.nameLanguageCode
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    private var isRunning: Bool { status?.isRunning ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Looks up every species that has a scientific name and is not linked to iNaturalist yet. Only exact scientific-name matches are used; other species can be looked up one by one from their page. Only the species name is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if UserPreferences.shared.useINaturalistCommonNames {
                    Text("With “Use iNaturalist common names” on, a species linked here takes iNaturalist's common name, and the name it had is kept in Other Names.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let pendingCount {
                    Text(verbatim: String(format: NSLocalizedString("Species to look up: %@", bundle: .forAppLanguage(), value: "Species to look up: %@", comment: "Number of catalogue species not yet looked up on iNaturalist"), Double(pendingCount).localizedString(decimals: 0)))
                        .font(.subheadline)
                }

                Button {
                    if isRunning { task?.cancel() } else { start() }
                } label: {
                    Group {
                        if isRunning {
                            // Not the shared "Stop" key: that one is a decompression stop.
                            Label("Stop Updating", systemImage: "stop.fill")
                        } else {
                            Label("Update Species", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .green)
                .disabled(isFetchingNames || (!isRunning && (pendingCount ?? 0) == 0))

                if let status { statusView(status) }

                Divider()
                    .padding(.vertical, 8)

                Text(verbatim: String(format: NSLocalizedString("Fetch Common Names in %@", bundle: .forAppLanguage(), value: "Fetch Common Names in %@", comment: "Heading: fetch iNaturalist common names in the common-names language; %@ is the language name, e.g. Deutsch"), languageName))
                    .font(.headline)
                Text("For species already linked to iNaturalist, fetches their common name in this language, so they are shown in it. Only the species' iNaturalist number and the language are sent; the names you entered are not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let namesPendingCount {
                    Text(verbatim: String(format: NSLocalizedString("Species without a name in %@: %@", bundle: .forAppLanguage(), value: "Species without a name in %@: %@", comment: "Number of linked species missing an iNaturalist common name in the common-names language; first %@ is the language name"), languageName, Double(namesPendingCount).localizedString(decimals: 0)))
                        .font(.subheadline)
                }
                Button {
                    if isFetchingNames { namesTask?.cancel() } else { startNames() }
                } label: {
                    Group {
                        if isFetchingNames {
                            Label("Stop Fetching", systemImage: "stop.fill")
                        } else {
                            Label("Fetch Names", systemImage: "character.bubble")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isFetchingNames ? .red : .green)
                .disabled(isRunning || (!isFetchingNames && (namesPendingCount ?? 0) == 0))

                if let namesStatus { statusView(namesStatus) }
            }
            .padding()
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Update Species", bundle: .forAppLanguage(), value: "Update Species", comment: "Title of the Settings page that looks up all species on iNaturalist")))
        .task { countPending() }
        .onDisappear {
            task?.cancel()
            namesTask?.cancel()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, isRunning { task?.cancel() }
            if phase == .background, isFetchingNames { namesTask?.cancel() }
        }
        #endif
    }

    @ViewBuilder
    private func statusView(_ status: INaturalistUpdater.BatchStatus) -> some View {
        switch status {
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(verbatim: "\(Double(done).localizedString(decimals: 0)) / \(Double(total).localizedString(decimals: 0))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .finished(let updated, let notFound, _):
            Text(verbatim: String(format: NSLocalizedString("Updated: %@. Not found on iNaturalist: %@.", bundle: .forAppLanguage(), value: "Updated: %@. Not found on iNaturalist: %@.", comment: "Result of the iNaturalist update of all species (locale-formatted numbers)"), Double(updated).localizedString(decimals: 0), Double(notFound).localizedString(decimals: 0)))
                .font(.subheadline)
        case .stoppedOffline(let updated):
            Text(verbatim: String(format: NSLocalizedString("Stopped: no connection. Updated: %@.", bundle: .forAppLanguage(), value: "Stopped: no connection. Updated: %@.", comment: "iNaturalist update stopped because the device is offline (locale-formatted number)"), Double(updated).localizedString(decimals: 0)))
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .stoppedUnavailable(let updated):
            Text(verbatim: String(format: NSLocalizedString("Stopped: iNaturalist is not available right now. Updated: %@.", bundle: .forAppLanguage(), value: "Stopped: iNaturalist is not available right now. Updated: %@.", comment: "iNaturalist update stopped because the service answered with an error (locale-formatted number)"), Double(updated).localizedString(decimals: 0)))
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .stopped(let updated):
            Text(verbatim: String(format: NSLocalizedString("Stopped. Updated: %@.", bundle: .forAppLanguage(), value: "Stopped. Updated: %@.", comment: "iNaturalist update stopped by the user (locale-formatted number)"), Double(updated).localizedString(decimals: 0)))
                .font(.subheadline)
        }
    }

    private func countPending() {
        let all = (try? modelContext.fetch(FetchDescriptor<Species>())) ?? []
        // The same rule as the update itself, so the count is what Update Species processes.
        pendingCount = all.filter(INaturalistUpdater.needsLookup).count
        namesPendingCount = INaturalistUpdater.speciesMissingName(
            in: all, languageCode: INaturalistService.nameLanguageCode).count
    }

    private func startNames() {
        let container = modelContext.container
        let language = INaturalistService.nameLanguageCode
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        namesTask = Task {
            let final = await INaturalistUpdater.fetchCommonNames(languageCode: language, container: container) {
                namesStatus = $0
            }
            namesStatus = final
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            countPending()
        }
    }

    private func start() {
        let container = modelContext.container
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        task = Task {
            let final = await INaturalistUpdater.updateAll(container: container) { status = $0 }
            status = final
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            countPending()
        }
    }
}
