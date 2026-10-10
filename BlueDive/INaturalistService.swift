import Foundation
import SwiftData
import os.log

// MARK: - iNaturalist Service

enum INaturalistError: Error {
    /// The request could not be made or completed (no connection, timeout, no HTTP response).
    case requestFailed
    /// iNaturalist answered with an error (e.g. rate limit) or an unreadable response.
    case serviceUnavailable
}

/// Looks up species in the iNaturalist taxonomy (https://api.inaturalist.org/v1), which needs
/// no API key. Only the species name typed or detected is sent. Used only when Settings →
/// Online Services → Look up species on iNaturalist is on.
enum INaturalistService {

    /// One rank of a taxon's classification, root first.
    struct Rank: Codable, Hashable, Sendable {
        let rank: String
        let name: String
        let id: Int
        /// iNaturalist's common name for this group in the lookup's language
        /// ("Ray-finned Fishes"); absent in classifications stored before it was kept.
        var commonName: String?
    }

    /// A search result.
    struct TaxonSummary: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let rank: String
        let commonName: String?
        /// Preview of the default photo, only when its licence lets it be stored (the
        /// photo that would be stored); nil otherwise.
        let photoURL: URL?
        /// The default photo cannot be stored (all rights reserved): another photo of the taxon
        /// may be used instead (`previewPhotos(for:)`).
        let needsAlternativePhoto: Bool
    }

    /// Full details of one taxon.
    struct Taxon: Sendable {
        let id: Int
        let name: String
        let rank: String
        /// Common name in the requested language, and in English.
        let localizedCommonName: String?
        let englishCommonName: String?
        let languageCode: String
        /// Root (kingdom) to this taxon, inclusive.
        let classification: [Rank]
        let wikipediaURL: String?
        /// Wikipedia summary as plain text.
        let wikipediaSummary: String?
        /// The photo stored for the taxon (`chosenPhoto`): the default photo, or another
        /// Creative Commons photo of the taxon when the default one cannot be stored.
        let photoURL: URL?
        let photoAttribution: String?
        /// Licence code of that photo (e.g. "cc-by-nc"); nil = all rights reserved.
        let photoLicense: String?
    }

    static func pageURL(taxonID: Int) -> URL? {
        URL(string: "https://www.inaturalist.org/taxa/\(taxonID)")
    }

    /// Two-letter code of the app language (in-app override, else the system).
    @MainActor
    static var appLanguageCode: String {
        let locale = UserPreferences.shared.languageMode.locale ?? Locale.current
        return locale.language.languageCode?.identifier ?? "en"
    }

    /// Language of the iNaturalist common names: the one chosen in Settings → Online Services,
    /// else the app language. Used for every request and for the name shown.
    @MainActor
    static var nameLanguageCode: String {
        let chosen = UserPreferences.shared.taxonomyNameLanguage
        return chosen.isEmpty ? appLanguageCode : chosen
    }

    /// Languages offered for the common names (iNaturalist locales with good coverage).
    static let nameLanguageCodes = ["en", "fr", "de", "nl", "es", "it", "pt", "nb", "sv", "da", "fi", "pl", "ja"]

    /// Taxa whose name or common name matches `query`.
    static func search(_ query: String, languageCode: String) async throws -> [TaxonSummary] {
        let response: SearchResponse = try await get(path: "taxa", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "locale", value: languageCode)
        ])
        return response.results.map {
            let defaultIsOpen = isOpenLicence($0.defaultPhoto?.licenseCode)
            return TaxonSummary(id: $0.id, name: $0.name, rank: $0.rank,
                                commonName: $0.preferredCommonName ?? $0.englishCommonName,
                                photoURL: defaultIsOpen ? $0.defaultPhoto?.squareURL.flatMap(URL.init(string:)) : nil,
                                needsAlternativePhoto: !defaultIsOpen)
        }
    }

    /// Previews of the photo that would be stored for each taxon (`chosenPhoto`, alternative
    /// photos allowed), by taxon ID: one request for all of them. A taxon with no Creative
    /// Commons photo is left out.
    static func previewPhotos(for ids: [Int], languageCode: String) async throws -> [Int: URL] {
        guard !ids.isEmpty else { return [:] }
        let response: DetailResponse = try await get(path: "taxa/\(ids.map(String.init).joined(separator: ","))", query: [
            URLQueryItem(name: "locale", value: languageCode)
        ])
        var previews: [Int: URL] = [:]
        for result in response.results {
            if let url = chosenPhoto(of: result, allowAlternative: true)?.squareURL.flatMap(URL.init(string:)) {
                previews[result.id] = url
            }
        }
        return previews
    }

    /// Whether a photo's licence lets BlueDive store it: Creative Commons ("cc-by", "cc0", …) or
    /// public domain ("pd"); not "all rights reserved" (no licence).
    static func isOpenLicence(_ license: String?) -> Bool {
        guard let license = license?.lowercased() else { return false }
        return license.hasPrefix("cc") || license == "pd"
    }

    /// The photo stored for a taxon: its default photo when its licence allows it, else — with
    /// `allowAlternative` ("Use another Creative Commons photo") — the first of its other photos
    /// whose licence does, else none. A photo listed under another taxon is skipped (a safeguard:
    /// iNaturalist lists every photo under the taxon asked for); one without a taxon is kept.
    private static func chosenPhoto(of result: Result, allowAlternative: Bool) -> Photo? {
        if let photo = result.defaultPhoto, isOpenLicence(photo.licenseCode) { return photo }
        guard allowAlternative else { return nil }
        return result.taxonPhotos?.first {
            ($0.taxon.map { $0.id == result.id } ?? true) && isOpenLicence($0.photo?.licenseCode)
        }?.photo
    }

    /// The taxon whose scientific name is exactly `name` (ignoring case), at the rank the
    /// name's form implies — one word: a genus or higher; two: a species; three: below the
    /// species — or nil. A search lists several taxa with one name (a species "complex" before
    /// the species, the same genus name in two kingdoms): only one of the expected rank is
    /// linked without asking, and none when that is ambiguous.
    static func exactMatch(for name: String, languageCode: String) async throws -> TaxonSummary? {
        let results = try await search(name, languageCode: languageCode)
        let matching = results.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let words = name.split(separator: " ").filter { $0 != "×" }.count
        let expected: Set<String>
        switch words {
        case 1: expected = ["genus", "family", "order", "class", "phylum", "kingdom", "subgenus"]
        case 2: expected = ["species", "hybrid"]
        default: expected = ["subspecies", "variety", "form"]
        }
        let ofRank = matching.filter { expected.contains($0.rank) }
        return ofRank.count == 1 ? ofRank.first : nil
    }

    static func taxon(id: Int, languageCode: String,
                      allowAlternativePhoto: Bool) async throws -> Taxon {
        let response: DetailResponse = try await get(path: "taxa/\(id)", query: [
            URLQueryItem(name: "locale", value: languageCode)
        ])
        guard let result = response.results.first else { throw INaturalistError.serviceUnavailable }
        var classification = (result.ancestors ?? []).map {
            Rank(rank: $0.rank, name: $0.name, id: $0.id, commonName: $0.preferredCommonName)
        }
        classification.append(Rank(rank: result.rank, name: result.name, id: result.id,
                                   commonName: result.preferredCommonName))
        let photo = chosenPhoto(of: result, allowAlternative: allowAlternativePhoto)
        return Taxon(
            id: result.id, name: result.name, rank: result.rank,
            localizedCommonName: result.preferredCommonName,
            englishCommonName: result.englishCommonName,
            languageCode: languageCode,
            classification: classification,
            wikipediaURL: result.wikipediaURL,
            wikipediaSummary: result.wikipediaSummary.map(plainText),
            photoURL: photo?.mediumURL.flatMap(URL.init(string:)),
            photoAttribution: photo?.attribution,
            photoLicense: photo?.licenseCode
        )
    }

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw INaturalistError.serviceUnavailable }
        return data
    }

    // MARK: Request

    /// Ephemeral session: nothing written to the on-disk URL cache.
    private static let session = URLSession(configuration: .ephemeral)

    private static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        return "BlueDive/\(version) (https://github.com/houle988/BlueDive)"
    }()

    private static func get<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(string: "https://api.inaturalist.org/v1/\(path)") else {
            throw INaturalistError.requestFailed
        }
        components.queryItems = query
        guard let url = components.url else { throw INaturalistError.requestFailed }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw INaturalistError.requestFailed
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw INaturalistError.serviceUnavailable }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw INaturalistError.serviceUnavailable
        }
    }

    /// Removes HTML tags and decodes the few entities iNaturalist's summaries use.
    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SearchResponse: Decodable { let results: [Result] }
    private struct DetailResponse: Decodable { let results: [Result] }

    private struct Result: Decodable {
        let id: Int
        let name: String
        let rank: String
        let preferredCommonName: String?
        let englishCommonName: String?
        let wikipediaURL: String?
        let wikipediaSummary: String?
        let defaultPhoto: Photo?
        /// The taxon's photos, default first (detail requests only).
        let taxonPhotos: [TaxonPhoto]?
        let ancestors: [Ancestor]?

        enum CodingKeys: String, CodingKey {
            case id, name, rank, ancestors
            case taxonPhotos = "taxon_photos"
            case preferredCommonName = "preferred_common_name"
            case englishCommonName = "english_common_name"
            case wikipediaURL = "wikipedia_url"
            case wikipediaSummary = "wikipedia_summary"
            case defaultPhoto = "default_photo"
        }
    }

    private struct Ancestor: Decodable {
        let id: Int
        let name: String
        let rank: String
        let preferredCommonName: String?

        enum CodingKeys: String, CodingKey {
            case id, name, rank
            case preferredCommonName = "preferred_common_name"
        }
    }

    private struct TaxonPhoto: Decodable {
        struct TaxonReference: Decodable { let id: Int }
        /// Optional: one entry without a photo must not fail the whole taxon.
        let photo: Photo?
        /// The taxon the photo is listed under.
        let taxon: TaxonReference?
    }

    private struct Photo: Decodable {
        let squareURL: String?
        let mediumURL: String?
        let attribution: String?
        let licenseCode: String?

        enum CodingKeys: String, CodingKey {
            case squareURL = "square_url"
            case mediumURL = "medium_url"
            case attribution
            case licenseCode = "license_code"
        }
    }
}

