import SwiftUI
import SwiftData

// MARK: - Ordinary Words

/// Whether a word is an ordinary English word, with the system spelling dictionary. Tells
/// "Great barracuda" or "Sea fan" from a scientific name. English only: the French, German
/// and Dutch dictionaries contain Latin words ("vulgaris", "maximus", "obscurus") and would
/// reject real scientific names. Results are cached: one dictionary lookup per word.
@MainActor
enum OrdinaryWords {
    private static var cache: [String: Bool] = [:]

    private static let languages: [String] = {
        #if os(macOS)
        let available = NSSpellChecker.shared.availableLanguages
        #else
        let available = UITextChecker.availableLanguages
        #endif
        // "en", else the first English variant ("en_US").
        let english = available.first { $0 == "en" } ?? available.first { $0.hasPrefix("en_") || $0.hasPrefix("en-") }
        return english.map { [$0] } ?? []
    }()

    static func contains(_ word: String) -> Bool {
        let lower = word.lowercased()
        if let known = cache[lower] { return known }
        #if os(macOS)
        let isWord = languages.contains { language in
            NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0, language: language, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        #else
        let checker = UITextChecker()
        let range = NSRange(lower.startIndex..., in: lower)
        let isWord = languages.contains { language in
            checker.rangeOfMisspelledWord(in: lower, range: range, startingAt: 0, wrap: false,
                                          language: language).location == NSNotFound
        }
        #endif
        cache[lower] = isWord
        return isWord
    }
}

// MARK: - Scientific Name Detector

/// Finds scientific names in a photo's IPTC text (Keywords, Caption/Abstract, Object Name).
///
/// Recognised: a binomial or trinomial in parentheses after its common name — "European
/// Lobster (Homarus gammarus)", "(Octopus vulgaris)", "(Chromis chromis chromis)", "(Diodon
/// sp.)" — or before it ("Thalassoma bifasciatum (Bluehead wrasse)", "Mobula birostris
/// (オニイトマキエイ)"), and a keyword that is itself such a name ("Homarus gammarus"). The
/// genus must be capitalised, as scientific names are written, and a name made of ordinary
/// words ("Great barracuda", "Sea fan", "(Salt pier)") is not a scientific name. Nothing is
/// changed in the photo.
@MainActor
enum ScientificNameDetector {

    struct Detection: Hashable {
        /// The name as written, with spacing normalised ("Homarus gammarus").
        let scientificName: String
        /// The common name written with it ("European Lobster"), if any.
        let commonNameHint: String?
        /// Written with parentheses (the convention for a scientific name and its common
        /// name). A keyword without parentheses ("Homarus gammarus") is only a candidate: it
        /// counts when the photo's other keywords confirm it, or when it names a species
        /// already in the catalogue.
        var inParentheses = true
        /// The photo's other keywords confirm the name is scientific, as in a Lightroom keyword
        /// hierarchy: the genus is a keyword ("Gymnothorax", "Barracuda (Sphyraena)"), or a
        /// keyword is a Latin name of a higher rank ("Myliobatidae").
        var genusIsKeyword = false
        /// Clearly a scientific name: in parentheses, or confirmed by its own genus keyword
        /// (not only by a family keyword). Only these start switched on as new species in the
        /// batch import summary; the others are offered switched off.
        var isConfident = false
    }

    /// Family, order and class endings that ordinary words do not have. A keyword with one of
    /// them ("Myliobatidae", "Perciformes") confirms the photo's other Latin-looking keywords;
    /// shorter rank endings ("-ia", "-ata") also end place names ("Indonesia", "Croatia").
    private static let confirmingRankSuffixes = ["idae", "inae", "iformes", "oidea", "aceae", "phyceae"]

    private static func isConfirmingRankName(_ word: String) -> Bool {
        guard word.first?.isUppercase == true, !word.contains(" ") else { return false }
        let lower = word.lowercased()
        return confirmingRankSuffixes.contains { lower.hasSuffix($0) }
    }

