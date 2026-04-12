import Foundation
import SwiftData
import SwiftUI

// MARK: - Gear Model

@Model
final class Gear {
    var id: UUID = UUID()
    var name: String = ""
    var category: String = ""
    var manufacturer: String?   // Manufacturer / Brand (e.g. "Shearwater")
    var model: String?          // Modèle exact (ex: "Perdix 2")
    var serialNumber: String?   // Numéro de série
    var datePurchased: Date = Date.now
    var purchasePrice: Double?  // Prix d'achat
    var currency: String?       // Devise (CAD, USD, EUR…)
    var purchasedFrom: String?  // Magasin / vendeur
    var lastServiceDate: Date?
    var nextServiceDue: Date?   // Prochain entretien prévu (choix manuel)
    var serviceHistory: String? // Journal d'entretien (texte libre)
    var gearNotes: String?      // Notes libres sur l'équipement
    var weightContribution: Double = 0.0 // en kg
    var weightContributionUnit: String? // "kg" or "lb"
    var isInactive: Bool = false
    
    // Relation inverse avec les plongées
    @Relationship(inverse: \Dive.usedGear)
    var dives: [Dive]? = []

    // Relation inverse avec les groupes d'équipement
    @Relationship(inverse: \GearGroup.gear)
    var gearGroups: [GearGroup]? = []

    // MARK: - Computed Properties
    
    /// Nombre total de plongées effectuées avec cet équipement
    var totalDivesCount: Int {
        (dives ?? []).count
    }
    
    /// Temps total d'immersion avec cet équipement (en minutes)
    var totalBottomTime: Int {
        (dives ?? []).reduce(0) { $0 + $1.duration }
    }
    
    /// Temps total formaté (heures et minutes)
    var formattedTotalTime: String {
        let hours = totalBottomTime / 60
        let minutes = totalBottomTime % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
    
    /// Temps moyen par plongée (en minutes)
    var averageTimePerDive: Int {
        guard totalDivesCount > 0 else { return 0 }
        return totalBottomTime / totalDivesCount
    }
    
    /// Nombre de jours depuis le dernier entretien
    var daysSinceLastService: Int {
        guard let referenceDate = lastServiceDate else { return 0 }
        let components = Calendar.current.dateComponents([.day], from: referenceDate, to: Date())
        return components.day ?? 0
    }
    
    
    /// Catégorie typée (enum)
    var gearCategory: GearCategory? {
        GearCategory(exportKeyOrRawValue: category)
    }
    
    // MARK: - Initialization
    
    init(
        id: UUID = UUID(),
        name: String,
        category: String,
        manufacturer: String? = nil,
        model: String? = nil,
        serialNumber: String? = nil,
        datePurchased: Date = Date(),
        purchasePrice: Double? = nil,
        currency: String? = nil,
        purchasedFrom: String? = nil,
        weightContribution: Double = 0.0,
        weightContributionUnit: String,
        isInactive: Bool = false,
        lastServiceDate: Date? = nil,
        nextServiceDue: Date? = nil,
        serviceHistory: String? = nil,
        gearNotes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.datePurchased = datePurchased
        self.purchasePrice = purchasePrice
        self.currency = currency
        self.purchasedFrom = purchasedFrom
        self.weightContribution = weightContribution
        self.weightContributionUnit = weightContributionUnit
        self.isInactive = isInactive
        self.lastServiceDate = lastServiceDate
        self.nextServiceDue = nextServiceDue
        self.serviceHistory = serviceHistory
        self.gearNotes = gearNotes
    }
    
    // MARK: - Service Methods
    
    /// Marque l'équipement comme entretenu à la date donnée
    func markAsServiced(on date: Date = Date()) {
        lastServiceDate = date
    }
}

// MARK: - Gear Category

enum GearCategory: String, CaseIterable, Identifiable {
    case suit = "Wetsuit"
    case tank = "Tank"
    case firstStage = "First Stage"
    case secondStage = "Second Stage"
    case bcd = "BCD/Backplate"
    case weights = "Weights"
    case computer = "Computer"
    case fins = "Fins"
    case mask = "Mask"
    case snorkel = "Snorkel"
    case underwear = "Undersuit"
    case drysuit = "Drysuit"
    case reel = "Reel"
    case gloves = "Gloves"
    case backplate = "Backplate"
    case hood = "Hood"
    case boots = "Boots"
    case knife = "Knife"
    case light = "Light"
    case compass = "Compass"
    case surfaceMarker = "SMB"
    case wing = "Wing"
    case transmitter = "Transmitter"
    case analyzer = "Analyzer"
    case spg = "SPG"
    case whistle = "Whistle"
    case tool = "Tool"
    case other = "Other"
    
    var id: String { rawValue }

    /// Localized display name for this gear category.
    /// Uses a prefixed key ("gear.category.X") to avoid conflicts with
    /// other uses of the same English word (e.g. "Light" = appearance mode).
    var localizedName: LocalizedStringKey {
        let key = "gear.category." + rawValue
        return LocalizedStringKey(key)
    }

