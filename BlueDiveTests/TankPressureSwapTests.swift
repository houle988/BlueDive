import Foundation
import Testing
@testable import BlueDive

/// `TankPressureSwap`: Gas tab → Tank Tools → Swap Pressure Readings. All pressures are made up.
@MainActor
struct TankPressureSwapTests {

    /// A sample as the decoder gives it: the primary pressure is tank 0's reading, else the
    /// lowest index's, else the legacy single pressure.
    private func point(_ time: Double, readings: [Int: Double]?, legacy: Double? = nil,
                       currentGas: Int? = 0) -> DiveProfilePoint {
        let primary = readings.flatMap { $0[0] ?? $0.min(by: { $0.key < $1.key })?.value } ?? legacy
        return DiveProfilePoint(time: time, depth: 10, tankPressure: primary, tankPressures: readings,
                                currentGas: currentGas)
    }

    @Test func movesReadingsToATankWithoutAny() {
        let profile = [point(0, readings: [0: 200]), point(60, readings: [0: 190])]
        let swapped = TankPressureSwap.swappingReadings(profile, 0, 1)
        #expect(swapped.map(\.tankPressures) == [[1: 200], [1: 190]])
        // The primary pressure follows the readings (lowest index left).
        #expect(swapped.map(\.tankPressure) == [200, 190])
    }

    @Test func exchangesReadingsOfTwoTanks() {
        let profile = [point(0, readings: [0: 200, 1: 180, 2: 150])]
        let swapped = TankPressureSwap.swappingReadings(profile, 0, 1)
        #expect(swapped[0].tankPressures == [0: 180, 1: 200, 2: 150])
        #expect(swapped[0].tankPressure == 180)
    }

    @Test func swappingTwiceRestoresTheProfile() {
        let profile = [point(0, readings: [0: 200, 1: 180]), point(60, readings: [1: 170]),
                       point(120, readings: [2: 90])]
        let twice = TankPressureSwap.swappingReadings(TankPressureSwap.swappingReadings(profile, 0, 1), 1, 0)
        #expect(twice.map(\.tankPressures) == profile.map(\.tankPressures))
        #expect(twice.map(\.tankPressure) == profile.map(\.tankPressure))
    }

    @Test func leavesOtherFieldsAndUninvolvedSamplesUnchanged() {
        let untouched = point(0, readings: [2: 90], currentGas: 1)
        let moved = point(60, readings: [0: 200], currentGas: 1)
        let swapped = TankPressureSwap.swappingReadings([untouched, moved], 0, 1)
        #expect(swapped[0].tankPressures == [2: 90])
        #expect(swapped[1].time == 60)
        #expect(swapped[1].currentGas == 1)
        // Every sample gets a new id, so the chart sees the profile was replaced.
        #expect(swapped[0].id != untouched.id && swapped[1].id != moved.id)
        // Swapping a tank with itself changes nothing, not even the ids.
        #expect(TankPressureSwap.swappingReadings([moved], 0, 0)[0].id == moved.id)
    }

    @Test func readsTheLegacyPressureAsTankZero() {
        let profile = [point(0, readings: nil, legacy: 200)]
        #expect(TankPressureSwap.swappingReadings(profile, 0, 1)[0].tankPressures == [1: 200])
        // Not involved when neither tank is tank 0.
        #expect(TankPressureSwap.swappingReadings(profile, 1, 2)[0].tankPressures == nil)
    }

    @Test func exchangesStartAndEndPressuresOnly() {
        let a = TankData(o2: 0.32, startPressure: 200, endPressure: 60, usageStartTime: 0)
        let b = TankData(o2: 1.0, volume: 3)
        let swapped = TankPressureSwap.swappingStartEndPressures([a, b], 0, 1)
        #expect(swapped[0].id == a.id && swapped[0].o2 == 0.32 && swapped[0].usageStartTime == 0)
        #expect(swapped[0].startPressure == nil && swapped[0].endPressure == nil)
        #expect(swapped[1].id == b.id && swapped[1].o2 == 1.0 && swapped[1].volume == 3)
        #expect(swapped[1].startPressure == 200 && swapped[1].endPressure == 60)
        #expect(TankPressureSwap.swappingStartEndPressures([a, b], 0, 5)[0].startPressure == 200)
    }
}
