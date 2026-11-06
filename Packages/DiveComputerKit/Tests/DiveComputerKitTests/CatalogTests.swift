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

    @Test func familyRawValuesUnchanged() {
        #expect(DeviceFamily.allCases.map(\.rawValue) == LegacyCatalog.shared.families)
    }

    /// Names, families and model numbers are persisted: identical to the old catalog,
    /// minus the dropped non-BLE entries, in the same order.
    @Test func modelsMatchLegacyCatalog() {
        let legacy = LegacyCatalog.shared.supportedModels.filter { !droppedNonBLEModels.contains($0.name) }
        let current = DeviceCatalog.supportedModels
        #expect(current.count == legacy.count)
        for (new, old) in zip(current, legacy) {
            #expect(new.name == old.name)
            #expect(new.family.rawValue == old.family, "\(new.name)")
            #expect(new.modelID == old.modelID, "\(new.name)")
        }
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

    @Test func serviceUUIDsUnchanged() {
        #expect(BLEServiceCatalog.knownServiceUUIDStrings == LegacyCatalog.shared.knownServiceUUIDs)
        #expect(BLEServiceCatalog.knownServiceUUIDs.count == 14)
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
