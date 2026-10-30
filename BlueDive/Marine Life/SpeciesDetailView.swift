import SwiftUI
import SwiftData
import MapKit
import ImageIO

// MARK: - Species Detail

/// One species of the catalogue: its profile, statistics over the dives it was seen on,
/// encounter history, photos, distribution map and notes. Pushed in the Marine Life tab, or
/// inside the photo viewer's sheet.
struct SpeciesDetailView: View {
    @Bindable var species: Species
    let numberMap: [PersistentIdentifier: Int]

    @Environment(DiveStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.isPushedInSheet) private var isPushedInSheet
    /// The sheet the page is pushed in, if any (its dives' pages get its close button).
    @Environment(\.sheetDismiss) private var sheetDismiss
    /// Shows the dive list, for "View Dives with This Critter" (filters the list, then shows
    /// it). Nil hides the button: set on the Marine Life tab only — in the photo viewer it
    /// would only return to the dive shown, with the list filtered behind it.
    @Environment(\.showDiveList) private var showDiveList
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @State private var prefs = UserPreferences.shared

    private enum Tab: Hashable { case overview, photos, distribution, notes }
    @State private var tab: Tab = .overview
    @State private var showEdit = false
    @State private var showMerge = false
    @State private var showDeleteAlert = false
    @State private var photoPreview: IdentifiablePhotoData?
    /// The photos when the viewer was opened, for a viewer still open after the species is
    /// gone (its photos stay on their dives).
    @State private var previewPhotos: [DivePhoto] = []
    /// This species' identifier, kept with them, so the viewer never reads a gone species.
    @State private var previewSpeciesID: PersistentIdentifier?
    @State private var showLookup = false

    /// Dives of sightings recorded under one of the species' names but not linked to it (an
    /// XML import, an older app version): Marine Life counts them with the species, so they
    /// are listed here too. Loaded when the page opens and after any sighting change.
    @State private var unlinkedSightingDives: [Dive] = []

    /// Distinct dives the species was seen on (diver filter applied), newest first.
    private var dives: [Dive] {
        var seen = Set<PersistentIdentifier>()
        let all = ((species.sightings ?? []).compactMap(\.dive) + unlinkedSightingDives)
            // A dive deleted and merged reports no context (isDeleted alone misses it once saved).
            .filter { !$0.isDeleted && $0.modelContext != nil && seen.insert($0.persistentModelID).inserted }
        return DiverFilter.apply(selectedDiver, to: all).sorted { $0.timestamp > $1.timestamp }
    }

    /// The species' photos (diver filter applied, as the dives are: a photo of another diver's
    /// dive is left out, a photo with no dive is kept), oldest first.
    private var photos: [DivePhoto] {
        (species.photos ?? []).filter { photo in
            guard !selectedDiver.isEmpty, let dive = photo.dive else { return true }
            // A dive deleted and merged reports no context; its photo is not this diver's.
            guard !dive.isDeleted, dive.modelContext != nil else { return false }
            return !DiverFilter.apply(selectedDiver, to: [dive]).isEmpty
        }
        .sorted { ($0.captureDate ?? $0.createdAt) < ($1.captureDate ?? $1.createdAt) }
    }

    /// The species was deleted or merged from another page of it higher in the stack (e.g.
    /// opened again from a photo of one of its dives): this page must no longer read it. Its
    /// content goes blank, but its sheets stay attached, so a photo viewer opened from here
    /// (and what was opened from it) stays open.
    private var isGone: Bool { species.isDeleted || species.modelContext == nil }