// MARK: - Species taxonomy

extension Species {
    /// iNaturalist classification, root (kingdom) first; empty before a lookup.
    var taxonomy: [INaturalistService.Rank] {
        guard let data = taxonomyData else { return [] }
        return (try? JSONDecoder().decode([INaturalistService.Rank].self, from: data)) ?? []
    }

    /// Name at a rank ("class", "order", "family", …), if known.
    func taxonName(rank: String) -> String? {
        taxonomy.first { $0.rank == rank }?.name
    }

    /// "Actinopterygii (Ray-finned Fishes)": a group's Latin name with its common name when known.
    static func groupLabel(name: String, commonName: String?) -> String {
        guard let commonName, !commonName.isEmpty,
              commonName.caseInsensitiveCompare(name) != .orderedSame else { return name }
        return "\(name) (\(commonName))"
    }

    /// iNaturalist common names by language code.
    var inatCommonNames: [String: String] {
        guard let data = inatCommonNamesData else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Name shown for the species. When the stored common name is one of iNaturalist's
    /// names, iNaturalist's name in the names language (`nameLanguageCode`) is shown if it was fetched;
    /// otherwise — a name typed by the user or read from keywords — the stored name, as is.
    /// Display only: `commonName` is never changed.
    @MainActor
    var displayName: String {
        let names = inatCommonNames
        guard !names.isEmpty,
              names.values.contains(where: { SpeciesCatalog.key($0) == SpeciesCatalog.key(commonName) }),
              let localized = names[INaturalistService.nameLanguageCode], !localized.isEmpty
        else { return commonName }
        return localized
    }
}

// MARK: - Applying a taxon

@MainActor
enum INaturalistUpdater {
    static let logger = Logger(subsystem: "com.bluedive.app", category: "iNaturalist")