    /// A Latin rank written before its common name ("Teleostei (Egentlige beinfisker)",
    /// "Gastropoda (Sea snails)"): one capitalised word with a rank ending, which is the whole
    /// text before the parentheses. "-ei" and "-ini" count only on long words ("Teleostei",
    /// not "Brunei", "Bikini"); a rank is never the genus of the name in parentheses
    /// ("Aurelia (Aurelia aurita)").
    private static func isRankName(_ word: String, beforeName name: String) -> Bool {
        guard word.first?.isUppercase == true, !word.contains(" "),
              name.split(separator: " ").first.map(String.init) != word else { return false }
        let lower = word.lowercased()
        let endings = confirmingRankSuffixes + ["oidei", "acea", "morpha", "oda", "ura", "ata", "zoa", "phyta"]
        if endings.contains(where: { lower.hasSuffix($0) }) && word.count >= 7 { return true }
        return word.count >= 8 && ["ei", "ini"].contains { lower.hasSuffix($0) }
    }

    /// Short words that fit the name pattern but are never epithets ("Taken at night").
    private static let nonLatinWords: Set<String> = ["the", "and", "for", "with", "from", "near", "over",
                                                     "under", "into", "onto", "off", "out", "was", "were",
                                                     "are", "his", "her", "its", "our", "their", "this",
                                                     "that", "there", "here"]

    /// Whether `name` (genus and epithets) reads as a scientific name: epithets of at least
    /// three letters (or "sp."), and not ordinary words — a name whose genus is an ordinary
    /// word followed by another one ("Great barracuda", "Sea fan", "Common octopus") is a
    /// common name. "Octopus vulgaris", "Pterois miles" and a repeated name ("Conger conger")
    /// are scientific.
    static func isScientific(_ name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init).filter { $0 != "×" }
        guard words.count >= 2 else { return false }
        let genus = words[0]
        let epithets = Array(words.dropFirst())
        guard epithets.allSatisfy({ $0.hasSuffix(".") || ($0.count >= 3 && !nonLatinWords.contains($0)) }) else {
            return false
        }
        if epithets.contains(where: { $0.lowercased() == genus.lowercased() }) { return true }
        guard OrdinaryWords.contains(genus) else { return true }
        return !epithets.contains { !$0.hasSuffix(".") && OrdinaryWords.contains($0) }
    }

    /// Endings of Latin species epithets ("birostris", "gammarus", "mydas", "niger"). Asked
    /// only of a keyword confirmed by a family keyword alone, a weak sign on its own.
    private static let latinEpithetEndings = ["us", "um", "a", "ae", "is", "i", "ii", "x", "os", "on", "ys",
                                              "as", "er", "es", "ns", "ps", "o", "or", "ar"]

    private static func hasLatinEndings(_ name: String) -> Bool {
        name.split(separator: " ").dropFirst().filter { $0 != "×" }.allSatisfy { word in
            word.hasSuffix(".") || latinEpithetEndings.contains { word.lowercased().hasSuffix($0) }
        }
    }

