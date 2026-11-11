import Foundation

/// The site lists of Edit Site Details → Copy from Existing Site, built from `DiveSummary`
/// values once per change of the store's summaries (not on every redraw of the sheet), so typing
/// in the sheet reads no dive. A picked site's dive is resolved with `DiveStore.liveDive(id:)`.
struct SiteIndex {
    /// One dive per site name (case and surrounding spaces ignored, `NearbySiteFinder.nameKey`),
    /// the most recent one, newest first. Recent shows the first of these.
    private(set) var byDate: [DiveSummary] = []
    /// The same sites, sorted by name: the search list.
    private(set) var all: [DiveSummary] = []

    init() {}

    /// Leaves out the dive `excluding` (the one being edited) and dives without a site name.
    init(summaries: [DiveSummary], excluding diveID: UUID) {
        var seen = Set<String>()
        for summary in summaries.sorted(by: { $0.timestamp > $1.timestamp }) where summary.id != diveID {
            let key = NearbySiteFinder.nameKey(summary.siteName)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            byDate.append(summary)
        }
        all = byDate.sorted { $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending }
    }
}
