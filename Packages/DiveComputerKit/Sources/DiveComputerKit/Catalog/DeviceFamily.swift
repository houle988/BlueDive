import CLibDiveComputer

/// A libdivecomputer protocol family reachable over Bluetooth LE.
///
/// The raw values are persisted (`DeviceFingerprint.familyID`, Fingerprint XML,
/// `com.libdc.storedDevices`) and must never change.
public enum DeviceFamily: String, Codable, CaseIterable, Sendable {
    case suuntoEonSteel
    case shearwaterPetrel
    case hwOstc3
    case uwatecSmart
    case oceanicAtom2
    case pelagicI330R
    case maresIconHD
    case deepsixExcursion
    case deepbluCosmiq
    case oceansS1
    case mcleanExtreme
    case divesoftFreedom
    case cressiGoa
    case diveSystem
    case seacScreen
    case halcyonSymbios

    /// The libdivecomputer family.
    var dcFamily: dc_family_t {
        switch self {
        case .suuntoEonSteel: return DC_FAMILY_SUUNTO_EONSTEEL
        case .shearwaterPetrel: return DC_FAMILY_SHEARWATER_PETREL
        case .hwOstc3: return DC_FAMILY_HW_OSTC3
        case .uwatecSmart: return DC_FAMILY_UWATEC_SMART
        case .oceanicAtom2: return DC_FAMILY_OCEANIC_ATOM2
        case .pelagicI330R: return DC_FAMILY_PELAGIC_I330R
        case .maresIconHD: return DC_FAMILY_MARES_ICONHD
        case .deepsixExcursion: return DC_FAMILY_DEEPSIX_EXCURSION
        case .deepbluCosmiq: return DC_FAMILY_DEEPBLU_COSMIQ
        case .oceansS1: return DC_FAMILY_OCEANS_S1
        case .mcleanExtreme: return DC_FAMILY_MCLEAN_EXTREME
        case .divesoftFreedom: return DC_FAMILY_DIVESOFT_FREEDOM
        case .cressiGoa: return DC_FAMILY_CRESSI_GOA
        case .diveSystem: return DC_FAMILY_DIVESYSTEM_IDIVE
        case .seacScreen: return DC_FAMILY_SEAC_SCREEN
        case .halcyonSymbios: return DC_FAMILY_HALCYON_SYMBIOS
        }
    }

    /// The family for a libdivecomputer family, or nil for families BlueDive does not
    /// support over BLE (Shearwater Predator, Suunto D9, Tecdiving, serial-only ones…).
    init?(dcFamily: dc_family_t) {
        guard let family = DeviceFamily.allCases.first(where: { $0.dcFamily == dcFamily }) else {
            return nil
        }
        self = family
    }
}
