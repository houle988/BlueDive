/// The dive computers BlueDive supports over Bluetooth LE, and advertised-name lookups.
public enum DeviceCatalog {

    /// Every supported model, in display order. Only models whose libdivecomputer
    /// descriptor offers BLE are listed (Docs/DECISIONS.md, Q4); `CatalogConsistencyTests`
    /// checks this against libdivecomputer in both directions. Names are persisted:
    /// never rename an entry.
    public static let supportedModels: [ComputerModel] = [
        // Shearwater
        .init(name: "Shearwater Peregrine", family: .shearwaterPetrel, modelID: 9),
        .init(name: "Shearwater Peregrine TX", family: .shearwaterPetrel, modelID: 13),
        .init(name: "Shearwater Petrel 2", family: .shearwaterPetrel, modelID: 3),
        .init(name: "Shearwater Petrel 3", family: .shearwaterPetrel, modelID: 10),
        .init(name: "Shearwater Perdix", family: .shearwaterPetrel, modelID: 5),
        .init(name: "Shearwater Perdix AI", family: .shearwaterPetrel, modelID: 6),
        .init(name: "Shearwater Perdix 2", family: .shearwaterPetrel, modelID: 11),
        .init(name: "Shearwater Perdix 3", family: .shearwaterPetrel, modelID: 14),
        .init(name: "Shearwater Teric", family: .shearwaterPetrel, modelID: 8),
        .init(name: "Shearwater Tern", family: .shearwaterPetrel, modelID: 12),
        .init(name: "Shearwater Tern TX", family: .shearwaterPetrel, modelID: 12),
        .init(name: "Shearwater NERD 2", family: .shearwaterPetrel, modelID: 7),
        // Suunto
        .init(name: "Suunto EON Steel", family: .suuntoEonSteel, modelID: 0),
        .init(name: "Suunto EON Core", family: .suuntoEonSteel, modelID: 1),
        .init(name: "Suunto D5", family: .suuntoEonSteel, modelID: 2),
        .init(name: "Suunto EON Steel Black", family: .suuntoEonSteel, modelID: 3),
        // Scubapro
        .init(name: "Scubapro G2", family: .uwatecSmart, modelID: 0x32),
        .init(name: "Scubapro G2 TEK", family: .uwatecSmart, modelID: 0x31),
        .init(name: "Scubapro G2 Console", family: .uwatecSmart, modelID: 0x32),
        .init(name: "Scubapro G2 HUD", family: .uwatecSmart, modelID: 0x42),
        .init(name: "Scubapro G3", family: .uwatecSmart, modelID: 0x34),
        .init(name: "Scubapro Aladin A1", family: .uwatecSmart, modelID: 0x25),
        .init(name: "Scubapro Aladin A2", family: .uwatecSmart, modelID: 0x28),
        .init(name: "Scubapro Aladin Sport Matrix", family: .uwatecSmart, modelID: 0x17),
        .init(name: "Scubapro Aladin H Matrix", family: .uwatecSmart, modelID: 0x17),
        .init(name: "Scubapro Luna 2.0", family: .uwatecSmart, modelID: 0x51),
        .init(name: "Scubapro Luna 2.0 AI", family: .uwatecSmart, modelID: 0x50),
        // Heinrichs Weikamp
        .init(name: "Heinrichs Weikamp OSTC 2", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC 2 TR", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC 3", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC 4", family: .hwOstc3, modelID: 0x43),
        .init(name: "Heinrichs Weikamp OSTC 5", family: .hwOstc3, modelID: 0x44),
        .init(name: "Heinrichs Weikamp OSTC cR", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC Nano", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC Plus", family: .hwOstc3, modelID: 0x00),
        .init(name: "Heinrichs Weikamp OSTC Sport", family: .hwOstc3, modelID: 0x00),
        // Oceanic / Aqualung / Sherwood (Atom2 protocol)
        .init(name: "Oceanic Geo 4.0", family: .oceanicAtom2, modelID: 0x4653),
        .init(name: "Oceanic Veo 4.0", family: .oceanicAtom2, modelID: 0x4654),
        .init(name: "Oceanic Pro Plus X", family: .oceanicAtom2, modelID: 0x4552),
        .init(name: "Oceanic Pro Plus 4", family: .oceanicAtom2, modelID: 0x4656),
        .init(name: "Oceanic Geo Air", family: .oceanicAtom2, modelID: 0x474B),
        .init(name: "Aqualung i770R", family: .oceanicAtom2, modelID: 0x4651),
        .init(name: "Aqualung i750TC", family: .oceanicAtom2, modelID: 0x455A),
        .init(name: "Aqualung i550C", family: .oceanicAtom2, modelID: 0x4652),
        .init(name: "Aqualung i470TC", family: .oceanicAtom2, modelID: 0x4743),
        .init(name: "Aqualung i300C", family: .oceanicAtom2, modelID: 0x4648),
        .init(name: "Aqualung i200C", family: .oceanicAtom2, modelID: 0x4649),
        .init(name: "Aqualung i200C (v2)", family: .oceanicAtom2, modelID: 0x4749),
        .init(name: "Sherwood Wisdom 4", family: .oceanicAtom2, modelID: 0x4655),
        .init(name: "Sherwood Sage", family: .oceanicAtom2, modelID: 0x4647),
        .init(name: "Sherwood Beacon", family: .oceanicAtom2, modelID: 0x4742),
        // Pelagic (i330R protocol)
        .init(name: "Aqualung i330R", family: .pelagicI330R, modelID: 0x4744),
        .init(name: "Aqualung i330R Console", family: .pelagicI330R, modelID: 0x474D),
        .init(name: "Apeks DSX", family: .pelagicI330R, modelID: 0x4741),
        // Mares
        .init(name: "Mares Puck Pro", family: .maresIconHD, modelID: 0x18),
        .init(name: "Mares Puck Pro +", family: .maresIconHD, modelID: 0x18),
        .init(name: "Mares Smart", family: .maresIconHD, modelID: 0x000010),
        .init(name: "Mares Smart Apnea", family: .maresIconHD, modelID: 0x010010),
        .init(name: "Mares Quad", family: .maresIconHD, modelID: 0x29),
        .init(name: "Mares Quad Air", family: .maresIconHD, modelID: 0x23),
        .init(name: "Mares Quad Ci", family: .maresIconHD, modelID: 0x31),
        .init(name: "Mares Quad 2", family: .maresIconHD, modelID: 0x32),
        .init(name: "Mares Smart Air", family: .maresIconHD, modelID: 0x24),
        .init(name: "Mares Sirius", family: .maresIconHD, modelID: 0x2F),
        .init(name: "Mares Sirius L", family: .maresIconHD, modelID: 0x33),
        .init(name: "Mares Puck Air 2", family: .maresIconHD, modelID: 0x2D),
        .init(name: "Mares Genius", family: .maresIconHD, modelID: 0x1C),
        .init(name: "Mares Puck 4", family: .maresIconHD, modelID: 0x35),
        .init(name: "Mares Puck Lite", family: .maresIconHD, modelID: 0x35),
        .init(name: "Mares Puck Pro EZ", family: .maresIconHD, modelID: 0x35),
        .init(name: "Mares Puck Pro Ultra", family: .maresIconHD, modelID: 0x35),
        // Deep Six platform
        .init(name: "Deep Six Excursion", family: .deepsixExcursion, modelID: 0),
        .init(name: "Crest CR-4", family: .deepsixExcursion, modelID: 0),
        .init(name: "Genesis Centauri", family: .deepsixExcursion, modelID: 0),
        .init(name: "Scorpena Alpha", family: .deepsixExcursion, modelID: 0),
        // Single-model families
        .init(name: "Deepblu Cosmiq+", family: .deepbluCosmiq, modelID: 0),
        .init(name: "Oceans S1", family: .oceansS1, modelID: 0),
        .init(name: "McLean Extreme", family: .mcleanExtreme, modelID: 0),
        // Divesoft
        .init(name: "Divesoft Freedom", family: .divesoftFreedom, modelID: 19),
        .init(name: "Divesoft Liberty", family: .divesoftFreedom, modelID: 10),
        // Cressi
        .init(name: "Cressi Goa", family: .cressiGoa, modelID: 2),
        .init(name: "Cressi Cartesio", family: .cressiGoa, modelID: 1),
        .init(name: "Cressi Leonardo 2.0", family: .cressiGoa, modelID: 3),
        .init(name: "Cressi Donatello", family: .cressiGoa, modelID: 4),
        .init(name: "Cressi Michelangelo", family: .cressiGoa, modelID: 5),
        .init(name: "Cressi Raffaello", family: .cressiGoa, modelID: 6),
        .init(name: "Cressi Neon", family: .cressiGoa, modelID: 9),
        .init(name: "Cressi Nepto", family: .cressiGoa, modelID: 10),
        // Ratio / DiveSystem
        .init(name: "Ratio iX3M 2021 GPS Fancy", family: .diveSystem, modelID: 0x60),
        .init(name: "Ratio iX3M 2021 GPS Easy", family: .diveSystem, modelID: 0x61),
        .init(name: "Ratio iX3M 2021 GPS Pro", family: .diveSystem, modelID: 0x62),
        .init(name: "Ratio iX3M 2021 GPS Deep", family: .diveSystem, modelID: 0x63),
        .init(name: "Ratio iX3M 2021 GPS Tech+", family: .diveSystem, modelID: 0x64),
        .init(name: "Ratio iX3M 2021 GPS Reb", family: .diveSystem, modelID: 0x65),
        .init(name: "Ratio iDive 2 Free", family: .diveSystem, modelID: 0x80),
        .init(name: "Ratio iDive 2 Fancy", family: .diveSystem, modelID: 0x81),
        .init(name: "Ratio iDive 2 Easy", family: .diveSystem, modelID: 0x82),
        .init(name: "Ratio iDive 2 Pro", family: .diveSystem, modelID: 0x83),
        .init(name: "Ratio iDive 2 Deep", family: .diveSystem, modelID: 0x84),
        .init(name: "Ratio iDive 2 Tech", family: .diveSystem, modelID: 0x85),
        .init(name: "Ratio iDive 2 Reb", family: .diveSystem, modelID: 0x86),
        .init(name: "Ratio iX3M 2 GPS Gauge", family: .diveSystem, modelID: 0x90),
        .init(name: "Ratio iX3M 2 GPS Easy", family: .diveSystem, modelID: 0x91),
        .init(name: "Ratio iX3M 2 GPS Pro", family: .diveSystem, modelID: 0x92),
        .init(name: "Ratio iX3M 2 GPS Deep", family: .diveSystem, modelID: 0x93),
        .init(name: "Ratio iX3M 2 GPS Tech", family: .diveSystem, modelID: 0x94),
        .init(name: "Ratio iX3M 2 GPS Reb", family: .diveSystem, modelID: 0x95),
        .init(name: "Ratio ATOM", family: .diveSystem, modelID: 0x96),
        .init(name: "Ratio iX3M 2 Gauge", family: .diveSystem, modelID: 0x100),
        .init(name: "Ratio iX3M 2 Easy", family: .diveSystem, modelID: 0x101),
        .init(name: "Ratio iX3M 2 Pro", family: .diveSystem, modelID: 0x102),
        .init(name: "Ratio iX3M 2 Deep", family: .diveSystem, modelID: 0x103),
        .init(name: "Ratio iX3M 2 Tech+", family: .diveSystem, modelID: 0x104),
        // Seac, Halcyon
        .init(name: "Seac Tablet", family: .seacScreen, modelID: 0x10),
        .init(name: "Halcyon Symbios HUD", family: .halcyonSymbios, modelID: 1),
        .init(name: "Halcyon Symbios Handset", family: .halcyonSymbios, modelID: 7)
    ]

    /// The first catalog entry for (family, model) — siblings sharing a model number
    /// resolve to the first one listed.
    public static func model(family: DeviceFamily, modelID: UInt32) -> ComputerModel? {
        supportedModels.first { $0.family == family && $0.modelID == modelID }
    }

    /// The catalog entry with this exact display name.
    public static func model(named name: String) -> ComputerModel? {
        supportedModels.first { $0.name == name }
    }

    /// (family, model) for an advertised BLE name, or nil when it is not a supported
    /// dive computer. See `BLENameResolver` for the rules.
    public static func resolve(advertisedName: String) -> (family: DeviceFamily, modelID: UInt32)? {
        BLENameResolver.resolve(advertisedName)
    }

    /// The name to show for an advertised BLE name: the catalog name when the name
    /// resolves to a catalog model; the raw name when it resolves to a model outside
    /// the catalog; otherwise libdivecomputer's "Vendor Product" for the name, or the
    /// raw name.
    public static func displayName(forAdvertisedName name: String) -> String {
        if let resolved = BLENameResolver.resolve(name) {
            return model(family: resolved.family, modelID: resolved.modelID)?.name ?? name
        }
        if let descriptor = BLENameResolver.libraryDescriptor(forName: name) {
            return "\(descriptor.vendor) \(descriptor.product)"
        }
        return name
    }
}