    var body: some View {
        let isGone = isGone
        let dives = isGone ? [] : dives
        ScrollView {
            if !isGone {
                content(dives)
            }
        }
        .background(AppBackground().ignoresSafeArea())
        .task(id: isGone ? "" : "\(store.sightingsVersion)|\(species.commonName)|\(species.altNames?.count ?? 0)") {
            guard !self.isGone else { return }
            unlinkedSightingDives = SpeciesCatalog.unlinkedSightings(of: species, in: modelContext).compactMap(\.dive)
        }
        .navigationTitle(Text(verbatim: isGone ? "" : species.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isGone { toolbarItems }
        }
        .sheet(isPresented: $showEdit) {
            EditSpeciesView(species: species)
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showLookup) {
            INaturalistLookupSheet(species: species)
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showMerge) {
            MergeSpeciesSheet(source: species) { target in
                // Leave this page first: the merged species is deleted, and its page must not
                // read it afterwards.
                let source = species
                let context = modelContext
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    SpeciesCatalog.merge(source, into: target, in: context)
                }
            }
            .standardSheetPresentation()
        }
        .sheet(item: $photoPreview) { item in
            let photos = isGone ? previewPhotos.filter { !$0.isDeleted && $0.modelContext != nil } : photos
            PhotoPreviewSheet(
                photoIDs: photos.map(\.id.uuidString),
                photoData: { index in
                    guard photos.indices.contains(index) else { return Data() }
                    return photos[index].previewBytes ?? Data()
                },
                initialIndex: item.index,
                photoRecord: { index in photos.indices.contains(index) ? photos[index] : nil },
                hasOriginal: { index in photos.indices.contains(index) && photos[index].original != nil },
                speciesPageShown: previewSpeciesID,
                onDelete: nil
            )
            .standardSheetPresentation()
        }
        .alert("Delete Species", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                // Leave this page before deleting, so it never reads the deleted species.
                let target = species
                let context = modelContext
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    SpeciesCatalog.delete(target, in: context)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The species is removed from the catalogue. Its sightings stay on their dives with the names they were recorded with, and its photos stay on their dives.")
        }
    }

    /// In a sheet, macOS would draw a `.primaryAction` item as the sheet's default button.
    private var toolbarPlacement: ToolbarItemPlacement {
        isPushedInSheet ? .sheetPrimaryAction : .primaryAction
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        #if os(macOS)
        // One group, so macOS shares a single glass capsule as the iOS navigation bar does.
        ToolbarItemGroup(placement: toolbarPlacement) {
            editButton
            moreMenu
        }
        #else
        ToolbarItem(placement: toolbarPlacement) {
            editButton
        }
        ToolbarItem(placement: toolbarPlacement) {
            moreMenu
        }
        #endif
    }

    // Toolbar controls, shared by the iOS and macOS toolbar layouts above.

    private var editButton: some View {
        Button {
            showEdit = true
        } label: {
            Image(systemName: "pencil")
        }
        .accessibilityLabel(Text("Edit Species"))
    }

