import Foundation

/// Classifies a salinity value (g/cm³) into a canonical water-type string.
/// Uses a tolerance window for the EN13319 brackish boundary (≈1.020)
/// to avoid exact floating-point comparison.
func waterType(forSalinity sal: Double) -> String {
    if sal < 1.01 { return "Freshwater" }
    // EN13319 standard uses 1020 kg/m³ exactly (Shearwater → 1.020).
    // Mares IconHD uses MSW/GRAVITY ≈ 1019.716 kg/m³ → 1.01972 (saltwater, not EN13319).
    // Threshold 0.0002 sits between the two (margins: Shearwater ≈0, Mares ≈0.000284).
    if abs(sal - 1.020) < 0.0002 { return "EN13319" }
    return "Saltwater"
}

/// Returns the water pressure divisor (m/bar) for the given water type string.
/// Physics: 100 / (density_g_cm3 × 9.81)
/// Recognises both canonical BlueDive strings ("Freshwater", "EN13319") and
/// MacDive XML vocabulary ("Fresh", "Brackish") via lowercased matching.
func waterPressureDivisor(forWaterTypeString waterType: String?) -> Double {
    switch waterType?.lowercased() {
    case "freshwater", "fresh":  return 100.0 / (1.000 * 9.81)  // ~10.19 m/bar
    case "en13319",   "brackish": return 100.0 / (1.020 * 9.81)  // ~9.99 m/bar
    default:                      return 100.0 / (1.030 * 9.81)  // ~9.90 m/bar (saltwater)
    }
}

/// Returns atmospheric pressure (bar) for the given altitude (metres above sea level).
/// Uses the standard atmosphere barometric formula. Returns 1.01325 bar at sea level.
/// Handles negative altitudes (below-sea-level sites) correctly.
func atmosphericPressure(forAltitudeMeters altitude: Double?) -> Double {
    guard let alt = altitude, alt != 0, alt.isFinite else { return 1.01325 }
    return 1.01325 * pow(1.0 - 2.2558e-5 * alt, 5.2559)
}

/// Normalises any known water-type vocabulary to a canonical BlueDive string.
/// Maps MacDive XML vocabulary ("Fresh", "Salt", "Brackish") to BlueDive canonical forms
/// so the database always stores consistent values regardless of import source.
func canonicalWaterType(_ raw: String?) -> String? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "fresh", "freshwater": return "Freshwater"
    case "salt",  "saltwater":  return "Saltwater"
    case "brackish", "en13319": return "EN13319"
    default:                    return raw
    }
}

/// Localizes a stored water-type string for display.
/// Normalises through canonicalWaterType first so both canonical BlueDive strings and
/// MacDive XML vocabulary ("Fresh", "Salt", "Brackish") produce the correct localized label.
func localizedWaterType(_ raw: String?) -> String {
    guard let raw = raw, !raw.isEmpty else { return "—" }
    switch canonicalWaterType(raw) {
    case "Freshwater": return NSLocalizedString("Freshwater",               bundle: .forAppLanguage(), comment: "Water type: fresh water")
    case "Saltwater":  return NSLocalizedString("Saltwater",                bundle: .forAppLanguage(), comment: "Water type: salt water")
    case "EN13319":    return NSLocalizedString("Brackish water (EN13319)", bundle: .forAppLanguage(), comment: "Water type: EN13319 brackish calibration standard")
    default:           return raw
    }
}