    /// The ranks shown and filtered on, in order (the feature request's list).
    static let displayedRanks = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]

    static func localizedRank(_ rank: String) -> String {
        let bundle = Bundle.forAppLanguage()
        switch rank {
        case "kingdom": return NSLocalizedString("Kingdom", bundle: bundle, value: "Kingdom", comment: "Taxonomic rank")
        case "phylum":  return NSLocalizedString("Phylum", bundle: bundle, value: "Phylum", comment: "Taxonomic rank")
        case "class":   return NSLocalizedString("Class", bundle: bundle, value: "Class", comment: "Taxonomic rank")
        case "order":   return NSLocalizedString("Order", bundle: bundle, value: "Order", comment: "Taxonomic rank")
        case "family":  return NSLocalizedString("Family", bundle: bundle, value: "Family", comment: "Taxonomic rank")
        case "genus":   return NSLocalizedString("Genus", bundle: bundle, value: "Genus", comment: "Taxonomic rank")
        // Its own key: "Species" is the plural count label ("Espèces", "Arten").
        case "species": return NSLocalizedString("Species (taxonomic rank)", bundle: bundle, value: "Species", comment: "Taxonomic rank, singular (one species)")
        case "subspecies": return NSLocalizedString("Subspecies", bundle: bundle, value: "Subspecies", comment: "Taxonomic rank")
        case "variety": return NSLocalizedString("Variety", bundle: bundle, value: "Variety", comment: "Taxonomic rank")
        case "complex": return NSLocalizedString("Species complex", bundle: bundle, value: "Species complex", comment: "Taxonomic rank: a group of closely related species")
        case "hybrid": return NSLocalizedString("Hybrid", bundle: bundle, value: "Hybrid", comment: "Taxonomic rank")
        case "subgenus": return NSLocalizedString("Subgenus", bundle: bundle, value: "Subgenus", comment: "Taxonomic rank")
        case "subfamily": return NSLocalizedString("Subfamily", bundle: bundle, value: "Subfamily", comment: "Taxonomic rank")
        case "superfamily": return NSLocalizedString("Superfamily", bundle: bundle, value: "Superfamily", comment: "Taxonomic rank")
        case "suborder": return NSLocalizedString("Suborder", bundle: bundle, value: "Suborder", comment: "Taxonomic rank")
        case "subclass": return NSLocalizedString("Subclass", bundle: bundle, value: "Subclass", comment: "Taxonomic rank")
        default:
            // A rank BlueDive does not translate ("infraorder", "tribe"): iNaturalist's own
            // term, capitalised.
            return rank.prefix(1).uppercased() + rank.dropFirst()
        }
    }

