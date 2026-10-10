import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// Adds a species to the catalogue (`species` nil) or edits one.
struct EditSpeciesView: View {
    let species: Species?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Species.commonName) private var catalogue: [Species]

    /// The values the form opened with. Save writes only the fields changed here, so an
    /// iNaturalist update that finished while the form was open (scientific name, category,
    /// image) is not overwritten with the older values. @State: kept across parent re-renders.
    private struct Opened: Equatable {
        var commonName = "", scientificName = "", category = "", notes = ""
        var otherNames: [String] = []
        var sizeUnit: String?
    }
    @State private var opened: Opened

    @State private var commonName: String
    @State private var scientificName: String
    /// Stored category value: "" for none, a default key, a custom name, or `newCategoryTag`.
    @State private var categorySelection: String
    @State private var newCategory = ""
    @State private var sizeText: String
    @State private var sizeOriginal: PrefilledDouble
    /// Unit of the size as entered ("cm"/"in"); nil = unknown (a stored size without a unit,
    /// e.g. imported), shown with no segment selected and kept unless the user picks one.
    @State private var sizeUnit: String?
    @State private var notes: String
    /// Other names of the species (spellings merged or linked from sightings), edited here
    /// and saved with the form.
    @State private var otherNames: [String]
    @State private var newOtherName = ""
    /// Another species already known by the other name being typed.
    @State private var otherNameConflict: Species?
    /// The featured image, loaded once when the form opens (not in `init`, which runs on every
    /// re-render of the presenting view), and whether it was changed here.
    @State private var imageData: Data?
    @State private var imageLoaded = false
    @State private var imageChanged = false
    /// The preview, decoded off the main thread when the image changes — not in `body`, which
    /// runs on every keystroke in the form.
    @State private var previewImage: PlatformImage?
    @State private var thumbnailData: Data?
    @State private var imageAttribution: String?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showImageFileImporter = false
    /// Built once when the catalogue changes, so typing never scans the whole catalogue.
    @State private var nameIndex = SpeciesNameIndex()
    @State private var customCategories: [String] = []
    /// Another species already known by the entered common or scientific name; updated
    /// once per keystroke.
    @State private var duplicate: Species?
    @State private var prefs = UserPreferences.shared
    /// New species: the iNaturalist taxon chosen in the form, linked when the species is saved.
    @State private var pickedTaxon: INaturalistService.Taxon?
    /// The common name the last lookup wrote in the form: a later lookup replaces it rather
    /// than keeping it as another name (it was never typed).
    @State private var filledCommonName: String?
    /// The scientific name of a taxon picked, then declined with "Don't Link": Save does not
    /// link the species to it automatically either.
    @State private var declinedTaxonName: String?
    @State private var showLookup = false

    private static let newCategoryTag = "\u{0}new"

    init(species: Species?) {
        self.species = species
        _commonName = State(initialValue: species?.commonName ?? "")
        _scientificName = State(initialValue: species?.scientificName ?? "")
        _categorySelection = State(initialValue: species?.category ?? "")
        let size = PrefilledDouble.decimals(species?.averageSize, 1)
        _sizeOriginal = State(initialValue: size)
        _sizeText = State(initialValue: size.text)
        // A species without a size starts on the profile's unit (imperial → in, metric → cm).
        _sizeUnit = State(initialValue: species?.averageSize == nil
                          ? Species.defaultSizeUnit
                          : species?.averageSizeUnit)
        _notes = State(initialValue: species?.notes ?? "")
        _otherNames = State(initialValue: species?.altNames ?? [])
        _opened = State(initialValue: Opened(
            commonName: species?.commonName ?? "", scientificName: species?.scientificName ?? "",
            category: species?.category ?? "", notes: species?.notes ?? "",
            otherNames: species?.altNames ?? [],
            sizeUnit: species?.averageSize == nil ? Species.defaultSizeUnit : species?.averageSizeUnit))
    }

    private var trimmedName: String { commonName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Another species with the typed common or scientific name. Only a name changed here is
    /// checked: an edit that keeps a name another species already shares (e.g. two species
    /// created on two devices) is not blocked.
    private func updateDuplicate() {
        let scientific = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = species.map { SpeciesCatalog.key($0.commonName) != SpeciesCatalog.key(trimmedName) } ?? true
        let scientificChanged = species.map { SpeciesCatalog.key($0.scientificName ?? "") != SpeciesCatalog.key(scientific) } ?? true
        duplicate = (nameChanged ? nameIndex.otherSpecies(named: trimmedName, excluding: species) : nil)
            ?? (scientificChanged && !scientific.isEmpty ? nameIndex.otherSpecies(named: scientific, excluding: species) : nil)
    }

    private var trimmedOtherName: String { newOtherName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The typed other name can be added: not empty, not already one of this species' names,
    /// not another species' name.
    private var canAddOtherName: Bool {
        let key = SpeciesCatalog.key(trimmedOtherName)
        guard !key.isEmpty, otherNameConflict == nil else { return false }
        let ownNames = [commonName, scientificName] + otherNames
        return !ownNames.contains { SpeciesCatalog.key($0) == key }
    }

    private func addOtherName() {
        guard canAddOtherName else { return }
        otherNames.append(trimmedOtherName)
        newOtherName = ""
    }

    private func updateOtherNameConflict() {
        otherNameConflict = trimmedOtherName.isEmpty ? nil
            : nameIndex.otherSpecies(named: trimmedOtherName, excluding: species)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && duplicate == nil && otherNameConflict == nil
            && (categorySelection != Self.newCategoryTag || !newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        imagePreview
                        Spacer()
                    }
                    PhotosPicker(selection: $pickedPhoto, matching: .images, preferredItemEncoding: .current) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    .listRowButton()
                    Button {
                        showImageFileImporter = true
                    } label: {
                        Label("Choose a File", systemImage: "folder")
                    }
                    .listRowButton()
                    if imageData != nil {
                        Button(role: .destructive) {
                            imageData = nil
                            thumbnailData = nil
                            imageChanged = true
                            imageAttribution = nil
                        } label: {
                            Label("Remove Image", systemImage: "trash")
                        }
                        .listRowButton()
                    }
                } header: {
                    Text("Featured Image")
                }

                Section {
                    MenuTextField(label: "Common Name", text: $commonName, icon: "textformat", color: .orange)
                    MenuTextField(label: "Scientific Name", text: $scientificName, icon: "character.book.closed", color: .orange)
                    if let duplicate {
                        Text(verbatim: String(format: NSLocalizedString("%@ is already in the catalogue.", bundle: .forAppLanguage(), value: "%@ is already in the catalogue.", comment: "Warning in the species form: another species already has this name"), duplicate.commonName))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if species == nil, prefs.fetchTaxonomyOnline {
                        Button {
                            showLookup = true
                        } label: {
                            Label("Look Up on iNaturalist", systemImage: "leaf")
                        }
                        .listRowButton()
                        // Not while a typed name is another species' (the lookup could move it to
                        // Other Names and get round the duplicate check).
                        .disabled(lookupQuery.isEmpty || duplicate != nil)
                        if let pickedTaxon {
                            HStack(spacing: 8) {
                                Text(verbatim: String(format: NSLocalizedString("Will be linked to %@", bundle: .forAppLanguage(), value: "Will be linked to %@", comment: "New species form: the iNaturalist taxon chosen, linked when the species is saved; %@ is its scientific name"), pickedTaxon.name))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    declinedTaxonName = pickedTaxon.name
                                    self.pickedTaxon = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .clearButtonTapTarget()
                                        .accessibilityLabel(Text("Don't Link"))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Names")
                }

                Section {
                    ForEach(otherNames, id: \.self) { name in
                        HStack(spacing: 12) {
                            Text(verbatim: name)
                            Spacer()
                            Button {
                                otherNames.removeAll { $0 == name }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .red)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove the other name %@", bundle: .forAppLanguage(), value: "Remove the other name %@", comment: "Accessibility label: removes one of a species' other names; %@ is the name"), name)))
                        }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        formTextField("Add a name", text: $newOtherName)
                            .autocorrectionDisabled()
                            .onSubmit { addOtherName() }
                        if !newOtherName.isEmpty {
                            Button {
                                newOtherName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .clearButtonTapTarget()
                                    .accessibilityLabel(Text("Clear"))
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Add") { addOtherName() }
                            .borderlessButton()
                            .disabled(!canAddOtherName)
                    }
                    if let otherNameConflict {
                        Text(verbatim: String(format: NSLocalizedString("%@ already uses this name.", bundle: .forAppLanguage(), value: "%@ already uses this name.", comment: "Warning when adding another name to a species: a different species already has it; %@ is that species"), otherNameConflict.displayName))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Other Names")
                } footer: {
                    Text("Other names are used to recognise sightings and photo keywords written differently. Removing one does not change any sighting.")
                }

                Section {
                    Picker(selection: $categorySelection) {
                        Text("None").tag("")
                        ForEach(SpeciesCategory.allCases) { category in
                            Text(verbatim: category.localizedName).tag(category.storedValue)
                        }
                        if !customCategories.isEmpty {
                            Divider()
                            ForEach(customCategories, id: \.self) { name in
                                Text(verbatim: name).tag(name)
                            }
                        }
                        Divider()
                        Text("New Category…").tag(Self.newCategoryTag)
                    } label: {
                        Label("Category", systemImage: "square.grid.2x2")
                    }
                    if categorySelection == Self.newCategoryTag {
                        MenuTextField(label: "Category Name", text: $newCategory, icon: "plus", color: .orange)
                    }
                } header: {
                    Text("Category")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "ruler")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        formTextField("Average Size", text: $sizeText)
                            .platformKeyboardType(.decimalPad)
                        if !sizeText.isEmpty {
                            Button {
                                sizeText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .clearButtonTapTarget()
                                    .accessibilityLabel(Text("Clear"))
                            }
                            .buttonStyle(.plain)
                        }
                        Picker(selection: $sizeUnit) {
                            Text("cm").tag(String?.some("cm"))
                            Text("in").tag(String?.some("in"))
                        } label: {
                            Text("Unit")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 110)
                    }
                } header: {
                    Text("Average Size")
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        formTextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(3...10)
                        if !notes.isEmpty {
                            Button {
                                notes = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .clearButtonTapTarget()
                                    .accessibilityLabel(Text("Clear"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Notes")
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle(species == nil ? Text("New Species") : Text("Edit Species"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .confirmationActionForeground(.orange)
                    }
                    .disabled(!canSave)
                }
            }
            .task(id: imageData?.photoTaskID ?? 0) {
                let data = thumbnailData ?? imageData
                guard let data else { previewImage = nil; return }
                let decoded = await Task.detached(priority: .userInitiated) { PlatformImage(data: data) }.value
                guard !Task.isCancelled else { return }
                previewImage = decoded
            }
            .task {
                guard !imageLoaded, let species else { return }
                imageLoaded = true
                imageData = species.featuredImageData
                thumbnailData = species.featuredThumbnailData
                imageAttribution = species.featuredImageAttribution
            }
            .task(id: catalogue.count) {
                nameIndex = SpeciesNameIndex(catalogue: catalogue)
                customCategories = SpeciesCategory.customCategories(in: catalogue)
                updateDuplicate()
                updateOtherNameConflict()
            }
            .sheet(isPresented: $showLookup) {
                INaturalistLookupSheet(query: lookupQuery) { taxon in fill(from: taxon) }
                    .standardSheetPresentation()
            }
            .onChange(of: commonName) { updateDuplicate() }
            .onChange(of: newOtherName) { updateOtherNameConflict() }
            .onChange(of: scientificName) {
                updateDuplicate()
                // A scientific name retyped after the lookup no longer names the chosen taxon:
                // linking it would show one taxon's classification under another's name.
                if let pickedTaxon, SpeciesCatalog.key(scientificName.trimmingCharacters(in: .whitespacesAndNewlines))
                    != SpeciesCatalog.key(pickedTaxon.name) {
                    self.pickedTaxon = nil
                }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { await setImage(data) }
                    pickedPhoto = nil
                }
            }
            .fileImporter(isPresented: $showImageFileImporter, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try? Data(contentsOf: url)
                    }.value
                    if let data { await setImage(data) }
                }
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image = previewImage {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
        } else {
            SpeciesImageView(species: nil, size: 120)
        }
    }

    /// What a lookup from the form searches: the scientific name, else the common name.
    private var lookupQuery: String {
        let scientific = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        return scientific.isEmpty ? trimmedName : scientific
    }

    /// New species: remembers the chosen taxon (linked on Save) and fills the fields left empty.
    /// The scientific name becomes the chosen taxon's (a typed synonym or another result would
    /// put one taxon's classification under another's name). With "Use iNaturalist common
    /// names" on, iNaturalist's name replaces the typed common name, which moves to Other
    /// Names — shown before saving, so it can be undone: Save then keeps the form's name
    /// (`allowNameSwap: false`).
    private func fill(from taxon: INaturalistService.Taxon) {
        pickedTaxon = taxon
        if SpeciesCatalog.key(scientificName.trimmingCharacters(in: .whitespacesAndNewlines)) != SpeciesCatalog.key(taxon.name) {
            scientificName = taxon.name
        }
        let inatName = taxon.localizedCommonName ?? taxon.englishCommonName
        let typed = trimmedName
        let wasFilled = filledCommonName.map { SpeciesCatalog.key($0) == SpeciesCatalog.key(typed) } ?? false
        if typed.isEmpty || wasFilled {
            commonName = inatName ?? taxon.name
            filledCommonName = commonName
            otherNames.removeAll { SpeciesCatalog.key($0) == SpeciesCatalog.key(commonName) }
        } else if prefs.useINaturalistCommonNames, let inatName,
                  SpeciesCatalog.key(inatName) != SpeciesCatalog.key(typed),
                  nameIndex.otherSpecies(named: inatName, excluding: species) == nil,
                  nameIndex.otherSpecies(named: typed, excluding: species) == nil {
            // A typed name that is only the scientific name is not kept: it is stored already.
            let isScientificName = SpeciesCatalog.key(typed) == SpeciesCatalog.key(scientificName)
            if !isScientificName, !otherNames.contains(where: { SpeciesCatalog.key($0) == SpeciesCatalog.key(typed) }) {
                otherNames.append(typed)
            }
            otherNames.removeAll { SpeciesCatalog.key($0) == SpeciesCatalog.key(inatName) }
            commonName = inatName
            filledCommonName = inatName
        }
        if categorySelection.isEmpty, let category = INaturalistUpdater.suggestedCategory(for: taxon.classification) {
            categorySelection = category.storedValue
        }
    }

    /// The user's own image: stored unchanged, with a thumbnail; no attribution.
    private func setImage(_ data: Data) async {
        let info = await Task.detached(priority: .userInitiated) { PhotoMetadataReader.read(data) }.value
        guard let info else { return }
        imageData = data
        // A thumbnail only when it is smaller than the image itself.
        thumbnailData = (info.thumbnail?.count ?? .max) < data.count ? info.thumbnail : nil
        imageAttribution = nil
        imageChanged = true
    }

    private func save() {
        // Names the species had before this edit (none when it is new).
        let previousNames = Set(species.map { [$0.commonName, $0.scientificName ?? ""] + ($0.altNames ?? []) }?
            .map(SpeciesCatalog.key) ?? [])
        let isNew = species == nil
        let target = species ?? Species(commonName: trimmedName)
        if isNew { modelContext.insert(target) }
        // A renamed species keeps its former common name as another name, as a merge does, so
        // the sightings and keywords written with it are still recognised.
        if !isNew, SpeciesCatalog.key(opened.commonName) != SpeciesCatalog.key(trimmedName),
           !opened.commonName.isEmpty,
           !otherNames.contains(where: { SpeciesCatalog.key($0) == SpeciesCatalog.key(opened.commonName) }) {
            otherNames.append(opened.commonName)
        }
        if isNew || trimmedName != opened.commonName { target.commonName = trimmedName }
        let scientific = scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew || scientific != opened.scientificName.trimmingCharacters(in: .whitespacesAndNewlines) {
            target.scientificName = scientific.isEmpty ? nil : scientific
            // A new scientific name is looked up again (a "not found" applied to the old one).
            if target.inatTaxonID == nil { target.inatFetchedAt = nil }
        }
        let category = categorySelection == Self.newCategoryTag
            ? newCategory.trimmingCharacters(in: .whitespacesAndNewlines) : categorySelection
        if isNew || category != opened.category { target.category = category.isEmpty ? nil : category }
        let size = sizeOriginal.resolve(sizeText)
        if isNew || size != target.averageSize || sizeUnit != opened.sizeUnit {
            target.averageSize = size
            // The unit the size is entered in; a size of unknown unit keeps none until one is picked.
            target.averageSizeUnit = size == nil ? nil : sizeUnit
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew || trimmedNotes != opened.notes.trimmingCharacters(in: .whitespacesAndNewlines) {
            target.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        }
        // A name typed but not added yet is kept too.
        if canAddOtherName { otherNames.append(trimmedOtherName) }
        // A new species' name is not also one of its other names (the iNaturalist name swap
        // undone in the form leaves the typed name in both).
        if isNew { otherNames.removeAll { SpeciesCatalog.key($0) == SpeciesCatalog.key(trimmedName) } }
        if isNew || otherNames != opened.otherNames { target.altNames = otherNames.isEmpty ? nil : otherNames }
        if isNew || imageChanged {
            target.setFeaturedImage(imageData, thumbnail: thumbnailData, attribution: imageAttribution)
        }
        // The species takes the earlier sightings recorded under a name it gets here (all its
        // names when it is new; an added or changed name otherwise), so that name is not also
        // listed as "not in the catalogue". The sightings keep their names.
        let newNames = ([trimmedName] + [target.scientificName].compactMap { $0 } + otherNames)
            .filter { !previousNames.contains(SpeciesCatalog.key($0)) }
        if !newNames.isEmpty {
            SpeciesCatalog.linkUnlinkedSightings(named: newNames, to: target, in: modelContext)
        }
        // A taxon declined with "Don't Link", while the scientific name is still its own: marked
        // as looked up, so no automatic lookup (here or "Update Species") links it; it can still
        // be linked from the species page.
        let declined = isNew && pickedTaxon == nil
            && declinedTaxonName.map { SpeciesCatalog.key($0) == SpeciesCatalog.key(scientific) } ?? false
        if declined { target.inatFetchedAt = .now }
        try? modelContext.save()
        if isNew, let pickedTaxon {
            // Linked to the taxon chosen in the form (classification, names, Wikipedia and a
            // Creative Commons photo when the species has no image of its own).
            let id = target.persistentModelID
            let container = modelContext.container
            Task { await INaturalistUpdater.apply(pickedTaxon, toSpecies: id, container: container, allowNameSwap: false) }
        } else if !declined {
            // Fill in the taxonomy from iNaturalist when allowed (exact scientific name only).
            INaturalistUpdater.updateInBackground([target], in: modelContext)
        }
        dismiss()
    }
}
