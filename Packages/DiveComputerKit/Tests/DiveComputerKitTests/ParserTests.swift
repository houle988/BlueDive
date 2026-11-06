import Foundation
import Testing
@testable import DiveComputerKit

/// The profile state machine, driven with scripted libdivecomputer sample streams.
struct SampleAccumulatorTests {

    private func run(_ samples: [SampleInput], setpointPerSample: Bool = false,
                     diluents: Set<UInt32> = [], oxygens: Set<UInt32> = []) -> SampleAccumulator {
        let accumulator = SampleAccumulator(setpointPerSample: setpointPerSample,
                                            diluentIndices: diluents, oxygenIndices: oxygens)
        samples.forEach(accumulator.add)
        accumulator.finish()
        return accumulator
    }

    @Test func eachPointCarriesItsOwnInterval() {
        let a = run([.time(milliseconds: 0), .depth(1.5), .temperature(20),
                     .time(milliseconds: 10_000), .depth(5.2), .temperature(18)])
        #expect(a.profile.map(\.time) == [0, 10])
        #expect(a.profile.map(\.depth) == [1.5, 5.2])
        #expect(a.profile.map(\.temperature) == [20, 18])
        #expect(a.maxTime == 10)
        #expect(a.maxDepth == 5.2)
    }

    @Test func millisecondsBecomeSeconds() {
        let a = run([.time(milliseconds: 2_500), .depth(1)])
        #expect(a.profile.first?.time == 2.5)
    }

    @Test func noSamplesNoPoints() {
        let a = run([])
        #expect(a.profile.isEmpty)
        #expect(a.tempMinimum == .infinity)
        #expect(a.tempMaximum == -.infinity)
        #expect(a.tempSurface == .infinity)
    }

    /// 0 °C is a real temperature; unset uses infinity sentinels.
    @Test func temperatureStatistics() {
        let a = run([.time(milliseconds: 0), .temperature(0), .time(milliseconds: 1000), .temperature(-1.5),
                     .time(milliseconds: 2000), .temperature(2)])
        #expect(a.tempMinimum == -1.5)
        #expect(a.tempMaximum == 2)
        #expect(a.tempSurface == 0)
        #expect(a.lastTemperature == 2)
    }

    @Test func eventsGetTheirOwnPoint() {
        let a = run([.time(milliseconds: 0), .depth(3), .event(.bookmark), .event(nil),
                     .time(milliseconds: 10_000), .depth(4)])
        #expect(a.profile.count == 4)
        #expect(a.profile[0].events == [.bookmark])
        #expect(a.profile[0].depth == 3)
        #expect(a.profile[1].events.isEmpty)   // unmapped event type: point, no event
        #expect(a.profile[2].events.isEmpty)   // interval point
        #expect(a.profile.map(\.time) == [0, 0, 0, 10])
    }

    @Test func pressuresArePerIntervalButLastPressureCarries() {
        let a = run([.time(milliseconds: 0), .pressure(tank: 0, bar: 200), .pressure(tank: 1, bar: 180),
                     .time(milliseconds: 10_000)])
        #expect(a.profile[0].pressures == [0: 200, 1: 180])
        #expect(a.profile[0].pressure == 180)
        #expect(a.profile[1].pressures.isEmpty)
        #expect(a.profile[1].pressure == 180)
        #expect(a.pressureValues == [200, 180])
    }

    @Test func votedAndSensorPPO2() {
        let a = run([.time(milliseconds: 0), .ppo2(sensor: 0xFFFF_FFFF, bar: 1.2),
                     .ppo2(sensor: 0, bar: 1.18), .ppo2(sensor: 1, bar: 1.22),
                     .time(milliseconds: 10_000), .ppo2(sensor: 0, bar: 1.19)])
        #expect(a.profile[0].po2 == 1.2)
        #expect(a.profile[0].sensorPPO2 == [0: 1.18, 1: 1.22])
        #expect(a.profile[1].po2 == nil)          // no stale voted value
        #expect(a.profile[1].sensorPPO2 == [0: 1.19])
        #expect(a.ppo2Readings.map(\.sensor) == [0, 1, 0])
    }

    @Test func gasChangeIsSynthesizedOnceAndUnknownIgnored() {
        let a = run([.time(milliseconds: 0), .gasmix(0),
                     .time(milliseconds: 10_000), .gasmix(1),
                     .time(milliseconds: 20_000), .event(.gasChange), .gasmix(0),
                     .time(milliseconds: 30_000), .gasmix(0xFFFF_FFFF)])
        let gasChanges = a.profile.filter { $0.events == [.gasChange] }
        #expect(gasChanges.map(\.time) == [10, 20])   // the 20 s change was already an event
        #expect(gasChanges.first?.currentGas == 1)
        #expect(a.profile.last?.currentGas == -1)     // DC_GASMIX_UNKNOWN
        #expect(a.lastGasMix == 0)                    // last real index
    }

    @Test func setpointPerSampleResetsEachInterval() {
        let a = run([.time(milliseconds: 0), .setpoint(1.3), .time(milliseconds: 10_000)], setpointPerSample: true)
        #expect(a.profile[0].setpoint == 1.3)
        #expect(a.profile[1].setpoint == nil)
        #expect(a.setpoint == 1.3)
    }

