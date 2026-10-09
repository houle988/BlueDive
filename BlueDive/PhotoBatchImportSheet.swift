import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Imports many photos at once from Files / Finder (files or whole folders, e.g. a camera
/// card) and attaches each to the dive it was taken during, from its EXIF capture time
/// (strict: dive start ≤ capture ≤ dive end). The user reviews the matches, can correct the
/// camera clock, and picks the dive when several match. Photos matching no dive are skipped.
struct PhotoBatchImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @Environment(\.locale) private var locale
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private struct Row: Identifiable {
        let id = UUID()
        let file: ScannedPhotoFile
        /// Dives the photo was taken during (strict match), after the diver preference.
        var candidates: [UUID] = []
        /// Dive the photo will be attached to; nil = skipped.
        var chosen: UUID?
    }

    private enum Phase: Equatable {
        case choosing
        case scanning(done: Int, total: Int)
        case review
        case importing(done: Int, total: Int)
        case finished(PhotoImporter.Result)
    }

    @State private var phase: Phase = .choosing
    @State private var rows: [Row] = []
    @State private var showFileImporter = false
    @State private var clockHours = 0
    @State private var clockMinutes = 0
    @State private var work: Task<Void, Never>?
    /// Folders picked by the user, kept accessible (security scope) until the sheet closes.
    @State private var accessedFolders: [URL] = []
    /// Species named in the imported photos' captions or keywords, reviewed in the summary.
    @State private var speciesProposals: [SpeciesPhotoProposal] = []
    @State private var acceptedProposals: Set<String> = []
    @State private var recordSightings = true
    /// Photos not imported because their dive was deleted (here or on another device) before
    /// its turn came.
    @State private var photosOfDeletedDives = 0

    private var clockAdjustment: Double { Double(clockHours * 3600 + clockMinutes * 60) }

    private var matchedRows: [Row] { rows.filter { $0.candidates.count == 1 } }
    private var choiceRows: [Row] { rows.filter { $0.candidates.count > 1 } }
    private var unmatchedRows: [Row] { rows.filter { $0.candidates.isEmpty } }
    private var assignedCount: Int { rows.filter { $0.chosen != nil }.count }

    private var isWorking: Bool {
        switch phase {
        case .scanning, .importing: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .choosing:
                    choosingSection
                case .scanning(let done, let total):
                    progressSection(title: Text("Reading photos…"), done: done, total: total)
                case .review:
                    reviewSections
                case .importing(let done, let total):
                    progressSection(title: Text("Importing photos…"), done: done, total: total)
                case .finished(let result):
                    finishedSection(result)
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle(Text("Import Photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { close() }
                }
                if phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            runImport()
                        } label: {
                            Text("Import")
                                .confirmationActionForeground(.pink)
                        }
                        .disabled(assignedCount == 0)
                    }
                } else if case .finished = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        // Done links the species switched on in the summary; the close
                        // button leaves without linking (the photos are imported either way).
                        Button("Done") {
                            applySpeciesProposals(speciesProposals, accepted: acceptedProposals,
                                                  recordSightings: recordSightings,
                                                  context: modelContext, store: store)
                            close()
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image, .folder],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                startScan(urls)
            }
            .onChange(of: clockHours) { rematch() }
            .onChange(of: clockMinutes) { rematch() }
            // While photos are read or imported the sheet closes only through its close
            // button, which stops the work first: the picked folders must stay accessible.
            .interactiveDismissDisabled(isWorking)
            .onDisappear {
                work?.cancel()
                releaseFolders()
            }
        }
    }

    // MARK: Sections

    private var choosingSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                Label("Choose Photos or a Folder…", systemImage: "folder")
            }
            .listRowButton()
        } footer: {
            Text("Each photo is attached to the dive it was taken during, using the capture time recorded by the camera. Make sure the camera clock matched the dive computer, or correct it in the next step. Photos taken outside any dive are skipped.")
        }
    }

    private func progressSection(title: Text, done: Int, total: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                title
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(verbatim: "\(Double(done).localizedString(decimals: 0)) / \(Double(total).localizedString(decimals: 0))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var reviewSections: some View {
        Section {
            Stepper(value: $clockHours, in: -23...23) {
                Text(verbatim: String(format: NSLocalizedString("Hours: %@", bundle: .forAppLanguage(), value: "Hours: %@", comment: "Camera clock correction in hours, e.g. Hours: +2"), signed(clockHours)))
            }
            Stepper(value: $clockMinutes, in: -59...59) {
                Text(verbatim: String(format: NSLocalizedString("Minutes: %@", bundle: .forAppLanguage(), value: "Minutes: %@", comment: "Camera clock correction in minutes, e.g. Minutes: -5"), signed(clockMinutes)))
            }
        } header: {
            Text("Camera Clock Correction")
        } footer: {
            Text("Added to every photo's capture time before matching, e.g. +1 h if the camera was an hour behind the dive computer.")
        }

        if !matchedRows.isEmpty {
            Section {
                ForEach(matchedRows) { row in
                    photoRow(row) {
                        if let id = row.chosen { diveLabel(id) }
                    }
                }
            } header: {
                Text(verbatim: String(format: NSLocalizedString("Matched (%@)", bundle: .forAppLanguage(), value: "Matched (%@)", comment: "Section header: photos matched to exactly one dive, with their count"), Double(matchedRows.count).localizedString(decimals: 0)))
            }
        }

        if !choiceRows.isEmpty {
            Section {
                ForEach(choiceRows) { row in
                    photoRow(row) {
                        Picker(selection: chosenBinding(for: row.id)) {
                            Text("Skip").tag(UUID?.none)
                            ForEach(row.candidates, id: \.self) { id in
                                diveLabel(id).tag(UUID?.some(id))
                            }
                        } label: {
                            Text("Dive")
                        }
                        .labelsHidden()
                    }
                }
            } header: {
                Text(verbatim: String(format: NSLocalizedString("Several Dives Match (%@)", bundle: .forAppLanguage(), value: "Several Dives Match (%@)", comment: "Section header: photos taken during more than one dive (e.g. two divers' dives), with their count"), Double(choiceRows.count).localizedString(decimals: 0)))
            } footer: {
                Text("These photos were taken during more than one logged dive. Choose the dive for each photo.")
            }
        }

        if !unmatchedRows.isEmpty {
            Section {
                ForEach(unmatchedRows) { row in
                    photoRow(row) {
                        Group {
                            if !row.file.isImage {
                                Text("Not a readable image")
                            } else if row.file.capture == nil {
                                Text("No capture time in the file")
                            } else {
                                Text("No dive at this time")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(verbatim: String(format: NSLocalizedString("Not Matched (%@)", bundle: .forAppLanguage(), value: "Not Matched (%@)", comment: "Section header: photos that match no dive and will be skipped, with their count"), Double(unmatchedRows.count).localizedString(decimals: 0)))
            } footer: {
                Text("These photos are skipped. You can still add them to a dive from its Photos section.")
            }
        }
    }

    @ViewBuilder
    private func finishedSection(_ result: PhotoImporter.Result) -> some View {
        Section {
            summaryRow(Text("Imported"), result.imported, icon: "checkmark.circle.fill", color: .green)
            summaryRow(Text("Already attached to their dive"), result.duplicates, icon: "equal.circle", color: .secondary)
            summaryRow(Text("Could not be read"), result.unreadable, icon: "exclamationmark.triangle", color: .orange)
            if result.failedToSave > 0 {
                summaryRow(Text("Could not be saved"), result.failedToSave, icon: "xmark.octagon", color: .red)
            }
            if photosOfDeletedDives > 0 {
                summaryRow(Text("Dive deleted before the import"), photosOfDeletedDives, icon: "trash", color: .secondary)
            }
        }
        if !speciesProposals.isEmpty {
            SpeciesProposalSections(proposals: speciesProposals, accepted: $acceptedProposals,
                                    recordSightings: $recordSightings) {
                Text("Names found in the photos’ captions and keywords. Done links the species switched on; the close button leaves without linking. The photos themselves are not changed.")
            }
        }
    }

    /// One line of the import summary: label leading, count trailing.
    private func summaryRow(_ label: Text, _ count: Int, icon: String, color: Color) -> some View {
        HStack {
            Label {
                label
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Spacer()
            Text(verbatim: Double(count).localizedString(decimals: 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func photoRow<Detail: View>(_ row: Row, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 12) {
            Group {
                if let data = row.file.preview, let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.file.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let capture = row.file.capture, let date = WallClock.storedDate(from: capture) {
                    Text(date.addingTimeInterval(clockAdjustment),
                         format: .dateTime.day().month().year().hour().minute().second().locale(locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                detail()
                    .font(.caption)
            }
        }
    }

    /// "#146 · Site · date time" for a dive of the list.
    private func diveLabel(_ id: UUID) -> Text {
        guard let summary = store.cachedSummaries.first(where: { $0.id == id }) else { return Text(verbatim: "—") }
        var parts: [String] = []
        if let number = summary.diveNumber {
            parts.append("#\(Double(number).localizedString(decimals: 0))")
        }
        if !summary.siteName.isEmpty { parts.append(summary.siteName) }
        if !summary.diverName.isEmpty { parts.append(summary.diverName) }
        let date = summary.timestamp.formatted(.dateTime.day().month().year().hour().minute().locale(locale))
        parts.append(date)
        return Text(verbatim: parts.joined(separator: " · "))
    }

    private func signed(_ value: Int) -> String {
        let text = Double(abs(value)).localizedString(decimals: 0)
        return value > 0 ? "+\(text)" : value < 0 ? "−\(text)" : text
    }

    private func chosenBinding(for rowID: UUID) -> Binding<UUID?> {
        Binding(
            get: { rows.first { $0.id == rowID }?.chosen },
            set: { newValue in
                if let index = rows.firstIndex(where: { $0.id == rowID }) { rows[index].chosen = newValue }
            }
        )
    }

    // MARK: Actions

    private func startScan(_ picked: [URL]) {
        work?.cancel()
        work = Task {
            phase = .scanning(done: 0, total: 0)
            // Listing a large folder (a camera card) runs off the main thread.
            let (files, folders) = await Task.detached(priority: .userInitiated) {
                Self.imageFiles(in: picked)
            }.value
            // Closed while listing (the detached listing is not cancelled with `work`): the
            // sheet has already released its folders, so release these here.
            if Task.isCancelled {
                for folder in folders { folder.stopAccessingSecurityScopedResource() }
                return
            }
            accessedFolders += folders
            phase = .scanning(done: 0, total: files.count)
            var scanned: [Row] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { return }
                let file = await Task.detached(priority: .userInitiated) { ScannedPhotoFile.scan(url) }.value
                scanned.append(Row(file: file))
                phase = .scanning(done: index + 1, total: files.count)
            }
            rows = scanned.sorted {
                let a = $0.file.capture.flatMap(WallClock.storedDate(from:)) ?? .distantFuture
                let b = $1.file.capture.flatMap(WallClock.storedDate(from:)) ?? .distantFuture
                return a == b ? $0.file.filename < $1.file.filename : a < b
            }
            rematch()
            phase = .review
        }
    }

    /// The picked files, plus the image files inside picked folders (searched recursively),
    /// and the folders whose security scope was started. A folder stays accessible until the
    /// sheet closes, so its files can be read at import; a picked file is accessed when read.
    nonisolated private static func imageFiles(in picked: [URL]) -> (files: [URL], folders: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in picked {
            // Access is started before asking whether the URL is a folder: outside the app's
            // container (iCloud Drive, an external drive) resource values may not be readable
            // before it.
            let scoped = url.startAccessingSecurityScopedResource()
            let isFolder = url.hasDirectoryPath
                || ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            guard isFolder else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                files.append(url)
                continue
            }
            if scoped { folders.append(url) }
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.contentType?.conforms(to: .image) == true else { continue }
                files.append(fileURL)
            }
        }
        return (files, folders)
    }

    /// Matches every photo to the dives it was taken during, for the current clock correction.
    private func rematch() {
        let matcher = PhotoDiveMatcher(summaries: store.cachedSummaries)
        let divesByID = Dictionary(store.dives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let adjustment = clockAdjustment
        // A dive's precise duration reads its profile: once per dive, not once per photo.
        var durations: [UUID: Int] = [:]
        func duration(of dive: Dive) -> Int {
            if let known = durations[dive.id] { return known }
            let value = dive.durationSeconds
            durations[dive.id] = value
            return value
        }
        for index in rows.indices {
            guard let capture = rows[index].file.capture else {
                rows[index].candidates = []
                rows[index].chosen = nil
                continue
            }
            // Strict check with the dive's precise duration (its profile), candidates only.
            let windows = matcher.candidates(for: capture, clockAdjustment: adjustment).filter { window in
                guard let dive = divesByID[window.id] else { return false }
                return PhotoTiming.profileOffset(capture: capture, clockAdjustment: adjustment,
                                                 diveStart: dive.timestamp,
                                                 durationSeconds: duration(of: dive)) != nil
            }
            var ids = windows.map(\.id)
            // Two divers' dives at the same time: prefer the diver selected in the dive list.
            if ids.count > 1, !selectedDiver.isEmpty {
                let mine = windows.filter { $0.diverName == selectedDiver }.map(\.id)
                if !mine.isEmpty { ids = mine }
            }
            let previous = rows[index].chosen
            rows[index].candidates = ids
            if ids.count == 1 {
                rows[index].chosen = ids[0]
            } else if let previous, ids.contains(previous) {
                rows[index].chosen = previous
            } else {
                rows[index].chosen = nil
            }
        }
    }

    private func runImport() {
        // Identifiers only: a dive deleted during the import is never read.
        let divePIDs = Dictionary(store.dives.map { ($0.id, $0.persistentModelID) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: rows.filter { $0.chosen != nil }, by: { $0.chosen! })
        let total = groups.values.reduce(0) { $0 + $1.count }
        let adjustment = clockAdjustment
        let container = modelContext.container
        work?.cancel()
        work = Task {
            phase = .importing(done: 0, total: total)
            var summary = PhotoImporter.Result()
            var done = 0
            var diveGone = 0
            for (diveID, items) in groups {
                if Task.isCancelled { break }
                guard let divePID = divePIDs[diveID],
                      PhotoImporter.fetchDive(divePID, in: modelContext) != nil else {
                    diveGone += items.count
                    done += items.count
                    continue
                }
                let base = done
                let result = await PhotoImporter.importPhotos(
                    items.map { .file($0.file.url) }, toDiveWith: divePID,
                    container: container, clockAdjustment: adjustment
                ) { processed, _ in
                    phase = .importing(done: base + processed, total: total)
                }
                done += items.count
                summary.imported += result.imported
                summary.duplicates += result.duplicates
                summary.unreadable += result.unreadable
                summary.failedToSave += result.failedToSave
                summary.importedPhotoIDs += result.importedPhotoIDs
                // Fetched again: the dive may have been deleted (here or remotely) meanwhile.
                if let live = PhotoImporter.fetchDive(divePID, in: modelContext) {
                    store.commit(live, affects: .rowBadges)
                }
            }
            let catalogue = (try? modelContext.fetch(FetchDescriptor<Species>())) ?? []
            speciesProposals = SpeciesPhotoMatcher.proposals(
                for: SpeciesPhotoMatcher.photos(withIDs: summary.importedPhotoIDs, in: modelContext),
                catalogue: catalogue)
            // After a batch import the proposals start switched on, new species included when
            // their name is clearly scientific; a weaker reading starts off.
            acceptedProposals = defaultAcceptedProposals(speciesProposals, includeConfidentNewSpecies: true)
            photosOfDeletedDives = diveGone
            phase = .finished(summary)
        }
    }

    private func close() {
        work?.cancel()
        dismiss()
    }

    private func releaseFolders() {
        for url in accessedFolders { url.stopAccessingSecurityScopedResource() }
        accessedFolders = []
    }
}
