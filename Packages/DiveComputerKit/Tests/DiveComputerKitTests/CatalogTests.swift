import Foundation
import Testing
@testable import DiveComputerKit

/// The old library's public catalog and name resolution, recorded by the golden harness
/// (`--dump-catalog`, Fixtures/legacy-catalog.json from Fixtures/ble-name-samples.json).
struct LegacyCatalog: Decodable, Sendable {
    struct Model: Decodable, Sendable { let name: String; let family: String; let modelID: UInt32 }
    struct Resolved: Decodable, Sendable { let family: String; let modelID: UInt32 }
    struct Resolution: Decodable, Sendable { let name: String; let resolved: Resolved?; let displayName: String }
    let families: [String]
    let supportedModels: [Model]
    let knownServiceUUIDs: [String]
    let resolutions: [Resolution]

    static let shared: LegacyCatalog = {
        let url = Bundle.module.url(forResource: "legacy-catalog", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(LegacyCatalog.self, from: Data(contentsOf: url))
    }()
}

/// Non-BLE models the old catalog listed and DiveComputerKit drops (Docs/DECISIONS.md, Q4).
let droppedNonBLEModels: Set<String> = ["Oceanic Atom 3.1", "Sherwood Wisdom 3", "Mares Icon HD"]

struct CatalogConsistencyTests {

    /// Family raw values are persisted (`DeviceFingerprint.familyID`, Fingerprint XML,
    /// `com.libdc.storedDevices`). The old library's families stay first, unchanged and in
    /// order; new families may only be appended (Docs/ADDING_A_DIVE_COMPUTER.md, case C).
    /// Each libdivecomputer family maps to one case: `init?(dcFamily:)` silently takes the first.
    @Test func legacyFamiliesAreKept() {
        let problems = LegacyCatalogCheck.familyProblems(legacy: LegacyCatalog.shared.families,
                                                         current: DeviceFamily.allCases.map(\.rawValue))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        let dcFamilies = DeviceFamily.allCases.map { String($0.dcFamily.rawValue) }
        let shared = LegacyCatalogCheck.duplicates(dcFamilies)
        #expect(shared.isEmpty, "libdivecomputer families mapped by more than one case: \(shared.joined(separator: ", "))")
    }

