import SwiftUI
import UIKit

// MARK: - Gear Icon View

struct GearIconView: View {
    let manufacturer: String?
    let category: GearCategory?
    let size: CGFloat
    // Used when category is nil and no brand asset resolves. Pass "building.2" for brand-suggestion rows
    // where category context is unavailable; leave as default for gear list/detail where a wrench is appropriate.
    let noMatchFallbackIcon: String
    private let resolvedAsset: String?

    init(manufacturer: String?, category: GearCategory?, size: CGFloat = 44, noMatchFallbackIcon: String = "wrench.and.screwdriver.fill") {
        self.manufacturer = manufacturer
        self.category = category
        self.size = size
        self.noMatchFallbackIcon = noMatchFallbackIcon
        if let name = GearIconView.assetName(forManufacturer: manufacturer), UIImage(named: name) != nil {
            self.resolvedAsset = name
        } else {
            self.resolvedAsset = nil
        }
    }

    private var cornerRadius: CGFloat { size * 10 / 44 }
    private var padding: CGFloat { size * 6 / 44 }
    private var symbolSize: CGFloat { size * 18 / 44 }

    var body: some View {
        if let assetName = resolvedAsset {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(padding)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(iconColor.opacity(0.15))
                Image(systemName: iconName)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(iconColor)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: Asset resolution — single source of truth
    //
    // To add a brand: append one Brand entry here.
    // knownManufacturers, assetName(), and manufacturerSuggestions() all derive from this table.
    // Resolution: input is trimmed, lowercased, and apostrophe-normalised; it must then exactly
    // equal the canonical name (lowercased) OR exactly equal one token.
    // Tokens are the complete strings a user might store as manufacturer (e.g. "dui", "ostc").

    private struct Brand {
        let name: String       // canonical display name used in autocomplete
        let tokens: [String]   // exact lowercase strings that also resolve this brand (e.g. abbreviations)
        let asset: String      // asset catalog image name
    }

    private static let brandTable: [Brand] = [
        // Dive Computers / Multi-category
        Brand(name: "Shearwater",              tokens: ["shearwater", "shearwater research"],  asset: "GearIcon_Shearwater"),
        Brand(name: "Suunto",                  tokens: ["suunto"],                             asset: "GearIcon_Suunto"),
        Brand(name: "ScubaPro",                tokens: ["scubapro"],                           asset: "GearIcon_Scubapro"),
        Brand(name: "Mares",                   tokens: ["mares"],                              asset: "GearIcon_Mares"),
        Brand(name: "Oceanic",                 tokens: ["oceanic"],                            asset: "GearIcon_Oceanic"),
        Brand(name: "Aqualung",                tokens: ["aqualung"],                           asset: "GearIcon_Aqualung"),
        Brand(name: "Sherwood",                tokens: ["sherwood"],                           asset: "GearIcon_Sherwood"),
        Brand(name: "Heinrichs Weikamp",       tokens: ["heinrichs", "weikamp", "ostc"],       asset: "GearIcon_HeinrichsWeikamp"),
        Brand(name: "Cressi",                  tokens: ["cressi"],                             asset: "GearIcon_Cressi"),
        Brand(name: "Divesoft",                tokens: ["divesoft"],                           asset: "GearIcon_Divesoft"),
        // Accessories / Knives / Safety
        Brand(name: "Deep Six",                tokens: ["deep six"],                           asset: "GearIcon_DeepSix"),
        Brand(name: "Deepblu",                 tokens: ["deepblu"],                            asset: "GearIcon_Deepblu"),
        Brand(name: "McLean",                  tokens: ["mclean"],                             asset: "GearIcon_McLean"),
        Brand(name: "Oceans",                  tokens: ["oceans"],                             asset: "GearIcon_Oceans"),
        Brand(name: "Seac",                    tokens: ["seac"],                               asset: "GearIcon_Seac"),
        Brand(name: "Halcyon",                 tokens: ["halcyon"],                            asset: "GearIcon_Halcyon"),
        Brand(name: "Ratio",                   tokens: ["ratio"],                              asset: "GearIcon_Ratio"),
        Brand(name: "DiveSystem",              tokens: ["divesystem", "idive"],                asset: "GearIcon_DiveSystem"),
        Brand(name: "Apeks",                   tokens: ["apeks"],                              asset: "GearIcon_Apeks"),
        Brand(name: "Fourth Element",          tokens: ["fourth element"],                     asset: "GearIcon_FourthElement"),
        Brand(name: "Underwater Kinetics",     tokens: ["underwater kinetics", "uk"],          asset: "GearIcon_UnderwaterKinetics"),
        Brand(name: "Light Monkey",            tokens: ["light monkey"],                       asset: "GearIcon_LightMonkey"),
        Brand(name: "OrcaTorch",               tokens: ["orcatorch"],                          asset: "GearIcon_OrcaTorch"),
        Brand(name: "Dive Rite",               tokens: ["dive rite"],                          asset: "GearIcon_DiveRite"),
        Brand(name: "Sea-Dog",                 tokens: ["sea-dog", "sea dog"],                 asset: "GearIcon_SeaDog"),
        Brand(name: "XS Scuba",                tokens: ["xs scuba"],                           asset: "GearIcon_XSScuba"),
        Brand(name: "Highland",                tokens: ["highland"],                           asset: "GearIcon_Highland"),
        Brand(name: "Nautec",                  tokens: ["nautec"],                             asset: "GearIcon_Nautec"),
        Brand(name: "Catalina",                tokens: ["catalina"],                           asset: "GearIcon_Catalina"),
        Brand(name: "Faber",                   tokens: ["faber"],                              asset: "GearIcon_Faber"),
        Brand(name: "Storm",                   tokens: ["storm"],                              asset: "GearIcon_Storm"),
        Brand(name: "YRVA",                    tokens: ["yrva"],                               asset: "GearIcon_YRVA"),
        Brand(name: "Bare",                    tokens: ["bare"],                               asset: "GearIcon_Bare"),
        // Wetsuits / Drysuits / Thermal
        Brand(name: "Diving Unlimited International", tokens: ["diving unlimited", "dui"],     asset: "GearIcon_DUI"),
        Brand(name: "Waterproof",              tokens: ["waterproof"],                         asset: "GearIcon_Waterproof"),
        Brand(name: "Santi",                   tokens: ["santi"],                              asset: "GearIcon_Santi"),
        Brand(name: "O'Three",                 tokens: ["o'three", "o three", "othree"],       asset: "GearIcon_OThree"),
        Brand(name: "Typhoon",                 tokens: ["typhoon"],                            asset: "GearIcon_Typhoon"),
        Brand(name: "Henderson",               tokens: ["henderson"],                          asset: "GearIcon_Henderson"),
        Brand(name: "Whites",                  tokens: ["whites"],                             asset: "GearIcon_Whites"),
        Brand(name: "Camaro",                  tokens: ["camaro"],                             asset: "GearIcon_Camaro"),
        Brand(name: "Ursuit",                  tokens: ["ursuit"],                             asset: "GearIcon_Ursuit"),
        // Regulators / BCDs / Wings
        Brand(name: "Poseidon",                tokens: ["poseidon"],                           asset: "GearIcon_Poseidon"),
        Brand(name: "Atomic Aquatics",         tokens: ["atomic"],                             asset: "GearIcon_AtomicAquatics"),
        Brand(name: "Zeagle",                  tokens: ["zeagle"],                             asset: "GearIcon_Zeagle"),
        Brand(name: "Hollis",                  tokens: ["hollis"],                             asset: "GearIcon_Hollis"),
        Brand(name: "xDeep",                   tokens: ["xdeep", "x-deep"],                    asset: "GearIcon_Xdeep"),
        Brand(name: "Kubi",                    tokens: ["kubi"],                               asset: "GearIcon_Kubi"),
        Brand(name: "Eezycut",                 tokens: ["eezycut"],                            asset: "GearIcon_Eezycut"),
        Brand(name: "Tecline",                 tokens: ["tecline"],                            asset: "GearIcon_Tecline"),
        // Computers / Multi-category
        Brand(name: "Tusa",                    tokens: ["tusa"],                               asset: "GearIcon_Tusa"),
        Brand(name: "Garmin",                  tokens: ["garmin"],                             asset: "GearIcon_Garmin"),
        // Masks / Fins
        Brand(name: "Beuchat",                 tokens: ["beuchat"],                            asset: "GearIcon_Beuchat"),
        Brand(name: "IST Sports",              tokens: ["ist sports", "ist pro", "ists"],      asset: "GearIcon_ISTSports"),
        // Lights / Imaging
        Brand(name: "Bigblue",                 tokens: ["bigblue", "big blue"],                asset: "GearIcon_Bigblue"),
        Brand(name: "Light & Motion",          tokens: ["light & motion", "light and motion"], asset: "GearIcon_LightAndMotion"),
        Brand(name: "Keldan",                  tokens: ["keldan"],                             asset: "GearIcon_Keldan"),
        Brand(name: "Ikelite",                 tokens: ["ikelite"],                            asset: "GearIcon_Ikelite"),
        Brand(name: "Sea & Sea",               tokens: ["sea & sea", "sea&sea", "sea and sea"],asset: "GearIcon_SeaAndSea"),
        Brand(name: "GoPro",                   tokens: ["gopro"],                              asset: "GearIcon_GoPro"),
        Brand(name: "Paralenz",                tokens: ["paralenz"],                           asset: "GearIcon_Paralenz"),
        Brand(name: "Nauticam",                tokens: ["nauticam"],                           asset: "GearIcon_Nauticam"),
        Brand(name: "Sola",                    tokens: ["sola"],                               asset: "GearIcon_Sola"),
        // Cylinders
        Brand(name: "Luxfer",                  tokens: ["luxfer"],                             asset: "GearIcon_Luxfer"),
        Brand(name: "Worthington",             tokens: ["worthington"],                        asset: "GearIcon_Worthington"),
        Brand(name: "Eurocylinder",            tokens: ["eurocylinder"],                       asset: "GearIcon_Eurocylinder"),
    ]

    /// Canonical display names derived from brandTable — used to seed the manufacturer autocomplete.
    /// The `name:` field determines the casing shown in the dropdown; a user-entered variant that
    /// lowercases to the same value as a canonical name is shadowed by the canonical spelling.
    static let knownManufacturers: [String] = brandTable.map(\.name)

    /// Pre-sorted canonical names — computed once at launch, returned directly on the common path.
    private static let sortedKnownManufacturers: [String] = knownManufacturers.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    /// Every string that resolves a known brand — derived directly from nameIndex and tokenIndex keys
    /// so it stays in sync automatically. Used by manufacturerSuggestions to prevent token-form aliases
    /// like "dui" and "ostc" from appearing as unknown extras alongside their canonical brand.
    private static let knownManufacturerLookup: Set<String> = Set(nameIndex.keys).union(tokenIndex.keys)

    /// O(1) asset lookup by canonical name (lowercased).
    private static let nameIndex: [String: String] = Dictionary(
        uniqueKeysWithValues: brandTable.map { ($0.name.lowercased(), $0.asset) }
    )
    /// O(1) asset lookup by token (tokens are already lowercase).
    private static let tokenIndex: [String: String] = {
        let pairs = brandTable.flatMap { entry in entry.tokens.map { token in (token, entry.asset) } }
        #if DEBUG
        assert(
            Set(pairs.map(\.0)).count == pairs.count,
            "GearIconView.brandTable has a duplicate token — check for collisions"
        )
        #endif
        return Dictionary(uniqueKeysWithValues: pairs)
    }()

    /// Returns a deduplicated, sorted suggestion list seeded with all canonical brands, followed by
    /// any user-entered manufacturers not already covered by a canonical name or token.
    /// Returns the pre-sorted static array directly when there are no extras — zero allocation on
    /// the common render path.
    static func manufacturerSuggestions(from gearItems: [Gear]) -> [String] {
        var seen = Set<String>()
        let extras = gearItems.compactMap(\.manufacturer)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                let lc = normalizedLookupKey(name)
                return !name.isEmpty && !knownManufacturerLookup.contains(lc) && seen.insert(lc).inserted
            }
            .map { name -> String in
                // Normalize typographic apostrophes in the display string so suggestions are
                // ASCII-canonical (matching the canonical brand names in sortedKnownManufacturers).
                guard name.contains("\u{2019}") || name.contains("\u{02BC}") else { return name }
                return name
                    .replacingOccurrences(of: "\u{2019}", with: "'")
                    .replacingOccurrences(of: "\u{02BC}", with: "'")
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return extras.isEmpty ? sortedKnownManufacturers : mergeSorted(sortedKnownManufacturers, extras)
    }

    private static func assetName(forManufacturer manufacturer: String?) -> String? {
        guard let manufacturer else { return nil }
        // Trim so that live form state (e.g. "Shearwater ") resolves the same as the saved value.
        let trimmed = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lc = normalizedLookupKey(trimmed)
        return nameIndex[lc] ?? tokenIndex[lc]
    }

    /// Lowercases and normalises typographic apostrophes to ASCII (U+0027) — applied consistently
    /// to every user string before hitting nameIndex, tokenIndex, or knownManufacturerLookup.
    /// Internal (not private) so GearAutocompleteField.filtered can call it without inlining a copy.
    static func normalizedLookupKey(_ s: String) -> String {
        let lower = s.lowercased()
        guard lower.contains("\u{2019}") || lower.contains("\u{02BC}") else { return lower }
        return lower
            .replacingOccurrences(of: "\u{2019}", with: "'")  // RIGHT SINGLE QUOTATION MARK (iOS smart quote)
            .replacingOccurrences(of: "\u{02BC}", with: "'")  // MODIFIER LETTER APOSTROPHE (some keyboards/paste)
    }

    /// Linear O(n+m) merge of two arrays already sorted by localizedCaseInsensitiveCompare.
    /// On a tie, the canonical (a) entry is kept and the extra (b) is dropped, collapsing any
    /// case-insensitively-equal pair that slipped through the knownManufacturerLookup dedup filter.
    private static func mergeSorted(_ a: [String], _ b: [String]) -> [String] {
        var result = [String]()
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let order = a[i].localizedCaseInsensitiveCompare(b[j])
            if order != .orderedDescending {
                result.append(a[i]); i += 1
                if order == .orderedSame { j += 1 }  // skip extra that duplicates a canonical
            } else {
                result.append(b[j]); j += 1
            }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }

    // MARK: SF Symbol fallback

    private var iconName: String {
        category?.icon ?? noMatchFallbackIcon
    }

    private var iconColor: Color {
        category?.swiftUIColor ?? .cyan
    }
}
