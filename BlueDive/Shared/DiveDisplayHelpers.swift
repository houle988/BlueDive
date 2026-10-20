import SwiftUI
import SwiftData

// Display helpers shared by the dive statistics screens (Statistics dashboard, trips, Diver
// Profile, Calendar): the one RMV format and aggregate, and the one dive-site rule.

// MARK: - RMV Aggregate

/// Average RMV over `dives` (L/min, 0 when no dive has one), whether any of those RMVs was not
/// natively available in bar and litres (`isEstimated`: the value carries the " *" marker), and
/// the dives with the lowest (`best`) and highest (`worst`) RMV. One pass, reading each dive's
/// `calculatedRMV` once. Skips a dive deleted on another device and not yet removed from the
/// caller's list (reading its attributes would crash). The single rule for the trip details
/// and the Statistics dashboard.
@MainActor
func rmvAggregate(_ dives: [Dive]) -> (average: Double, isEstimated: Bool, best: Dive?, worst: Dive?) {
    var sum = 0.0
    var count = 0
    var isEstimated = false
    var best: (dive: Dive, rmv: Double)?
    var worst: (dive: Dive, rmv: Double)?
    for dive in dives where !dive.isDeleted && dive.modelContext != nil {
        let rmv = dive.calculatedRMV
        guard rmv > 0 else { continue }
        sum += rmv
        count += 1
        if !dive.isRMVInNativeUnits { isEstimated = true }
        // Strict comparisons keep the first of equal values, as min(by:) / max(by:) do.
        if rmv < (best?.rmv ?? .infinity) { best = (dive, rmv) }
        if rmv > (worst?.rmv ?? -.infinity) { worst = (dive, rmv) }
    }
    return (count > 0 ? sum / Double(count) : 0, isEstimated, best?.dive, worst?.dive)
}

// MARK: - RMV Formatting

/// An RMV (respiratory minute volume, calculated in litres per minute) formatted for display:
/// "L/min" with 2 decimals, or cubic feet per minute (1 cu ft = 28.3168 L) with 3 decimals
/// when the pressure unit is psi. `isEstimated` appends " *" — the footnote marker for an RMV
/// not natively available in bar and litres (`Dive.isRMVInNativeUnits` false). The single
/// RMV format for dives, tanks, trips and the Statistics dashboard.
func formatRMV(_ litresPerMinute: Double, pressureUnit: PressureUnit, isEstimated: Bool = false) -> String {
    let value = pressureUnit != .psi
        ? litresPerMinute.localizedString(decimals: 2, minDecimals: 2) + " " + NSLocalizedString("unit.volume.rmv.l_per_min", bundle: .forAppLanguage(), value: "L/min", comment: "RMV unit: litres per minute")
        : (litresPerMinute / 28.3168).localizedString(decimals: 3, minDecimals: 3) + " " + NSLocalizedString("unit.volume.rmv.cu_ft_per_min", bundle: .forAppLanguage(), value: "cu ft/min", comment: "RMV unit: cubic feet per minute")
    return isEstimated ? value + " *" : value
}

/// The note explaining the " *" `formatRMV` adds to an average RMV over several dives (trip
/// details, the Statistics dashboard). The single copy of its text and style.
struct EstimatedRMVFootnote: View {
    var body: some View {
        Text("* Some dives' RMV is calculated from units other than bar and litres.",
             comment: "Footnote under an average RMV (trip details and the Statistics dashboard), explaining the * after the value: some of the dives were not recorded in bar and litres.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Site Counting

/// The key two dive sites are compared by: the name ignoring case and surrounding spaces.
/// An empty key is a dive without a site. The single site rule for the Sites counts
/// (Statistics, Calendar, Diver Profile, trips) and the Statistics Top Sites. Display only:
/// the stored site name is never changed.
func siteNameKey(_ siteName: String) -> String {
    siteName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Number of distinct dive sites among `siteNames` (`siteNameKey`), dives without a site
/// not counted.
func uniqueSiteCount<S: Sequence>(_ siteNames: S) -> Int where S.Element == String {
    Set(siteNames.map(siteNameKey).filter { !$0.isEmpty }).count
}

/// The spelling to show for a group of dives at one site (same `siteNameKey`): the most
/// used one, trimmed; ties go to the alphabetically first (locale-aware, so "Épave" sorts
/// with the E's), so the choice is stable.
func displaySiteName<S: Sequence>(_ siteNames: S) -> String where S.Element == String {
    let counts = Dictionary(siteNames.map { ($0.trimmingCharacters(in: .whitespacesAndNewlines), 1) }, uniquingKeysWith: +)
    // `max` keeps the largest: fewer uses rank lower, and on a tie the alphabetically later
    // spelling ranks lower, so the alphabetically first one wins.
    return counts.max {
        $0.value != $1.value
            ? $0.value < $1.value
            : $0.key.localizedStandardCompare($1.key) == .orderedDescending
    }?.key ?? ""
}