    /// Canonical English key used in XML export/import round-trips.
    /// Must stay in sync with `mapMacDiveGearType(_:)` in ContentView.
    var exportKey: String {
        switch self {
        case .suit:          return "wetsuit"
        case .tank:          return "tank"
        case .firstStage:    return "first stage"
        case .secondStage:   return "second stage"
        case .bcd:           return "bcd"
        case .weights:       return "weights"
        case .computer:      return "computer"
        case .fins:          return "fins"
        case .mask:          return "mask"
        case .snorkel:       return "snorkel"
        case .underwear:     return "underwear"
        case .drysuit:       return "drysuit"
        case .reel:          return "reel"
        case .gloves:        return "gloves"
        case .backplate:     return "backplate"
        case .hood:          return "hood"
        case .boots:         return "boots"
        case .knife:         return "knife"
        case .light:         return "light"
        case .compass:       return "compass"
        case .surfaceMarker: return "dsmb"
        case .wing:          return "wing"
        case .transmitter:   return "transmitter"
        case .analyzer:      return "analyzer"
        case .spg:           return "spg"
        case .whistle:       return "whistle"
        case .tool:          return "tool"
        case .other:         return "other"
        }
    }

    /// Initialises a category from an XML export key (English) or a rawValue (French),
    /// enabling robust round-trip import regardless of which format was written.
    /// Additional English aliases that map to a specific category.
    /// Used by `init?(exportKeyOrRawValue:)` as a third resolution step.
    private static let aliases: [String: GearCategory] = [
        "first stage":   .firstStage,
        "firststage":    .firstStage,
        "regulator":     .secondStage,
        "second stage":  .secondStage,
        "secondstage":   .secondStage,
        "octopus":       .secondStage,
        "détendeur":     .firstStage,
        "wetsuit": .suit,
        "drysuit": .drysuit,
        "smb": .surfaceMarker,
        "surface marker": .surfaceMarker,
        "torch": .light,
        "cylinder": .tank,
        "bottle": .tank,
        "o2 analyzer": .analyzer,
        "oxygen analyzer": .analyzer,
        "gas analyzer": .analyzer,
        "pressure gauge": .spg,
        "submersible pressure gauge": .spg,
    ]

    /// Initialises a category from an XML export key (English) or a rawValue (French),
    /// enabling robust round-trip import regardless of which format was written.
    init?(exportKeyOrRawValue value: String) {
        let lowercased = value.lowercased()
        if let match = GearCategory.allCases.first(where: { $0.exportKey == lowercased }) {
            self = match
        } else if let match = GearCategory.aliases[lowercased] {
            self = match
        } else if let match = GearCategory.allCases.first(where: { $0.rawValue == value }) {
            self = match
        } else {
            return nil
        }
    }

    /// Icône SF Symbol associée à la catégorie
    var icon: String {
        switch self {
        case .suit: return "figure.pool.swim"
        case .tank: return "cylinder.fill"
        case .firstStage:  return "gauge.with.dots.needle.bottom.50percent"
        case .secondStage: return "mouth.fill"
        case .bcd: return "livephoto"
        case .weights: return "scalemass.fill"
        case .computer: return "applewatch"
        case .fins: return "shoe.2.fill"
        case .mask: return "eyeglasses"
        case .snorkel: return "bubbles.and.sparkles.fill"
        case .underwear: return "tshirt.fill"
        case .drysuit: return "figure.water.fitness"
        case .reel: return "circle.dotted.and.circle"
        case .gloves: return "hand.raised.fill"
        case .backplate: return "square.3.layers.3d.bottom.filled"
        case .hood: return "helmet.fill"
        case .boots: return "shoe.fill"
        case .knife: return "pencil.tip"
        case .light: return "flashlight.on.fill"
        case .compass: return "safari.fill"
        case .surfaceMarker: return "arrow.up.circle.fill"
        case .wing: return "wind"
        case .transmitter: return "antenna.radiowaves.left.and.right"
        case .analyzer: return "gauge.with.dots.needle.bottom.50percent.badge.plus"
        case .spg: return "gauge.high"
        case .whistle: return "speaker.wave.2.fill"
        case .tool: return "wrench.fill"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }
    
    /// Couleur associée à la catégorie
    var color: String {
        switch self {
        case .suit: return "purple"
        case .tank: return "blue"
        case .firstStage:  return "green"
        case .secondStage: return "teal"
        case .bcd: return "orange"
        case .weights: return "gray"
        case .computer: return "cyan"
        case .fins: return "pink"
        case .mask: return "indigo"
        case .snorkel: return "mint"
        case .underwear: return "purple"
        case .drysuit: return "blue"
        case .reel: return "yellow"
        case .gloves: return "red"
        case .backplate: return "gray"
        case .hood: return "black"
        case .boots: return "brown"
        case .knife: return "red"
        case .light: return "yellow"
        case .compass: return "blue"
        case .surfaceMarker: return "orange"
        case .wing: return "cyan"
        case .transmitter: return "blue"
        case .analyzer: return "green"
        case .spg: return "teal"
        case .whistle: return "yellow"
        case .tool: return "gray"
        case .other: return "brown"
        }
    }
}