    /// Names, families and model numbers are persisted (`Dive.computerName`,
    /// `DeviceFingerprint`, `com.libdc.storedDevices`, icons). Every model of the old
    /// catalog, minus the dropped non-BLE entries, is still listed with the same name,
    /// family and model number, in the same relative order, and each (family, model)
    /// still resolves to the same first name. New models may be added anywhere that keeps
    /// this (Docs/ADDING_A_DIVE_COMPUTER.md).
    @Test func legacyModelsAreKept() {
        let legacy = LegacyCatalog.shared.supportedModels
            .filter { !droppedNonBLEModels.contains($0.name) }
            .map { LegacyCatalogCheck.Entry(name: $0.name, family: $0.family, modelID: $0.modelID) }
        let current = DeviceCatalog.supportedModels
            .map { LegacyCatalogCheck.Entry(name: $0.name, family: $0.family.rawValue, modelID: $0.modelID) }
        let problems = LegacyCatalogCheck.modelProblems(legacy: legacy, current: current)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func namesAreUnique() {
        let names = DeviceCatalog.supportedModels.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// Every catalog model has a libdivecomputer descriptor with BLE.
    @Test func everyModelHasBLEDescriptor() {
        let ble = DescriptorLookup.all.filter(\.supportsBLE)
        for model in DeviceCatalog.supportedModels {
            let found = ble.contains { $0.family == model.family && $0.model == model.modelID }
            #expect(found, "\(model.name) (\(model.family), 0x\(String(model.modelID, radix: 16))) has no BLE descriptor")
        }
    }

    /// Every BLE descriptor of a supported family is in the catalog: the tripwire for
    /// devices added upstream (Sources/CLibDiveComputer/UPSTREAM.md, sync step 5).
    @Test func everyBLEDescriptorIsInCatalog() {
        for descriptor in DescriptorLookup.all where descriptor.supportsBLE {
            guard let family = descriptor.family else { continue }
            let found = DeviceCatalog.model(family: family, modelID: descriptor.model) != nil
            #expect(found, "\(descriptor.vendor) \(descriptor.product) (\(family), 0x\(String(descriptor.model, radix: 16))) is missing from DeviceCatalog")
        }
    }

    /// The old library's 14 service UUIDs are all still known (scan filter and service
    /// selection), compared case-insensitively; new UUIDs may be added; every entry is
    /// lowercased (`BLEServiceCatalog.isKnown` compares lowercased forms) and none is listed twice.
    @Test func legacyServiceUUIDsAreKept() {
        let legacy = LegacyCatalog.shared.knownServiceUUIDs
        #expect(legacy.count == 14)
        let current = BLEServiceCatalog.knownServiceUUIDStrings
        let notLowercased = current.filter { $0 != $0.lowercased() }
        #expect(notLowercased.isEmpty, "Not lowercased (BLEServiceCatalog.isKnown compares lowercased UUIDs): \(notLowercased.joined(separator: ", "))")
        let missing = LegacyCatalogCheck.missingUUIDs(legacy: legacy, current: current)
        #expect(missing.isEmpty, "Service UUIDs of the old catalog missing: \(missing.joined(separator: ", "))")
        let duplicates = LegacyCatalogCheck.duplicates(current.map { $0.lowercased() })
        #expect(duplicates.isEmpty, "Service UUIDs listed twice: \(duplicates.joined(separator: ", "))")
    }
}

/// The checks behind `legacyFamiliesAreKept`, `legacyModelsAreKept` and `legacyServiceUUIDsAreKept`, kept pure so
/// `LegacyCatalogCheckTests` can prove them with made-up catalogs.
enum LegacyCatalogCheck {

    struct Entry: Equatable, Sendable {
        let name: String
        let family: String
        let modelID: UInt32
    }

    /// One line per problem; empty when `legacy` is a subsequence of `current` (matched by
    /// name, with the same family and model) and every legacy (family, model) still resolves
    /// to the same first name (`DeviceCatalog.model(family:modelID:)` takes the first match).
    static func modelProblems(legacy: [Entry], current: [Entry]) -> [String] {
        var problems: [String] = []
        var positionByName: [String: Int] = [:]
        for (position, entry) in current.enumerated() where positionByName[entry.name] == nil {
            positionByName[entry.name] = position
        }
        var previous: (name: String, position: Int)?
        for old in legacy {
            guard let position = positionByName[old.name] else {
                problems.append("\"\(old.name)\" (\(old.family), 0x\(String(old.modelID, radix: 16))) is missing: removed or renamed")
                continue
            }
            let new = current[position]
            if new.family != old.family || new.modelID != old.modelID {
                problems.append("\"\(old.name)\" changed from (\(old.family), 0x\(String(old.modelID, radix: 16))) to (\(new.family), 0x\(String(new.modelID, radix: 16)))")
            }
            if let previous, position < previous.position {
                problems.append("\"\(old.name)\" moved before \"\(previous.name)\"; legacy models keep their relative order")
            } else {
                previous = (old.name, position)
            }
        }
        var checkedPairs = Set<String>()
        for old in legacy {
            let key = "\(old.family)/\(old.modelID)"
            guard checkedPairs.insert(key).inserted else { continue }
            if let first = current.first(where: { $0.family == old.family && $0.modelID == old.modelID }),
               first.name != old.name {
                problems.append("(\(old.family), 0x\(String(old.modelID, radix: 16))) now resolves to \"\(first.name)\" instead of \"\(old.name)\"; list a new sibling after it")
            }
        }
        return problems
    }

    /// One line per problem; empty when `legacy` is a prefix of `current` (the same raw
    /// values in the same order, new families appended after them) and no raw value is
    /// listed twice.
    static func familyProblems(legacy: [String], current: [String]) -> [String] {
        var problems: [String] = []
        for (position, old) in legacy.enumerated() {
            guard position < current.count else {
                problems.append("\"\(old)\" (position \(position)) is missing: removed")
                continue
            }
            let new = current[position]
            if new != old {
                problems.append("Position \(position) is \"\(new)\" instead of \"\(old)\"; legacy families keep their raw value and order, new ones are appended")
            }
        }
        for repeated in duplicates(current) {
            problems.append("\"\(repeated)\" is listed more than once")
        }
        return problems
    }

    /// The legacy UUIDs absent from `current`, case-insensitively.
    static func missingUUIDs(legacy: [String], current: [String]) -> [String] {
        let known = Set(current.map { $0.lowercased() })
        return legacy.filter { !known.contains($0.lowercased()) }
    }

    /// The values that appear more than once, in first-appearance order.
    static func duplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var repeated: [String] = []
        for value in values where !seen.insert(value).inserted && !repeated.contains(value) {
            repeated.append(value)
        }
        return repeated
    }
}

/// `LegacyCatalogCheck` with made-up catalogs: additions pass; removals, renames,
/// changes, reorders, shadowed model numbers, removed UUIDs and families not appended fail.
struct LegacyCatalogCheckTests {