    /// Genus (capitalised), then one or two lower-case epithets, or "sp."/"spp.".
    private static let namePattern = #"[A-Z][a-z]+(?:\s+(?:×\s*)?[a-z][a-z\-]+){1,2}|[A-Z][a-z]+\s+spp?\."#
    /// Any text in parentheses, with the text before it.
    private static let parenthesised = try! NSRegularExpression(pattern: #"([^()]*?)\(\s*([^()]+?)\s*\)"#)
    private static let wholeName = try! NSRegularExpression(pattern: #"^\s*("# + namePattern + #")\s*$"#)

    private static func matchesName(_ text: String) -> Bool {
        wholeName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func detect(keywords: [String]?, caption: String?, title: String?) -> [Detection] {
        var found: [Detection] = []
        func add(_ detection: Detection) {
            if !found.contains(where: { $0.scientificName == detection.scientificName }) { found.append(detection) }
        }
        let allKeywords = (keywords ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasHigherRankKeyword = allKeywords.contains { isConfirmingRankName($0) }
        /// The genus is a keyword of its own ("Gymnothorax"), or the Latin side of a keyword
        /// pair ("Barracuda (Sphyraena)", "Sphyraena (Barracuda)"); a keyword that merely
        /// starts with the same word ("Sea turtle" + "Sea fan") does not count.
        func genusIsKeyword(_ name: String) -> Bool {
            guard let genus = name.split(separator: " ").first.map(String.init) else { return false }
            return allKeywords.contains { keyword in
                keyword == genus || keyword.hasSuffix("(\(genus))") || keyword.hasPrefix("\(genus) (")
            }
        }

        // Name and common name with parentheses, in either order.
        for text in [title, caption].compactMap({ $0 }) + allKeywords {
            for (before, inside) in parenthesisedPairs(in: text) {
                let insideIsName = matchesName(inside) && isScientific(normalised(inside))
                let beforeName = lastName(in: before)
                if insideIsName {
                    // "Teleostei (Egentlige beinfisker)" reads the same way: a rank first.
                    let hint = commonNameHint(before: before)
                    if let hint, isRankName(hint, beforeName: inside), normalised(before) == hint { continue }
                    var detection = Detection(scientificName: normalised(inside), commonNameHint: hint)
                    detection.isConfident = true
                    add(detection)
                } else if let beforeName, isScientific(beforeName),
                          !isRankName(normalised(inside), beforeName: beforeName) {
                    // "Thalassoma bifasciatum (Bluehead wrasse)": the common name in parentheses.
                    // Not "Bonaire (Salt pier)" (one word, no name) nor "(Anomura)" (a rank).
                    var detection = Detection(scientificName: beforeName, commonNameHint: normalised(inside))
                    detection.isConfident = true
                    add(detection)
                }
            }
        }

        // A keyword that is a name on its own: confirmed by the other keywords.
        for keyword in allKeywords where matchesName(keyword) {
            let name = normalised(keyword)
            guard isScientific(name) else { continue }
            let byGenus = genusIsKeyword(name)
            let byFamily = hasHigherRankKeyword && hasLatinEndings(name)
            add(Detection(scientificName: name, commonNameHint: nil, inParentheses: false,
                          genusIsKeyword: byGenus || byFamily, isConfident: byGenus))
        }
        return found
    }

    /// Each "(…)" in `text` with the text before it (since the previous parenthesis).
    private static func parenthesisedPairs(in text: String) -> [(before: String, inside: String)] {
        let range = NSRange(text.startIndex..., in: text)
        return parenthesised.matches(in: text, range: range).compactMap { match in
            guard let beforeRange = Range(match.range(at: 1), in: text),
                  let insideRange = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[beforeRange]), String(text[insideRange]))
        }
    }

    /// The scientific name ending the text before a parenthesis ("… Thalassoma bifasciatum"),
    /// if the text ends with one.
    private static func lastName(in before: String) -> String? {
        let segment = before.split(whereSeparator: { ",;:.".contains($0) }).last.map(String.init) ?? ""
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        for count in [3, 2] where words.count >= count {
            let candidate = words.suffix(count).joined(separator: " ")
            if matchesName(candidate) { return candidate }
        }
        return nil
    }

    /// The common name written just before "(": the words after any earlier punctuation, from
    /// the last article ("A green sea turtle (…)" → "green sea turtle"), else from the first
    /// capitalised word, and after the last lower-case word followed by a capitalised one
    /// ("Diver with Giant Moray (…)" → "Giant Moray"); at most four words. One word after a
    /// comma is usually a place ("Seal, Wales (…)"): no hint.
    private static func commonNameHint(before: String) -> String? {
        let segments = before.split(whereSeparator: { ",;:.".contains($0) })
        let segment = segments.last.map(String.init) ?? ""
        var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        let articles: Set<String> = ["a", "an", "the", "un", "une", "le", "la", "les", "der", "die", "das", "ein", "eine", "de", "het", "een"]
        if let last = words.lastIndex(where: { articles.contains($0.lowercased()) }) {
            words = Array(words[(last + 1)...])
        } else {
            words = Array(words.drop { !($0.first?.isUppercase ?? false) })
            if let cut = words.indices.dropLast().last(where: { index in
                !(words[index].first?.isUppercase ?? false) && (words[index + 1].first?.isUppercase ?? false)
            }) {
                words = Array(words[(cut + 1)...])
            }
        }
        words = Array(words.suffix(4))
        let afterPunctuation = segments.count > 1 || before.trimmingCharacters(in: .whitespaces).first.map { ",;:.".contains($0) } == true
        if words.isEmpty || (afterPunctuation && words.count == 1) { return nil }
        return words.joined(separator: " ")
    }

    private static func normalised(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The binomial of a trinomial ("Chromis chromis chromis" → "Chromis chromis"), or nil.
    static func binomial(of name: String) -> String? {
        let words = name.split(separator: " ")
        guard words.count == 3, words[1] != "×" else { return nil }
        return words.prefix(2).joined(separator: " ")
    }
}

// MARK: - Species Photo Proposal

/// A species detected in a photo's IPTC text, waiting for the user's confirmation.
struct SpeciesPhotoProposal: Identifiable {
    let id: String
    let photo: DivePhoto
    let detection: ScientificNameDetector.Detection
    /// The catalogue species the photo will be linked to; nil = a new species.
    let existing: Species?
    /// Name of the new species (when `existing` is nil).
    let newSpeciesName: String
}

/// Decides, photo by photo, which species each detected name belongs to — the same way for
/// the review (nothing created) and when the switched-on proposals are applied, so what the
/// review shows is what Done does. Later photos see what earlier ones did: a species created,
/// or a scientific name given to a species found by its common name.
@MainActor
struct SpeciesProposalResolver {
    enum Resolution {
        case existing(Species)
        /// A new species, known by `key` within this batch.
        case new(key: String, commonName: String)
    }

    private let index: SpeciesNameIndex
    /// Names given within this batch: a scientific name filled in, a species created.
    private var batchNames: [String: Resolution] = [:]
    /// Scientific names given within this batch to species that had none.
    private var filledScientificNames: [PersistentIdentifier: String] = [:]

    init(index: SpeciesNameIndex) { self.index = index }

    private func lookup(_ name: String) -> Resolution? {
        let key = SpeciesCatalog.key(name)
        guard !key.isEmpty else { return nil }
        if let known = batchNames[key] { return known }
        return index.species(named: name).map { .existing($0) }
    }

    /// "Gymnothorax sp." names a genus, not one species: two photos with it are told apart by
    /// their common names.
    private static func isUnspecific(_ name: String) -> Bool {
        name.hasSuffix(" sp.") || name.hasSuffix(" spp.")
    }

    mutating func resolve(_ detection: ScientificNameDetector.Detection) -> Resolution {
        let scientific = detection.scientificName
        let unspecific = Self.isUnspecific(scientific)
        // 1. By scientific name (or the binomial of a trinomial).
        if !unspecific, let found = lookup(scientific)
            ?? ScientificNameDetector.binomial(of: scientific).flatMap({ lookup($0) }) {
            return found
        }
        // 2. By the common name written with it: species built from sightings have no
        //    scientific name yet ("European Lobster"). Not one with another scientific name
        //    ("Lobster" may be Homarus americanus, the photo says Homarus gammarus).
        if let hint = detection.commonNameHint, let found = lookup(hint) {
            switch found {
            case .existing(let species):
                let stored = filledScientificNames[species.persistentModelID] ?? species.scientificName ?? ""
                if unspecific || stored.isEmpty || SpeciesCatalog.key(stored) == SpeciesCatalog.key(scientific) {
                    // The species takes the scientific name: later photos find it by it, and a
                    // photo with another scientific name no longer joins it.
                    if !unspecific && stored.isEmpty {
                        batchNames[SpeciesCatalog.key(scientific)] = found
                        filledScientificNames[species.persistentModelID] = scientific
                    }
                    return found
                }
            case .new:
                if unspecific { return found }
            }
        }
        // 3. A new species, named after its common name unless another species already has
        //    that name (then after its scientific name, which iNaturalist can complete).
        let hintFree = detection.commonNameHint.map { lookup($0) == nil } ?? false
        let commonName = (hintFree ? detection.commonNameHint : nil) ?? scientific
        let key = unspecific ? SpeciesCatalog.key(detection.commonNameHint ?? scientific) : SpeciesCatalog.key(scientific)
        let resolution = Resolution.new(key: key, commonName: commonName)
        if !unspecific { batchNames[SpeciesCatalog.key(scientific)] = resolution }
        if hintFree, let hint = detection.commonNameHint { batchNames[SpeciesCatalog.key(hint)] = resolution }
        return resolution
    }
}

@MainActor
enum SpeciesPhotoMatcher {

    /// Proposals for the photos' detected names, skipping links that already exist.
    static func proposals(for photos: [DivePhoto], catalogue: [Species]) -> [SpeciesPhotoProposal] {
        var result: [SpeciesPhotoProposal] = []
        var resolver = SpeciesProposalResolver(index: SpeciesNameIndex(catalogue: catalogue))
        for photo in photos {
            let detections = ScientificNameDetector.detect(keywords: photo.iptcKeywords,
                                                           caption: photo.iptcCaption, title: photo.iptcTitle)
            for detection in detections {
                let resolution = resolver.resolve(detection)
                let species: Species?
                let newName: String
                switch resolution {
                case .existing(let found): species = found; newName = ""
                case .new(_, let commonName): species = nil; newName = commonName
                }
                // A bare keyword that names no catalogue species counts only when the photo's
                // other keywords confirm it ("Gymnothorax" + "Gymnothorax meleagris").
                if species == nil && !detection.inParentheses && !detection.genusIsKeyword { continue }
                if let species, (photo.species ?? []).contains(where: { $0.persistentModelID == species.persistentModelID }) {
                    continue
                }
                result.append(SpeciesPhotoProposal(id: "\(photo.id.uuidString)|\(detection.scientificName)",
                                                   photo: photo, detection: detection, existing: species,
                                                   newSpeciesName: newName))
            }
        }
        return result
    }

    /// Makes sure the dive lists `species`: nothing when a sighting is already linked to it; a
    /// sighting recorded before the catalogue under one of the species' names is linked (its
    /// name is kept) instead of adding a second one; otherwise a sighting is added. Returns
    /// whether the dive's sightings changed (not saved).
    @discardableResult
    static func recordSighting(of species: Species, on dive: Dive, in context: ModelContext) -> Bool {
        let sights = dive.seenFish ?? []
        if sights.contains(where: { $0.species?.persistentModelID == species.persistentModelID }) {
            return false
        }
        let names = SpeciesNameIndex(catalogue: [species])
        if let unlinked = sights.first(where: { $0.species == nil && names.species(named: $0.name) != nil }) {
            unlinked.species = species
            return true
        }
        let sight = MarineSight(name: species.commonName, count: SightingQuantity.single.rawValue)
        context.insert(sight)
        sight.dive = dive
        sight.species = species
        return true
    }

    /// The photos that have IPTC text.
    static func photosWithIPTC(in context: ModelContext) -> [DivePhoto] {
        let descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate {
            $0.iptcKeywords != nil || $0.iptcCaption != nil || $0.iptcTitle != nil
        })
        let photos = (try? context.fetch(descriptor)) ?? []
        return photos.filter { !($0.iptcKeywords?.isEmpty ?? true) || $0.iptcCaption != nil || $0.iptcTitle != nil }
    }

    /// The photos with these ids, 200 per query (a large import has thousands, more than one
    /// query should list).
    static func photos(withIDs ids: [UUID], in context: ModelContext) -> [DivePhoto] {
        var result: [DivePhoto] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            let descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { chunk.contains($0.id) })
            result += (try? context.fetch(descriptor)) ?? []
            start += 200
        }
        return result
    }

