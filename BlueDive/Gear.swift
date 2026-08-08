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
    var diverName: String = ""
    
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
        weightContributionUnit: String? = nil,
        isInactive: Bool = false,
        diverName: String = "",
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
        self.diverName = diverName
        self.lastServiceDate = lastServiceDate
        self.nextServiceDue = nextServiceDue
        self.serviceHistory = serviceHistory
        self.gearNotes = gearNotes
    }

}

// MARK: - Dedup Helper

extension Gear {
    /// Placeholder values that should not be treated as real serial numbers.
    /// Items whose serial normalises to one of these fall through to the name+diverName branch.
    private static let sentinelSerials: Set<String> = [
        "n/a", "na", "unknown", "none", "0", "00", "-", "--"
    ]

    /// Trims whitespace and newlines, returns nil for empty strings and known sentinel values.
    private static func normalizedSerial(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return sentinelSerials.contains(trimmed.lowercased()) ? nil : trimmed
    }

    /// Returns true if this gear matches the given import attributes.
    /// Name is always compared (trimmed, case-insensitive). When both items have a
    /// real serial, only the serial is compared (diverName is ignored). When neither
    /// has a serial, diverName must match exactly (trimmed, case-insensitive); items
    /// with differing diverNames — including empty vs. non-empty — are never merged.
    /// Known sentinel serials (e.g. "N/A", "0") are normalised to nil.
    func matches(name: String, category: String, diverName: String, serial: String?) -> Bool {
        let trimmedSelfName = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSelfName.caseInsensitiveCompare(trimmedName) == .orderedSame &&
              self.category == category else { return false }
        let a = Gear.normalizedSerial(serialNumber)
        let b = Gear.normalizedSerial(serial)
        switch (a, b) {
        case let (x?, y?):
            // Serial number uniquely identifies a physical item — diverName not required.
            return x.caseInsensitiveCompare(y) == .orderedSame
        case (nil, nil):
            // No serial on either side: require an exact (case-insensitive) diverName match.
            // Items with different diverNames — including empty vs. non-empty — are treated
            // as distinct records so that a diver-attributed import never silently merges
            // into an unattributed record and discards the diver information.
            let storedDiver = self.diverName.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingDiver = diverName.trimmingCharacters(in: .whitespacesAndNewlines)
            return storedDiver.caseInsensitiveCompare(incomingDiver) == .orderedSame
        default:
            return false
        }
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
        "strobe": .light,
        "cylinder": .tank,
        "bottle": .tank,
        "o2 analyzer": .analyzer,
        "oxygen analyzer": .analyzer,
        "gas analyzer": .analyzer,
        "pressure gauge": .spg,
        "submersible pressure gauge": .spg,
        "spool": .reel,
        "lift bag": .other,
        "underwear": .underwear,
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

// MARK: - Service Records

struct ServiceRecord: Codable, Identifiable {
    var id: UUID
    var date: Date
    var description: String
    var cost: Double?
    var isLegacy: Bool

    init(id: UUID = UUID(), date: Date, description: String, cost: Double? = nil, isLegacy: Bool = false) {
        self.id = id
        self.date = date
        self.description = description
        self.cost = cost
        self.isLegacy = isLegacy
    }
}

extension Gear {
    // Stable sentinel UUID used only for in-memory legacy plain-text records (never stored in JSON).
    static let legacySentinelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// True when `serviceHistory` holds structured JSON rather than a legacy plain-text note.
    /// Use this instead of repeating `hasPrefix("[")` at call sites.
    var hasStructuredServiceHistory: Bool {
        serviceHistory?.hasPrefix("[") == true
    }

    /// Parses structured records from `serviceHistory`. Falls back to a synthetic legacy
    /// record when the field contains plain text written before structured records were introduced.
    var parsedServiceRecords: [ServiceRecord] {
        guard let raw = serviceHistory, !raw.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = raw.data(using: .utf8),
           let records = try? decoder.decode([ServiceRecord].self, from: data) {
            return records
        }
        // If the value looks like JSON but failed to decode (e.g. written by a newer schema version),
        // return empty rather than treating the raw JSON blob as a legacy plain-text note.
        // syncServiceData() prevents malformed JSON from entering via imports, so this guard
        // is only reached in the event of storage corruption.
        if raw.hasPrefix("[") { return [] }
        // Legacy plain text — wrap in a synthetic record so it displays in the list.
        return [ServiceRecord(id: Gear.legacySentinelID, date: lastServiceDate ?? .distantPast, description: raw, isLegacy: true)]
    }

    /// Returns `parsedServiceRecords` with any in-memory sentinel UUID promoted to a stable
    /// export UUID, ready for XML export. Never persist the result — promotion is for serialisation only.
    ///
    /// The export UUID is derived deterministically from the gear's own `id` so that repeated
    /// exports of the same gear always produce the same UUID for the legacy record, keeping
    /// exported XML stable across multiple export passes.
    ///
    /// The sentinel can only appear in `parsedServiceRecords` for plain-text gear (serviceHistory
    /// does not start with "["). Since `serviceHistoryXMLLines` early-returns for plain-text gear
    /// without calling this property, the sentinel promotion branch is not triggered through the
    /// current export path. The promotion logic is retained as a safety net for future callers.
    var exportableServiceRecords: [ServiceRecord] {
        parsedServiceRecords.map { r in
            r.id == Gear.legacySentinelID
                ? ServiceRecord(id: legacyExportID, date: r.date, description: r.description, cost: r.cost, isLegacy: r.isLegacy)
                : r
        }
    }

    /// A stable export UUID for the legacy sentinel record, derived deterministically from the
    /// gear's own `id` by XOR-ing two boundary bytes with fixed markers. Ensures that
    /// repeated exports of the same gear always produce the same UUID for the legacy record.
    private var legacyExportID: UUID {
        var bytes = id.uuid
        bytes.0 ^= 0x4C   // 'L' for legacy
        bytes.15 ^= 0x47  // 'G' for gear
        let derived = UUID(uuid: bytes)
        // Guard against the astronomically unlikely case where the XOR yields the reserved sentinel.
        // Perturbing byte[1] produces a different but still deterministic UUID for this gear.
        if derived == Gear.legacySentinelID {
            bytes.1 ^= 0x01
            return UUID(uuid: bytes)
        }
        return derived
    }

    /// Returns true when `json` is a valid JSON-encoded `[ServiceRecord]` array.
    /// Used to validate incoming history blobs before mutating any stored state.
    private static func canDecodeServiceHistory(_ json: String) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return false }
        return (try? decoder.decode([ServiceRecord].self, from: data)) != nil
    }