    @Test func changeOnlySetpointHeldUntilBailout() {
        let a = run([.time(milliseconds: 0), .gasmix(0), .setpoint(1.3),
                     .time(milliseconds: 10_000),
                     .time(milliseconds: 20_000), .gasmix(2),          // bailout gas
                     .time(milliseconds: 30_000), .gasmix(1),          // oxygen: unchanged
                     .time(milliseconds: 40_000), .gasmix(0)],         // back on the loop
                    diluents: [0], oxygens: [1])
        let intervals = a.profile.filter { $0.events.isEmpty }
        #expect(intervals.map(\.setpoint) == [1.3, 1.3, nil, nil, 1.3])
    }

    @Test func entryAndExitLocations() {
        let a = run([.time(milliseconds: 0), .location(latitude: 1, longitude: 2, altitude: 0),
                     .location(latitude: 3, longitude: 4, altitude: 0),
                     .location(latitude: 5, longitude: 6, altitude: 0)])
        #expect(a.location?.latitude == 1)
        #expect(a.exitLocation?.latitude == 5)
    }

    @Test func decoAndCNS() {
        let a = run([.time(milliseconds: 0), .deco(type: 0, time: 600, depth: 0, tts: 0), .cns(0.12),
                     .time(milliseconds: 10_000), .deco(type: 2, time: 120, depth: 6, tts: 300)])
        #expect(a.profile[0].ndl == 600)
        #expect(a.profile[0].decoStop == nil)
        #expect(a.profile[0].cns == 12)
        #expect(a.profile[1].ndl == nil)
        #expect(a.profile[1].decoStop == 6)
        #expect(a.profile[1].decoTime == 120)
        #expect(a.profile[1].tts == 300)
        #expect(a.lastDeco?.type == 2)
    }
}

struct FieldRuleTests {

    @Test func averageDepthTrapezoid() {
        let profile = [ProfileSample(time: 0, depth: 0), ProfileSample(time: 10, depth: 10),
                       ProfileSample(time: 20, depth: 10), ProfileSample(time: 30, depth: 0)]
        #expect(AverageDepth.of(profile) == 200.0 / 30.0)
        // Cut at 25 s: depth interpolated to 5 m.
        #expect(AverageDepth.of(profile, until: 25) == (50 + 100 + 37.5) / 25)
        // A cut outside the profile is ignored.
        #expect(AverageDepth.of(profile, until: 30) == 200.0 / 30.0)
        #expect(AverageDepth.of([ProfileSample(time: 0, depth: 4)]) == 4)
        #expect(AverageDepth.of([]) == 0)
    }

    @Test func shearwaterPNFDetection() {
        #expect(DiveParser.isShearwaterPNF(family: .shearwaterPetrel, data: Data([0x10, 0x00])))
        #expect(!DiveParser.isShearwaterPNF(family: .shearwaterPetrel, data: Data([0xFF, 0xFF, 0x00])))
        #expect(!DiveParser.isShearwaterPNF(family: .shearwaterPetrel, data: Data([0x10])))
        #expect(!DiveParser.isShearwaterPNF(family: .oceanicAtom2, data: Data([0x10, 0x00])))
    }

    @Test func setpointFamilies() {
        #expect(DiveParser.reportsSetpointEverySample(.shearwaterPetrel))
        #expect(DiveParser.reportsSetpointEverySample(.diveSystem))
        #expect(DiveParser.reportsSetpointEverySample(.mcleanExtreme))
        #expect(!DiveParser.reportsSetpointEverySample(.hwOstc3))
        #expect(!DiveParser.reportsSetpointEverySample(.divesoftFreedom))
    }

    @Test func decoModelDescriptions() {
        #expect(DiveData.DecoModel(type: .buhlmann, conservatism: 0, gfLow: 30, gfHigh: 70).description == "Bühlmann GF 30/70")
        #expect(DiveData.DecoModel(type: .buhlmann, conservatism: 0, gfLow: 0, gfHigh: 0).description == "Bühlmann")
        #expect(DiveData.DecoModel(type: .vpm, conservatism: 2, gfLow: 0, gfHigh: 0).description == "VPM (2)")
        #expect(DiveData.DecoModel(type: .rgbm, conservatism: 0).description == "RGBM")
        #expect(DiveData.DecoModel(type: .none, conservatism: 0).description == "None")
    }

    @Test func eventTypeMapping() {
        #expect(SampleInput.event(type: 3) == .ascent)            // SAMPLE_EVENT_ASCENT
        #expect(SampleInput.event(type: 13) == .safetyStop(mandatory: true))
        #expect(SampleInput.event(type: 12) == nil)               // voluntary safety stop: not shown
        #expect(SampleInput.event(type: 20) == .po2)
    }

    @Test func garbageDataFails() {
        #expect(throws: ParseError.datetimeRetrievalFailed(.dataFormat)) {
            try DiveParser.parse(family: .shearwaterPetrel, modelID: 11, data: Data([0, 1, 2]), diveNumber: 1)
        }
        #expect(throws: ParseError.parserCreationFailed(.unsupported)) {
            try DiveParser.parse(family: .shearwaterPetrel, modelID: 999, data: Data([0, 1, 2]), diveNumber: 1)
        }
    }
}
