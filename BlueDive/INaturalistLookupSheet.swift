import SwiftUI
import SwiftData

/// Searches iNaturalist for a species and links the chosen taxon to it (taxonomy, common
/// names, Wikipedia summary, a Creative Commons photo if the species has no image), or — for a
/// species not created yet (Add Species) — hands the chosen taxon back to the form.
struct INaturalistLookupSheet: View {
    enum Target {
        /// Links the taxon to this species and saves it.
        case species(Species)
        /// Returns the taxon to the caller (nothing is saved here).
        case pick((INaturalistService.Taxon) -> Void)
    }

    private let target: Target
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var query: String
    @State private var results: [INaturalistService.TaxonSummary] = []
    /// Previews of another Creative Commons photo, for results whose default photo is not one
    /// ("Use another Creative Commons photo"), by taxon ID.
    @State private var alternativePreviews: [Int: URL] = [:]
    @State private var isSearching = false
    @State private var applyingID: Int?
    @State private var errorText: String?
    /// The search running: a new one replaces it, so results of an older query never show.
    @State private var searchTask: Task<Void, Never>?
    @State private var chooseTask: Task<Void, Never>?

    init(species: Species) {
        target = .species(species)
        let scientific = species.scientificName ?? ""
        _query = State(initialValue: scientific.isEmpty ? species.commonName : scientific)
    }

    /// Searches `query` and hands the chosen taxon to `onPick`.
    init(query: String, onPick: @escaping (INaturalistService.Taxon) -> Void) {
        target = .pick(onPick)
        _query = State(initialValue: query)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        formTextField("Scientific or common name", text: $query)
                            .autocorrectionDisabled()
                            .onSubmit { startSearch() }
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .clearButtonTapTarget()
                                    .accessibilityLabel(Text("Clear"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        startSearch()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .listRowButton()
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                } footer: {
                    Text("Only the name above is sent to iNaturalist.")
                }

                if isSearching {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if let errorText {
                    Section { Text(verbatim: errorText).foregroundStyle(.orange) }
                } else if !results.isEmpty {
                    Section {
                        ForEach(results) { result in
                            Button {
                                // Previews still loading are dropped: their request would go out
                                // with the taxon's own (iNaturalist asks for one per second).
                                searchTask?.cancel()
                                chooseTask?.cancel()
                                chooseTask = Task { await choose(result) }
                            } label: {
                                resultRow(result)
                            }
                            .listRowButton()
                            .disabled(applyingID != nil)
                        }
                    } header: {
                        Text("Choose the matching taxon")
                    }
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle(Text("Look Up on iNaturalist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .onAppear { startSearch() }
            .onDisappear {
                searchTask?.cancel()
                chooseTask?.cancel()
            }
        }
    }

    private func resultRow(_ result: INaturalistService.TaxonSummary) -> some View {
        HStack(spacing: 12) {
            // The photo that would be stored: the default one when Creative Commons, else the
            // alternative one, else none (the placeholder).
            AsyncImage(url: result.photoURL ?? alternativePreviews[result.id]) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.name)
                    .italic()
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let common = result.commonName {
                        Text(verbatim: common)
                    }
                    Text(verbatim: INaturalistUpdater.localizedRank(result.rank))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if applyingID == result.id { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
    }

    private func startSearch() {
        searchTask?.cancel()
        searchTask = Task { await search() }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        errorText = nil
        do {
            let found = try await INaturalistService.search(text, languageCode: INaturalistService.nameLanguageCode)
            guard !Task.isCancelled else { return }
            isSearching = false
            results = found
            alternativePreviews = [:]
            if results.isEmpty {
                errorText = NSLocalizedString("No taxon found on iNaturalist.", bundle: .forAppLanguage(), value: "No taxon found on iNaturalist.", comment: "iNaturalist lookup: the search returned nothing")
            }
            await loadAlternativePreviews(for: found)
        } catch {
            guard !Task.isCancelled else { return }
            isSearching = false
            errorText = NSLocalizedString("iNaturalist could not be reached. Check the connection and try again.", bundle: .forAppLanguage(), value: "iNaturalist could not be reached. Check the connection and try again.", comment: "iNaturalist lookup failed (offline or service error)")
        }
    }

    /// One request for the results whose default photo is not Creative Commons, a second after
    /// the search (as iNaturalist asks). On failure they keep the placeholder; choosing works.
    private func loadAlternativePreviews(for found: [INaturalistService.TaxonSummary]) async {
        let ids = found.filter(\.needsAlternativePhoto).map(\.id)
        guard !ids.isEmpty, UserPreferences.shared.useAlternativeINaturalistPhoto else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled,
              let previews = try? await INaturalistService.previewPhotos(for: ids, languageCode: INaturalistService.nameLanguageCode),
              !Task.isCancelled else { return }
        alternativePreviews = previews
    }

    private func choose(_ result: INaturalistService.TaxonSummary) async {
        applyingID = result.id
        defer { applyingID = nil }
        do {
            let taxon = try await INaturalistService.taxon(id: result.id, languageCode: INaturalistService.nameLanguageCode,
                                                           allowAlternativePhoto: UserPreferences.shared.useAlternativeINaturalistPhoto)
            guard !Task.isCancelled else { return }
            let species: Species
            switch target {
            case .pick(let onPick):
                onPick(taxon)
                dismiss()
                return
            case .species(let target):
                species = target
            }
            // In a taxonomy context of its own (see INaturalistUpdater.apply); the species page
            // shows the result once the main context merges the save.
            // Saved first, so a species just created (still unsaved here) can be found there.
            try? modelContext.save()
            guard INaturalistUpdater.isAlive(species),
                  await INaturalistUpdater.apply(taxon, toSpecies: species.persistentModelID,
                                                 container: modelContext.container) else {
                errorText = NSLocalizedString("The species could not be updated. Try again.", bundle: .forAppLanguage(), value: "The species could not be updated. Try again.", comment: "iNaturalist lookup: the chosen taxon could not be saved on the species")
                return
            }
            dismiss()
        } catch {
            errorText = NSLocalizedString("iNaturalist could not be reached. Check the connection and try again.", bundle: .forAppLanguage(), value: "iNaturalist could not be reached. Check the connection and try again.", comment: "iNaturalist lookup failed (offline or service error)")
        }
    }
}