    /// Merges service data from a re-import.
    ///
    /// When `importedDate` is provided, the function acts as a freshness-gated merge:
    /// the call is a no-op when the incoming date is not newer than `lastServiceDate`.
    /// When `importedDate` is nil, the function fills in a missing `serviceHistory` only
    /// if the gear currently has none (never overwrites).
    ///
    /// In both paths, malformed JSON is validated and rejected before any state is mutated.
    /// Plain-text history never overwrites existing structured JSON history.
    @discardableResult
    func syncServiceData(importedDate: Date?, importedHistory: String?) -> Bool {
        // Treat an empty string identically to nil — both mean "no history provided."
        let importedHistory = importedHistory.flatMap { $0.isEmpty ? nil : $0 }
        if let importedDate {
            guard lastServiceDate == nil || importedDate > lastServiceDate! else { return false }
            // Validate incoming JSON before mutating any state so a malformed blob leaves
            // `lastServiceDate` and `serviceHistory` completely untouched.
            if let incoming = importedHistory, incoming.hasPrefix("[") {
                guard Self.canDecodeServiceHistory(incoming) else { return false }
            }
            if let incoming = importedHistory {
                // Never let incoming plain text overwrite existing structured JSON history.
                // If that would be the case, skip the entire update — advancing lastServiceDate
                // without also updating serviceHistory would create a date/record mismatch where
                // the displayed "Last Maintenance" date doesn't correspond to any stored record.
                guard !hasStructuredServiceHistory || incoming.hasPrefix("[") else { return false }
                serviceHistory = incoming
            } else if hasStructuredServiceHistory {
                // No history provided but gear already has structured records. Advancing
                // lastServiceDate without a matching record would violate the invariant that
                // lastServiceDate is always derivable from stored records.
                return false
            }
            lastServiceDate = importedDate
            return true
        } else {
            // No date anchor: only fill in history when the gear has none, and validate
            // incoming JSON so a malformed blob is rejected rather than stored silently.
            guard let incoming = importedHistory, serviceHistory == nil else { return false }
            if incoming.hasPrefix("[") {
                guard Self.canDecodeServiceHistory(incoming) else { return false }
            }
            serviceHistory = incoming
            return true
        }
    }

