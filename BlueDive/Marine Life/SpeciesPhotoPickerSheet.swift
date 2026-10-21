import SwiftUI
import SwiftData

/// Picks a species' featured image among the dive photos already in BlueDive: the photos
/// linked to the species, then the other photos of the dives it was sighted on. Choosing a
/// photo hands its original bytes to `onPick` and closes the sheet (like `PhotosPicker`).
struct SpeciesPhotoPickerSheet: View {
    let candidates: SpeciesPhotoCandidates
    let onPick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// The photo whose original is being read; every tile is disabled meanwhile.
    @State private var loadingID: PersistentIdentifier?
    /// The read of the chosen original: cancelled when the sheet closes, so a photo the user
    /// backed out of (Close during the read) is not handed to the form.
    @State private var loadTask: Task<Void, Never>?

    nonisolated static let author = "BlueDive.speciesImage"

    var body: some View {
        // A photo or dive deleted on another device while the sheet is open is not read.
        let linked = candidates.linked.filter { Self.isLive($0) }
        let fromDives = candidates.fromDives.filter { Self.isLive($0) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if linked.isEmpty && fromDives.isEmpty {
                        Group {
                            // With a diver chosen, the filter may hide other divers' photos.
                            if candidates.diver.isEmpty {
                                Text("No dive photo of this species yet.")
                            } else {
                                Text("No photo of this species on this diver's dives.")
                            }
                        }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    if !linked.isEmpty {
                        section(Text("Photos of This Species"), photos: linked)
                    }
                    if !fromDives.isEmpty {
                        section(Text("Other Photos from These Dives"), photos: fromDives)
                    }
                }
                .padding()
            }
            .navigationTitle(Text("Choose a Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
        }
        .onDisappear { loadTask?.cancel() }
    }

    private static func isLive(_ photo: DivePhoto) -> Bool {
        !photo.isDeleted && photo.modelContext != nil
    }

    private func section(_ title: Text, photos: [DivePhoto]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    tile(photo, position: index + 1, total: photos.count)
                }
            }
        }
    }

    private func tile(_ photo: DivePhoto, position: Int, total: Int) -> some View {
        // The original may still be downloading from iCloud: the thumbnail is never used as
        // the featured image, so such a photo cannot be chosen yet.
        let isAvailable = photo.original != nil
        let isLoading = loadingID == photo.persistentModelID
        return Button {
            pick(photo)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoThumbnailTile(imageKey: "\(photo.id)|\(photo.thumbnail != nil)") { photo.thumbnailBytes }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAvailable {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(6)
                    }
                }
                .overlay {
                    if isLoading { ProgressView() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isAvailable ? 1 : 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || loadingID != nil)
        .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Photo %@ of %@", bundle: .forAppLanguage(), value: "Photo %@ of %@", comment: "Announces the current photo's position while paging through photos (locale-formatted numbers)"), Double(position).localizedString(decimals: 0), Double(total).localizedString(decimals: 0))))
        .accessibilityValue(isAvailable ? Text(verbatim: "") : Text("Downloading from iCloud"))
    }

    /// Reads the photo's original off the main thread (often several MB), then hands it over.
    private func pick(_ photo: DivePhoto) {
        guard loadingID == nil, Self.isLive(photo) else { return }
        let id = photo.persistentModelID
        let container = modelContext.container
        loadingID = id
        loadTask = Task {
            let saved = await Task.detached(priority: .userInitiated) {
                Self.readOriginal(id, container: container)
            }.value
            loadingID = nil
            // The sheet was closed during the read: the photo is not chosen.
            guard !Task.isCancelled else { return }
            // Deleted on another device during the read: reading it would crash.
            guard Self.isLive(photo) else { return }
            // Not in the store yet (an original not saved): read from the main context.
            guard let data = saved ?? photo.original?.data else { return }
            onPick(data)
            dismiss()
        }
    }

    /// The saved original of a dive photo, read in a context of its own.
    nonisolated private static func readOriginal(_ id: PersistentIdentifier, container: ModelContainer) -> Data? {
        let context = ModelContext(container)
        context.author = author
        var descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.original?.data
    }
}

/// The dive photos a species' featured image can be chosen from.
struct SpeciesPhotoCandidates: Identifiable {
    /// One per build, so the picker sheet (`sheet(item:)`) is presented with this list.
    let id = UUID()
    /// Photos linked to the species, oldest first (as on the species page).
    var linked: [DivePhoto] = []
    /// The other photos of the dives the species was sighted on, oldest first.
    var fromDives: [DivePhoto] = []
    /// The diver filter the photos were chosen with (empty for every diver).
    let diver: String

    /// Built when "BlueDive Photos" is chosen. Skips photos and dives deleted on another
    /// device that the main context has not dropped yet. `diver`: the diver filter (as
    /// `DiverFilter.apply` compares; empty for every diver) — only that diver's dives' photos
    /// are offered (a linked photo with no dive is kept).
    init(species: Species, diver: String) {
        self.diver = diver
        func isLive(_ model: some PersistentModel) -> Bool { !model.isDeleted && model.modelContext != nil }
        func isDiversDive(_ dive: Dive) -> Bool {
            diver.isEmpty || dive.diverName.trimmingCharacters(in: .whitespaces) == diver
        }
        func byDate(_ a: DivePhoto, _ b: DivePhoto) -> Bool { (a.captureDate ?? a.createdAt) < (b.captureDate ?? b.createdAt) }

        linked = (species.photos ?? []).filter { photo in
            guard isLive(photo) else { return false }
            guard let dive = photo.dive else { return true }
            return isLive(dive) && isDiversDive(dive)
        }.sorted(by: byDate)
        let linkedIDs = Set(linked.map(\.persistentModelID))
        var seenDives = Set<PersistentIdentifier>()
        var others: [DivePhoto] = []
        for sighting in species.sightings ?? [] where isLive(sighting) {
            guard let dive = sighting.dive, isLive(dive), isDiversDive(dive),
                  seenDives.insert(dive.persistentModelID).inserted else { continue }
            others += (dive.photos ?? []).filter { isLive($0) && !linkedIDs.contains($0.persistentModelID) }
        }
        fromDives = others.sorted(by: byDate)
    }
}