    /// Applies the accepted proposals in order, with the same resolver as the review: links
    /// each photo to its species (creating the new ones, filling an empty scientific name) and,
    /// when `recordSightings`, adds a sighting of the species to the photo's dive if that dive
    /// has none. A proposal whose photo or species was deleted meanwhile is skipped. Returns
    /// the dives whose sightings changed, and the species created.
    static func apply(_ accepted: [SpeciesPhotoProposal], recordSightings: Bool,
                      in context: ModelContext) -> (dives: [Dive], created: [Species]) {
        var resolver = SpeciesProposalResolver(
            index: SpeciesNameIndex(catalogue: (try? context.fetch(FetchDescriptor<Species>())) ?? []))
        var created: [String: Species] = [:]
        var changedDives: [PersistentIdentifier: Dive] = [:]
        for proposal in accepted {
            let photo = proposal.photo
            guard !photo.isDeleted, photo.modelContext != nil else { continue }
            let species: Species
            switch resolver.resolve(proposal.detection) {
            case .existing(let found):
                guard !found.isDeleted, found.modelContext != nil else { continue }
                species = found
            case .new(let key, let commonName):
                if let new = created[key] {
                    species = new
                } else {
                    species = Species(commonName: commonName)
                    species.scientificName = proposal.detection.scientificName
                    context.insert(species)
                    SpeciesCatalog.linkUnlinkedSightings(named: [commonName, proposal.detection.scientificName],
                                                         to: species, in: context)
                    created[key] = species
                }
            }
            // Found by its common name: the confirmed scientific name fills an empty one.
            let scientific = proposal.detection.scientificName
            if species.scientificName?.isEmpty ?? true,
               !(scientific.hasSuffix(" sp.") || scientific.hasSuffix(" spp.")) {
                species.scientificName = scientific
            }
            var linked = photo.species ?? []
            if !linked.contains(where: { $0.persistentModelID == species.persistentModelID }) {
                linked.append(species)
                photo.species = linked
            }
            if recordSightings, let dive = photo.dive,
               recordSighting(of: species, on: dive, in: context) {
                changedDives[dive.persistentModelID] = dive
            }
        }
        try? context.save()
        return (Array(changedDives.values), Array(created.values))
    }
}

