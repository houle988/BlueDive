import Foundation

/// Classifies a salinity value (g/cm³) into a canonical water-type string.
/// Uses a tolerance window for the EN13319 brackish boundary (≈1.020)
/// to avoid exact floating-point comparison.
func waterType(forSalinity sal: Double) -> String {
    if sal < 1.01 { return "Freshwater" }
    if abs(sal - 1.020) < 0.001 { return "EN13319" }
    return "Saltwater"
}

/// Localizes a stored canonical water-type string for display.
func localizedWaterType(_ raw: String?) -> String {
    guard let raw = raw, !raw.isEmpty else { return "—" }
    switch raw {
    case "Freshwater": return NSLocalizedString("Freshwater",               bundle: .forAppLanguage(), comment: "Water type: fresh water")
    case "Saltwater":  return NSLocalizedString("Saltwater",                bundle: .forAppLanguage(), comment: "Water type: salt water")
    case "EN13319":    return NSLocalizedString("Brackish water (EN13319)", bundle: .forAppLanguage(), comment: "Water type: EN13319 brackish calibration standard")
    default:           return raw
    }
}
