import Foundation

/// Maps an advertised BLE name to a (family, model), in four steps; the first that
/// succeeds wins (Docs/BEHAVIOURAL_SPEC.md §4.3):
///
/// 1. Oceanic / Pelagic: two printable ASCII characters (the model code) followed only
///    by digits, e.g. "FH020399" → 0x4648 (i300C), when that code is a catalog model.
/// 2. Cressi: "<model in canonical lowercase hex>_<hex digits>", e.g. "6_1A2B" → Raffaello.
/// 3. A case-insensitive prefix table, mostly Mares (and Seac's "Tablet").
/// 4. libdivecomputer: a pattern table naming a descriptor by vendor/product, then the
///    first BLE descriptor whose filter accepts the name. Only families BlueDive
///    supports are returned (the descriptor's model need not be in the catalog).
enum BLENameResolver {

    static func resolve(_ name: String) -> (family: DeviceFamily, modelID: UInt32)? {
        if let model = oceanicModel(name) ?? cressiModel(name) ?? prefixModel(name) {
            return (model.family, model.modelID)
        }
        if let descriptor = libraryDescriptor(forName: name), let family = descriptor.family {
            return (family, descriptor.model)
        }
        return nil
    }

    // MARK: - Step 1: Oceanic / Pelagic

    static func oceanicModel(_ name: String) -> ComputerModel? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2,
              scalars[0...1].allSatisfy({ (0x20...0x7E).contains($0.value) }),
              scalars.dropFirst(2).allSatisfy({ (0x30...0x39).contains($0.value) })
        else { return nil }
        let code = scalars[0].value << 8 | scalars[1].value
        return DeviceCatalog.supportedModels.first {
            ($0.family == .oceanicAtom2 || $0.family == .pelagicI330R) && $0.modelID == code
        }
    }

    // MARK: - Step 2: Cressi

    static func cressiModel(_ name: String) -> ComputerModel? {
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        let head = name[..<underscore].lowercased()
        let tail = name[name.index(after: underscore)...]
        guard let model = UInt32(head, radix: 16),
              String(model, radix: 16) == head,
              tail.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit })
        else { return nil }
        return DeviceCatalog.model(family: .cressiGoa, modelID: model)
    }

    // MARK: - Step 3: prefix table

    /// Case-insensitive, anchored; most specific first.
    static let prefixTable: [(prefix: String, family: DeviceFamily, modelID: UInt32)] = [
        ("Mares Genius", .maresIconHD, 0x1C),
        ("Sirius L", .maresIconHD, 0x33),
        ("Sirius", .maresIconHD, 0x2F),
        ("Quad Ci", .maresIconHD, 0x31),
        ("Quad Air", .maresIconHD, 0x23),
        ("Quad2", .maresIconHD, 0x32),
        ("Puck Pro U", .maresIconHD, 0x35),
        ("Puck Pro", .maresIconHD, 0x18),
        ("Puck4", .maresIconHD, 0x35),
        ("Puck Lite", .maresIconHD, 0x35),
        ("Puck Air", .maresIconHD, 0x2D),
        ("Puck", .maresIconHD, 0x18),
        ("Smart Air", .maresIconHD, 0x24),
        ("Smart Apnea", .maresIconHD, 0x010010),
        ("Smart", .maresIconHD, 0x000010),
        ("Mares bluelink pro", .maresIconHD, 0x000010),
        ("Tablet", .seacScreen, 0x10)
    ]

    static func prefixModel(_ name: String) -> ComputerModel? {
        let lowered = name.lowercased()
        guard let entry = prefixTable.first(where: { lowered.hasPrefix($0.prefix.lowercased()) }) else {
            return nil
        }
        return DeviceCatalog.model(family: entry.family, modelID: entry.modelID)
    }

    // MARK: - Step 4: libdivecomputer

    enum PatternMatch { case prefix, substring }

    /// Pattern → descriptor (vendor, product); case-sensitive; first match wins.
    static let patternTable: [(pattern: String, match: PatternMatch, vendor: String, product: String)] = [
        // Shearwater ("Petrel" covers both Petrel generations)
        ("Predator", .substring, "Shearwater", "Predator"),
        ("Perdix 2", .substring, "Shearwater", "Perdix 2"),
        ("Perdix 3", .substring, "Shearwater", "Perdix 3"),
        ("Petrel 3", .substring, "Shearwater", "Petrel 3"),
        ("Petrel", .substring, "Shearwater", "Petrel 2"),
        ("Perdix", .substring, "Shearwater", "Perdix"),
        ("Teric", .substring, "Shearwater", "Teric"),
        ("Peregrine TX", .substring, "Shearwater", "Peregrine TX"),
        ("Peregrine", .substring, "Shearwater", "Peregrine"),
        ("NERD 2", .substring, "Shearwater", "Nerd 2"),
        ("NERD", .prefix, "Shearwater", "Nerd"),
        ("Tern SC", .prefix, "Shearwater", "Tern"),
        ("Tern", .prefix, "Shearwater", "Tern"),
        // Suunto
        ("EON Steel", .substring, "Suunto", "EON Steel"),
        ("Suunto D5", .substring, "Suunto", "D5"),
        ("EON Core", .substring, "Suunto", "EON Core"),
        // Scubapro
        ("G2 HUD", .prefix, "Scubapro", "G2 HUD"),
        ("HUD", .prefix, "Scubapro", "G2 HUD"),
        ("G2", .prefix, "Scubapro", "G2"),
        ("G3", .prefix, "Scubapro", "G3"),
        ("Aladin A1", .prefix, "Scubapro", "Aladin A1"),
        ("Aladin A2", .prefix, "Scubapro", "Aladin A2"),
        ("Aladin", .substring, "Scubapro", "Aladin Sport Matrix"),
        ("A1", .prefix, "Scubapro", "Aladin A1"),
        ("A2", .prefix, "Scubapro", "Aladin A2"),
        ("Luna 2.0 AI", .substring, "Scubapro", "Luna 2.0 AI"),
        ("Luna 2.0", .substring, "Scubapro", "Luna 2.0"),
        // Mares
        ("Mares Genius", .substring, "Mares", "Genius"),
        ("Sirius L", .prefix, "Mares", "Sirius L"),
        ("Sirius", .prefix, "Mares", "Sirius"),
        ("Quad Ci", .substring, "Mares", "Quad Ci"),
        ("Puck4", .substring, "Mares", "Puck 4"),
        // Cressi (real names are "<hex>_<hex>", handled by step 2)
        ("CARESIO_", .prefix, "Cressi", "Cartesio"),
        ("GOA_", .prefix, "Cressi", "Goa"),
        ("Leonardo", .substring, "Cressi", "Leonardo 2.0"),
        ("Donatello", .substring, "Cressi", "Donatello"),
        ("Michelangelo", .substring, "Cressi", "Michelangelo"),
        ("Neon", .prefix, "Cressi", "Neon"),
        ("Nepto", .prefix, "Cressi", "Nepto"),
        // Heinrichs Weikamp
        ("OSTC 3", .substring, "Heinrichs Weikamp", "OSTC Plus"),
        ("OSTC s#", .substring, "Heinrichs Weikamp", "OSTC Sport"),
        ("OSTC s ", .substring, "Heinrichs Weikamp", "OSTC Sport"),
        ("OSTC 4-", .substring, "Heinrichs Weikamp", "OSTC 4"),
        ("OSTC 2-", .substring, "Heinrichs Weikamp", "OSTC 2N"),
        ("OSTC + ", .substring, "Heinrichs Weikamp", "OSTC 2"),
        ("OSTC", .substring, "Heinrichs Weikamp", "OSTC 2"),
        // Others
        ("COSMIQ", .substring, "Deepblu", "Cosmiq+"),
        ("S1", .prefix, "Oceans", "S1"),
        ("McLean Extreme", .substring, "McLean", "Extreme"),
        ("DiveComputer", .substring, "Tecdiving", "DiveComputer.eu"),
        ("DS", .prefix, "Ratio", "iX3M 2021 GPS Easy"),
        ("IX5M", .prefix, "Ratio", "iX3M 2021 GPS Easy"),
        ("RATIO-", .prefix, "Ratio", "iX3M 2021 GPS Easy")
    ]

    /// The libdivecomputer descriptor for an advertised name (any family, any transport
    /// for the pattern table; BLE only for the filter fallback), or nil.
    static func libraryDescriptor(forName name: String) -> LibraryDescriptor? {
        if let entry = patternTable.first(where: { matches(name, $0.pattern, $0.match) }),
           let descriptor = DescriptorLookup.first(vendor: entry.vendor, product: entry.product) {
            return descriptor
        }
        return DescriptorLookup.firstBLEMatch(forAdvertisedName: name)
    }

    private static func matches(_ name: String, _ pattern: String, _ match: PatternMatch) -> Bool {
        switch match {
        case .prefix: return name.utf8.starts(with: pattern.utf8)
        case .substring: return name.range(of: pattern, options: .literal) != nil
        }
    }
}