// MARK: - Review

/// Initial selection: links to catalogue species start on. A proposal that would create a new
/// species starts off, so a misread caption never creates one without a deliberate choice —
/// except, with `includeConfidentNewSpecies` (the batch import), a name that is clearly
/// scientific (written with parentheses, or confirmed by its genus keyword).
@MainActor
func defaultAcceptedProposals(_ proposals: [SpeciesPhotoProposal], includeConfidentNewSpecies: Bool = false) -> Set<String> {
    Set(proposals.filter { $0.existing != nil || (includeConfidentNewSpecies && $0.detection.isConfident) }.map(\.id))
}

/// Applies the switched-on proposals, refreshes the changed dives' rows, and fills in the new
/// species' taxonomy from iNaturalist when allowed. Shared by every place species are reviewed.
@MainActor
func applySpeciesProposals(_ proposals: [SpeciesPhotoProposal], accepted: Set<String>,
                           recordSightings: Bool, context: ModelContext, store: DiveStore) {
    let chosen = proposals.filter { accepted.contains($0.id) }
    guard !chosen.isEmpty else { return }
    let (dives, created) = SpeciesPhotoMatcher.apply(chosen, recordSightings: recordSightings, in: context)
    for dive in dives { store.commit(dive, affects: .rowBadges) }
    INaturalistUpdater.updateInBackground(created, in: context)
}

