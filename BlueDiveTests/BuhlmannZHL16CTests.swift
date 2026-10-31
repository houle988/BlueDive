import Foundation
import Testing
@testable import BlueDive

/// BlueDive's ZHL-16C tissue model (`BuhlmannZHL16C`, `BuhlmannProfile`), which gives the dive
/// chart's GF99 and Surface GF.
@MainActor
struct BuhlmannZHL16CTests {

    private let seaLevel = 1.01325
    private let saltDivisor = 100.0 / (1.030 * 9.81)
    private let air = TankData(o2: 0.21, he: 0)

    /// Inputs for a metric profile in salt water at sea level.
    private func inputs(_ points: [(time: Double, depth: Double)], tanks: [TankData]? = nil,
                        setpoint: Double? = nil) -> BuhlmannZHL16C.Inputs? {
        let samples = points.map { DiveProfilePoint(time: $0.time, depth: $0.depth, setpoint: setpoint) }
        return buhlmannInputs(samples: samples, tanks: tanks ?? [air], depthToMetres: 1,
                              surfacePressure: seaLevel, waterDivisor: saltDivisor)
    }

    @Test func surfaceOnAirKeepsTheStartingTissues() throws {
        let profile = BuhlmannProfile(inputs: try #require(inputs([(0, 0), (60, 0)])))
        let start = BuhlmannZHL16C.surfaceState(surfacePressure: seaLevel)
        let end = try #require(profile.states.last ?? nil)
        for i in 0..<BuhlmannZHL16C.compartmentCount {
            #expect(abs(end.n2[i] - start.n2[i]) < 1e-12)
            #expect(end.he[i] == 0)
        }
    }

    @Test func compartmentOneIsHalfwayAfterOneHalfTime() throws {
        // At 30 m from the first sample for 5 min, the N₂ half-time of compartment 1.
        let profile = BuhlmannProfile(inputs: try #require(inputs([(0, 30), (5, 30)])))
        let start = BuhlmannZHL16C.surfaceState(surfacePressure: seaLevel).n2[0]
        let inspired = (30 / saltDivisor + seaLevel - BuhlmannZHL16C.waterVapourPressure) * air.n2
        let end = try #require(profile.states.last ?? nil)
        #expect(abs(end.n2[0] - (start + (inspired - start) / 2)) < 1e-12)
    }

    @Test func schreinerRampMatchesSmallHaldaneSteps() throws {
        // Descent from 0 to 40 m in 4 min on trimix 21/35.
        let trimix = TankData(o2: 0.21, he: 0.35)
        let ramp = try #require(inputs([(0, 0), (4, 40)], tanks: [trimix]))
        let exact = try #require(BuhlmannProfile(inputs: ramp).states.last ?? nil)
        let segment = try #require(ramp.segments[0])

        // Constant-pressure (Haldane) steps of 0.06 s at each step's mid-point pressure.
        var state = BuhlmannZHL16C.surfaceState(surfacePressure: seaLevel)
        let steps = 4000
        let dt = 4.0 / Double(steps)
        for step in 0..<steps {
            let f = (Double(step) + 0.5) / Double(steps)
            let n2 = segment.n2Start + (segment.n2End - segment.n2Start) * f
            let he = segment.heStart + (segment.heEnd - segment.heStart) * f
            let flat = BuhlmannZHL16C.Segment(n2Start: n2, n2End: n2, heStart: he, heEnd: he)
            state = BuhlmannZHL16C.advance(state, through: flat, segmentMinutes: dt, elapsed: dt)
        }
        for i in 0..<BuhlmannZHL16C.compartmentCount {
            #expect(abs(state.n2[i] - exact.n2[i]) < 1e-6)
            #expect(abs(state.he[i] - exact.he[i]) < 1e-6)
        }
    }

    @Test func squareDiveSupersaturatesOnAscent() throws {
        // 30 m for 20 min on air, ascent at 9 m/min, then the surface.
        let profile = BuhlmannProfile(inputs: try #require(
            inputs([(0, 0), (1.5, 30), (21.5, 30), (24.833, 0), (26, 0)])))
        let atDepth = try #require(profile.values(atSample: 2))
        let surfaced = try #require(profile.values(atSample: 3))
        #expect(atDepth.surfaceGF > atDepth.gf99)
        #expect(atDepth.surfaceGF > 0)
        #expect(surfaced.gf99 > 0)
        #expect(abs(surfaced.gf99 - surfaced.surfaceGF) < 1e-9)
        // Off-gassing at the surface lowers it.
        let later = try #require(profile.values(atSample: 4))
        #expect(later.gf99 < surfaced.gf99)
    }

    @Test func cursorValueAtASampleMatchesTheSample() throws {
        let profile = BuhlmannProfile(inputs: try #require(inputs([(0, 0), (2, 20), (30, 20), (33, 5)])))
        for (index, time) in [(0, 0.0), (1, 2.0), (2, 30.0), (3, 33.0)] {
            #expect(profile.values(atMinutes: time) == profile.values(atSample: index))
        }
        let between = try #require(profile.values(atMinutes: 31.5))
        #expect(between.gf99.isFinite)
    }

    @Test func pureOxygenAndHelioxAreFinite() throws {
        for tank in [TankData(o2: 1.0, he: 0), TankData(o2: 0.21, he: 0.79)] {
            let profile = BuhlmannProfile(inputs: try #require(inputs([(0, 0), (2, 6), (20, 6), (22, 0)], tanks: [tank])))
            for index in profile.states.indices {
                let values = try #require(profile.values(atSample: index))
                #expect(values.gf99.isFinite && values.surfaceGF.isFinite)
            }
        }
    }

    @Test func samplesAtTheSameTimeLeaveTheStateUnchanged() throws {
        let profile = BuhlmannProfile(inputs: try #require(inputs([(0, 10), (3, 10), (3, 25), (2, 25)])))
        #expect(profile.states[2] == profile.states[1])
        #expect(profile.states[3] == profile.states[2])
    }

    @Test func noTankMeansNoCalculation() {
        #expect(inputs([(0, 0), (10, 20)], tanks: []) == nil)
    }

    @Test func loopWithoutInertGasStopsTheCalculation() throws {
        // On the loop (setpoint 1.3) with only an O₂ cylinder: the diluent is unknown.
        let profile = BuhlmannProfile(inputs: try #require(
            inputs([(0, 0), (2, 20), (10, 20)], tanks: [TankData(o2: 1.0, he: 0)], setpoint: 1.3)))
        #expect(profile.values(atSample: 0) != nil)
        #expect(profile.values(atSample: 1) == nil)
        #expect(profile.values(atSample: 2) == nil)
    }

    @Test func loopBreathesLessInertGasThanOpenCircuit() throws {
        let points: [(time: Double, depth: Double)] = [(0, 0), (2, 30), (40, 30)]
        let openCircuit = BuhlmannProfile(inputs: try #require(inputs(points)))
        let loop = BuhlmannProfile(inputs: try #require(inputs(points, setpoint: 1.3)))
        let oc = try #require(openCircuit.states.last ?? nil)
        let ccr = try #require(loop.states.last ?? nil)
        #expect(ccr.n2[0] < oc.n2[0])
    }

    // MARK: - Residual loading from earlier dives

    private let day1 = Date(timeIntervalSinceReferenceDate: 815_000_000)

    /// An earlier 26 m / 50 min air dive starting at `start`.
    private func prior(at start: Date, inputs override: BuhlmannZHL16C.Inputs?? = nil) throws -> BuhlmannZHL16C.PriorDive {
        let profile = try #require(inputs([(0, 0), (2, 26), (50, 26), (54, 5), (57, 5), (58, 0)]))
        return BuhlmannZHL16C.PriorDive(start: start, end: start.addingTimeInterval(58 * 60),
                                        inputs: override ?? profile)
    }

    private var shortDive: BuhlmannZHL16C.Inputs {
        get throws { try #require(inputs([(0, 0), (2, 18), (30, 18), (32, 5), (35, 5), (36, 0)])) }
    }

    @Test func noEarlierDiveStartsClean() throws {
        let residual = BuhlmannZHL16C.residual(priorDives: [], diveStart: day1, surfacePressure: seaLevel)
        #expect(residual.state == nil && residual.includedDives == 0 && !residual.missingDive)
    }

    @Test func earlierDiveAnHourBeforeRaisesSurfaceGF() throws {
        let earlier = try prior(at: day1)
        let start = earlier.end.addingTimeInterval(3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [earlier], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.includedDives == 1 && !residual.missingDive)
        let state = try #require(residual.state)
        // The slow compartments still hold more N₂ than tissues saturated at the surface.
        #expect(state.n2[15] > BuhlmannZHL16C.surfaceState(surfacePressure: seaLevel).n2[15])

        let clean = BuhlmannProfile(inputs: try shortDive)
        let repetitive = BuhlmannProfile(inputs: try shortDive, residual: residual)
        let last = clean.states.count - 1
        let cleanEnd = try #require(clean.values(atSample: last))
        let repetitiveEnd = try #require(repetitive.values(atSample: last))
        #expect(repetitiveEnd.surfaceGF > cleanEnd.surfaceGF)
    }

    @Test func earlierDive48HoursBeforeIsNotIncluded() throws {
        let earlier = try prior(at: day1)
        let start = earlier.end.addingTimeInterval(BuhlmannZHL16C.residualWindow)
        let residual = BuhlmannZHL16C.residual(priorDives: [earlier], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.state == nil && residual.includedDives == 0)
    }

    @Test func earlierDivesAreChainedBack() throws {
        // Three dives 20 h apart: the first is 40 h before the last earlier one, but each
        // gap is under 48 h, so both earlier dives are included.
        let first = try prior(at: day1)
        let second = try prior(at: first.end.addingTimeInterval(20 * 3600))
        let start = second.end.addingTimeInterval(20 * 3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [second, first], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.includedDives == 2)
    }

    @Test func earlierDiveWithoutProfileStartsCleanAndSaysSo() throws {
        let earlier = try prior(at: day1, inputs: .some(nil))
        let start = earlier.end.addingTimeInterval(3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [earlier], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.missingDive)
        #expect(residual.state == nil && residual.includedDives == 0)
    }

    @Test func overlappingRecordOfTheSameDiveIsSkipped() throws {
        // The same dive downloaded from a second computer, starting a minute earlier: it is not
        // a previous dive, so it must not load the tissues a second time.
        let copy = try prior(at: day1)
        let start = day1.addingTimeInterval(60)
        let residual = BuhlmannZHL16C.residual(priorDives: [copy], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.state == nil && residual.includedDives == 0 && !residual.missingDive)
    }

    @Test func overlappingCopyOfAnEarlierDiveIsSkippedButTheDiveIsKept() throws {
        // An earlier dive recorded by two computers, then this dive an hour later: one copy is
        // chained, the other skipped.
        let earlier = try prior(at: day1)
        let copy = try prior(at: day1.addingTimeInterval(60))
        let start = copy.end.addingTimeInterval(3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [earlier, copy], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.includedDives == 1)
    }

    @Test func tankWithoutOxygenIsAnUnknownMix() throws {
        // 0 % O₂ is an unknown mix (e.g. a gas an import did not record), never pure nitrogen.
        let profile = BuhlmannProfile(inputs: try #require(
            inputs([(0, 0), (2, 20), (30, 20)], tanks: [TankData(o2: 0, he: 0)])))
        #expect(profile.values(atSample: 1) == nil)
        #expect(profile.values(atSample: 2) == nil)
    }

    @Test func copyWithDataIsPreferredOverCopyWithout() throws {
        // An earlier dive recorded twice: the later-starting copy (a bottom timer) has no
        // profile, the other has. The one with data is chained, so nothing is reported missing.
        let withData = try prior(at: day1)
        let withoutData = try prior(at: day1.addingTimeInterval(60), inputs: .some(nil))
        let start = withoutData.end.addingTimeInterval(3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [withData, withoutData], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.includedDives == 1 && !residual.missingDive)
        #expect(residual.state != nil)
    }

    @Test func calculableCopyIsPreferredOverUnknownMixCopy() throws {
        // An earlier dive recorded twice: the later-starting copy has a profile but an unknown
        // mix (0 % O₂), so it cannot be calculated; the air copy is chained instead.
        let air = try prior(at: day1)
        let unknownMix = try #require(inputs([(0, 0), (2, 26), (50, 26), (54, 5), (57, 5), (58, 0)],
                                             tanks: [TankData(o2: 0, he: 0)]))
        let copy = BuhlmannZHL16C.PriorDive(start: day1.addingTimeInterval(60),
                                            end: day1.addingTimeInterval(59 * 60), inputs: unknownMix)
        #expect(!copy.isCalculable && air.isCalculable)
        let start = copy.end.addingTimeInterval(3600)
        let residual = BuhlmannZHL16C.residual(priorDives: [air, copy], diveStart: start, surfacePressure: seaLevel)
        #expect(residual.includedDives == 1 && !residual.missingDive && residual.state != nil)
    }

    @Test func noValueIsHeldOverWhereTheGasIsUnknown() throws {
        // On the loop with only an O₂ cylinder from the second sample: between samples 1 and 2
        // nothing is known, so the cursor shows nothing there rather than sample 1's values.
        let samples = [DiveProfilePoint(time: 0, depth: 0), DiveProfilePoint(time: 2, depth: 20),
                       DiveProfilePoint(time: 10, depth: 20, setpoint: 1.3)]
        let inputs = try #require(buhlmannInputs(samples: samples, tanks: [TankData(o2: 1.0, he: 0)],
                                                 depthToMetres: 1, surfacePressure: seaLevel,
                                                 waterDivisor: saltDivisor))
        // Pure O₂ on open circuit is known (no inert gas); the loop stretch is not.
        let looped = BuhlmannZHL16C.Inputs(times: inputs.times, ambient: inputs.ambient,
                                           segments: [inputs.segments[0], nil],
                                           surfacePressure: inputs.surfacePressure)
        let profile = BuhlmannProfile(inputs: looped)
        #expect(profile.values(atMinutes: 1) != nil)
        #expect(profile.values(atMinutes: 5) == nil)
    }

    @Test func setpointFallbackIsRecorded() throws {
        // On the loop with no voted ppO₂ and no cells, the setpoint is used, and said so.
        let setpointOnly = try #require(inputs([(0, 0), (2, 20), (10, 20)], setpoint: 1.3))
        #expect(setpointOnly.usesSetpointAsPPO2)
        // With a recorded ppO₂ it is not.
        let samples = [(0.0, 0.0), (2.0, 20.0), (10.0, 20.0)].map {
            DiveProfilePoint(time: $0.0, depth: $0.1, ppo2: 1.25, setpoint: 1.3)
        }
        let recorded = try #require(buhlmannInputs(samples: samples, tanks: [air], depthToMetres: 1,
                                                   surfacePressure: seaLevel, waterDivisor: saltDivisor))
        #expect(!recorded.usesSetpointAsPPO2)
        // Open circuit never.
        #expect(try #require(inputs([(0, 0), (2, 20)])).usesSetpointAsPPO2 == false)
    }

    @Test func sampleValueIsShownAtItsOwnTimeBeforeAnUnknownStretch() throws {
        let known = try #require(inputs([(0, 0), (2, 20), (10, 20)]))
        let profile = BuhlmannProfile(inputs: BuhlmannZHL16C.Inputs(
            times: known.times, ambient: known.ambient, segments: [known.segments[0], nil],
            surfacePressure: known.surfacePressure))
        #expect(profile.values(atMinutes: 2) != nil)
        #expect(profile.values(atMinutes: 2) == profile.values(atSample: 1))
        #expect(profile.values(atMinutes: 3) == nil)
    }

    @Test func setpointAfterTheGasBecomesUnknownIsNotFlagged() throws {
        // Open-circuit descent on an O₂-only tank list, then the loop: the loop stretches cannot
        // be calculated (no inert gas known), so no setpoint fed any calculated value.
        let samples = [DiveProfilePoint(time: 0, depth: 0), DiveProfilePoint(time: 1, depth: 6),
                       DiveProfilePoint(time: 2, depth: 6, setpoint: 1.3),
                       DiveProfilePoint(time: 10, depth: 6, setpoint: 1.3)]
        let inputs = try #require(buhlmannInputs(samples: samples, tanks: [TankData(o2: 1.0, he: 0)],
                                                 depthToMetres: 1, surfacePressure: seaLevel,
                                                 waterDivisor: saltDivisor))
        #expect(!inputs.usesSetpointAsPPO2)
    }

    @Test func setpointInAnEarlierDiveOfTheChainIsFlagged() throws {
        let ccr = try #require(inputs([(0, 0), (2, 20), (40, 20), (44, 0)], setpoint: 1.3))
        #expect(ccr.usesSetpointAsPPO2)
        let earlier = BuhlmannZHL16C.PriorDive(start: day1, end: day1.addingTimeInterval(44 * 60), inputs: ccr)
        let residual = BuhlmannZHL16C.residual(priorDives: [earlier], diveStart: earlier.end.addingTimeInterval(3600),
                                               surfacePressure: seaLevel)
        #expect(residual.includedDives == 1 && residual.usesSetpointAsPPO2)
    }
}
