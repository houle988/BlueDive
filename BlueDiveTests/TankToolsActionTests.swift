import Foundation
import Testing
@testable import BlueDive

/// The Tank Tools actions on a dive (`Dive.moveTank`, `swapTankReadings`, `removeTank`): Gas tab
/// → Tank Tools → Move Tank / Swap Pressure Readings, and Remove Tank. All values are made up.
@MainActor
struct TankToolsActionTests {

    /// A dive with three tanks told apart by their O₂ (21 %, 32 %, 50 %) and their start
    /// pressures (200, 210, 190), and a profile whose readings equal 100 × (position + 1).
    private func threeTankDive(withProfile: Bool = true) -> Dive {
        let dive = Dive()
        dive.tanks = [TankData(o2: 0.21, startPressure: 200, endPressure: 50),
                      TankData(o2: 0.32, startPressure: 210, endPressure: 120),
                      TankData(o2: 0.50, startPressure: 190, endPressure: 150)]
        if withProfile {
            dive.profileSamples = [
                DiveProfilePoint(time: 0, depth: 10, tankPressure: 100,
                                 tankPressures: [0: 100, 1: 200, 2: 300], currentGas: 0),
                DiveProfilePoint(time: 60, depth: 20, tankPressure: 100,
                                 tankPressures: [0: 100, 1: 200, 2: 300], currentGas: 2)
            ]
        }
        return dive
    }

    // MARK: - Move Tank

    @Test func moveTakesTheReadingsAndGasSwitchesAlong() {
        let dive = threeTankDive()
        #expect(dive.moveTank(from: 0, to: 2, movesSamples: true))
        #expect(dive.tanks.map(\.o2) == [0.32, 0.50, 0.21])
        // The 21 % tank's readings (100) and its gas switch follow it to position 2.
        #expect(dive.profileSamples[0].tankPressures == [2: 100, 0: 200, 1: 300])
        #expect(dive.profileSamples.map(\.currentGas) == [2, 1])
        // Its start and end pressures are tank fields: they move with it.
        #expect(dive.tanks[2].startPressure == 200)
    }

    @Test func moveWithoutReadingsLeavesTheProfile() {
        let dive = threeTankDive()
        let before = dive.profileSamples
        #expect(dive.moveTank(from: 0, to: 2, movesSamples: false))
        #expect(dive.tanks.map(\.o2) == [0.32, 0.50, 0.21])
        #expect(dive.profileSamples.map(\.tankPressures) == before.map(\.tankPressures))
        #expect(dive.profileSamples.map(\.currentGas) == before.map(\.currentGas))
    }

    @Test func moveBackRestoresTheDive() {
        let dive = threeTankDive()
        let tanks = dive.tanks.map(\.id), profile = dive.profileSamples
        dive.moveTank(from: 0, to: 2, movesSamples: true)
        dive.moveTank(from: 2, to: 0, movesSamples: true)
        #expect(dive.tanks.map(\.id) == tanks)
        #expect(dive.profileSamples.map(\.tankPressures) == profile.map(\.tankPressures))
        #expect(dive.profileSamples.map(\.currentGas) == profile.map(\.currentGas))
    }

    @Test func moveRefusesInvalidOrNoOpPositions() {
        let dive = threeTankDive()
        let tanks = dive.tanks.map(\.id)
        #expect(!dive.moveTank(from: 1, to: 1, movesSamples: true))
        #expect(!dive.moveTank(from: 0, to: 3, movesSamples: true))
        #expect(!dive.moveTank(from: -1, to: 0, movesSamples: true))
        #expect(dive.tanks.map(\.id) == tanks)
    }

    @Test func moveWritesNoProfileForADiveWithout() {
        let dive = threeTankDive(withProfile: false)
        #expect(dive.moveTank(from: 0, to: 1, movesSamples: true))
        #expect(dive.tanks.map(\.o2) == [0.32, 0.21, 0.50])
        #expect(dive.profileSamples.isEmpty)
    }

    // MARK: - Swap Pressure Readings

    @Test func swapExchangesReadingsAndStartEndPressuresOnly() {
        let dive = threeTankDive()
        #expect(dive.swapTankReadings(0, 1))
        // Gases and order stay; readings and start/end pressures are exchanged.
        #expect(dive.tanks.map(\.o2) == [0.21, 0.32, 0.50])
        #expect(dive.tanks.map(\.startPressure) == [210, 200, 190])
        #expect(dive.tanks.map(\.endPressure) == [120, 50, 150])
        #expect(dive.profileSamples[0].tankPressures == [0: 200, 1: 100, 2: 300])
        // Gas switches are not touched.
        #expect(dive.profileSamples.map(\.currentGas) == [0, 2])
    }