    /// Encodes `records` as JSON into `serviceHistory` and keeps `lastServiceDate` in sync.
    func saveServiceRecords(_ records: [ServiceRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if records.isEmpty {
            serviceHistory = nil
            // lastServiceDate intentionally NOT cleared here — callers that want a full wipe
            // must set lastServiceDate = nil explicitly before calling this method.
            // Both the "Clear All Records" action (GearServiceView) and deleteServiceRecord
            // (when the last record is removed) do this explicitly.
            // nextServiceDue is also intentionally NOT cleared here; only "Clear All Records"
            // resets it explicitly after warning the user the reminder will be removed.
        } else {
            // Promote any in-memory legacy sentinel IDs to real UUIDs before persisting
            // so the sentinel ID (reserved for the parse-time synthetic record) is never stored in JSON.
            var toSave = records
            for i in toSave.indices where toSave[i].id == Gear.legacySentinelID {
                toSave[i].id = UUID()
            }
            if let data = try? encoder.encode(toSave),
               let json = String(data: data, encoding: .utf8) {
                serviceHistory = json
                // Derive lastServiceDate from ALL records (including legacy) so that adding an
                // older non-legacy record to legacy-only gear does not regress the displayed date.
                // Exclude .distantPast, which is the sentinel for "unknown date" on synthetic
                // records built from gear whose original service date was never recorded.
                if let maxDate = toSave
                    .filter({ $0.date > .distantPast })
                    .max(by: { $0.date < $1.date })?.date {
                    lastServiceDate = maxDate
                } else {
                    lastServiceDate = nil
                }
            }
        }
    }

    func addServiceRecord(date: Date, description: String, cost: Double?) {
        // If serviceHistory looks like JSON but failed to decode (storage corruption or a newer
        // schema version), parsedServiceRecords returns [] and a naive append would overwrite the
        // unreadable blob with a single-record array, silently discarding whatever was there.
        // Bail out instead — silent data loss is worse than failing to add the new record.
        guard !(hasStructuredServiceHistory && parsedServiceRecords.isEmpty) else { return }
        var records = parsedServiceRecords
        records.append(ServiceRecord(date: date, description: description, cost: cost))
        records.sort { $0.date > $1.date }
        saveServiceRecords(records)
    }

    func updateServiceRecord(_ updated: ServiceRecord, originalId: UUID? = nil) {
        var records = parsedServiceRecords
        let searchId = originalId ?? updated.id
        if let index = records.firstIndex(where: { $0.id == searchId }) {
            records[index] = updated
            records.sort { $0.date > $1.date }
            saveServiceRecords(records)
        }
    }

    func deleteServiceRecord(id: UUID) {
        let records = parsedServiceRecords.filter { $0.id != id }
        if records.isEmpty {
            lastServiceDate = nil
        }
        saveServiceRecords(records)
    }
}

