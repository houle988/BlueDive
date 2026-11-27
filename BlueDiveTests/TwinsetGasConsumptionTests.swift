import Foundation
import Testing
@testable import BlueDive

/// RMV and SAC of a twinset. A twinset's `volume` is one cylinder's (`TankData.cylinderCount`
/// is 2), so the gas used and the RMV count both cylinders, and the SAC (the pressure drop the
/// pair's gauge shows, per minute at the surface) divides that RMV by the pair's volume.
/// Single tanks and sidemount cylinders are unchanged.
@MainActor
struct TwinsetGasConsumptionTests {

    /// 40 min at 20 m: 3 ATA in the app's depth / 10 + 1 model.
    private func samples() -> [BlueDive.DiveProfilePoint] {
        [BlueDive.DiveProfilePoint(time: 0, depth: 20), BlueDive.DiveProfilePoint(time: 40, depth: 20)]
    }

    @Test func cylinderCountFollowsTheFormat() {
        #expect(TankData(tankType: "Twinset").cylinderCount == 2)
        #expect(TankData(tankType: "Double").cylinderCount == 2)
        #expect(TankData(tankType: "Single tank").cylinderCount == 1)
        #expect(TankData(tankType: "Sidemount").cylinderCount == 1)
        #expect(TankData().cylinderCount == 1)
    }

    @Test func twinsetSACIsThePairsPressureDrop() {
        // 2 × 12 L, 200 → 100 bar: 2400 L / 40 min / 3 = 20 L/min; SAC 100 / 40 / 3 bar/min.
        let dive = Dive(duration: 40, profileSamples: samples())
        dive.tanks = [TankData(volume: 12, startPressure: 200, endPressure: 100, tankType: "Twinset")]
        let expectedSAC = 100.0 / 40.0 / 3.0

        #expect(abs(dive.calculatedRMV(forTankAt: 0) - 20) < 0.001)
        #expect(abs(dive.combinedRMV - 20) < 0.001)
        #expect(abs(dive.calculatedSAC(forTankAt: 0) - expectedSAC) < 0.001)
        #expect(abs(dive.combinedSAC - expectedSAC) < 0.001)
        #expect(abs(dive.totalAirConsumption - 2400) < 0.001)
    }

    @Test func twinsetSACInImperialUnits() {
        // 2 × AL80 (80 cu ft at 3000 psi), 3000 → 1500 psi: the gauge drops 1500 / 40 / 3 psi/min.
        let dive = Dive(duration: 40, importPressureUnit: "psi", importVolumeUnit: "cubic feet", profileSamples: samples())
        dive.tanks = [TankData(volume: 80, startPressure: 3000, endPressure: 1500,
                               workingPressure: 3000, tankType: "Twinset")]
        let consumedBar = PressureUnit.bar.convert(1500, from: .psi)
        let pairLiters = dive.waterVolumeLiters(rawVolume: 80, workingPressureRaw: 3000) * 2
        let expectedRMV = consumedBar * pairLiters / 40.0 / 3.0
        let expectedSACPsi = 1500.0 / 40.0 / 3.0

        #expect(abs(dive.calculatedRMV(forTankAt: 0) - expectedRMV) < 0.001)
        #expect(abs(dive.combinedRMV - expectedRMV) < 0.001)
        #expect(abs(PressureUnit.psi.convert(dive.calculatedSAC(forTankAt: 0), from: .bar) - expectedSACPsi) < 0.01)
        #expect(abs(PressureUnit.psi.convert(dive.combinedSAC, from: .bar) - expectedSACPsi) < 0.01)
    }

    @Test func twinsetWithAStageUsesThePairsVolumeInTheWeightedAverage() {
        // Twinset 2 × 12 L for 30 min, then an 11 L stage for 10 min; each tank drops 100 bar.
        let dive = Dive(duration: 40, profileSamples: samples())
        dive.tanks = [
            TankData(volume: 12, startPressure: 200, endPressure: 100, tankType: "Twinset",
                     usageStartTime: 0, usageEndTime: 30 * 60),
            TankData(volume: 11, startPressure: 200, endPressure: 100, tankType: "Stage",
                     usageStartTime: 30 * 60, usageEndTime: 40 * 60)
        ]
        // Time-weighted volume: 24 L × 30/40 + 11 L × 10/40.
        let weightedLiters = 24.0 * 0.75 + 11.0 * 0.25
        #expect(dive.combinedRMV > 0)
        #expect(abs(dive.combinedSAC - dive.combinedRMV / weightedLiters) < 0.001)
    }

    @Test func singleTankIsUnchanged() {
        // 12 L, 200 → 100 bar: 1200 L / 40 min / 3 = 10 L/min; SAC 10 / 12.
        let dive = Dive(duration: 40, profileSamples: samples())
        dive.tanks = [TankData(volume: 12, startPressure: 200, endPressure: 100, tankType: "Single tank")]

        #expect(abs(dive.combinedRMV - 10) < 0.001)
        #expect(abs(dive.calculatedSAC(forTankAt: 0) - 10.0 / 12.0) < 0.001)
        #expect(abs(dive.combinedSAC - 10.0 / 12.0) < 0.001)
    }

    @Test func sidemountKeepsTheAverageCylinderVolume() {
        // Two separate 11 L cylinders, each 200 → 100 bar, no usage times: the combined SAC
        // still divides the combined RMV by the average cylinder volume (not changed here).
        let dive = Dive(duration: 40, profileSamples: samples())
        dive.tanks = [
            TankData(volume: 11, startPressure: 200, endPressure: 100, tankType: "Sidemount"),
            TankData(volume: 11, startPressure: 200, endPressure: 100, tankType: "Sidemount")
        ]
        #expect(abs(dive.combinedRMV - 2200.0 / 40.0 / 3.0) < 0.001)
        #expect(abs(dive.combinedSAC - dive.combinedRMV / 11.0) < 0.001)
    }
}