    /// Whether the species can still be written (not deleted or merged away meanwhile — a
    /// lookup awaits the network, during which the user can delete it).
    static func isAlive(_ species: Species) -> Bool {
        !species.isDeleted && species.modelContext != nil
    }

    /// Stores the taxon on the species. iNaturalist data goes into its own fields; the
    /// user's fields are only filled when empty, except the common name: a placeholder (only
    /// the scientific name) is replaced by the iNaturalist common name, and any other name
    /// too when "Use iNaturalist common names" is on (the name it had becomes another name). A name
    /// another species already has is not given (no two species with one name). The taxon's
    /// photo (`chosenPhoto`) is downloaded only when the species has no image and the photo's
    /// licence allows it, and its credit is kept with it. Returns whether it was saved.
    ///
    /// The photo is downloaded first; the species is then read as saved now, in a taxonomy
    /// context of its own, and every field is decided and saved with no suspension in between,
    /// so an edit saved during the requests and the download (a rename, a category, an image)
    /// is never overwritten. With `lookupOf`, the update is skipped unless the species still
    /// waits for a lookup of that name (`lookupName(of:)`). `allowNameSwap: false` keeps the
    /// common name the caller decided on (the new species form, which already offered the swap).
    @discardableResult
    static func apply(_ taxon: INaturalistService.Taxon, toSpecies id: PersistentIdentifier,
                      container: ModelContainer, lookupOf name: String? = nil,
                      allowNameSwap: Bool = true) async -> Bool {
        let photo = await featuredPhoto(of: taxon, forSpecies: id, container: container)
        let context = taxonomyContext(container)
        guard let species = fetchSpecies(id, in: context) else { return false }
        if let name {
            guard let pending = lookupName(of: species),
                  SpeciesCatalog.key(pending) == SpeciesCatalog.key(name) else { return false }
        }
        // Re-linked to another taxon (a correction in the lookup sheet): what came from the
        // previous taxon is replaced — its names in every language, its Creative Commons photo
        // (an image with a credit; the user's own image has none and is kept), and a scientific
        // or common name that was the previous taxon's.
        let previousTaxonID = species.inatTaxonID
        let relinked = previousTaxonID != nil && previousTaxonID != taxon.id
        let previousTaxonName = relinked ? species.taxonomy.last?.name : nil
        let previousCommonNames = relinked ? Set(species.inatCommonNames.values.map(SpeciesCatalog.key)) : []
        if relinked, species.featuredImageAttribution != nil {
            species.setFeaturedImage(nil, thumbnail: nil, attribution: nil)
        }
        var names = relinked ? [:] : species.inatCommonNames
        species.inatTaxonID = taxon.id
        if let english = taxon.englishCommonName { names["en"] = english }
        if let localized = taxon.localizedCommonName { names[taxon.languageCode] = localized }
        species.inatCommonNamesData = try? JSONEncoder().encode(names)
        species.taxonomyData = try? JSONEncoder().encode(taxon.classification)
        species.wikipediaURL = taxon.wikipediaURL
        species.wikipediaSummary = taxon.wikipediaSummary
        species.inatFetchedAt = .now

        let others = SpeciesNameIndex(catalogue: ((try? context.fetch(FetchDescriptor<Species>())) ?? [])
            .filter { $0.persistentModelID != species.persistentModelID })
        // The scientific name: filled when empty (unless another species has it); after a
        // re-link, the previous taxon's name is always replaced by the chosen taxon's — keeping
        // it would show one taxon's name over another's classification.
        let scientificFromPreviousTaxon = previousTaxonName.map {
            SpeciesCatalog.key($0) == SpeciesCatalog.key(species.scientificName ?? "")
        } ?? false
        if scientificFromPreviousTaxon {
            species.scientificName = taxon.name
        } else if species.scientificName?.isEmpty ?? true, others.species(named: taxon.name) == nil {
            species.scientificName = taxon.name
        }
        // The common name: a placeholder (the scientific name of a species created from a
        // detected name or a sighting) becomes iNaturalist's common name when no other species
        // has it — only with "Use iNaturalist common names" on (and not when the caller kept
        // its name); off, the species keeps the name it was given. After a re-link, a common
        // name that was the previous taxon's (its name or one of its iNaturalist names) is
        // always replaced in the same way, else by the chosen taxon's scientific name, so no
        // name of the previous taxon is left.
        let commonName = taxon.localizedCommonName ?? taxon.englishCommonName
        let commonKey = SpeciesCatalog.key(species.commonName)
        let commonFromPreviousTaxon = previousTaxonName.map { SpeciesCatalog.key($0) == commonKey } ?? false
            || previousCommonNames.contains(commonKey)
        let commonIsPlaceholder = commonKey == SpeciesCatalog.key(taxon.name) || commonFromPreviousTaxon
        let usesINaturalistNames = allowNameSwap && UserPreferences.shared.useINaturalistCommonNames
        if commonIsPlaceholder, commonFromPreviousTaxon || usesINaturalistNames {
            if let commonName, others.species(named: commonName) == nil {
                species.commonName = commonName
                // The sightings recorded under that name join it, as when a species is created.
                SpeciesCatalog.linkUnlinkedSightings(named: [commonName], to: species, in: context)
            } else if commonFromPreviousTaxon {
                species.commonName = taxon.name
            }
        } else if !commonIsPlaceholder, usesINaturalistNames, previousTaxonID == nil,
                  let commonName, !commonKey.isEmpty, SpeciesCatalog.key(commonName) != commonKey,
                  !names.values.contains(where: { SpeciesCatalog.key($0) == commonKey }),
                  others.species(named: commonName) == nil {
            // "Use iNaturalist common names", on a first link only (a species already linked
            // keeps its name): iNaturalist's name (in the names language, else English) becomes
            // the name, and the name the species had — typed or read from a keyword — is kept as
            // another name, so the sightings and keywords written with it are still recognised.
            // Kept as is when it is already one of iNaturalist's names (shown in the names
            // language anyway) or another species has iNaturalist's name.
            var otherNames = species.altNames ?? []
            if !otherNames.contains(where: { SpeciesCatalog.key($0) == commonKey }) {
                otherNames.append(species.commonName)
            }
            // The new name is not also listed as another name.
            otherNames.removeAll { SpeciesCatalog.key($0) == SpeciesCatalog.key(commonName) }
            species.altNames = otherNames.isEmpty ? nil : otherNames
            species.commonName = commonName
            SpeciesCatalog.linkUnlinkedSightings(named: [commonName], to: species, in: context)
        }
        if species.category?.isEmpty ?? true, let category = suggestedCategory(for: taxon.classification) {
            species.category = category.storedValue
        }
        if !species.hasFeaturedImage, let photo {
            species.setFeaturedImage(photo.data, thumbnail: photo.thumbnail, attribution: taxon.photoAttribution)
        }
        // `context` is this update's own, so a failed save rolls back only this update,
        // never another screen's pending edits.
        return save(context)
    }

