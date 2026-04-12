import Foundation
import SwiftData

// MARK: - Tank Template Model

@Model
final class TankTemplate {
    var id: UUID = UUID()
    var name: String = ""
    var volume: Double?            // Tank volume in the unit specified by volumeUnit
    var workingPressure: Double?   // Working pressure in the unit specified by pressureUnit
    var volumeUnit: String = "liters"       // VolumeUnit rawValue ("liters" or "cubic feet")
    var pressureUnit: String = "bar"        // PressureUnit rawValue ("bar", "psi", or "pa")
    var material: String?          // Tank material (Steel, Aluminium, etc.)
    var format: String?            // Tank format/type (Single tank, Twinset, etc.)
    var manufacturer: String?      // Tank manufacturer
    var model: String?             // Tank model

    init(
        id: UUID = UUID(),
        name: String,
        volume: Double? = nil,
        workingPressure: Double? = nil,
        volumeUnit: String = "liters",
        pressureUnit: String = "bar",
        material: String? = nil,
        format: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.workingPressure = workingPressure
        self.volumeUnit = volumeUnit
        self.pressureUnit = pressureUnit
        self.material = material
        self.format = format
        self.manufacturer = manufacturer
        self.model = model
    }
}

// MARK: - Computed Properties

extension TankTemplate {
    /// The resolved VolumeUnit for this template.
    var storedVolumeUnit: VolumeUnit {
        VolumeUnit(rawValue: volumeUnit) ?? .liters
    }

    /// The resolved PressureUnit for this template.
    var storedPressureUnit: PressureUnit {
        PressureUnit(rawValue: pressureUnit) ?? .bar
    }

    /// Converts tank volume to the target volume unit using the working pressure.
    /// L → cu ft:  cuft = (L × wp_bar) / 28.3168
    /// cu ft → L:  L = (cuft × 28.3168) / wp_bar
    /// Returns the original value if units match or working pressure is unavailable.
    func convertedVolume(to targetUnit: VolumeUnit) -> Double? {
        guard let vol = volume else { return nil }
        if storedVolumeUnit == targetUnit { return vol }
        guard let wp = workingPressure else { return vol }

        let wpBar = PressureUnit.bar.convert(wp, from: storedPressureUnit)
        if storedVolumeUnit == .liters && targetUnit == .cubicFeet {
            return (vol * wpBar) / 28.3168
        } else if storedVolumeUnit == .cubicFeet && targetUnit == .liters {
            return (vol * 28.3168) / wpBar
        }
        return vol
    }

    /// A summary string for display in lists, using the user's preferred units.
    /// Volume is converted between L and cu ft using the working pressure formula.
    /// e.g. "80.0 ft³ · 3000 psi · Steel · Single tank"
    var summaryDescription: String {
        let prefs = UserPreferences.shared
        var parts: [String] = []
        if let displayVol = convertedVolume(to: prefs.volumeUnit) {
            parts.append(String(format: "%.1f %@", displayVol, prefs.volumeUnit.symbol))
        }
        if let wp = workingPressure {
            let displayWP = prefs.pressureUnit.convert(wp, from: storedPressureUnit)
            parts.append(String(format: "%.0f %@", displayWP, prefs.pressureUnit.symbol))
        }
        if let mat = material, !mat.isEmpty {
            parts.append(mat)
        }
        if let fmt = format, !fmt.isEmpty {
            parts.append(fmt)
        }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }

    /// Manufacturer and model combined (e.g. "Aqualung / Calypso")
    var manufacturerAndModel: String? {
        let mfr = manufacturer ?? ""
        let mdl = model ?? ""
        if mfr.isEmpty && mdl.isEmpty { return nil }
        if mfr.isEmpty { return mdl }
        if mdl.isEmpty { return mfr }
        return "\(mfr) / \(mdl)"
    }
}