    private var moreMenu: some View {
        Menu {
            if prefs.fetchTaxonomyOnline {
                Button {
                    showLookup = true
                } label: {
                    Label("Look Up on iNaturalist", systemImage: "leaf")
                }
            }
            Button {
                showMerge = true
            } label: {
                Label("Merge Into Another Species…", systemImage: "arrow.triangle.merge")
            }
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete Species", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .toolbarMenuIndicatorHiddenOnMac()
        .accessibilityLabel(Text("More"))
    }

    private func content(_ dives: [Dive]) -> some View {
        VStack(spacing: 20) {
            header
            Picker(selection: $tab) {
                Text("Overview").tag(Tab.overview)
                Text("Photos").tag(Tab.photos)
                Text("Distribution").tag(Tab.distribution)
                Text("Notes").tag(Tab.notes)
            } label: {
                Text("Section")
            }
            .fullWidthSegmentedPicker()
            .padding(.horizontal)

            switch tab {
            case .overview: overview(dives)
            case .photos: photosGrid
            case .distribution: distribution(dives)
            case .notes: notesCard
            }
        }
        .padding(.vertical)
    }

    // MARK: Header

    /// The species' Other Names shown under its name, in the order they were saved: names
    /// matching the displayed or scientific name, case-only duplicates and empty names are
    /// left out.
    private var headerOtherNames: [String] {
        var seen: Set<String> = [
            SpeciesCatalog.key(species.displayName),
            SpeciesCatalog.key(species.scientificName ?? "")
        ]
        return (species.altNames ?? []).filter { name in
            let key = SpeciesCatalog.key(name)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            // 240 × 160 pt in 3:2 (Settings → Wide species photos), close to the stored image's
            // ~500 px so it is not enlarged much; else a 120 pt square.
            SpeciesImageView(species: species, size: prefs.wideSpeciesImages ? 240 : 120,
                             aspectRatio: prefs.wideSpeciesImages ? SpeciesImageView.wideAspectRatio : 1)
            VStack(spacing: 4) {
                Text(verbatim: species.displayName)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                let otherNames = headerOtherNames
                if !otherNames.isEmpty {
                    Text(verbatim: "(\(otherNames.joined(separator: ", ")))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let scientific = species.scientificName, !scientific.isEmpty {
                    Text(verbatim: scientific)
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                    // Linked through a former scientific name (a genus renamed since): the name
                    // written is kept, and iNaturalist's current one is shown under it.
                    if let current = species.currentTaxonName {
                        Text("Current name: \(Text(verbatim: current).italic())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let category = SpeciesCategory.displayName(species.category) {
                        Text(verbatim: category)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                    if let size = species.averageSize {
                        Text(verbatim: String(format: NSLocalizedString("Average size: %@", bundle: .forAppLanguage(), value: "Average size: %@", comment: "Species average size, e.g. Average size: 30 cm"), sizeText(size)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let attribution = species.featuredImageAttribution, !attribution.isEmpty {
                Text(verbatim: attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /// The size in the profile's unit (converted from the unit it was entered in, as dive
    /// values are); a size of unknown unit is shown as stored, without a unit.
    private func sizeText(_ size: Double) -> String {
        let (value, unitCode) = Species.displaySize(size, storedUnit: species.averageSizeUnit,
                                                    displayInInches: prefs.depthUnit == .feet)
        let unit: String
        switch unitCode {
        case "in": unit = NSLocalizedString("in", bundle: .forAppLanguage(), value: "in", comment: "Unit symbol: inches")
        case "cm": unit = NSLocalizedString("cm", bundle: .forAppLanguage(), value: "cm", comment: "Unit symbol: centimetres")
        default: unit = ""
        }
        let number = value.localizedString(decimals: 1)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    // MARK: Overview

    private func overview(_ dives: [Dive]) -> some View {
        let metrics = SpeciesMetrics(dives: dives)
        return VStack(spacing: 16) {
            HStack(spacing: 12) {
                StatisticsHeroCard(
                    value: Double(metrics.diveCount).localizedString(decimals: 0),
                    label: "Dives",
                    icon: "figure.open.water.swim",
                    color: .cyan
                )
                StatisticsHeroCard(
                    value: metrics.averageDepth.map { "\($0.localizedString(decimals: 2, minDecimals: 2)) \(prefs.depthUnit.symbol)" } ?? "—",
                    label: "Avg. Depth",
                    icon: "arrow.down.to.line",
                    color: .blue
                )
                StatisticsHeroCard(
                    value: metrics.averageTemperature.map { "\($0.localizedString(decimals: 2, minDecimals: 2)) \(prefs.temperatureUnit.symbol)" } ?? "—",
                    label: "Avg. Temp.",
                    icon: "thermometer.medium",
                    color: .green
                )
            }
            .padding(.horizontal)

            if showDiveList != nil, !dives.isEmpty {
                Button {
                    viewDivesWithSpecies()
                } label: {
                    Label("View Dives with This Critter", systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }

            if !species.taxonomy.isEmpty || species.wikipediaSummary != nil {
                taxonomyCard
            } else if prefs.fetchTaxonomyOnline, species.inatTaxonID == nil {
                notLinkedCard
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Encounters")
                    .font(.headline)
                    .padding(.horizontal, 4)
                if dives.isEmpty {
                    Text("Not seen on any dive yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    // Lazy: a species seen on hundreds of dives builds only the visible rows.
                    LazyVStack(spacing: 8) {
                        ForEach(dives) { dive in
                            NavigationLink {
                                DiveDetailView(dive: dive, sortedDives: dives, initialTab: .marineLife, diveNumber: numberMap[dive.persistentModelID] ?? 0)
                                    .closeSheetButtonOnMac(sheetDismiss)
                            } label: {
                                encounterRow(dive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func encounterRow(_ dive: Dive) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(Double(dive.diveNumber ?? numberMap[dive.persistentModelID] ?? 0).localizedString(decimals: 0))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text(dive.timestamp, format: .dateTime.day().month().year().locale(locale))
                        .font(.subheadline.weight(.semibold))
                }
                let place = [dive.siteName, dive.location].filter { !$0.isEmpty }.joined(separator: " · ")
                if !place.isEmpty {
                    Text(verbatim: place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: "\(dive.displayMaxDepth.localizedString(decimals: 1, minDecimals: 1)) \(prefs.depthUnit.symbol)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
                if let temperature = dive.displayWaterTemperature {
                    Text(verbatim: "\(temperature.localizedString(decimals: 1, minDecimals: 1)) \(prefs.temperatureUnit.symbol)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformSecondaryBackground.opacity(0.6)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Where the classification would be, for a species not linked to iNaturalist yet: the
    /// lookup without going through the … menu.
    private var notLinkedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not linked to iNaturalist")
                .font(.headline)
            Button {
                showLookup = true
            } label: {
                Label("Look Up on iNaturalist", systemImage: "leaf")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformSecondaryBackground.opacity(0.6)))
        .padding(.horizontal)
    }

    /// iNaturalist classification (kingdom to species), other common names, Wikipedia summary.
    private var taxonomyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Classification")
                .font(.headline)
            let taxonomy = species.taxonomy
            ForEach(INaturalistUpdater.displayedRanks, id: \.self) { rank in
                if let group = taxonomy.first(where: { $0.rank == rank }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: INaturalistUpdater.localizedRank(rank))
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: group.name)
                                .italic()
                            // The group's common name ("Ray-finned Fishes"); not repeated for
                            // the species itself, whose names are shown above.
                            if rank != "species", let common = group.commonName, !common.isEmpty,
                               common.caseInsensitiveCompare(group.name) != .orderedSame {
                                Text(verbatim: common)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                }
            }
            let otherNames = species.inatCommonNames.values
                .filter { !$0.isEmpty && SpeciesCatalog.key($0) != SpeciesCatalog.key(species.displayName) }
            if !otherNames.isEmpty {
                Text(verbatim: String(format: NSLocalizedString("Also known as: %@", bundle: .forAppLanguage(), value: "Also known as: %@", comment: "Other common names of a species from iNaturalist"), Set(otherNames).sorted().joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = species.wikipediaSummary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let id = species.inatTaxonID, let url = INaturalistService.pageURL(taxonID: id) {
                    Link(destination: url) {
                        Label("View on iNaturalist", systemImage: "leaf")
                    }
                }
                if let wiki = species.wikipediaURL, let url = URL(string: wiki) {
                    Link(destination: url) {
                        Label("Wikipedia", systemImage: "book")
                    }
                }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformSecondaryBackground.opacity(0.6)))
        .padding(.horizontal)
    }

    /// Filters the dive list to the dives with this species (by the names its sightings were
    /// recorded with, including the unlinked ones counted here) and shows the dive list.
    private func viewDivesWithSpecies() {
        store.filterMarineLifeMode = .any
        store.filterMarineLife = SpeciesCatalog.diveFilterNames(for: [species], in: modelContext)
        showDiveList?()
    }

    // MARK: Photos

    @ViewBuilder
    private var photosGrid: some View {
        let photos = photos
        if photos.isEmpty {
            Group {
                // With a diver chosen, the filter may hide other divers' photos.
                if selectedDiver.isEmpty {
                    Text("No photo of this species yet. Photos whose caption or keywords name this species can be linked when you import them or scan your photos.")
                } else {
                    Text("No photo of this species on this diver's dives.")
                }
            }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button {
                        previewPhotos = photos
                        previewSpeciesID = species.persistentModelID
                        photoPreview = IdentifiablePhotoData(index: index)
                    } label: {
                        Group {
                            if let data = photo.thumbnailBytes, let image = PlatformImage(data: data) {
                                Image(platformImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Photo %@ of %@", bundle: .forAppLanguage(), value: "Photo %@ of %@", comment: "Announces the current photo's position while paging through photos (locale-formatted numbers)"), Double(index + 1).localizedString(decimals: 0), Double(photos.count).localizedString(decimals: 0))))
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Distribution

    private struct SitePoint: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    @ViewBuilder
    private func distribution(_ dives: [Dive]) -> some View {
        let points = sitePoints(dives)
        if points.isEmpty {
            Text("None of the dives with this species has GPS coordinates.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            Map(initialPosition: .automatic) {
                ForEach(points) { point in
                    Marker(point.name, systemImage: "fish.fill", coordinate: point.coordinate)
                        .tint(.orange)
                }
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    /// One pin per distinct site position (entry coordinates, else exit coordinates).
    private func sitePoints(_ dives: [Dive]) -> [SitePoint] {
        var points: [String: SitePoint] = [:]
        for dive in dives {
            let pair: (Double, Double)?
            if let lat = dive.siteLatitude, let lon = dive.siteLongitude, !(lat == 0 && lon == 0) {
                pair = (lat, lon)
            } else if let lat = dive.exitLatitude, let lon = dive.exitLongitude, !(lat == 0 && lon == 0) {
                pair = (lat, lon)
            } else {
                pair = nil
            }
            guard let (lat, lon) = pair else { continue }
            let id = String(format: "%.5f,%.5f", lat, lon)
            if points[id] == nil {
                points[id] = SitePoint(id: id, name: dive.siteName,
                                       coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        return Array(points.values)
    }

    // MARK: Notes

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notes = species.notes, !notes.isEmpty {
                Text(verbatim: notes)
                    .font(.body)
                    .textSelection(.enabled)
            } else {
                Text("No notes.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformSecondaryBackground.opacity(0.6)))
        .padding(.horizontal)
    }
}

// MARK: - Species Sheet

/// A species page presented as a sheet (from the Marine Life tab, or a sighting in a dive's
/// Marine Life grid), with its own navigation for the dives it lists.
struct SpeciesSheet: View {
    let species: Species
    let numberMap: [PersistentIdentifier: Int]
    /// Shows the dive list, for "View Dives with This Critter": the sheet closes first. Nil
    /// hides the button (from a dive, it would filter the list behind the dive). Set here,
    /// not inherited: a sheet inherits the presenter's value on iOS only.
    let showDiveList: ShowDiveListAction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SpeciesDetailView(species: species, numberMap: numberMap)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        closeToolbarButton { dismiss() }
                    }
                }
                #endif
                // macOS: the close button (and Escape), and `\.sheetDismiss`, so the page
                // places its utility items for a sheet and the dives it opens get the button too.
                .closeSheetButtonOnMac { dismiss() }
        }
        .environment(\.showDiveList, showDiveList.map { show in
            ShowDiveListAction {
                dismiss()
                show()
            }
        })
    }
}

// MARK: - Species Rows

/// A species in a list row: its image, the name shown for it and its scientific name. With
/// no species (a sighting not in the catalogue), the fish symbol, the recorded name and a
/// "Not in the catalogue" note.
struct SpeciesRowLabel: View {
    let species: Species?
    let name: String

    init(species: Species) {
        self.species = species
        self.name = species.displayName
    }

    /// A sighting not in the catalogue, shown under the name it was recorded with.
    init(recordedName: String) {
        self.species = nil
        self.name = recordedName
    }

    var body: some View {
        HStack(spacing: 12) {
            SpeciesImageView(species: species, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .foregroundStyle(.primary)
                if let species {
                    if let scientific = species.scientificName, !scientific.isEmpty {
                        Text(verbatim: scientific)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not in the catalogue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The search field of a species list, with its clear button.
struct SpeciesSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            formTextField("Search species", text: $text)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .clearButtonTapTarget()
                        .accessibilityLabel(Text("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Species Image

/// The species' featured image, or a fish symbol when it has none.
struct SpeciesImageView: View {
    let species: Species?
    /// Width of the image (its side when `aspectRatio` is 1), clipped to rounded corners. Nil
    /// fills the space it is given (a grid tile, which clips it), the image then scaled down to
    /// a tile's size when decoded.
    let size: CGFloat?
    /// Width over height when `size` is set: 1 (a square) or `wideAspectRatio`. `size` is then
    /// the width; the image fills the frame and is cropped to it.
    var aspectRatio: CGFloat = 1
    /// Decoded once per image record, off the main thread — not in `body`, which runs for
    /// every visible row on each keystroke of a search field.
    @State private var image: PlatformImage?

    /// The 3:2 format of Settings → Appearance & Language → Wide species photos
    /// (`UserPreferences.wideSpeciesImages`).
    static let wideAspectRatio: CGFloat = 3 / 2

    var body: some View {
        if let size {
            let height = size / aspectRatio
            // Outlined from 64 pt high (the species page header), as on the tiles; filled for the
            // small list icons, where an outline reads poorly. The symbol and corners follow
            // the height, so a wide image keeps the proportions of the square one.
            content(symbol: height >= 64 ? "fish" : "fish.fill", symbolFont: .system(size: height * 0.4))
                .frame(width: size, height: height)
                .clipShape(RoundedRectangle(cornerRadius: height * 0.2))
        } else {
            // A tile: a larger outlined fish (the small icons keep the filled one, which reads
            // better at 32 pt).
            content(symbol: "fish", symbolFont: .system(size: 44, weight: .regular))
        }
    }

    private func content(symbol: String, symbolFont: Font) -> some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    // Neutral, as a photo tile waiting for its thumbnail; the fish keeps the
                    // Marine Life orange.
                    Color.secondary.opacity(0.15)
                    Image(systemName: symbol)
                        .font(symbolFont)
                        .foregroundStyle(.orange)
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: species?.image?.persistentModelID) {
            guard let species, !species.isDeleted, species.modelContext != nil,
                  let data = species.featuredThumbnailData ?? species.featuredImageData else {
                image = nil
                return
            }
            let fillsTile = size == nil
            // Nil: the row or tile scrolled away while waiting for its turn (nothing decoded).
            guard let decoded = await PhotoMetadataReader.onImageQueueUnlessCancelled({ () -> PlatformImage? in
                // A tile: a large image (a user's own, kept without a thumbnail when it is
                // smaller than one) is scaled down, as dive photo tiles are, not decoded in full.
                if fillsTile, let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = PhotoMetadataReader.thumbnailJPEG(of: source, maxPixelSize: 450, quality: 0.85) {
                    return PlatformImage(data: thumbnail)
                }
                return PlatformImage(data: data)
            }), !Task.isCancelled else { return }
            image = decoded
        }
    }
}

// MARK: - Merge Species

/// Picks the species another one is merged into.
struct MergeSpeciesSheet: View {
    let source: Species
    /// Called with the chosen species after the user confirms; the caller merges.
    let onChoose: (Species) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: Species?

    var body: some View {
        NavigationStack {
            SpeciesPickerList(excluding: source, onPick: { target = $0 }) {
                Text(verbatim: String(format: NSLocalizedString("Choose the species that keeps the sightings. The sightings and photos of %@ move to it, it keeps %@ as another name, and %@ is then deleted.", bundle: .forAppLanguage(), value: "Choose the species that keeps the sightings. The sightings and photos of %@ move to it, it keeps %@ as another name, and %@ is then deleted.", comment: "Merge species explanation; each %@ is the name of the species being merged"), source.displayName, source.displayName, source.displayName))
            }
            .navigationTitle(Text("Merge Into"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .alert("Merge Species", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { target in
                Button("Merge", role: .destructive) {
                    dismiss()
                    onChoose(target)
                }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text(verbatim: String(format: NSLocalizedString("Merge %@ into %@?", bundle: .forAppLanguage(), value: "Merge %@ into %@?", comment: "Merge species confirmation: source name, target name"), source.displayName, target.displayName))
            }
        }
    }
}

// MARK: - Link Sightings to a Species

/// Links the sightings recorded under a name that is not in the catalogue to an existing
/// species. The sightings keep their name; the species gets it as another name.
struct LinkSightingsToSpeciesSheet: View {
    let name: String
    /// Called after the sightings were linked.
    let onLinked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var target: Species?

    var body: some View {
        NavigationStack {
            SpeciesPickerList(excluding: nil, onPick: { target = $0 }) {
                Text(verbatim: String(format: NSLocalizedString("Choose the species these sightings belong to. They keep the name “%@”, which the species also keeps as another name.", bundle: .forAppLanguage(), value: "Choose the species these sightings belong to. They keep the name “%@”, which the species also keeps as another name.", comment: "Link sightings to a species explanation; %@ is the sightings' recorded name"), name))
            }
            .navigationTitle(Text("Link to Species"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .alert("Link Sightings", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { target in
                Button("Link") {
                    SpeciesCatalog.linkSightings(named: name, to: target, in: modelContext)
                    dismiss()
                    onLinked()
                }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text(verbatim: String(format: NSLocalizedString("Link the sightings named “%@” to %@?", bundle: .forAppLanguage(), value: "Link the sightings named “%@” to %@?", comment: "Link sightings confirmation: recorded name, species name"), name, target.displayName))
            }
        }
    }
}

// MARK: - Species Picker

/// Searchable list of catalogue species with their scientific name and number of dives.
struct SpeciesPickerList<Footer: View>: View {
    let excluding: Species?
    let onPick: (Species) -> Void
    @ViewBuilder let footer: () -> Footer
    @Query(sort: \Species.commonName) private var catalogue: [Species]
    @State private var search = ""
    /// Built once when the catalogue changes; the list is filtered once per keystroke.
    @State private var nameIndex = SpeciesNameIndex()
    @State private var shown: [Species] = []

    private func updateShown() {
        shown = nameIndex.species(containing: search,
                                  excluding: Set([excluding?.persistentModelID].compactMap { $0 }))
    }

    var body: some View {
        groupedList {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    formTextField("Search species", text: $search)
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .clearButtonTapTarget()
                                .accessibilityLabel(Text("Clear"))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                footer()
            }
            Section {
                ForEach(shown) { species in
                    Button {
                        onPick(species)
                    } label: {
                        HStack(spacing: 12) {
                            SpeciesImageView(species: species, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: species.displayName)
                                    .foregroundStyle(.primary)
                                if let scientific = species.scientificName, !scientific.isEmpty {
                                    Text(verbatim: scientific)
                                        .font(.caption)
                                        .italic()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(verbatim: diveCountText(species))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowButton()
                }
            }
        }
        .task(id: catalogue.count) {
            nameIndex = SpeciesNameIndex(catalogue: catalogue)
            updateShown()
        }
        .onChange(of: search) { updateShown() }
    }

    private func diveCountText(_ species: Species) -> String {
        let count = Set((species.sightings ?? []).compactMap { $0.dive?.persistentModelID }).count
        return count == 1
            ? NSLocalizedString("1 dive", bundle: .forAppLanguage(), value: "1 dive", comment: "Single dive count")
            : String(format: NSLocalizedString("%@ dives", bundle: .forAppLanguage(), value: "%@ dives", comment: "Plural dive count goal label"), Double(count).localizedString(decimals: 0))
    }
}
