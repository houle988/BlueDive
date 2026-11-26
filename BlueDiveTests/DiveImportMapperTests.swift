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

    private func merged(_ data: DiveData, firstFilter: Bool = false, mergeFilter: Bool = false) -> (before: [UUID], after: [UUID]) {
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context(filterUnusedTanks: firstFilter))
        let before = dive.tanks.map(\.id)
        DiveImportMapper.merge(data, into: dive, context: context(filterUnusedTanks: mergeFilter))
        return (before, dive.tanks.map(\.id))
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
        #expect(unknown.computerName == NSLocalizedString("Dive Computer", bundle: Bundle.forAppLanguage(), value: "Dive Computer",
                                                          comment: "Fallback name for an unknown Bluetooth dive computer"))
        // A translated name, never a raw catalog key.
        #expect(!unknown.computerName.isEmpty && !unknown.computerName.contains("."))
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
        let ids = dive.tanks.map(\.id)
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
        #expect(dive.tanks.map(\.id) == ids)
        #expect(dive.airTemperature == 25)
        #expect(dive.surfacePressure == 0.98)
        #expect(dive.notes == "Great visibility" && dive.rating == 4)
    }

    // MARK: Tank identity on a re-download

    @Test func mergeKeepsTankIDsForComputerTanks() {
        var data = threeMixDive()
        data.tanks = [DiveData.Tank(volume: 11.1, workingPressure: 207, beginPressure: 200, endPressure: 60,
                                    gasMix: 0, usage: .none)]
        let ids = merged(data)
        #expect(!ids.before.isEmpty && ids.after == ids.before)
    }

    @Test func mergeKeepsTheTankIDForTankPressureOnly() {
        var data = threeMixDive()
        data.gasMixes = nil
        data.tankPressure = [200, 180, 120]
        let ids = merged(data)
        #expect(ids.before.count == 1 && ids.after == ids.before)
    }

    @Test func mergeKeepsTankIDsForGasMixesOnly() {
        let ids = merged(threeMixDive())
        #expect(ids.before.count == 3 && ids.after == ids.before)
    }

    @Test func mergeKeepsTheTankIDForASingleNonAirGas() {
        var data = threeMixDive()
        data.gasMixes = nil
        data.gasMix = 32
        let ids = merged(data)
        #expect(ids.before.count == 1 && ids.after == ids.before)
    }

    /// The id follows the tank at the same position, like the user's tank details: switching
    /// "Filter unused tanks" between downloads keeps the first tank's id and gives any added
    /// tank a new one.
    @Test func mergeKeepsIDsByPositionWhenTheTankCountChanges() {
        let fewer = merged(threeMixDive(), firstFilter: false, mergeFilter: true)
        #expect(fewer.before.count == 3 && fewer.after == [fewer.before[0]])
        let more = merged(threeMixDive(), firstFilter: true, mergeFilter: false)
        #expect(more.before.count == 1 && more.after.count == 3 && more.after[0] == more.before[0])
        #expect(Set(more.after).count == 3)
    }

    // MARK: Gas mixes that could not be read

    /// Mix 1 of three could not be read: `gasMixes` holds field mixes 0 and 2. A sample on
    /// field mix 2 must reach the 50 % mix, never another one.
    @Test func gasReferencesSkipAMixThatCouldNotBeRead() {
        var data = threeMixDive()
        data.gasMixes = [GasMix(helium: 0, oxygen: 0.32, nitrogen: 0.68, usage: .none),
                         GasMix(helium: 0, oxygen: 0.50, nitrogen: 0.50, usage: .none)]
        data.gasMixFieldIndices = [0, 2]
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0),
                        ProfileSample(time: 600, depth: 18, currentGas: 2),
                        ProfileSample(time: 1200, depth: 10, currentGas: 1),   // the unreadable mix
                        ProfileSample(time: 2400, depth: 0)]
        data.gasMix = 2
        let byPosition = DiveImportMapper.gasMixReferencesByPosition(data)
        #expect(byPosition.profile.map(\.currentGas) == [0, 1, nil, nil])
        #expect(byPosition.gasMix == 1)
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        #expect(dive.tanks.map(\.o2) == [0.32, 0.50])
        // The stored profile follows the translation: field mix 2 is tank 1, the unreadable
        // mix is no tank (without it, field mix 1 would land on the 50 % tank).
        #expect(dive.profileSamples.map(\.currentGas) == [0, 1, nil, nil])
        // A re-download merges through the same translation.
        DiveImportMapper.merge(data, into: dive, context: context())
        #expect(dive.tanks.map(\.o2) == [0.32, 0.50])
        #expect(dive.profileSamples.map(\.currentGas) == [0, 1, nil, nil])
    }

    /// A tank on the unreadable mix gets the no-gas-data default, never another mix's gas.
    @Test func aTankOnAnUnreadableMixBorrowsNoOtherGas() {
        var data = threeMixDive()
        data.gasMixes = [GasMix(helium: 0, oxygen: 0.32, nitrogen: 0.68, usage: .none),
                         GasMix(helium: 0, oxygen: 0.50, nitrogen: 0.50, usage: .none)]
        data.gasMixFieldIndices = [0, 2]
        data.tanks = (0..<3).map {
            DiveData.Tank(volume: 11.1, workingPressure: 207, beginPressure: 200, endPressure: 60, gasMix: $0, usage: .none)
        }
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        #expect(dive.tanks.map(\.o2) == [0.32, 0.21, 0.50])
    }

    /// A switch to the unreadable mix ends the previous tank's usage window (its RMV/SAC
    /// would otherwise be spread over time it was not breathed).
    @Test func aSwitchToAnUnreadableMixEndsTheUsageWindow() {
        var data = threeMixDive()
        data.gasMixes = [GasMix(helium: 0, oxygen: 0.32, nitrogen: 0.68, usage: .none),
                         GasMix(helium: 0, oxygen: 0.50, nitrogen: 0.50, usage: .none)]
        data.gasMixFieldIndices = [0, 2]
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0),
                        ProfileSample(time: 600, depth: 18, events: [.gasChange], currentGas: 2),
                        ProfileSample(time: 1200, depth: 10, events: [.gasChange], currentGas: 1),
                        ProfileSample(time: 2400, depth: 0)]
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        #expect(dive.tanks.count == 2)
        #expect(dive.tanks[0].usageStartTime == 0 && dive.tanks[0].usageEndTime == 600)
        #expect(dive.tanks[1].usageStartTime == 600 && dive.tanks[1].usageEndTime == 1200)
    }

    /// Every mix read: a gas change without a gas is ignored, as before (the window of the
    /// starting tank still covers the whole dive).
    @Test func aSwitchWithoutAGasChangesNothingWhenEveryMixWasRead() {
        var data = threeMixDive()
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0),
                        ProfileSample(time: 1200, depth: 10, events: [.gasChange]),
                        ProfileSample(time: 2400, depth: 0)]
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        #expect(dive.tanks[0].usageStartTime == 0 && dive.tanks[0].usageEndTime == 2400)
    }

    @Test func gasReferencesAreUnchangedWhenEveryMixWasRead() {
        let data = threeMixDive()
        let same = DiveImportMapper.gasMixReferencesByPosition(data)
        #expect(same.profile.map(\.currentGas) == data.profile.map(\.currentGas))
        #expect(same.gasMix == data.gasMix)
    }

    // MARK: Dive type

    @Test func aDiveWithoutAReportedModeGetsNoDiveType() {
        var data = threeMixDive()
        data.diveMode = nil
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context())
        #expect(dive.diveTypes == nil)
        data.diveMode = .closedCircuit
        #expect(DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                          context: context()).diveTypes == "Rebreather")
    }

    // MARK: CCR diluent / oxygen tank formats

    /// A CCR dive: a diluent and an oxygen cylinder, both on transmitters.
    private func ccrDive(tankUsage: [GasUsage], mixUsage: [GasUsage]) -> DiveData {
        var data = DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                            maxDepth: 30, avgDepth: 18, divetime: 3600, reportedDivetime: 3600, temperature: 10)
        data.gasMixes = [GasMix(helium: 0, oxygen: 0.21, nitrogen: 0.79, usage: mixUsage[0]),
                         GasMix(helium: 0, oxygen: 1.0, nitrogen: 0, usage: mixUsage[1])]
        data.gasMix = 0
        data.tanks = [DiveData.Tank(volume: 3, workingPressure: 200, beginPressure: 200, endPressure: 150, gasMix: 0, usage: tankUsage[0]),
                      DiveData.Tank(volume: 3, workingPressure: 200, beginPressure: 200, endPressure: 140, gasMix: 1, usage: tankUsage[1])]
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0),
                        ProfileSample(time: 1200, depth: 30),
                        ProfileSample(time: 3600, depth: 0)]
        return data
    }

    @Test func computerDiluentAndOxygenTanksGetTheirFormat() {
        let dive = DiveImportMapper.makeDive(from: ccrDive(tankUsage: [.diluent, .oxygen], mixUsage: [.none, .none]),
                                             diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        #expect(dive.tanks.map(\.tankType) == ["Diluent", "O2"])
        #expect(dive.tanks.allSatisfy { $0.isExcludedFromRMV })
    }

    /// The computer reports each tank's gas (Divesoft flags only the mix): the mix's flag is used.
    @Test func tankFormatFallsBackToTheGasMixUsage() {
        let dive = DiveImportMapper.makeDive(from: ccrDive(tankUsage: [.none, .none], mixUsage: [.diluent, .oxygen]),
                                             diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        #expect(dive.tanks.map(\.tankType) == ["Diluent", "O2"])
    }

    /// Shearwater reports no gas for its transmitters, so tanks are matched to mixes by
    /// pressure inference or position; such a guessed match must not give a tank the mix's
    /// diluent flag (e.g. an unflagged bailout transmitter landing on the diluent).
    @Test func aGuessedGasMatchGivesNoFormat() {
        var data = ccrDive(tankUsage: [.none, .none], mixUsage: [.none, .diluent])
        let unknown = Int(UInt32.max)    // DC_GASMIX_UNKNOWN
        data.tanks = data.tanks?.map {
            DiveData.Tank(volume: $0.volume, workingPressure: $0.workingPressure, beginPressure: $0.beginPressure,
                          endPressure: $0.endPressure, gasMix: unknown, usage: $0.usage)
        }
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                             context: context(family: .shearwaterPetrel))
        #expect(dive.tanks.prefix(2).map(\.tankType) == [nil, nil])
        #expect(dive.tanks.prefix(2).allSatisfy { !$0.isExcludedFromRMV })
    }

    @Test func openCircuitAndSidemountTanksKeepNoFormat() {
        let dive = DiveImportMapper.makeDive(from: ccrDive(tankUsage: [.none, .sidemount], mixUsage: [.none, .none]),
                                             diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        #expect(dive.tanks.map(\.tankType) == [nil, nil])
    }

    @Test func gasOnlyTanksGetTheMixUsageFormat() {
        var data = ccrDive(tankUsage: [.none, .none], mixUsage: [.diluent, .oxygen])
        data.tanks = nil
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        #expect(dive.tanks.map(\.tankType) == ["Diluent", "O2"])
    }

    @Test func mergeKeepsTheUserFormatAndFillsAnUnsetOne() {
        let data = ccrDive(tankUsage: [.diluent, .oxygen], mixUsage: [.none, .none])
        let dive = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        dive.tanks = [TankData(id: dive.tanks[0].id, o2: 0.21, he: 0, tankType: "Single tank"),
                      TankData(id: dive.tanks[1].id, o2: 1.0, he: 0, tankType: nil)]
        DiveImportMapper.merge(data, into: dive, context: context())
        #expect(dive.tanks.map(\.tankType) == ["Single tank", "O2"])
    }

    /// "CCR" is the Garmin FIT import's former value for a diluent.
    @Test func excludedFromRMVMatchesDrysuitAndCCRFormatsOnly() {
        let excluded = ["Drysuit", "Diluent", "O2", "CCR", "drysuit"].map { TankData(tankType: $0).isExcludedFromRMV }
        let counted = [nil, "Single tank", "Twinset", "Sidemount", "Pony", "Rebreather", "Other"]
            .map { TankData(tankType: $0).isExcludedFromRMV }
        #expect(excluded.allSatisfy { $0 })
        #expect(counted.allSatisfy { !$0 })
    }

    // MARK: Shearwater CCR gases

    /// A Shearwater dive: mixes, transmitters (all DC_GASMIX_UNKNOWN, as Shearwater reports
    /// them) and a profile of (seconds, gas mix breathed from that sample, pressure per tank).
    private func shearwaterDive(mixes: [(o2: Double, he: Double, usage: GasUsage)],
                                tanks: [(usage: GasUsage, begin: Double, end: Double)],
                                profile: [(time: Double, gas: Int?, pressures: [Int: Double])]) -> DiveData {
        var data = DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                            maxDepth: 30, avgDepth: 18, divetime: 2500, reportedDivetime: 2500, temperature: 10)
        data.gasMixes = mixes.map { GasMix(helium: $0.he, oxygen: $0.o2, nitrogen: 1 - $0.o2 - $0.he, usage: $0.usage) }
        data.tanks = tanks.map {
            DiveData.Tank(volume: 0, workingPressure: 0, beginPressure: $0.begin, endPressure: $0.end,
                          gasMix: Int(UInt32.max), usage: $0.usage)
        }
        data.profile = profile.map {
            ProfileSample(time: $0.time, depth: $0.time == 0 || $0.time == profile.last?.time ? 0 : 25,
                          pressures: $0.pressures, events: $0.gas != nil && $0.time > 0 ? [.gasChange] : [],
                          currentGas: $0.gas)
        }
        return data
    }

    /// The observed case: an OC bailout listed first, the diluent second, an O₂ and a diluent
    /// transmitter; the diluent breathed all dive.
    private func ccrWithBailout(o2Drop: Double = 5.4, diluentDrop: Double = 22.2) -> DiveData {
        shearwaterDive(
            mixes: [(0.29, 0, .none), (0.21, 0.22, .diluent)],
            tanks: [(.oxygen, 220, 220 - o2Drop), (.diluent, 204.5, 204.5 - diluentDrop)],
            profile: [(0, 1, [0: 220, 1: 204.5]),
                      (800, nil, [0: 220 - o2Drop / 3, 1: 204.5 - diluentDrop / 3]),
                      (1600, nil, [0: 220 - o2Drop * 2 / 3, 1: 204.5 - diluentDrop * 2 / 3]),
                      (2500, nil, [0: 220 - o2Drop, 1: 204.5 - diluentDrop])])
    }

    private func shearwaterDiveFrom(_ data: DiveData) -> Dive {
        DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                  context: context(family: .shearwaterPetrel))
    }

    @Test func aShearwaterCCROxygenTransmitterIsPureOxygenAndTheBailoutGetsItsOwnTank() {
        let dive = shearwaterDiveFrom(ccrWithBailout())

        #expect(dive.tanks.count == 3)
        #expect(dive.tanks.map(\.tankType) == ["O2", "Diluent", nil])
        // Oxygen supply: pure oxygen, its own pressures, never breathed in the profile.
        #expect(dive.tanks[0].o2 == 1.0 && dive.tanks[0].he == 0 && dive.tanks[0].gasName == "Oxygen")
        #expect(dive.tanks[0].startPressure == 220 && dive.tanks[0].usageStartTime == nil)
        // Diluent on the diluent transmitter.
        #expect(dive.tanks[1].o2 == 0.21 && dive.tanks[1].he == 0.22 && dive.tanks[1].startPressure == 204.5)
        #expect(dive.tanks[1].usageStartTime == 0)
        // The bailout: gas-only, no pressures, no format.
        #expect(dive.tanks[2].o2 == 0.29 && dive.tanks[2].startPressure == nil && dive.tanks[2].usageStartTime == nil)
        #expect(dive.profileSamples.compactMap(\.currentGas).allSatisfy { $0 == 1 })
    }

    @Test func theDiluentStaysOnTheDiluentTransmitterWhenTheOxygenDropsMore() {
        let dive = shearwaterDiveFrom(ccrWithBailout(o2Drop: 30, diluentDrop: 4))
        #expect(dive.tanks.map(\.o2) == [1.0, 0.21, 0.29])
        #expect(dive.tanks[1].startPressure == 204.5)
    }

    @Test func aBailoutSwitchOpensTheBailoutTanksWindow() {
        let data = shearwaterDive(
            mixes: [(0.29, 0, .none), (0.21, 0.22, .diluent)],
            tanks: [(.oxygen, 220, 214), (.diluent, 204, 190)],
            profile: [(0, 1, [0: 220, 1: 204]), (1200, nil, [0: 217, 1: 195]),
                      (1500, 0, [0: 216, 1: 190]), (2500, nil, [0: 214, 1: 190])])
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [1.0, 0.21, 0.29])
        #expect(dive.tanks[0].usageStartTime == nil)
        #expect(dive.tanks[1].usageStartTime == 0 && dive.tanks[1].usageEndTime == 1500)
        #expect(dive.tanks[2].usageStartTime == 1500)
    }

    /// Both diluents are breathed while the one diluent transmitter drops, so the inference
    /// finds no distinct match (both mixes point at it) and the transmitter takes the first
    /// diluent breathed (18/45); the other becomes a gas-only "Diluent" tank. Never the O₂ supply.
    @Test func oneDiluentTransmitterTakesTheFirstDiluentBreathed() {
        let data = shearwaterDive(
            mixes: [(0.21, 0, .diluent), (0.18, 0.45, .diluent)],
            tanks: [(.oxygen, 200, 190), (.diluent, 200, 185)],
            profile: [(0, 1, [0: 200, 1: 200]), (1200, 0, [0: 195, 1: 192]), (2500, nil, [0: 190, 1: 185])])
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [1.0, 0.18, 0.21])
        #expect(dive.tanks[2].tankType == "Diluent" && dive.tanks[2].startPressure == nil)
    }

    /// The diluent breathed first leaves the transmitter flat; the one breathed second drops it
    /// 15 bar: the inference restricted to the diluents decides (profile order would not).
    @Test func theDiluentInferenceDecidesWhichDiluentIsOnTheTransmitter() {
        let data = shearwaterDive(
            mixes: [(0.21, 0, .diluent), (0.18, 0.45, .diluent)],
            tanks: [(.oxygen, 200, 190), (.diluent, 200, 185)],
            profile: [(0, 1, [0: 200, 1: 200]), (600, nil, [0: 197, 1: 200]), (1200, 0, [0: 195, 1: 200]),
                      (1800, nil, [0: 192, 1: 192]), (2500, nil, [0: 190, 1: 185])])
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [1.0, 0.21, 0.18])
        #expect(dive.tanks[1].usageStartTime == 1200)
        #expect(dive.tanks[2].tankType == "Diluent" && dive.tanks[2].startPressure == nil)
    }

    /// HP-CCR order (regular transmitters first, then diluent, then O₂) with two bailout
    /// transmitters: the inference restricted to the open-circuit gases puts each bailout on the
    /// transmitter that drops while it is breathed, against the list and profile order. Without
    /// the restriction the diluent's drop during the air bailout would win.
    @Test func theBailoutInferenceDecidesEachBailoutTransmitter() {
        let data = shearwaterDive(
            mixes: [(0.50, 0, .none), (0.21, 0, .none), (0.18, 0.45, .diluent)],
            tanks: [(.none, 200, 190), (.none, 200, 184), (.diluent, 200, 160), (.oxygen, 200, 190)],
            profile: [(0, 2, [0: 200, 1: 200, 2: 200, 3: 200]),
                      (600, nil, [0: 200, 1: 200, 2: 194, 3: 197]),
                      (1200, 1, [0: 200, 1: 200, 2: 188, 3: 194]),
                      (1600, nil, [0: 200, 1: 192, 2: 175, 3: 192]),
                      (2000, 0, [0: 200, 1: 184, 2: 162, 3: 190]),
                      (2500, nil, [0: 190, 1: 184, 2: 160, 3: 190])])
        let dive = shearwaterDiveFrom(data)

        #expect(dive.tanks.map(\.o2) == [0.50, 0.21, 0.18, 1.0])
        #expect(dive.tanks.map(\.tankType) == [nil, nil, "Diluent", "O2"])
        // Usage times go through the profile's minutes, so compare to the second.
        func seconds(_ value: Double?) -> Int? { value.map { Int($0.rounded()) } }
        #expect(seconds(dive.tanks[2].usageStartTime) == 0 && seconds(dive.tanks[2].usageEndTime) == 1200)
        #expect(seconds(dive.tanks[1].usageStartTime) == 1200 && seconds(dive.tanks[1].usageEndTime) == 2000)
        #expect(seconds(dive.tanks[0].usageStartTime) == 2000)
        #expect(dive.tanks[3].usageStartTime == nil)

        // A re-download with the O₂ transmitter last changes nothing.
        let ids = dive.tanks.map(\.id)
        DiveImportMapper.merge(data, into: dive, context: context(family: .shearwaterPetrel))
        #expect(dive.tanks.map(\.o2) == [0.50, 0.21, 0.18, 1.0])
        #expect(dive.tanks.map(\.id) == ids)
    }

    /// No diluent listed (e.g. an HP-CCR unit logged in open circuit, where libdivecomputer drops
    /// the diluents but keeps the slot flags): the diluent transmitter gets the no-data 21 %,
    /// never an open-circuit gas, and the open-circuit gases become gas-only tanks.
    @Test func aDiluentTransmitterWithoutADiluentGetsNoOtherGroupsGas() {
        let data = shearwaterDive(
            mixes: [(0.32, 0, .none), (0.50, 0, .none)],
            tanks: [(.oxygen, 200, 190), (.diluent, 200, 180)],
            profile: [(0, 0, [0: 200, 1: 200]), (2500, nil, [0: 190, 1: 180])])
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [1.0, 0.21, 0.32, 0.50])
        #expect(dive.tanks.map(\.tankType) == ["O2", "Diluent", nil, nil])
        #expect(dive.tanks[2].startPressure == nil && dive.tanks[3].startPressure == nil)
    }

    @Test func everyOxygenTransmitterIsPureOxygenWithNoUsageWindow() {
        let data = shearwaterDive(
            mixes: [(0.21, 0.22, .diluent)],
            tanks: [(.oxygen, 200, 190), (.oxygen, 200, 195), (.diluent, 200, 180)],
            profile: [(0, 0, [0: 200, 1: 200, 2: 200]), (2500, nil, [0: 190, 1: 195, 2: 180])])
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [1.0, 1.0, 0.21])
        #expect(dive.tanks[0].usageStartTime == nil && dive.tanks[1].usageStartTime == nil)
        #expect(dive.tanks[2].usageStartTime == 0)
    }

    /// Open circuit: no flagged transmitter, so the existing pressure inference still decides
    /// (here the second transmitter is on the first gas).
    @Test func anOpenCircuitShearwaterDiveIsUnchanged() {
        // Air breathed to 1300 s from the second transmitter (−4 bar per 100 s), then EAN50
        // from the first (−2.5 bar per 100 s).
        let profile = stride(from: 0.0, through: 2500, by: 100).map { t -> (time: Double, gas: Int?, pressures: [Int: Double]) in
            let onAir = min(t, 1300) / 100, onNitrox = max(t - 1300, 0) / 100
            return (t, t == 0 ? 0 : t == 1300 ? 1 : nil, [0: 200 - 2.5 * onNitrox, 1: 210 - 4 * onAir])
        }
        let data = shearwaterDive(mixes: [(0.21, 0, .none), (0.50, 0, .none)],
                                  tanks: [(.none, 200, 170), (.none, 210, 158)], profile: profile)
        let dive = shearwaterDiveFrom(data)
        #expect(dive.tanks.map(\.o2) == [0.50, 0.21])
        #expect(dive.tanks.map(\.tankType) == [nil, nil])
    }

    @Test func aReDownloadCorrectsTheOxygenTankButKeepsAUsersNearPureOxygen() {
        let data = ccrWithBailout()
        let stored = shearwaterDiveFrom(data)
        let ids = stored.tanks.map(\.id)
        func withFirstTankGas(_ o2: Double) {
            stored.tanks = stored.tanks.enumerated().map { i, t in
                TankData(id: t.id, o2: i == 0 ? o2 : t.o2, he: t.he, volume: t.volume, startPressure: t.startPressure,
                         endPressure: t.endPressure, tankType: t.tankType)
            }
        }
        withFirstTankGas(0.29)   // as an earlier version stored it
        DiveImportMapper.merge(data, into: stored, context: context(family: .shearwaterPetrel))
        #expect(stored.tanks[0].o2 == 1.0)
        #expect(stored.tanks.map(\.id) == ids)

        withFirstTankGas(0.995)  // set by the user
        DiveImportMapper.merge(data, into: stored, context: context(family: .shearwaterPetrel))
        #expect(stored.tanks[0].o2 == 0.995)
    }

    /// A CCR dive stored by an earlier version, which put the bailout gas on the O₂ transmitter
    /// and kept a second diluent as a gas-only tank the user then described. The re-download adds
    /// the bailout as a gas-only tank before that diluent; each stored tank's id and details must
    /// stay with its own gas, not move to the tank now at its position.
    @Test func aReDownloadKeepsEachGasOnlyTanksDetailsWithItsGas() {
        let data = shearwaterDive(
            mixes: [(0.29, 0, .none), (0.21, 0.22, .diluent), (0.10, 0.70, .diluent)],
            tanks: [(.oxygen, 220, 214), (.diluent, 204, 182)],
            profile: [(0, 1, [0: 220, 1: 204]), (1200, nil, [0: 218, 1: 196]), (2500, nil, [0: 214, 1: 182])])
        let dive = shearwaterDiveFrom(data)
        // As the earlier version stored it, with the user's details on every tank.
        let oxygenID = UUID(), diluentID = UUID(), secondDiluentID = UUID()
        dive.tanks = [
            TankData(id: oxygenID, o2: 0.29, he: 0, volume: 3, startPressure: 220, endPressure: 214, tankMaterial: "Steel"),
            TankData(id: diluentID, o2: 0.21, he: 0.22, volume: 3, startPressure: 204, endPressure: 182, tankMaterial: "Aluminium"),
            TankData(id: secondDiluentID, o2: 0.10, he: 0.70, volume: 2, tankMaterial: "Carbon", tankType: "Diluent"),
        ]

        DiveImportMapper.merge(data, into: dive, context: context(family: .shearwaterPetrel))

        let byGas = Dictionary(dive.tanks.map { ("\($0.o2Percentage)/\($0.hePercentage)", $0) }, uniquingKeysWith: { first, _ in first })
        #expect(dive.tanks.count == 4)
        #expect(byGas["100/0"]?.id == oxygenID && byGas["100/0"]?.tankMaterial == "Steel")
        #expect(byGas["21/22"]?.id == diluentID && byGas["21/22"]?.tankMaterial == "Aluminium")
        // The second diluent keeps its id and details; the new bailout gets none of them.
        #expect(byGas["10/70"]?.id == secondDiluentID && byGas["10/70"]?.tankMaterial == "Carbon")
        #expect(byGas["10/70"]?.volume == 2 && byGas["10/70"]?.tankType == "Diluent")
        #expect(byGas["29/0"]?.tankMaterial == nil && byGas["29/0"]?.tankType == nil && byGas["29/0"]?.volume == nil)
        #expect(byGas["29/0"].map { [oxygenID, diluentID, secondDiluentID].contains($0.id) } == false)
    }

    /// One transmitter on the first mix, the other mixes gas-only (not a Shearwater, so the mix
    /// the computer names for the transmitter is used).
    private func oneTransmitterDive(mixes: [(o2: Double, he: Double)]) -> DiveData {
        var data = DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                            maxDepth: 40, avgDepth: 22, divetime: 3000, reportedDivetime: 3000, temperature: 10)
        data.gasMixes = mixes.map { GasMix(helium: $0.he, oxygen: $0.o2, nitrogen: 1 - $0.o2 - $0.he, usage: .none) }
        data.gasMix = 0
        data.tanks = [DiveData.Tank(volume: 11, workingPressure: 232, beginPressure: 200, endPressure: 80, gasMix: 0, usage: .none)]
        data.profile = [ProfileSample(time: 0, depth: 0, currentGas: 0), ProfileSample(time: 1500, depth: 40),
                        ProfileSample(time: 3000, depth: 0)]
        return data
    }

    /// Two gas-only tanks with the same gas keep their ids and details in order, also when the
    /// re-download lists a new gas before them.
    @Test func sameGasOnlyTanksKeepTheirDetailsInOrder() {
        let stored = DiveImportMapper.makeDive(from: oneTransmitterDive(mixes: [(0.32, 0), (0.50, 0), (0.50, 0)]),
                                               diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        let firstID = stored.tanks[1].id, secondID = stored.tanks[2].id
        stored.tanks = stored.tanks.enumerated().map { i, t in
            TankData(id: t.id, o2: t.o2, he: t.he, volume: t.volume, startPressure: t.startPressure, endPressure: t.endPressure,
                     tankMaterial: i == 1 ? "First" : i == 2 ? "Second" : nil)
        }
        DiveImportMapper.merge(oneTransmitterDive(mixes: [(0.32, 0), (0.21, 0), (0.50, 0), (0.50, 0)]), into: stored, context: context())
        #expect(stored.tanks.map(\.o2Percentage) == [32, 21, 50, 50])
        #expect(stored.tanks[2].id == firstID && stored.tanks[2].tankMaterial == "First")
        #expect(stored.tanks[3].id == secondID && stored.tanks[3].tankMaterial == "Second")
        #expect(stored.tanks[1].tankMaterial == nil && ![firstID, secondID].contains(stored.tanks[1].id))
    }

    /// A gas-only tank whose gas the user edited (50 → 49 %) still keeps its id and details: no
    /// stored tank has the downloaded gas, so it takes the leftover stored gas-only tank.
    @Test func anEditedGasOnlyTankKeepsItsDetailsThroughTheLeftoverFallback() {
        let data = oneTransmitterDive(mixes: [(0.32, 0), (0.50, 0), (0.21, 0.35)])
        let stored = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "", context: context())
        let ids = stored.tanks.map(\.id)
        stored.tanks = stored.tanks.enumerated().map { i, t in
            TankData(id: t.id, o2: i == 1 ? 0.49 : t.o2, he: t.he, volume: i == 1 ? 7 : t.volume, startPressure: t.startPressure,
                     endPressure: t.endPressure, tankMaterial: i == 1 ? "Aluminium" : i == 2 ? "Steel" : nil)
        }
        DiveImportMapper.merge(data, into: stored, context: context())
        #expect(stored.tanks.map(\.id) == ids)
        #expect(stored.tanks[1].o2Percentage == 50 && stored.tanks[1].volume == 7 && stored.tanks[1].tankMaterial == "Aluminium")
        #expect(stored.tanks[2].tankMaterial == "Steel")
    }

    /// A CCR with three bailouts and no bailout transmitter: the first download gives each bailout
    /// a gas-only tank; a re-download over the dive as an earlier version stored it (the first
    /// bailout on the O₂ transmitter, the other two gas-only with the user's details) keeps every
    /// stored tank's id and details with its own gas and adds the first bailout as a new tank.
    @Test func aCCRWithThreeBailoutsKeepsEachBailoutsDetails() {
        let data = shearwaterDive(
            mixes: [(0.21, 0, .none), (0.50, 0, .none), (0.18, 0.45, .none), (0.10, 0.50, .diluent)],
            tanks: [(.oxygen, 200, 185), (.diluent, 200, 170)],
            profile: [(0, 3, [0: 200, 1: 200]), (1500, nil, [0: 192, 1: 185]), (3000, nil, [0: 185, 1: 170])])

        let downloaded = shearwaterDiveFrom(data)
        #expect(downloaded.tanks.map(\.o2Percentage) == [100, 10, 21, 50, 18])
        #expect(downloaded.tanks.map(\.tankType) == ["O2", "Diluent", nil, nil, nil])
        #expect(downloaded.tanks[2...].allSatisfy { $0.startPressure == nil && $0.usageStartTime == nil })

        // As an earlier version stored it: the first bailout (21 %) on the O₂ transmitter.
        let o2ID = UUID(), diluentID = UUID(), ean50ID = UUID(), trimixID = UUID()
        downloaded.tanks = [
            TankData(id: o2ID, o2: 0.21, he: 0, volume: 3, startPressure: 200, endPressure: 185, tankMaterial: "Steel"),
            TankData(id: diluentID, o2: 0.10, he: 0.50, volume: 3, startPressure: 200, endPressure: 170, tankMaterial: "Steel"),
            TankData(id: ean50ID, o2: 0.50, he: 0, volume: 5.7, tankMaterial: "Aluminium", tankType: "Stage"),
            TankData(id: trimixID, o2: 0.18, he: 0.45, volume: 11, tankMaterial: "Aluminium", tankType: "Stage"),
        ]
        DiveImportMapper.merge(data, into: downloaded, context: context(family: .shearwaterPetrel))

        let tanks = downloaded.tanks
        #expect(tanks.map(\.o2Percentage) == [100, 10, 21, 50, 18])
        #expect(tanks[0].id == o2ID && tanks[0].tankType == "O2" && tanks[0].tankMaterial == "Steel")
        #expect(tanks[1].id == diluentID && tanks[1].tankType == "Diluent")
        #expect(![o2ID, diluentID, ean50ID, trimixID].contains(tanks[2].id) && tanks[2].tankType == nil && tanks[2].volume == nil)
        #expect(tanks[3].id == ean50ID && tanks[3].volume == 5.7 && tanks[3].tankType == "Stage")
        #expect(tanks[4].id == trimixID && tanks[4].volume == 11 && tanks[4].tankType == "Stage")
    }

    @Test func pureOxygenIsNamedOxygen() {
        #expect(TankData(o2: 1.0).gasName == "Oxygen")
        #expect(TankData(o2: 0.995).gasName == "Oxygen")
        #expect(TankData(o2: 0.98).gasName == "Nitrox")
        #expect(TankData(o2: 0.21).gasName == "Air")
    }
}
