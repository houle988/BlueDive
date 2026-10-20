import SwiftUI

// Category sections shared by the Equipment list and the gear-group editors.

/// The category a gear item is shown under: its resolved stored category (`Gear.gearCategory`:
/// a case, an older export key or an alias), or Other when nothing is stored (an import without
/// a category saves ""), which the editor also shows as Other. Display only: the stored value is
/// never changed. nil for a non-empty value no category matches ("Camera Housing"), which keeps
/// its own section.
@MainActor
func displayCategory(of gear: Gear) -> GearCategory? {
    if let category = gear.gearCategory { return category }
    return gear.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .other : nil
}

/// Gear grouped into category sections, the one rule for the Equipment list and the gear-group
/// editors: grouped by resolved category (`category`, `displayCategory(of:)` when nil), so an item
/// stored under an alias or older export key ("Regulator", "first stage") joins its category's
/// section; a value no category matches keeps its own section. Sections are sorted by the
/// heading shown (the category name in the app language) with `locale`, the view's
/// `\.locale`; items keep their order within a section.
@MainActor
func gearCategorySections(
    _ gear: [Gear],
    locale: Locale,
    category: ((Gear) -> GearCategory?)? = nil
) -> [(key: String, items: [Gear])] {
    // nil: `displayCategory(of:)` (main-actor isolated, so not usable as a default argument).
    let resolve: (Gear) -> GearCategory? = category ?? { displayCategory(of: $0) }
    let grouped = Dictionary(grouping: gear) { resolve($0)?.rawValue ?? $0.category }
    let bundle = Bundle.forAppLanguage()
    // Each heading resolved once (O(n)) rather than per comparison (O(n log n)).
    let headings = Dictionary(uniqueKeysWithValues: grouped.keys.map {
        ($0, GearCategory(rawValue: $0)?.localizedDisplayName(bundle: bundle) ?? $0)
    })
    return grouped
        .sorted { (headings[$0.key] ?? $0.key).compare(headings[$1.key] ?? $1.key, locale: locale) == .orderedAscending }
        .map { (key: $0.key, items: $0.value) }
}

/// The heading of a `gearCategorySections` section: the category's name in the app language,
/// or an unrecognized stored value as stored (never used as a translation key). `showsIcon`
/// adds the category icon before the name (the Equipment list).
struct GearCategorySectionTitle: View {
    let key: String
    var showsIcon = false

    var body: some View {
        if let category = GearCategory(rawValue: key) {
            HStack {
                if showsIcon {
                    Image(systemName: category.icon)
                        .accessibilityHidden(true)
                }
                Text(category.localizedName)
            }
        } else {
            Text(verbatim: key)
        }
    }
}
