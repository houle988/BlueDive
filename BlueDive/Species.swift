import Foundation
import SwiftData

/// A species in the marine-life catalogue.
///
/// Sightings (`MarineSight`) and photos (`DivePhoto`) link to a species; the sighting's own
/// `name` text is never rewritten. All metrics (sightings, average depth, average water
/// temperature) are calculated from the linked dives when displayed, never stored.
@Model
final class Species {
    var id: UUID = UUID()
    /// When the species was created on this or another device. Not shown; kept so duplicates
    /// created on two devices before they sync can later be resolved automatically (keep the
    /// older one) — a value that cannot be reconstructed afterwards.
    var createdAt: Date = Date.now

    var commonName: String = ""
    var scientificName: String?
    /// Either a default category key (`"bd.category.<key>"`, displayed translated) or a
    /// custom category name stored verbatim (e.g. an imported "Crustacé").
    var category: String?
    var averageSize: Double?
    /// "cm" or "in"; nil when the unit is unknown.
    var averageSizeUnit: String?
    var notes: String?
    /// Other names this species is known by (e.g. spellings merged from sightings).
    var altNames: [String]?
    /// Identifier of the record this species was imported from (e.g. "macdive:<ZUUID>"),
    /// so a re-import updates instead of duplicating.
    var sourceIdentifier: String?

    /// The featured image, in its own record (DivePhotoBlobs.swift) so the species lists and
    /// name lookups, which fetch every species, never load it. Set with `setFeaturedImage`.
    @Relationship(deleteRule: .cascade, inverse: \SpeciesImage.species)
    var image: SpeciesImage?

    // iNaturalist (filled only when online lookups are enabled)
    var inatTaxonID: Int?
    /// JSON object of common names by language code, e.g. {"en": "European Lobster"}.
    var inatCommonNamesData: Data?
    /// JSON array of the taxonomy from the root to this taxon: [{"rank", "name", "id"}].
    var taxonomyData: Data?
    var wikipediaSummary: String?
    var wikipediaURL: String?
    var inatFetchedAt: Date?

    @Relationship(deleteRule: .nullify, inverse: \MarineSight.species)
    var sightings: [MarineSight]? = []
    var photos: [DivePhoto]? = []

    init(commonName: String) {
        self.commonName = commonName
    }
}

extension Species {
    var featuredImageData: Data? { image?.imageData }
    /// The thumbnail, stored only when smaller than the image (iNaturalist's medium photo is
    /// often already small).
    var featuredThumbnailData: Data? { image?.thumbnailData }
    /// Credit for a featured image that is not the user's own (e.g. an iNaturalist photo
    /// under a Creative Commons licence); nil for the user's own image.
    var featuredImageAttribution: String? { image?.attribution }
    /// Has a featured image (reads the link only, not the image).
    var hasFeaturedImage: Bool { image != nil }

    /// Sets (or, with nil `imageData`, removes) the featured image, in the species' own
    /// context (the species must already be inserted).
    func setFeaturedImage(_ imageData: Data?, thumbnail: Data?, attribution: String?) {
        guard let context = modelContext else { return }
        // A new image gets a new record (the old one is deleted), so views keyed on the
        // record (`SpeciesImageView`) decode the new image.
        if let image { context.delete(image) }
        image = nil
        guard let imageData else { return }
        let record = SpeciesImage()
        context.insert(record)
        record.imageData = imageData
        record.thumbnailData = thumbnail
        record.attribution = attribution
        record.speciesID = id
        image = record
    }
}
