import Foundation
import Testing
@testable import BlueDive

/// `TankSlotMove`: Gas tab → Tank Tools → Move Tank, and Remove Tank. All gases and
/// pressures are made up.
@MainActor
struct TankSlotMoveTests {

    /// Three tanks told apart by their O₂: 21 %, 32 %, 50 %.
    private let tanks = [TankData(o2: 0.21), TankData(o2: 0.32), TankData(o2: 0.50)]

    /// A sample as the decoder gives it: the primary pressure is tank 0's reading, else the
    /// lowest index's, else the legacy single pressure.
    private func point(_ time: Double, readings: [Int: Double]?, legacy: Double? = nil,
                       currentGas: Int?) -> DiveProfilePoint {
        let primary = readings.flatMap { $0[0] ?? $0.min(by: { $0.key < $1.key })?.value } ?? legacy
        return DiveProfilePoint(time: time, depth: 10, tankPressure: primary, tankPressures: readings,
                                currentGas: currentGas)
    }

    /// Each reading equals 100 × (its tank's position + 1), so a value names its tank.
    private var profile: [DiveProfilePoint] {
        [point(0, readings: [0: 100, 1: 200, 2: 300], currentGas: 0),
         point(60, readings: [0: 100, 1: 200, 2: 300], currentGas: 2)]
    }

    // MARK: - Move to Position

    @Test func newIndexShiftsTheTanksInBetween() {
        // Forward, 0 → 2: tanks 1 and 2 move one earlier.
        #expect([0, 1, 2].map { TankSlotMove.newIndex($0, from: 0, to: 2) } == [2, 0, 1])
        // Backward, 2 → 0: tanks 0 and 1 move one later.
        #expect([0, 1, 2].map { TankSlotMove.newIndex($0, from: 2, to: 0) } == [1, 2, 0])
        // Tanks outside the moved range keep their position.
        #expect(TankSlotMove.newIndex(3, from: 0, to: 2) == 3)
    }

    @Test func movingTankRemovesThenInserts() {
        #expect(TankSlotMove.movingTank(tanks, from: 0, to: 2).map(\.o2) == [0.32, 0.50, 0.21])
        #expect(TankSlotMove.movingTank(tanks, from: 2, to: 0).map(\.o2) == [0.50, 0.21, 0.32])
        #expect(TankSlotMove.movingTank(tanks, from: 0, to: 5).map(\.o2) == tanks.map(\.o2))
    }

    @Test func remappedSamplesFollowTheirTanks() {
        let moved = TankSlotMove.remappingSamples(profile, from: 0, to: 2)
        // The old tank 0 (reading 100) is now at 2; the old 1 and 2 shift one earlier.
        #expect(moved[0].tankPressures == [2: 100, 0: 200, 1: 300])
        #expect(moved.map(\.currentGas) == [2, 1])
        #expect(moved[0].tankPressure == 200)
        // Moving back restores the profile.
        let back = TankSlotMove.remappingSamples(moved, from: 2, to: 0)
        #expect(back.map(\.tankPressures) == profile.map(\.tankPressures))
        #expect(back.map(\.currentGas) == profile.map(\.currentGas))
        #expect(back.map(\.tankPressure) == profile.map(\.tankPressure))
    }

    @Test func legacyPressureFollowsTankZeroWhenItMoves() {
        let legacy = [point(0, readings: nil, legacy: 200, currentGas: nil)]
        // Tank 0 moves to 2: its pressure goes with it.
        let moved = TankSlotMove.remappingSamples(legacy, from: 0, to: 2)
        #expect(moved[0].tankPressures == [2: 200])
        #expect(moved[0].tankPressure == 200)
        // The tank now at 0 came from 1: the pressure stays with the old tank 0, now at 1.
        #expect(TankSlotMove.remappingSamples(legacy, from: 1, to: 0)[0].tankPressures == [1: 200])
        // A move that leaves position 0 alone leaves the sample unchanged.
        let untouched = TankSlotMove.remappingSamples(legacy, from: 1, to: 2)
        #expect(untouched[0].tankPressures == nil)
        #expect(untouched[0].tankPressure == 200)
    }

    // MARK: - Remove Tank

    @Test func removingATankDropsItsReadingsAndShiftsTheOthers() {
        let removed = TankSlotMove.removingTank(profile, at: 0)
        // The old tanks 1 and 2 are now 0 and 1, with their own readings.
        #expect(removed.map(\.tankPressures) == [[0: 200, 1: 300], [0: 200, 1: 300]])
        #expect(removed.map(\.tankPressure) == [200, 200])
        // A switch to the removed tank is cleared; one to a later tank follows it.
        #expect(removed.map(\.currentGas) == [nil, 1])
    }

    @Test func removingTheLastTankLeavesTheOthersUnchanged() {
        let removed = TankSlotMove.removingTank(profile, at: 2)
        #expect(removed.map(\.tankPressures) == [[0: 100, 1: 200], [0: 100, 1: 200]])
        #expect(removed.map(\.tankPressure) == [100, 100])
        #expect(removed.map(\.currentGas) == [0, nil])
    }

    @Test func removingTheOnlyTankWithReadingsClearsThem() {
        let only = [point(0, readings: [1: 180], currentGas: 1)]
        let removed = TankSlotMove.removingTank(only, at: 1)
        #expect(removed[0].tankPressures == nil)
        #expect(removed[0].tankPressure == nil)
        #expect(removed[0].currentGas == nil)
        // The other fields are kept, under a new id (see TankToolsActionTests for every field).
        #expect(removed[0].id != only[0].id && removed[0].time == 0 && removed[0].depth == 10)
    }

    @Test func readsTheLegacyPressureAsTankZero() {
        let legacy = [point(0, readings: nil, legacy: 200, currentGas: nil)]
        #expect(TankSlotMove.removingTank(legacy, at: 0)[0].tankPressure == nil)
        #expect(TankSlotMove.removingTank(legacy, at: 1)[0].tankPressure == 200)
    }
}
