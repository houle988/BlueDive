import Foundation
import DiveComputerKit
import Testing
@testable import BlueDive

/// `DiveImportMapper` paths the parity fixtures (DiveImportMapperParityTests) do not reach:
/// the computer-name fallbacks, the "Filter unused tanks" setting, and a merge into a dive
/// the user has edited.
@MainActor
struct DiveImportMapperTests {

    private func context(family: DeviceFamily? = .oceanicAtom2, catalogName: String? = nil,
                         connectedName: String? = nil, filterUnusedTanks: Bool = false,
                         weightUnit: String = "lb") -> DiveImportContext {
        DiveImportContext(deviceFamily: family, catalogComputerName: catalogName, connectedDeviceName: connectedName,
                          computerSerial: "00001234", filterUnusedTanks: filterUnusedTanks, importWeightUnit: weightUnit)
    }

    /// An i300C-style dive: three configured gas mixes, only the first breathed, no tank data.
    private func threeMixDive() -> DiveData {
        var data = DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                            maxDepth: 18, avgDepth: 11, divetime: 2400, reportedDivetime: 2400, temperature: 12)
        data.gasMixes = [GasMix(helium: 0, oxygen: 0.32, nitrogen: 0.68, usage: .none),
                         GasMix(helium: 0, oxygen: 0.21, nitrogen: 0.79, usage: .none),
                         GasMix(helium: 0, oxygen: 0.50, nitrogen: 0.50, usage: .none)]
        data.gasMix = 0
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0),
                        ProfileSample(time: 600, depth: 18),
                        ProfileSample(time: 2400, depth: 0)]
        return data
    }

    // MARK: Computer name and import settings

    @Test func newDiveTakesTheCatalogNameThenTheConnectedNameThenTheDefault() {
        let data = threeMixDive()
        let catalog = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                                context: context(catalogName: "Aqualung i300C", connectedName: "FH021857"))
        #expect(catalog.computerName == "Aqualung i300C")
        let connected = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                                  context: context(connectedName: "FH021857"))
        #expect(connected.computerName == "FH021857")
        let unknown = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                                context: context())
        #expect(unknown.computerName == NSLocalizedString("dive.computer.default_ble_name",
                                                          comment: "Fallback name for an unknown Bluetooth dive computer"))
    }

    @Test func newDiveStoresTheSerialAndTheWeightUnitFromTheContext() {
        let dive = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 7, previousDiveEndTime: nil, diverName: "Test Diver",
                                             context: context(weightUnit: "kg"))
        #expect(dive.computerSerialNumber == "00001234")
        #expect(dive.importWeightUnit == "kg")
        #expect(dive.diveNumber == 7 && dive.diverName == "Test Diver")
        #expect(dive.sourceImport == "Bluetooth")
    }

    @Test func mergeKeepsTheExistingNameWhenNoneIsKnown() {
        let dive = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context(catalogName: "Aqualung i300C"))
        dive.computerName = "My i300C"
        DiveImportMapper.merge(threeMixDive(), into: dive, context: context())
        #expect(dive.computerName == "My i300C")
        DiveImportMapper.merge(threeMixDive(), into: dive, context: context(connectedName: "FH021857"))
        #expect(dive.computerName == "FH021857")
        DiveImportMapper.merge(threeMixDive(), into: dive, context: context(catalogName: "Aqualung i300C", connectedName: "FH021857"))
        #expect(dive.computerName == "Aqualung i300C")
    }

    // MARK: Filter unused tanks

    @Test func unusedGasMixesAreDroppedOnlyWhenTheSettingIsOn() {
        let all = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                            context: context(filterUnusedTanks: false))
        #expect(all.tanks.map(\.o2) == [0.32, 0.21, 0.50])
        let used = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context(filterUnusedTanks: true))
        #expect(used.tanks.map(\.o2) == [0.32])
    }

    @Test func theFilterAppliesOnlyToFamiliesWhoseParserKeepsUnusedMixes() {
        // Shearwater's parser already reports only the gases in use: nothing is dropped.
        let shearwater = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                                   context: context(family: .shearwaterPetrel, filterUnusedTanks: true))
        #expect(shearwater.tanks.count == 3)
        // An unknown family is filtered, as before.
        let unknown = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                                context: context(family: nil, filterUnusedTanks: true))
        #expect(unknown.tanks.count == 1)
    }

    @Test func mergeAppliesTheFilterToo() {
        let dive = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context(filterUnusedTanks: false))
        #expect(dive.tanks.count == 3)
        DiveImportMapper.merge(threeMixDive(), into: dive, context: context(filterUnusedTanks: true))
        #expect(dive.tanks.map(\.o2) == [0.32])
    }

    // MARK: Merge into an edited dive

    @Test func mergeKeepsWhatTheUserEnteredAndTheComputerDoesNotProvide() {
        let dive = DiveImportMapper.makeDive(from: threeMixDive(), diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        dive.tanks = dive.tanks.map {
            TankData(o2: $0.o2, he: $0.he, volume: 11.1, workingPressure: 207, tankMaterial: "Aluminum", tankType: "Single")
        }
        dive.airTemperature = 25
        dive.surfacePressure = 0.98
        dive.notes = "Great visibility"
        dive.rating = 4

        var redownload = threeMixDive()
        redownload.measuredSurfaceTemperature = 18      // must not replace the user's air temperature
        redownload.atmospheric = nil                    // no reading: the stored one is kept
        DiveImportMapper.merge(redownload, into: dive, context: context())

        #expect(dive.tanks.count == 3)
        #expect(dive.tanks.allSatisfy {
            $0.volume == 11.1 && $0.workingPressure == 207 && $0.tankMaterial == "Aluminum" && $0.tankType == "Single"
        })
        #expect(dive.airTemperature == 25)
        #expect(dive.surfacePressure == 0.98)
        #expect(dive.notes == "Great visibility" && dive.rating == 4)
    }
}