    typealias Entry = LegacyCatalogCheck.Entry
    static let legacy: [Entry] = [
        Entry(name: "Vendor A One", family: "familyA", modelID: 1),
        Entry(name: "Vendor A Two", family: "familyA", modelID: 2),
        Entry(name: "Vendor A Two Plus", family: "familyA", modelID: 2),
        Entry(name: "Vendor B One", family: "familyB", modelID: 1)
    ]

    @Test func unchangedCatalogPasses() {
        #expect(LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: Self.legacy).isEmpty)
    }

    @Test func additionsAnywherePass() {
        var current = Self.legacy
        current.insert(Entry(name: "Vendor C One", family: "familyC", modelID: 1), at: 0)
        current.insert(Entry(name: "Vendor A Three", family: "familyA", modelID: 3), at: 3)
        current.append(Entry(name: "Vendor A Two Lite", family: "familyA", modelID: 2))
        #expect(LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current).isEmpty)
    }

    @Test func removedModelFails() {
        let current = Self.legacy.filter { $0.name != "Vendor A Two Plus" }
        let problems = LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("\"Vendor A Two Plus\"") == true)
    }

    @Test func renamedModelFails() {
        var current = Self.legacy
        current[3] = Entry(name: "Vendor B 1", family: "familyB", modelID: 1)
        let problems = LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current)
        #expect(problems.contains { $0.contains("\"Vendor B One\"") && $0.contains("missing") })
    }

