import Foundation

// MARK: - Dive Goal Tier Logic
//
// Single source of truth for dive-count milestone tiers.
// Both DiverProfileView (display goals) and NotificationManager (milestone
// notifications) derive their values from these functions so a tier change
// propagates automatically to both.

/// Returns the stride increment for the tier that contains `diveCount`.
func diveGoalIncrement(for diveCount: Int) -> Int {
    if diveCount < 100  { return 25  }
    if diveCount < 500  { return 100 }
    if diveCount < 1000 { return 250 }
    return 500
}

/// Returns every milestone value that falls at or below `total`, in ascending
/// order, by walking the tier grid from zero.
///
/// Generated sequence: 25, 50, 75, 100, 200, 300, 400, 500, 750, 1000, 1500, …
func diveMilestones(upTo total: Int) -> [Int] {
    var result: [Int] = []
    var v = 0
    while true {
        v += diveGoalIncrement(for: v)
        if v > total { break }
        result.append(v)
    }
    return result
}