    @Test func swapTwiceRestoresTheDive() {
        let dive = threeTankDive()
        let profile = dive.profileSamples, starts = dive.tanks.map(\.startPressure)
        dive.swapTankReadings(0, 2)
        dive.swapTankReadings(2, 0)
        #expect(dive.tanks.map(\.startPressure) == starts)
        #expect(dive.profileSamples.map(\.tankPressures) == profile.map(\.tankPressures))
    }

    @Test func swapRefusesInvalidOrNoOpTanks() {
        let dive = threeTankDive()
        #expect(!dive.swapTankReadings(1, 1))
        #expect(!dive.swapTankReadings(0, 3))
        #expect(dive.tanks.map(\.startPressure) == [200, 210, 190])
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 200, 2: 300])
    }

    @Test func swapWritesNoProfileForADiveWithout() {
        let dive = threeTankDive(withProfile: false)
        #expect(dive.swapTankReadings(0, 1))
        #expect(dive.tanks.map(\.startPressure) == [210, 200, 190])
        #expect(dive.profileSamples.isEmpty)
    }

    // MARK: - Remove Tank

    @Test func removeDropsTheTankAndItsReadings() {
        let dive = threeTankDive()
        #expect(dive.removeTank(at: 1))
        #expect(dive.tanks.map(\.o2) == [0.21, 0.50])
        // The 50 % tank (reading 300, gas switch 2) is now at position 1 and keeps its own.
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 300])
        #expect(dive.profileSamples.map(\.currentGas) == [0, 1])
    }

    @Test func removeRefusesTheLastTankAndInvalidIndexes() {
        let single = Dive()
        single.tanks = [TankData(o2: 0.32)]
        #expect(!single.removeTank(at: 0))
        #expect(single.tanks.count == 1)

        let dive = threeTankDive()
        #expect(!dive.removeTank(at: 3))
        #expect(dive.tanks.count == 3)
    }

    @Test func removingATankWithoutReadingsOnlyRenumbersTheOthers() {
        let dive = threeTankDive()
        dive.profileSamples = [DiveProfilePoint(time: 0, depth: 10, tankPressure: 100,
                                                tankPressures: [0: 100, 2: 300], currentGas: 2)]
        #expect(dive.removeTank(at: 1))
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 300])
        #expect(dive.profileSamples[0].currentGas == 1)
    }

    @Test func removeWritesNoProfileForADiveWithout() {
        let dive = threeTankDive(withProfile: false)
        #expect(dive.removeTank(at: 0))
        #expect(dive.tanks.map(\.o2) == [0.32, 0.50])
        #expect(dive.profileSamples.isEmpty)
    }

    // MARK: - Every other sample field is kept, under a new id

    /// A sample with every optional field set, so a field the tools drop shows up.
    private func fullSample() -> DiveProfilePoint {
        DiveProfilePoint(time: 12, depth: 31.5, temperature: 18.5, tankPressure: 100,
                         tankPressures: [0: 100, 1: 200, 2: 300], ndl: 7, ceilingDepth: 3,
                         ceilingTime: 2, cns: 14, ppo2: 1.2, sensorPPO2: [0: 1.19, 1: 1.21],
                         events: [.gasChange, .bookmark], currentGas: 1, setpoint: 1.3, tts: 9, rbt: 25)
    }

    /// Every stored field by name, except the ones the tank tools are meant to change. Read
    /// through Mirror, so a field added to `DiveProfilePoint` later is compared too.
    private func otherFields(_ point: DiveProfilePoint) -> [String: String] {
        let changed: Set<String> = ["id", "tankPressure", "tankPressures", "currentGas"]
        var fields: [String: String] = [:]
        for child in Mirror(reflecting: point).children {
            guard let name = child.label, !changed.contains(name) else { continue }
            fields[name] = String(describing: child.value)
        }
        return fields
    }

    @Test func everyActionKeepsTheOtherFieldsUnderANewID() {
        let original = fullSample()
        let results = [
            TankPressureSwap.swappingReadings([original], 0, 1)[0],
            TankPressureSwap.swappingReadings([original], 3, 4)[0],          // neither tank: readings kept
            TankSlotMove.remappingSamples([original], from: 0, to: 2)[0],
            TankSlotMove.remappingSamples([original], from: 1, to: 2)[0],
            TankSlotMove.removingTank([original], at: 1)[0]
        ]
        #expect(otherFields(original).count >= 13)
        for result in results {
            #expect(otherFields(result) == otherFields(original))
            #expect(result.id != original.id)
        }
        // A sample with neither tank keeps its readings, under its new id.
        #expect(results[1].tankPressures == original.tankPressures)
    }

    @Test func everySampleOfAnActionGetsANewID() {
        let dive = threeTankDive()
        let before = Set(dive.profileSamples.map(\.id))
        dive.swapTankReadings(0, 1)
        let afterSwap = Set(dive.profileSamples.map(\.id))
        #expect(before.isDisjoint(with: afterSwap))
        dive.moveTank(from: 0, to: 1, movesSamples: true)
        #expect(afterSwap.isDisjoint(with: Set(dive.profileSamples.map(\.id))))
    }

    // MARK: - Unusual profiles

    @Test func adjacentMovesRenumberOnlyTheTwoTanks() {
        let dive = threeTankDive()
        #expect(dive.moveTank(from: 1, to: 2, movesSamples: true))
        #expect(dive.tanks.map(\.o2) == [0.21, 0.50, 0.32])
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 300, 2: 200])
        #expect(dive.profileSamples.map(\.currentGas) == [0, 1])
        #expect(dive.moveTank(from: 2, to: 1, movesSamples: true))
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 200, 2: 300])
        #expect(dive.profileSamples.map(\.currentGas) == [0, 2])
    }

    @Test func readingsAndGasSwitchesBeyondTheTanksAreKeptDistinct() {
        // Readings under tank 5 and a switch to tank 4 on a three-tank dive (no such tanks).
        let odd = [DiveProfilePoint(time: 0, depth: 10, tankPressure: 100,
                                    tankPressures: [0: 100, 5: 500], currentGas: 4)]
        let moved = TankSlotMove.remappingSamples(odd, from: 0, to: 2)
        #expect(moved[0].tankPressures == [2: 100, 5: 500])
        #expect(moved[0].currentGas == 4)
        let removed = TankSlotMove.removingTank(odd, at: 1)
        #expect(removed[0].tankPressures == [0: 100, 4: 500])
        #expect(removed[0].currentGas == 3)
    }

    @Test func samplesWithoutAGasSwitchKeepNoneExceptTheStartWhenTankZeroMoves() {
        let dive = threeTankDive()
        dive.profileSamples = [
            DiveProfilePoint(time: 0, depth: 10, tankPressure: 100, tankPressures: [0: 100, 1: 200], currentGas: nil),
            DiveProfilePoint(time: 30, depth: 15, tankPressure: 100, tankPressures: [0: 100, 1: 200], currentGas: nil),
            DiveProfilePoint(time: 60, depth: 20, tankPressure: 100, tankPressures: [0: 100, 1: 200], currentGas: 1)
        ]
        // Tank 0 moves to 1: the start gets its new position; the next sample still carries it.
        dive.moveTank(from: 0, to: 1, movesSamples: true)
        #expect(dive.profileSamples.map(\.currentGas) == [1, nil, 0])
        // Removing a later tank changes no gas.
        dive.removeTank(at: 2)
        #expect(dive.profileSamples.map(\.currentGas) == [1, nil, 0])
    }

    @Test func legacySinglePressureThroughTheDiveActions() {
        let legacy = [DiveProfilePoint(time: 0, depth: 10, tankPressure: 200, tankPressures: nil, currentGas: nil)]

        let swapped = threeTankDive()
        swapped.profileSamples = legacy
        swapped.swapTankReadings(0, 2)
        #expect(swapped.profileSamples[0].tankPressures == [2: 200])

        let moved = threeTankDive()
        moved.profileSamples = legacy
        moved.moveTank(from: 0, to: 1, movesSamples: true)
        #expect(moved.profileSamples[0].tankPressures == [1: 200])

        let removedOther = threeTankDive()
        removedOther.profileSamples = legacy
        removedOther.removeTank(at: 2)
        #expect(removedOther.profileSamples[0].tankPressure == 200)

        let removedZero = threeTankDive()
        removedZero.profileSamples = legacy
        removedZero.removeTank(at: 0)
        #expect(removedZero.profileSamples[0].tankPressure == nil)
    }

    @Test func emptyPerTankReadingsCountAsTheLegacyPressure() {
        // An empty dictionary beside a single pressure: the decoder reads the pressure as tank 0's.
        let empty = [DiveProfilePoint(time: 0, depth: 10, tankPressure: 200, tankPressures: [:], currentGas: nil)]
        #expect(TankPressureSwap.swappingReadings(empty, 0, 1)[0].tankPressures == [1: 200])
        #expect(TankSlotMove.remappingSamples(empty, from: 0, to: 2)[0].tankPressures == [2: 200])
        // Removing another tank keeps the pressure; removing tank 0 drops it.
        #expect(TankSlotMove.removingTank(empty, at: 2)[0].tankPressure == 200)
        #expect(TankSlotMove.removingTank(empty, at: 0)[0].tankPressure == nil)
    }

    // MARK: - The gas before the first gas switch

    /// Air (tank 0) breathed from the start without a recorded gas, then a switch to EAN50 (tank 1).
    private func implicitStartDive() -> Dive {
        let dive = Dive()
        dive.tanks = [TankData(o2: 0.21), TankData(o2: 0.50)]
        dive.profileSamples = [
            DiveProfilePoint(time: 0, depth: 30, tankPressure: 200, tankPressures: [0: 200], currentGas: nil),
            DiveProfilePoint(time: 10, depth: 30, tankPressure: 150, tankPressures: [0: 150], currentGas: nil),
            DiveProfilePoint(time: 20, depth: 21, tankPressure: 140, tankPressures: [0: 140, 1: 190],
                             events: [.gasChange], currentGas: 1)
        ]
        return dive
    }

    @Test func movingTheFirstTankKeepsTheGasAtTheStartOfTheDive() {
        let dive = implicitStartDive()
        #expect(dive.moveTank(from: 0, to: 1, movesSamples: true))
        // Air is now tank 1: the first sample says so, the next one carries it forward, and the
        // switch to EAN50 (now tank 0) follows it.
        #expect(dive.profileSamples.map(\.currentGas) == [1, nil, 0])
        #expect(dive.tanks[1].o2 == 0.21)
    }

    @Test func aMoveThatKeepsTheFirstTankLeavesTheStartAlone() {
        let dive = implicitStartDive()
        dive.tanks.append(TankData(o2: 0.32))
        #expect(dive.moveTank(from: 1, to: 2, movesSamples: true))
        #expect(dive.profileSamples.map(\.currentGas) == [nil, nil, 2])
    }

    @Test func movingWithoutReadingsLeavesTheProfileUntouched() {
        let dive = implicitStartDive()
        let ids = dive.profileSamples.map(\.id)
        #expect(dive.moveTank(from: 0, to: 1, movesSamples: false))
        #expect(dive.profileSamples.map(\.id) == ids)
        #expect(dive.profileSamples.map(\.currentGas) == [nil, nil, 1])
    }

    @Test func removingATankKeepsItsGasChangeEventWithoutAGas() {
        // The switch to the removed tank has no tank left: the gas is cleared, the event (computer
        // data) stays, and the earlier gas carries on.
        let dive = implicitStartDive()
        #expect(dive.removeTank(at: 1))
        #expect(dive.profileSamples[2].currentGas == nil)
        #expect(dive.profileSamples[2].events == [.gasChange])
        #expect(dive.profileSamples[2].tankPressures == [0: 140])
    }

    @Test func removingTheFirstTankMovesTheStartOfTheDiveToTheNextTank() {
        // Air (tank 0) is removed: its readings go, the start of the dive (no gas recorded) is
        // now calculated with EAN50, the new tank 0, as the Remove Tank confirmation says.
        let dive = implicitStartDive()
        #expect(dive.removeTank(at: 0))
        #expect(dive.tanks.map(\.o2) == [0.50])
        #expect(dive.profileSamples.map(\.currentGas) == [nil, nil, 0])
        #expect(dive.profileSamples.map(\.tankPressures) == [nil, nil, [0: 190]])
        #expect(dive.profileSamples.map(\.tankPressure) == [nil, nil, 190])
    }

    @Test func selectionAfterRemovingStaysAtThePosition() {
        // Tank 2 of 3 removed: the old Tank 3 now at position 2 is selected.
        #expect(Dive.selectionAfterRemovingTank(at: 1, remaining: 2) == 1)
        // The last tank removed: the new last tank.
        #expect(Dive.selectionAfterRemovingTank(at: 2, remaining: 2) == 1)
        #expect(Dive.selectionAfterRemovingTank(at: 0, remaining: 1) == 0)
    }

    // MARK: - Tank fields

    /// Every stored field of a tank by name, except its start and end pressures. Read through
    /// Mirror, so a field added to `TankData` later is compared too.
    private func tankFieldsExceptPressures(_ tank: TankData) -> [String: String] {
        var fields: [String: String] = [:]
        for child in Mirror(reflecting: tank).children {
            guard let name = child.label, name != "startPressure", name != "endPressure" else { continue }
            fields[name] = String(describing: child.value)
        }
        return fields
    }

    @Test func swapKeepsEveryOtherTankField() {
        let a = TankData(o2: 0.32, he: 0.10, volume: 11.1, startPressure: 200, endPressure: 60,
                         workingPressure: 207, tankMaterial: "Aluminium", tankType: "Sidemount",
                         usageStartTime: 0, usageEndTime: 1800)
        let b = TankData(o2: 1.0, volume: 3, startPressure: 190, endPressure: 120,
                         workingPressure: 200, tankMaterial: "Steel", tankType: "Rebreather",
                         usageStartTime: 60, usageEndTime: 3000)
        let swapped = TankPressureSwap.swappingStartEndPressures([a, b], 0, 1)
        #expect(tankFieldsExceptPressures(a).count >= 9)
        #expect(tankFieldsExceptPressures(swapped[0]) == tankFieldsExceptPressures(a))
        #expect(tankFieldsExceptPressures(swapped[1]) == tankFieldsExceptPressures(b))
        #expect(swapped[0].startPressure == 190 && swapped[0].endPressure == 120)
        #expect(swapped[1].startPressure == 200 && swapped[1].endPressure == 60)
    }

    // MARK: - Other cases

    @Test func swapWithoutATankZeroReadingKeepsTheLowestIndexAsPrimary() {
        let dive = threeTankDive()
        dive.profileSamples = [DiveProfilePoint(time: 0, depth: 10, tankPressure: 200,
                                                tankPressures: [1: 200, 2: 150], currentGas: 1)]
        #expect(dive.swapTankReadings(1, 2))
        #expect(dive.profileSamples[0].tankPressures == [1: 150, 2: 200])
        #expect(dive.profileSamples[0].tankPressure == 150)
    }

    @Test func negativeIndexesAreRefused() {
        let dive = threeTankDive()
        #expect(!dive.swapTankReadings(-1, 1))
        #expect(!dive.removeTank(at: -1))
        #expect(!dive.moveTank(from: 0, to: -1, movesSamples: true))
        #expect(dive.tanks.count == 3)
        #expect(dive.profileSamples[0].tankPressures == [0: 100, 1: 200, 2: 300])
    }

    /// What the next launch or another device reads: the stored JSON decoded again.
    private func decodedAgain(_ samples: [DiveProfilePoint]) throws -> [DiveProfilePoint] {
        try JSONDecoder().decode([DiveProfilePoint].self, from: JSONEncoder().encode(samples))
    }

    @Test func storedProfilesDecodeToWhatTheActionsProduced() throws {
        let swapped = threeTankDive()
        swapped.swapTankReadings(0, 2)
        let moved = implicitStartDive()
        moved.moveTank(from: 0, to: 1, movesSamples: true)
        let removed = threeTankDive()
        removed.removeTank(at: 0)
        for samples in [swapped.profileSamples, moved.profileSamples, removed.profileSamples] {
            let decoded = try decodedAgain(samples)
            // The decoder derives the primary pressure again: it must match the stored one.
            #expect(decoded.map(\.tankPressure) == samples.map(\.tankPressure))
            #expect(decoded.map(\.tankPressures) == samples.map(\.tankPressures))
            #expect(decoded.map(\.currentGas) == samples.map(\.currentGas))
            #expect(decoded.map(\.id) == samples.map(\.id))
        }
    }

    @Test func primaryPressureFollowsTankZeroAfterEachAction() {
        let swapped = threeTankDive()
        swapped.swapTankReadings(0, 1)
        #expect(swapped.profileSamples[0].tankPressure == 200)

        let removed = threeTankDive()
        removed.removeTank(at: 0)
        #expect(removed.profileSamples[0].tankPressure == 200)

        let moved = threeTankDive()
        moved.moveTank(from: 2, to: 0, movesSamples: true)
        #expect(moved.profileSamples[0].tankPressure == 300)
    }
}
