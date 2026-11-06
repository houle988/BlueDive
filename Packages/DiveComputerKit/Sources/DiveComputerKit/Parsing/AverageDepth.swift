import Foundation

/// Time-weighted average depth of a profile (trapezoidal rule), used when the computer
/// does not report `DC_FIELD_AVGDEPTH`.
enum AverageDepth {

    /// - Parameter end: when set and strictly inside the profile's time span, the
    ///   average stops there, with the depth interpolated at `end` (Shearwater PNF logs,
    ///   which keep logging after the computer's dive time).
    static func of(_ profile: [ProfileSample], until end: TimeInterval? = nil) -> Double {
        guard profile.count >= 2, let first = profile.first, let last = profile.last else {
            return profile.first?.depth ?? 0
        }
        let cut = end.flatMap { $0 > first.time && $0 < last.time ? $0 : nil }
        var area: Double = 0
        for index in 1..<profile.count {
            let a = profile[index - 1]
            let b = profile[index]
            if let cut, b.time > cut {
                let span = b.time - a.time
                let depthAtCut = span > 0 ? a.depth + (b.depth - a.depth) * (cut - a.time) / span : a.depth
                area += (a.depth + depthAtCut) / 2 * (cut - a.time)
                break
            }
            area += (a.depth + b.depth) / 2 * (b.time - a.time)
        }
        let duration = (cut ?? last.time) - first.time
        return duration > 0 ? area / duration : first.depth
    }
}