    /// The taxon's photo (`chosenPhoto`), downloaded when its licence allows it and the
    /// species, as saved now, would take it: no image, or the previous taxon's photo after a
    /// re-link. Whether it is stored is decided again after the download (`apply`).
    private static func featuredPhoto(of taxon: INaturalistService.Taxon, forSpecies id: PersistentIdentifier,
                                      container: ModelContainer) async -> (data: Data, thumbnail: Data?)? {
        // The context is kept for as long as the species is read.
        let context = taxonomyContext(container)
        guard let url = taxon.photoURL, INaturalistService.isOpenLicence(taxon.photoLicense),
              let species = fetchSpecies(id, in: context) else { return nil }
        let relinked = species.inatTaxonID != nil && species.inatTaxonID != taxon.id
        guard !species.hasFeaturedImage || (relinked && species.featuredImageAttribution != nil) else { return nil }
        guard let data = try? await INaturalistService.download(url),
              let info = await Task.detached(priority: .utility, operation: { PhotoMetadataReader.read(data) }).value
        else { return nil }
        // A thumbnail only when it is smaller than the image (iNaturalist's medium photo is
        // often already small).
        return (data, (info.thumbnail?.count ?? .max) < data.count ? info.thumbnail : nil)
    }

    /// A context of its own for an iNaturalist update: a failed save then rolls back only that
    /// update. The main context picks up the saved changes.
    static func taxonomyContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.author = "BlueDive.taxonomy"
        context.autosaveEnabled = false
        return context
    }

    /// The species in `context` (another context's object cannot be written there).
    static func species(_ species: Species, in context: ModelContext) -> Species? {
        let pid = species.persistentModelID
        var descriptor = FetchDescriptor<Species>(predicate: #Predicate { $0.persistentModelID == pid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// The default category matching a classification, if one does.
    static func suggestedCategory(for classification: [INaturalistService.Rank]) -> SpeciesCategory? {
        let names = Set(classification.map(\.name))
        if names.contains("Elasmobranchii") { return .sharkRay }
        if names.contains("Actinopterygii") || names.contains("Chondrichthyes") || names.contains("Sarcopterygii")
            || names.contains("Myxini") || names.contains("Petromyzonti") { return .fish }
        if names.contains("Crustacea") { return .crustacean }
        if names.contains("Mollusca") { return .mollusc }
        if names.contains("Cnidaria") || names.contains("Ctenophora") { return .cnidarian }
        if names.contains("Echinodermata") { return .echinoderm }
        if names.contains("Reptilia") || names.contains("Testudines") { return .reptile }
        if names.contains("Mammalia") { return .mammal }
        if names.contains("Porifera") { return .sponge }
        if names.contains("Annelida") || names.contains("Platyhelminthes") || names.contains("Nemertea") { return .worm }
        if names.contains("Plantae") || names.contains("Chromista") || names.contains("Rhodophyta") { return .plantAlgae }
        return nil
    }

    /// Whether an automatic lookup applies to the species: a scientific name, not linked to a
    /// taxon yet, and not already looked up without a match (until its scientific name changes).
    /// The rule for `updateAll` and the pending count in Settings; automatic lookups of new
    /// species (`updateIfPossible`) also accept a common name written as a scientific name
    /// (`lookupName(of:)`).
    static func needsLookup(_ species: Species) -> Bool {
        species.inatTaxonID == nil && species.inatFetchedAt == nil && !(species.scientificName?.isEmpty ?? true)
    }

    /// The name an automatic lookup of a new species asks for: its scientific name
    /// (`needsLookup`), else — for a species with no scientific name, not linked or looked up
    /// yet — a common name written as a scientific name (a sighting named "Octopus vulgaris").
    /// That name is never stored as the scientific name by itself: only an exact iNaturalist
    /// match fills it (`apply`), so "Whitetip reef shark", written the same way, stays a
    /// common name.
    static func lookupName(of species: Species) -> String? {
        if needsLookup(species) { return species.scientificName }
        guard species.inatTaxonID == nil, species.inatFetchedAt == nil,
              species.scientificName?.isEmpty ?? true else { return nil }
        let common = species.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScientificNameDetector.looksScientific(common) ? common : nil
    }

    enum LookupOutcome {
        /// Nothing asked: lookups off, no name to look up, already linked or already looked up.
        case skipped
        /// Asked, but nothing stored: the species changed or was deleted during the requests,
        /// or the save failed.
        case abandoned
        case updated
        /// No taxon of the expected rank with that name; recorded, not asked again until the
        /// scientific name changes.
        case notFound
        /// No connection, or iNaturalist refused (e.g. too many requests).
        case failed(serviceUnavailable: Bool)
    }

    /// Looks up the species by its scientific name, or a common name written as one
    /// (`lookupName(of:)`; exact match only), and applies the taxon. Does nothing when online
    /// lookups are off, the species has no such name, is already linked to a taxon, or was
    /// already looked up without a match (`inatFetchedAt` set, no taxon; cleared when its
    /// scientific name is edited).
    @discardableResult
    static func updateIfPossible(_ species: Species, in context: ModelContext) async -> LookupOutcome {
        guard UserPreferences.shared.fetchTaxonomyOnline, isAlive(species),
              let name = lookupName(of: species) else { return .skipped }
        let language = INaturalistService.nameLanguageCode
        do {
            guard let match = try await INaturalistService.exactMatch(for: name, languageCode: language) else {
                // Recorded on the species as saved now, if it still waits for this lookup.
                let fresh = taxonomyContext(context.container)
                guard let saved = fetchSpecies(species.persistentModelID, in: fresh),
                      let pending = lookupName(of: saved),
                      SpeciesCatalog.key(pending) == SpeciesCatalog.key(name) else { return .abandoned }
                saved.inatFetchedAt = .now
                save(fresh)
                return .notFound
            }
            let taxon = try await INaturalistService.taxon(id: match.id, languageCode: language,
                                                           allowAlternativePhoto: UserPreferences.shared.useAlternativeINaturalistPhoto)
            return await apply(taxon, toSpecies: species.persistentModelID, container: context.container,
                               lookupOf: name) ? .updated : .abandoned
        } catch {
            logger.info("iNaturalist lookup failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            let unavailable = (error as? INaturalistError) == .serviceUnavailable
            return .failed(serviceUnavailable: unavailable)
        }
    }

    /// Looks up newly created species one after another in the background (duplicates once),
    /// pausing a second after every request whatever its outcome, as iNaturalist asks, and
    /// stopping when iNaturalist refuses (e.g. too many requests). A species deleted or merged
    /// meanwhile is skipped.
    static func updateInBackground(_ species: [Species], in context: ModelContext) {
        var seen = Set<PersistentIdentifier>()
        let unique = species.filter { seen.insert($0.persistentModelID).inserted }
        guard !unique.isEmpty, UserPreferences.shared.fetchTaxonomyOnline else { return }
        // Each species is read again in a fresh taxonomy context just before its lookup (the
        // caller saved it first): its current saved state is what is decided on, and a failed
        // save there never undoes the caller's pending edits.
        let container = context.container
        Task {
            for (index, item) in unique.enumerated() {
                let taxonomy = taxonomyContext(container)
                guard isAlive(item), let target = Self.species(item, in: taxonomy) else { continue }
                let outcome = await updateIfPossible(target, in: taxonomy)
                if case .failed(serviceUnavailable: true) = outcome { return }
                // The pause follows every lookup that sent a request (all but `.skipped`).
                if case .skipped = outcome { continue }
                if index + 1 < unique.count { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    enum BatchStatus: Equatable {
        case running(done: Int, total: Int)
        case finished(updated: Int, notFound: Int, total: Int)
        case stoppedOffline(updated: Int)
        case stoppedUnavailable(updated: Int)
        case stopped(updated: Int)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Species linked to iNaturalist that have no common name recorded for `languageCode`
    /// (an empty entry means iNaturalist had none, so it is not asked again).
    static func speciesMissingName(in species: [Species], languageCode: String) -> [Species] {
        species.filter { $0.inatTaxonID != nil && $0.inatCommonNames[languageCode] == nil }
    }

    /// Fetches, for every linked species without one, iNaturalist's common name in
    /// `languageCode`, one species per second, by taxon ID. Adds to the names by language and
    /// refreshes the classification (its group names come in the requested language); the
    /// stored common name, photo and category are not changed. Stops at the first network or
    /// service error; what was fetched is kept.
    ///
    /// Each species is read again in a fresh context after its request and saved on its own:
    /// a species re-linked, edited or deleted elsewhere while the run goes on is decided on its
    /// current state (skipped when no longer linked to the requested taxon), and a failed save
    /// is rolled back and not counted, without affecting the next species.
    static func fetchCommonNames(languageCode: String, container: ModelContainer,
                                 progress: (BatchStatus) -> Void) async -> BatchStatus {
        let pending: [(id: PersistentIdentifier, taxonID: Int)] = {
            let context = taxonomyContext(container)
            return speciesMissingName(in: (try? context.fetch(FetchDescriptor<Species>())) ?? [],
                                      languageCode: languageCode)
                .compactMap { species in species.inatTaxonID.map { (species.persistentModelID, $0) } }
        }()
        var updated = 0, notFound = 0
        progress(.running(done: 0, total: pending.count))
        for (index, item) in pending.enumerated() {
            if Task.isCancelled { return .stopped(updated: updated) }
            do {
                // Names only: the photo is not used.
                let taxon = try await INaturalistService.taxon(id: item.taxonID, languageCode: languageCode,
                                                               allowAlternativePhoto: false)
                let context = taxonomyContext(container)
                if let species = fetchSpecies(item.id, in: context),
                   species.inatTaxonID == item.taxonID, species.inatCommonNames[languageCode] == nil {
                    var names = species.inatCommonNames
                    let found = !(taxon.localizedCommonName ?? "").isEmpty
                    // No name in this language: recorded as "", so it is not asked again.
                    names[languageCode] = found ? taxon.localizedCommonName : ""
                    if names["en"] == nil, let english = taxon.englishCommonName { names["en"] = english }
                    species.inatCommonNamesData = try? JSONEncoder().encode(names)
                    // The classification's group names, now in this language.
                    species.taxonomyData = try? JSONEncoder().encode(taxon.classification)
                    if save(context) {
                        if found { updated += 1 } else { notFound += 1 }
                    }
                }
            } catch is CancellationError {
                return .stopped(updated: updated)
            } catch INaturalistError.serviceUnavailable {
                return .stoppedUnavailable(updated: updated)
            } catch {
                return Task.isCancelled ? .stopped(updated: updated) : .stoppedOffline(updated: updated)
            }
            progress(.running(done: index + 1, total: pending.count))
            if index + 1 < pending.count, (try? await Task.sleep(for: .seconds(1))) == nil {
                return .stopped(updated: updated)
            }
        }
        return .finished(updated: updated, notFound: notFound, total: pending.count)
    }

    /// Looks up every species that `needsLookup`, one per second (well within iNaturalist's
    /// limit of about one request per second), stopping at the first network or service error.
    /// Each species is read again in a fresh context just before its update (see
    /// `fetchCommonNames`): one linked, renamed or deleted meanwhile is skipped.
    static func updateAll(container: ModelContainer, progress: (BatchStatus) -> Void) async -> BatchStatus {
        let pending: [(id: PersistentIdentifier, name: String)] = {
            let context = taxonomyContext(container)
            return ((try? context.fetch(FetchDescriptor<Species>())) ?? [])
                .filter(needsLookup)
                .compactMap { species in species.scientificName.map { (species.persistentModelID, $0) } }
        }()
        let language = INaturalistService.nameLanguageCode
        var updated = 0, notFound = 0
        progress(.running(done: 0, total: pending.count))
        for (index, item) in pending.enumerated() {
            if Task.isCancelled { return .stopped(updated: updated) }
            do {
                let match = try await INaturalistService.exactMatch(for: item.name, languageCode: language)
                var taxon: INaturalistService.Taxon?
                if let match {
                    try await Task.sleep(for: .seconds(1))
                    taxon = try await INaturalistService.taxon(id: match.id, languageCode: language,
                                                               allowAlternativePhoto: UserPreferences.shared.useAlternativeINaturalistPhoto)
                }
                // Applied to the species as saved now, if it still waits for a lookup under the
                // same name (`apply` checks it after the photo download).
                if let taxon {
                    if await apply(taxon, toSpecies: item.id, container: container, lookupOf: item.name) { updated += 1 }
                } else {
                    let context = taxonomyContext(container)
                    if let species = fetchSpecies(item.id, in: context), needsLookup(species),
                       SpeciesCatalog.key(species.scientificName ?? "") == SpeciesCatalog.key(item.name) {
                        // Recorded, so the next update does not ask again (until the name changes).
                        species.inatFetchedAt = .now
                        if save(context) { notFound += 1 }
                    }
                }
            } catch is CancellationError {
                return .stopped(updated: updated)
            } catch INaturalistError.serviceUnavailable {
                return .stoppedUnavailable(updated: updated)
            } catch {
                return Task.isCancelled ? .stopped(updated: updated) : .stoppedOffline(updated: updated)
            }
            progress(.running(done: index + 1, total: pending.count))
            if index + 1 < pending.count, (try? await Task.sleep(for: .seconds(1))) == nil {
                return .stopped(updated: updated)
            }
        }
        return .finished(updated: updated, notFound: notFound, total: pending.count)
    }

    private static func fetchSpecies(_ id: PersistentIdentifier, in context: ModelContext) -> Species? {
        var descriptor = FetchDescriptor<Species>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Saves a taxonomy context; on failure rolls it back (only that species' update) and
    /// returns false.
    @discardableResult
    private static func save(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            logger.error("iNaturalist update not saved: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            return false
        }
    }
}