    @Test func changedFamilyOrModelFails() {
        var current = Self.legacy
        current[0] = Entry(name: "Vendor A One", family: "familyB", modelID: 1)
        current[3] = Entry(name: "Vendor B One", family: "familyB", modelID: 9)
        let problems = LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current)
        #expect(problems.contains { $0.contains("\"Vendor A One\" changed") })
        #expect(problems.contains { $0.contains("\"Vendor B One\" changed") })
    }

    @Test func reorderedModelsFail() {
        var current = Self.legacy
        current.swapAt(0, 3)
        let problems = LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current)
        #expect(problems.contains { $0.contains("moved") })
    }

    @Test func newSiblingBeforeSharedModelNumberFails() {
        var current = Self.legacy
        current.insert(Entry(name: "Vendor A Two Lite", family: "familyA", modelID: 2), at: 1)
        let problems = LegacyCatalogCheck.modelProblems(legacy: Self.legacy, current: current)
        #expect(problems == ["(familyA, 0x2) now resolves to \"Vendor A Two Lite\" instead of \"Vendor A Two\"; list a new sibling after it"])
    }

    static let legacyFamilies = ["familyA", "familyB", "familyC"]

    @Test func unchangedFamiliesPass() {
        #expect(LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: Self.legacyFamilies).isEmpty)
    }

    @Test func appendedFamiliesPass() {
        let current = Self.legacyFamilies + ["familyD", "familyE"]
        #expect(LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current).isEmpty)
    }

    @Test func removedFamilyFails() {
        let current = ["familyA", "familyB"]
        let problems = LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current)
        #expect(problems == ["\"familyC\" (position 2) is missing: removed"])
    }

    @Test func renamedFamilyFails() {
        let current = ["familyA", "familyB2", "familyC"]
        let problems = LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("\"familyB2\" instead of \"familyB\"") == true)
    }

    @Test func reorderedFamiliesFail() {
        let current = ["familyB", "familyA", "familyC"]
        #expect(LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current).count == 2)
    }

    @Test func familyInsertedInTheMiddleFails() {
        let current = ["familyA", "familyD", "familyB", "familyC"]
        #expect(!LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current).isEmpty)
    }

    @Test func duplicateFamilyFails() {
        let current = Self.legacyFamilies + ["familyA"]
        let problems = LegacyCatalogCheck.familyProblems(legacy: Self.legacyFamilies, current: current)
        #expect(problems == ["\"familyA\" is listed more than once"])
    }

    @Test func serviceUUIDChecks() {
        let legacy = ["0000aaaa-0000-1000-8000-00805f9b34fb", "1234abcd-0000-0000-0000-000000000001"]
        #expect(LegacyCatalogCheck.missingUUIDs(legacy: legacy, current: legacy).isEmpty)
        #expect(LegacyCatalogCheck.missingUUIDs(legacy: legacy, current: legacy.map { $0.uppercased() }).isEmpty)
        #expect(LegacyCatalogCheck.missingUUIDs(legacy: legacy, current: legacy + ["5678ef00-0000-0000-0000-000000000002"]).isEmpty)
        #expect(LegacyCatalogCheck.missingUUIDs(legacy: legacy, current: [legacy[1]]) == [legacy[0]])
        #expect(LegacyCatalogCheck.duplicates(legacy + [legacy[0], legacy[0]]) == [legacy[0]])
        #expect(LegacyCatalogCheck.duplicates(legacy).isEmpty)
    }
}

struct NameResolutionTests {

    /// Names that resolved to a dropped non-BLE model in the old library.
    static let droppedResolutions: Set<String> = ["DV000001", "DX000001"]

    /// `resolve` gives the old library's result for every sample name.
    @Test(arguments: LegacyCatalog.shared.resolutions)
    func resolutionMatchesLegacy(_ sample: LegacyCatalog.Resolution) {
        let result = DeviceCatalog.resolve(advertisedName: sample.name)
        if Self.droppedResolutions.contains(sample.name) {
            #expect(result == nil, "\(sample.name) resolved to a dropped non-BLE model")
            return
        }
        #expect(result?.family.rawValue == sample.resolved?.family, "\(sample.name)")
        #expect(result?.modelID == sample.resolved?.modelID, "\(sample.name)")
    }

    /// `displayName` gives the old library's text for every sample name.
    @Test(arguments: LegacyCatalog.shared.resolutions)
    func displayNameMatchesLegacy(_ sample: LegacyCatalog.Resolution) {
        guard !Self.droppedResolutions.contains(sample.name) else { return }
        #expect(DeviceCatalog.displayName(forAdvertisedName: sample.name) == sample.displayName, "\(sample.name)")
    }
}

extension LegacyCatalog.Resolution: CustomTestStringConvertible {
    var testDescription: String { "\"\(name)\"" }
}

struct ServiceCatalogTests {
    /// CoreBluetooth reports Bluetooth-base UUIDs in their short form.
    @Test func shortServiceUUIDsMatchTheCatalog() {
        #expect(BLEServiceCatalog.isKnown("FEFB"))          // Heinrichs Weikamp Telit/Stollmann
        #expect(BLEServiceCatalog.isKnown("FCEF"))          // Divesoft Freedom
        #expect(BLEServiceCatalog.isKnown("0000FEFB-0000-1000-8000-00805F9B34FB"))
        #expect(!BLEServiceCatalog.isKnown("180A"))         // Device Information
        #expect(BLECharacteristicSelector.preferredService(among: ["1801", "FEFB"]) == "FEFB")
    }
}