/// The species found in photos, one switch each, and the "also add to the dive" switch, as
/// Form sections. Used by the review sheet and inside the batch photo import summary.
struct SpeciesProposalSections<Footer: View>: View {
    let proposals: [SpeciesPhotoProposal]
    @Binding var accepted: Set<String>
    @Binding var recordSightings: Bool
    /// Footer of the species section (what confirming does in that screen).
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        Section {
            ForEach(proposals) { proposal in
                Toggle(isOn: Binding(
                    get: { accepted.contains(proposal.id) },
                    set: { if $0 { accepted.insert(proposal.id) } else { accepted.remove(proposal.id) } }
                )) {
                    row(proposal)
                }
                .fullWidthSwitch()
            }
        } header: {
            Text("Species in Photos")
        } footer: {
            footer()
        }
        Section {
            Toggle(isOn: $recordSightings) {
                Text("Also add the species to each photo’s dive")
            }
            .fullWidthSwitch()
        } footer: {
            Text("Adds a sighting to the dive when the dive does not list the species yet.")
        }
    }

    private func row(_ proposal: SpeciesPhotoProposal) -> some View {
        HStack(spacing: 12) {
            Group {
                if let data = proposal.photo.thumbnailBytes, let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: proposal.detection.scientificName)
                    .italic()
                if let species = proposal.existing {
                    Text(verbatim: String(format: NSLocalizedString("Link to %@", bundle: .forAppLanguage(), value: "Link to %@", comment: "Species-in-photos review: link the photo to this existing species"), species.displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: String(format: NSLocalizedString("New species: %@", bundle: .forAppLanguage(), value: "New species: %@", comment: "Species-in-photos review: a new catalogue species is created with this common name"), proposal.newSpeciesName))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let filename = proposal.photo.originalFilename {
                    Text(verbatim: filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// Lists the species detected in photos and lets the user confirm each link before
/// anything is changed.
struct SpeciesPhotoReviewSheet: View {
    let proposals: [SpeciesPhotoProposal]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @State private var accepted: Set<String>
    @State private var recordSightings = true

    init(proposals: [SpeciesPhotoProposal]) {
        self.proposals = proposals
        _accepted = State(initialValue: defaultAcceptedProposals(proposals))
    }

    var body: some View {
        NavigationStack {
            Form {
                SpeciesProposalSections(proposals: proposals, accepted: $accepted,
                                        recordSightings: $recordSightings) {
                    Text("Names found in the photos’ captions and keywords. Only the links you switch on are made; new species start switched off. The photos themselves are not changed.")
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle(Text("Species in Photos"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        applySpeciesProposals(proposals, accepted: accepted, recordSightings: recordSightings,
                                              context: modelContext, store: store)
                        dismiss()
                    } label: {
                        Text("Link")
                            .confirmationActionForeground(.orange)
                    }
                    .disabled(accepted.isEmpty)
                }
            }
        }
    }
}
