import SwiftUI
import CoreBluetooth
import LibDCSwift
import os.log

// MARK: - Profile & Tank Processing

extension BluetoothScannerView {

    // MARK: - Unused Tank Filtering
    //
    // PURPOSE
    // -------
    // Some dive computer families report ALL configured gas mix slots as tanks,
    // even when only one gas was actually breathed during the dive.  For example
    // the Aqualung i300C always reports 3 gas slots regardless of usage, creating
    // 2 phantom "tanks" with no pressure data.  This filter removes those phantom
    // entries so only tanks that were actually used appear in the dive log.
    //
    // AFFECTED BRANDS (no C-level filtering in libdivecomputer)
    // ---------------------------------------------------------
    // - Oceanic Atom2:  Aqualung i300C, i200C, i770R, i550C, Oceanic Geo/Veo,
    //                   Sherwood Sage/Wisdom — reports 3–6 configured gas slots
    // - Pelagic I330R:  Aqualung i330R, Apeks DSX — same Oceanic-derived protocol
    // - HW OSTC3:       Heinrichs Weikamp OSTC 2/3/4/Sport — reports 3–5 mixes
    // - Cressi Goa:     Cressi Goa, Cartesio, Leonardo 2.0, Donatello
    // - DeepSix:        DeepSix Excursion
    // - Deepblu:        Deepblu Cosmiq+
    // - Oceans:         Oceans S1
    // - McLean:         McLean Extreme
    //
    // NOT AFFECTED (C-level parser already filters unused tanks)
    // ----------------------------------------------------------
    // Shearwater, Suunto, Scubapro/Uwatec, Mares, Divesoft, DiveSystem/Ratio
    // — these parsers only report tanks that are active/enabled with pressure
    //   data.  No Swift-side filtering is applied; data passes through as-is.
    //
    // LOGIC
    // -----
    // 1. Only runs when the "Filter unused tanks" toggle is ON (default: false)
    //    AND the connected device family is in familiesNeedingSwiftTankFilter.
    // 2. Determines which gas mix indices were actually used during the dive by:
    //    a) Scanning profile samples for DC_SAMPLE_GASMIX events (gas switches)
    //    b) Checking the header-level gasMix field (last-used gas index)
    //    c) Falling back to {0} (primary gas) if no evidence is found
    // 3. In the gas-mixes-only tank-building path (Path 3), only gas mixes whose
    //    index is in the used set are converted to TankData objects.
    // 4. The toggle is only visible in the UI when the connected (or previously
    //    paired) device belongs to an affected family.
    //
    // USER OVERRIDE
    // -------------
    // A diver carrying a configured-but-unused tank (e.g. pony bottle, bailout)
    // can turn off the toggle to import all configured gas slots as tanks.
    // The setting persists via @AppStorage("filterUnusedTanks").

    /// Families whose libdivecomputer parser does NOT filter unused tanks/gas mixes
    /// at the C level.  Only these need the Swift-side usedGasMixIndices filter.
    static let familiesNeedingSwiftTankFilter: Set<DeviceConfiguration.DeviceFamily> = [
        .oceanicAtom2,   // Reports all configured gas slots (3–6)
        .pelagicI330R,   // Same Oceanic-derived protocol
        .hwOstc3,        // Reports all 3–5 configured mixes, no DC_FIELD_TANK
        .cressiGoa,      // No DC_FIELD_TANK
        .deepsixExcursion,
        .deepbluCosmiq,
        .oceansS1,
        .mcleanExtreme,
    ]

    /// Maximum pressure drop (bar) allowed per profile sample pair before the reading is
    /// considered an AI transmitter dropout rather than real gas consumption.
    /// A diver cannot consume 10 bar in a single 5-30 second sample interval under any
    /// realistic conditions; readings that large are always signal-loss artifacts.
    private static let dropoutFilterBar = 10.0

    /// Minimum pressure lead (bar) a candidate tank must hold over the runner-up to be
    /// trusted as the breathing tank during a gas mix's active period. Temperature changes
    /// on a closed-valve tank can cause ~10-14 bar of accumulated apparent pressure drop as
    /// the diver descends into colder water; requires the breathing tank's genuine consumption
    /// to exceed that level to be distinguishable from noise.
    private static let pressureNoiseCeilingBar = 10.0

    /// Minimum ratio (winner / runner-up accumulated drops) at which the winner is trusted
    /// even when the absolute margin is below pressureNoiseCeilingBar. Catches short or
    /// shallow dives where genuine consumption is small in absolute terms but still clearly
    /// dominant (e.g. 7 bar vs 1 bar = 7× ratio).
    private static let pressureDropRatioThreshold = 3.0

    /// Returns the DeviceFamily of the currently connected device, if known.
    var connectedDeviceFamily: DeviceConfiguration.DeviceFamily? {
        guard let peripheral = selectedDevice,
              let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) else {
            return nil
        }
        return stored.family
    }

    /// Returns the set of gas mix indices that were actually used during the dive.
    /// Returns gas mix indices in the order they first appear via DC_SAMPLE_GASMIX in the profile.
    /// Used to infer which physical tank used which gas when the dive computer reports DC_GASMIX_UNKNOWN.
    static func orderedGasMixIndices(from diveData: DiveData) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for point in diveData.profile {
            if let gas = point.currentGas, gas >= 0, !seen.contains(gas) {
                seen.insert(gas)
                ordered.append(gas)
            }
        }
        return ordered
    }

    /// Checks profile gas-switch samples and the header-level gas mix.
    /// Falls back to {0} when no usage evidence is found (single-gas dive).
    static func usedGasMixIndices(from diveData: DiveData) -> Set<Int> {
        var indices = Set(diveData.profile.compactMap { $0.currentGas }.filter { $0 >= 0 })
        // Include the header-level gas mix (last-used gas) when available
        if let headerGas = diveData.gasMix { indices.insert(headerGas) }
        // If no evidence found, assume the primary gas (index 0) was used
        if indices.isEmpty { indices.insert(0) }
        return indices
    }

    /// Scans profile samples for the first and last non-zero pressure reading for a given tank index.
    /// Used when the dive computer header reports no begin/end pressure (e.g. pressure pod scenario).
    static func pressureRangeFromProfile(
        _ profile: [LibDCSwift.DiveProfilePoint],
        tankIndex: Int
    ) -> (start: Double?, end: Double?) {
        let readings = profile.compactMap { point -> Double? in
            let p = point.pressures[tankIndex] ?? (tankIndex == 0 ? point.pressure : nil)
            return (p ?? 0) > 0 ? p : nil
        }
        return (readings.first, readings.last)
    }

    /// Returns the header pressure when reported (> 0), otherwise falls back to a profile-derived value.
    static func resolvedPressure(header: Double, fallback: Double?) -> Double? {
        header > 0 ? header : fallback
    }

    /// Infers which DC tank index each gas mix index corresponds to by scanning profile
    /// pressure data. For each gas mix's active period, the tank whose pressure is
    /// decreasing the most is the one being breathed.
    ///
    /// On Shearwater, DC_GASMIX_UNKNOWN is always reported so the "tank N = mix N"
    /// heuristic fails when AI transmitter slot order ≠ gas configuration slot order.
    /// Returns nil when the profile lacks sufficient data for a reliable determination.
    private static func inferShearwaterGasMixToTank(
        profile: [LibDCSwift.DiveProfilePoint],
        tankCount: Int,
        gasMixCount: Int,
        minMappings: Int = 2
    ) -> [Int: Int]? {
        // Accumulate total pressure drop per (gasMixIndex, tankIndex) pair across all segments.
        // lastKnownGas carries the active gas mix forward through segments that lack an
        // explicit annotation — the raw LibDCSwift profile only places a currentGas value
        // on samples where a DC_SAMPLE_GASMIX event was fired; all other samples are nil.
        var drops: [Int: [Int: Double]] = [:]
        var lastKnownGas: Int? = nil
        for i in 1..<profile.count {
            let prev = profile[i - 1]
            let curr = profile[i]
            // Update lastKnownGas from prev first so the segment [prev→curr] is credited to
            // the gas that was active during the interval, not the incoming gas after a switch.
            if let g = prev.currentGas, g >= 0, g < gasMixCount { lastKnownGas = g }
            guard let gas = lastKnownGas else {
                if let g = curr.currentGas, g >= 0, g < gasMixCount { lastKnownGas = g }
                continue
            }
            for tankIdx in 0..<tankCount {
                let prevP = prev.pressures[tankIdx] ?? 0
                let currP = curr.pressures[tankIdx] ?? 0
                guard prevP > 0, currP > 0, prevP > currP else { continue }
                let drop = prevP - currP
                // Skip transmitter dropout artifacts — genuine consumption cannot exceed
                // dropoutFilterBar in a single sample interval under any realistic conditions.
                guard drop <= Self.dropoutFilterBar else { continue }
                drops[gas, default: [:]][tankIdx, default: 0] += drop
            }
            // Advance lastKnownGas after attribution so the next segment inherits the new gas.
            if let g = curr.currentGas, g >= 0, g < gasMixCount { lastKnownGas = g }
        }
        // For each gas mix, pick the tank with the largest accumulated pressure drop.
        // Trust unconditionally when no competing tank exists (runnerUp == 0). Otherwise
        // require a convincing absolute margin or ratio over the runner-up to avoid
        // temperature-artifact false positives. The ratio check handles short or shallow
        // dives where genuine consumption is small in absolute terms but clearly dominant.
        var result: [Int: Int] = [:]
        for (mix, tankDrops) in drops {
            let sorted = tankDrops.sorted { $0.value > $1.value }
            guard let best = sorted.first, best.value > 0 else { continue }
            let runnerUp = sorted.dropFirst().first?.value ?? 0
            let margin = best.value - runnerUp
            let ratio  = runnerUp > 0 ? best.value / runnerUp : Double.infinity
            guard runnerUp == 0 || margin >= Self.pressureNoiseCeilingBar || ratio >= Self.pressureDropRatioThreshold else { continue }
            result[mix] = best.key
        }
        // Only trust the result when at least minMappings confirmed and every mapped mix
        // resolves to a distinct tank (no two mixes pointing at the same AI transmitter).
        guard result.count >= minMappings, Set(result.values).count == result.count else { return nil }
        return result
    }

    /// Resolves the O2/He fractions and the gas-mix index for a single tank, applying
    /// device-family-specific fallback tiers when the DC reports DC_GASMIX_UNKNOWN.
    static func resolveGasMix(
        mixIndex: Int,
        tankIndex: Int,
        tankCount: Int,
        tankUsage: DiveData.Tank.Usage,
        dcGasMixes: [GasMix],
        profileGasMixOrder: [Int],
        deviceFamily: DeviceConfiguration.DeviceFamily?,
        headerGasMix: Int?
    ) -> (o2: Double, he: Double, resolvedMixIdx: Int?) {
        let o2: Double
        let he: Double
        var resolvedMixIdx: Int? = nil
        if mixIndex >= 0 && mixIndex < dcGasMixes.count {
            o2 = dcGasMixes[mixIndex].oxygen
            he = dcGasMixes[mixIndex].helium
            resolvedMixIdx = mixIndex
        } else if deviceFamily == .shearwaterPetrel && tankIndex < dcGasMixes.count {
            // Shearwater-only: tank N uses mix N (DC_GASMIX_UNKNOWN for tanks without AI pod)
            o2 = dcGasMixes[tankIndex].oxygen
            he = dcGasMixes[tankIndex].helium
            resolvedMixIdx = tankIndex
        } else if deviceFamily == .halcyonSymbios, tankUsage == .oxygen,
                  let pureO2Idx = dcGasMixes.indices.first(where: { dcGasMixes[$0].oxygen >= 0.99 }) {
            // Halcyon Symbios CCR: O2 supply tank carries DC_GASMIX_UNKNOWN by design.
            // Resolve by composition — find the pure-O2 mix (≥99% O2) instead of using index.
            o2 = dcGasMixes[pureO2Idx].oxygen
            he = dcGasMixes[pureO2Idx].helium
            resolvedMixIdx = pureO2Idx
        } else if deviceFamily != .halcyonSymbios,
                  tankIndex < profileGasMixOrder.count, profileGasMixOrder[tankIndex] < dcGasMixes.count {
            // DC_GASMIX_UNKNOWN on non-Shearwater: infer from profile appearance order.
            // Halcyon Symbios is excluded for two reasons: (a) tank enumeration order is
            // driven by transmitter wake-up time, decoupled from gas-switch order; (b) on
            // CCR dives the O2 supply tank and unpaired transmitters carry DC_GASMIX_UNKNOWN
            // by design and have no corresponding breathed mix — mapping them to "N-th
            // breathed mix" is semantically wrong. Halcyon falls to the positional tier below.
            if tankIndex >= dcGasMixes.count {
                Logger.shared.log("Tank \(tankIndex): \(tankCount) tanks but only \(dcGasMixes.count) mixes; using profile-order fallback", level: .warning)
            }
            o2 = dcGasMixes[profileGasMixOrder[tankIndex]].oxygen
            he = dcGasMixes[profileGasMixOrder[tankIndex]].helium
            resolvedMixIdx = profileGasMixOrder[tankIndex]
        } else if tankIndex < dcGasMixes.count {
            // Positional last resort: no profile evidence for this tank's gas
            o2 = dcGasMixes[tankIndex].oxygen
            he = dcGasMixes[tankIndex].helium
            resolvedMixIdx = tankIndex
        } else if let firstMix = dcGasMixes.first {
            o2 = firstMix.oxygen
            he = firstMix.helium
        } else {
            o2 = Double(headerGasMix ?? 21) / 100.0
            he = 0.0
        }
        return (o2, he, resolvedMixIdx)
    }

    /// Converts a LibDCSwift DiveEvent to a BlueDive DiveProfileEvent
    private static func convertDiveEvent(_ event: LibDCSwift.DiveEvent) -> DiveProfileEvent {
        switch event {
        case .ascent:
            return .ascent
        case .violation:
            return .violation
        case .decoStop:
            return .decoStop
        case .gasChange:
            return .gasChange
        case .bookmark:
            return .bookmark
        case .safetyStop(let mandatory):
            return .safetyStop(mandatory)
        case .ceiling:
            return .ceiling
        case .po2:
            return .po2
        case .deepStop:
            return .deepStop
        }
    }

    /// Remaps `currentGas` on each profile point from gas-mix index to tank-array index
    /// so consumers can index directly into `Dive.tanks`. Points whose gas-mix index has
    /// no mapping (e.g. filtered-out mixes) retain `currentGas = nil`.
    static func remapProfileCurrentGas(
        _ points: [DiveProfilePoint],
        using gasMixToTankIndex: [Int: Int]
    ) -> [DiveProfilePoint] {
        points.map { point in
            guard let gasIdx = point.currentGas, gasIdx >= 0 else { return point }
            return DiveProfilePoint(
                time: point.time, depth: point.depth, temperature: point.temperature,
                tankPressure: point.tankPressure, tankPressures: point.tankPressures,
                ndl: point.ndl, ppo2: point.ppo2, events: point.events,
                currentGas: gasMixToTankIndex[gasIdx]
            )
        }
    }

    /// Consolidates LibDCSwift profile points by merging event-only points into their
    /// corresponding time-based points, and synthesising events from DC_SAMPLE_DECO data.
    ///
    /// Events are only added when the dive computer explicitly reports them via DC_SAMPLE_EVENT
    /// or when a mandatory deco obligation is present (decoStop depth set for DC_DECO_DECOSTOP).
    /// NDL=0 alone does not generate a synthetic event.
    static func consolidateProfilePoints(
        _ profile: [LibDCSwift.DiveProfilePoint]
    ) -> [DiveProfilePoint] {
        // Group all points by their timestamp (seconds)
        var pointsByTime: [(time: TimeInterval, points: [LibDCSwift.DiveProfilePoint])] = []
        var lastTime: TimeInterval?

        for point in profile {
            if point.time == lastTime, !pointsByTime.isEmpty {
                pointsByTime[pointsByTime.count - 1].points.append(point)
            } else {
                pointsByTime.append((time: point.time, points: [point]))
                lastTime = point.time
            }
        }

        var result: [DiveProfilePoint] = []

        for group in pointsByTime {
            // Use the first point as the base (the DC_SAMPLE_TIME point)
            let base = group.points[0]
            // Collect explicit events from all points at this timestamp, deduplicating by type
            // (a computer firing both SAMPLE_EVENT_GASCHANGE and DC_SAMPLE_GASMIX at the same
            // timestamp would otherwise produce two .gasChange entries)
            var seen = Set<DiveProfileEvent>()
            var allEvents: [DiveProfileEvent] = group.points.flatMap { $0.events }
                .map { convertDiveEvent($0) }
                .filter { seen.insert($0).inserted }

            // Synthesize a decoStop event from DC_SAMPLE_DECO data when the dive computer
            // reports a mandatory deco obligation (decoStop depth is only set for DC_DECO_DECOSTOP).
            // NDL=0 alone does not imply a deco obligation and must not generate a synthetic event.
            if base.decoStop != nil {
                // Mandatory deco stop (decoStop depth is only set for DC_DECO_DECOSTOP)
                if !allEvents.contains(.decoStop) {
                    allEvents.append(.decoStop)
                }
            }

            let perTank: [Int: Double]? = base.pressures.isEmpty ? nil : base.pressures
            // Derive tankPressure from per-tank dict when available:
            // prefer tank 0 (primary), then lowest-index tank, then legacy single value
            let primaryPressure: Double? = perTank.flatMap { dict in
                dict[0] ?? dict.min(by: { $0.key < $1.key })?.value
            } ?? base.pressure

            // Use the last non-nil currentGas from this group — carries the most recent gas context.
            let currentGas: Int? = group.points.compactMap { $0.currentGas }.last

            result.append(DiveProfilePoint(
                time: base.time / 60.0, // LibDCSwift uses seconds, BlueDive uses minutes
                depth: base.depth,
                temperature: base.temperature,
                tankPressure: primaryPressure,
                tankPressures: perTank,
                ndl: base.ndl.map { Double($0) / 60.0 }, // Seconds to minutes
                ppo2: base.po2,
                events: allEvents,
                currentGas: currentGas
            ))
        }

        return result
    }

    /// Derives per-tank `usageStartTime` / `usageEndTime` from gas-switch events in the profile.
    /// Times are stored in seconds to match the convention expected by RMV/SAC calculations.
    ///
    /// - Parameters:
    ///   - tanks: Tank array to annotate.
    ///   - gasMixToTankIndex: Maps gas-mix index (as reported by `currentGas` / DC_SAMPLE_GASMIX)
    ///     to the corresponding index in `tanks`. Built during tank construction so that the
    ///     `dcTanks` path (where `tank.gasMix` ≠ array index) and filtered gas-mix paths are
    ///     handled correctly. When two tanks share the same gas-mix index (e.g. twinset sharing
    ///     a back-gas blend) the first tank in array order wins: the dictionary is built with
    ///     a `[resolved] == nil` guard so only the earliest tank keeps the entry and receives
    ///     usage times. This is intentional — tank 0 (the primary cylinder) should own the
    ///     gas-switch usage times for a shared blend.
    ///   - initialGasMixIndex: First gas-mix index active at dive start, derived from
    ///     `orderedGasMixIndices`. Opens a t=0 segment for the primary tank that the dive computer
    ///     never reports as an explicit switch event.
    ///   - profileSamples: Consolidated BlueDive profile points.
    static func applyGasSwitchUsageTimes(
        to tanks: [TankData],
        gasMixToTankIndex: [Int: Int],
        initialGasMixIndex: Int?,
        profileSamples: [DiveProfilePoint]
    ) -> [TankData] {
        // currentGas on profile samples is already a tank-array index (remapped before storage).
        // Negative values are filtered out; nil means no gas context at this sample.
        let rawSwitches: [(time: Double, tankIdx: Int)] = profileSamples
            .filter { $0.events.contains(.gasChange) }
            .compactMap { sample in
                guard let tankIdx = sample.currentGas, tankIdx >= 0 else { return nil }
                return (time: sample.time, tankIdx: tankIdx)
            }
            .sorted { $0.time < $1.time }
        guard !rawSwitches.isEmpty else {
            // Single-tank dive with no gas-change events: seed a full-dive segment so
            // RMV/SAC is available for the most common case (one tank, one gas, no switches).
            guard let initMix = initialGasMixIndex, initMix >= 0,
                  let initTankIdx = gasMixToTankIndex[initMix],
                  let endTime = profileSamples.last?.time, endTime > 0 else { return tanks }
            return tanks.enumerated().map { (idx, tank) in
                guard idx == initTankIdx,
                      tank.usageStartTime == nil, tank.usageEndTime == nil else { return tank }
                return TankData(
                    id: tank.id,
                    o2: tank.o2, he: tank.he,
                    volume: tank.volume,
                    startPressure: tank.startPressure,
                    endPressure: tank.endPressure,
                    workingPressure: tank.workingPressure,
                    tankMaterial: tank.tankMaterial,
                    tankType: tank.tankType,
                    usageStartTime: 0,
                    usageEndTime: endTime * 60.0
                )
            }
        }

        // Coalesce near-simultaneous switches (within 1e-6 minutes ≈ 60 μs) to the last
        // event at that instant. Prevents a rapid A→B→A double-flip from creating a tiny
        // non-contiguous gap that would falsely trigger the switch-back guard.
        let switches = rawSwitches.reduce(into: [(time: Double, tankIdx: Int)]()) { acc, s in
            if let last = acc.last, abs(last.time - s.time) < 1e-6 {
                acc[acc.count - 1] = s
            } else {
                acc.append(s)
            }
        }

        let diveEndMinutes = max(profileSamples.last?.time ?? 0, switches.last!.time)

        // Build (tankArrayIndex, startMinutes, endMinutes) segments.
        var segments: [(tank: Int, start: Double, end: Double)] = []

        // Open a t=0 segment for the initial gas — derived from profile data, not hardcoded.
        // The dive computer never emits an explicit switch event for the starting gas, so we
        // infer it from the first gas-mix index seen in the profile via orderedGasMixIndices.
        // Guard against a DC that re-asserts the starting gas as its first switch event: if
        // switches[0] targets the same tank as initTankIdx, the switch itself already covers
        // the full segment — seeding a duplicate would create mine.count == 2 and falsely
        // trigger the switch-back skip for the primary tank.
        if let initMix = initialGasMixIndex, initMix >= 0,
           let initTankIdx = gasMixToTankIndex[initMix],
           switches[0].tankIdx != initTankIdx,
           switches[0].time > 0 {
            segments.append((tank: initTankIdx, start: 0.0, end: switches[0].time))
        }

        for i in 0..<switches.count {
            let endTime = i + 1 < switches.count ? switches[i + 1].time : diveEndMinutes
            segments.append((tank: switches[i].tankIdx, start: switches[i].time, end: endTime))
        }

        return tanks.enumerated().map { (idx, tank) in
            guard tank.usageStartTime == nil && tank.usageEndTime == nil else { return tank }
            let mine = segments.filter { $0.tank == idx }
            guard !mine.isEmpty else { return tank }
            // Merge contiguous same-tank segments produced by duplicate switch events
            // (e.g. OSTC-style computers that re-emit gasChange at adjacent samples).
            // Epsilon tolerance guards against sub-ulp float drift from seconds/minutes conversion.
            let merged = mine.reduce(into: [(tank: Int, start: Double, end: Double)]()) { acc, seg in
                if let last = acc.last, abs(last.end - seg.start) < 1e-6 {
                    acc[acc.count - 1] = (tank: last.tank, start: last.start, end: seg.end)
                } else {
                    acc.append(seg)
                }
            }
            // Drop zero-duration segments (e.g. seed at t=0 when first switch is also at t=0,
            // or a trailing gas-change on the very last sample).
            let valid = merged.filter { $0.end > $0.start }
            // Skip tanks used in multiple non-contiguous segments (switch-back dives).
            // A single usageStart…usageEnd span would cover the gap and inflate the RMV/SAC
            // denominator, producing a falsely low consumption rate.
            guard valid.count == 1 else { return tank }
            return TankData(
                id: tank.id,
                o2: tank.o2, he: tank.he,
                volume: tank.volume,
                startPressure: tank.startPressure,
                endPressure: tank.endPressure,
                workingPressure: tank.workingPressure,
                tankMaterial: tank.tankMaterial,
                tankType: tank.tankType,
                usageStartTime: valid[0].start * 60.0,
                usageEndTime: valid[0].end * 60.0
            )
        }
    }

    // MARK: - Convert to BlueDive Dive

    /// Converts a LibDCSwift DiveData to a BlueDive Dive
    func convertToBlueDiveDive(_ diveData: DiveData, diveNumber: Int, previousDiveEndTime: Date?, diverName: String) -> Dive {
        // Convert the dive profile, merging event-only points into time-based points.
        // currentGas is remapped from gas-mix index to tank-array index after gasMixToTankIndex
        // is built (see below), so rawProfileSamples is an intermediate variable.
        let rawProfileSamples = Self.consolidateProfilePoints(diveData.profile)

        // Calculate average depth from profile (time-weighted average)
        let averageDepth: Double = diveData.avgDepth

        // Extract min/max temperatures from the profile
        let profileTemperatures = diveData.profile.compactMap { $0.temperature }
        let minTemperature: Double = diveData.minTemperature ?? profileTemperatures.min() ?? diveData.temperature
        let maxTemperature: Double? = diveData.maxTemperature ?? profileTemperatures.max()

        // Build tanks with inline gas data from LibDCSwift.
        // Also build gasMixToTankIndex: maps gas-mix index (as reported by DC_SAMPLE_GASMIX /
        // currentGas in profile) to the corresponding position in linkedTanks.
        let dcGasMixes = diveData.gasMixes ?? []
        var linkedTanks: [TankData] = []
        var gasMixToTankIndex: [Int: Int] = [:]
        let profileGasMixOrder = Self.orderedGasMixIndices(from: diveData)

        if let dcTanks = diveData.tanks, !dcTanks.isEmpty {
            // For Shearwater AI dives: derive gas-mix→tank assignment from pressure data.
            // The DC always reports DC_GASMIX_UNKNOWN, so "tank N = mix N" (tier 2) is
            // unreliable when AI transmitter slot order ≠ gas configuration slot order.
            // minMappings=1: even a single confirmed mapping is useful — if exactly one
            // (mix, tank) pair remains undetermined after inference, it is forced by
            // elimination (the only remaining slot must be the only remaining mix).
            let pressureGuidedMixForTank: [Int: Int]  // [tankIndex → mixIndex]
            if connectedDeviceFamily == .shearwaterPetrel, dcGasMixes.count > 1,
               var pgMap = Self.inferShearwaterGasMixToTank(
                   profile: diveData.profile,
                   tankCount: dcTanks.count,
                   gasMixCount: dcGasMixes.count,
                   minMappings: 1) {
                // If exactly one mix→tank pair is still undetermined, it is forced by
                // elimination: the sole remaining tank slot can only hold the sole
                // remaining mix. This handles dives where only one gas is ever breathed.
                let unmappedMixes = Set(dcGasMixes.indices).subtracting(pgMap.keys)
                let unassignedTanks = Set(0..<dcTanks.count).subtracting(pgMap.values)
                if unmappedMixes.count == 1, unassignedTanks.count == 1,
                   let lastMix = unmappedMixes.first, let lastTank = unassignedTanks.first {
                    pgMap[lastMix] = lastTank
                }
                pressureGuidedMixForTank = Dictionary(uniqueKeysWithValues: pgMap.map { ($0.value, $0.key) })
                for (mixIdx, tankIdx) in pgMap { gasMixToTankIndex[mixIdx] = tankIdx }
            } else {
                pressureGuidedMixForTank = [:]
            }

            for (index, tank) in dcTanks.enumerated() {
                let o2: Double
                let he: Double
                var resolvedMixIdx: Int? = nil

                if let mixIdx = pressureGuidedMixForTank[index], mixIdx < dcGasMixes.count {
                    // Pressure-guided: use the gas mix whose pressure matched this tank.
                    // gasMixToTankIndex was already pre-populated above.
                    o2 = dcGasMixes[mixIdx].oxygen
                    he = dcGasMixes[mixIdx].helium
                } else {
                    let result = Self.resolveGasMix(
                        mixIndex: tank.gasMix,
                        tankIndex: index,
                        tankCount: dcTanks.count,
                        tankUsage: tank.usage,
                        dcGasMixes: dcGasMixes,
                        profileGasMixOrder: profileGasMixOrder,
                        deviceFamily: connectedDeviceFamily,
                        headerGasMix: diveData.gasMix
                    )
                    o2 = result.o2
                    he = result.he
                    resolvedMixIdx = result.resolvedMixIdx
                    if let resolved = resolvedMixIdx, gasMixToTankIndex[resolved] == nil {
                        gasMixToTankIndex[resolved] = index
                    }
                }

                // When the dive computer header reports no begin/end pressure (pressure pod scenario),
                // derive start and end pressure from the first/last non-zero profile sample.
                let profilePressures = (tank.beginPressure <= 0 || tank.endPressure <= 0)
                    ? Self.pressureRangeFromProfile(diveData.profile, tankIndex: index)
                    : (start: nil, end: nil)
                let startPressure = Self.resolvedPressure(header: tank.beginPressure, fallback: profilePressures.start)
                let endPressure   = Self.resolvedPressure(header: tank.endPressure,   fallback: profilePressures.end)
                linkedTanks.append(TankData(
                    o2: o2, he: he,
                    volume: tank.volume > 0 ? tank.volume : nil,
                    startPressure: startPressure,
                    endPressure: endPressure,
                    workingPressure: tank.workingPressure > 0 ? tank.workingPressure : nil
                ))
            }

            // Add TankData for gas mixes not yet claimed by any AI tank.
            // Handles dives with fewer AI transmitters than gas mixes — e.g. one AI back-gas
            // plus N non-AI stage/deco bottles. Non-AI tanks carry gas mix data only;
            // they have no pressure data because there is no transmitter for them.
            let needsFilter = filterUnusedTanks && (connectedDeviceFamily.map { Self.familiesNeedingSwiftTankFilter.contains($0) } ?? true)
            let usedMixIndicesForSupplement = needsFilter ? Self.usedGasMixIndices(from: diveData) : nil
            for mixIdx in dcGasMixes.indices {
                guard gasMixToTankIndex[mixIdx] == nil else { continue }
                if let used = usedMixIndicesForSupplement, !used.contains(mixIdx) { continue }
                let tankIdx = linkedTanks.count
                gasMixToTankIndex[mixIdx] = tankIdx
                linkedTanks.append(TankData(o2: dcGasMixes[mixIdx].oxygen, he: dcGasMixes[mixIdx].helium))
            }
        } else if !diveData.tankPressure.isEmpty {
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            let startP = diveData.tankPressure.first(where: { $0 > 0 })
            let endP   = diveData.tankPressure.last(where:  { $0 > 0 })
            linkedTanks.append(TankData(o2: o2Fraction, he: 0.0, startPressure: startP, endPressure: endP))
            gasMixToTankIndex[0] = 0
        } else if !dcGasMixes.isEmpty {
            let needsFilter = filterUnusedTanks && (connectedDeviceFamily.map { Self.familiesNeedingSwiftTankFilter.contains($0) } ?? true)
            let usedMixes = needsFilter ? Self.usedGasMixIndices(from: diveData) : nil
            var tankIdx = 0
            linkedTanks = dcGasMixes.enumerated().compactMap { (index, mix) in
                if let used = usedMixes {
                    guard used.contains(index) else { return nil }
                }
                gasMixToTankIndex[index] = tankIdx
                tankIdx += 1
                return TankData(o2: mix.oxygen, he: mix.helium)
            }
        } else {
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            linkedTanks.append(TankData(o2: o2Fraction, he: 0.0))
            gasMixToTankIndex[0] = 0
        }

        // Remap profile currentGas from gas-mix index to tank-array index now that
        // gasMixToTankIndex is fully built.
        let profileSamples = Self.remapProfileCurrentGas(rawProfileSamples, using: gasMixToTankIndex)

        // Dive mode
        let diveType: String
        if let diveMode = diveData.diveMode {
            switch diveMode {
            case .freedive:
                diveType = "Freediving"
            case .gauge:
                diveType = "Gauge"
            case .openCircuit:
                diveType = "Open Circuit"
            case .closedCircuit:
                diveType = "Rebreather"
            case .semiClosedCircuit:
                diveType = "Semi-Rebreather"
            }
        } else {
            diveType = "Reef"
        }

        // Decompression model
        let decompressionAlgorithm: String?
        if let decoModel = diveData.decoModel {
            decompressionAlgorithm = decoModel.description
        } else {
            decompressionAlgorithm = nil
        }

        // Mandatory decompression dive?
        // DC_DECO_DECOSTOP = 2: only mandatory decompression stops count
        // diveData.decoStop is always non-nil when the computer reports deco samples,
        // even for NDL dives (type 0), so we must check the type field.
        let isDecompressionDive = (diveData.decoStop?.type == 2)
            || diveData.profile.contains { $0.decoStop != nil }
            || diveData.profile.contains { $0.events.contains(.decoStop) }

        // Water type from salinity (g/cm³): ~1.0 = Fresh, ~1.025 = Salt
        let waterType: String? = diveData.salinity.map { sal in
            if sal < 1.01 { "Freshwater" }
            else if sal == 1.02 { "EN13319" }
            else { "Saltwater" }
        }

        // Location GPS
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        if let location = diveData.location,
           (-90...90).contains(location.latitude),
           (-180...180).contains(location.longitude),
           !(location.latitude == 0 && location.longitude == 0) {
            latitude = location.latitude
            longitude = location.longitude
            altitude = location.altitude
        } else {
            latitude = nil
            longitude = nil
            altitude = nil
        }

        // CNS: use top-level value, or last profile sample with CNS data
        let cnsValue: Double? = diveData.cns ?? diveData.profile.last(where: { $0.cns != nil })?.cns

        // Calculate surface interval from previous dive end time
        let surfaceIntervalString: String
        var isRepetitiveDive = false
        if let previousEnd = previousDiveEndTime {
            let intervalSeconds = diveData.datetime.timeIntervalSince(previousEnd)
            if intervalSeconds > 0 {
                let totalMinutes = Int(intervalSeconds / 60)
                let days    = totalMinutes / 1440
                let hours   = (totalMinutes % 1440) / 60
                let minutes = totalMinutes % 60

                if days > 0 {
                    surfaceIntervalString = "\(days)d \(hours)h \(String(format: "%02d", minutes))m"
                } else {
                    surfaceIntervalString = "\(hours)h \(String(format: "%02d", minutes))m"
                }

                // A dive is repetitive if the surface interval is less than 24 hours (1440 minutes)
                isRepetitiveDive = totalMinutes < 1440
            } else {
                surfaceIntervalString = "0h 00m"
            }
        } else {
            surfaceIntervalString = "0h 00m"
        }

        let computerSerial = selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString)?.serial }

        // Create the dive
        let dive = Dive(
            diveNumber: diveNumber,
            timestamp: diveData.datetime,
            location: "",
            siteName: "",
            diveTypes: diveType,
            computerName: selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString) }.flatMap { stored in DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family })?.name } ?? connectedDeviceName ?? NSLocalizedString("dive.computer.default_ble_name",
                                                                    comment: "Fallback name for an unknown Bluetooth dive computer"),
            computerSerialNumber: computerSerial,
            surfaceInterval: surfaceIntervalString,
            diverName: diverName,
            buddies: "",
            rating: 0,
            isRepetitiveDive: isRepetitiveDive,
            maxDepth: diveData.maxDepth,
            averageDepth: averageDepth,
            duration: Int(diveData.divetime / 60), // LibDCSwift uses seconds
            waterTemperature: diveData.temperature,
            minTemperature: minTemperature,
            airTemperature: diveData.surfaceTemperature,
            maxTemperature: maxTemperature,
            decompressionAlgorithm: decompressionAlgorithm,
            cnsPercentage: cnsValue,
            isDecompressionDive: isDecompressionDive,
            notes: "",
            importDistanceUnit: "meters",
            importTemperatureUnit: "°c",
            importPressureUnit: "bar",
            importVolumeUnit: "liters",
            importWeightUnit: (WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "kilograms") ?? .kilograms).symbol,
            sourceImport: "Bluetooth",
            siteWaterType: waterType,
            siteAltitude: altitude,
            siteLatitude: latitude,
            siteLongitude: longitude,
            profileSamples: profileSamples
        )

        let initialGasMixIndex = profileGasMixOrder.first
        dive.tanks = Self.applyGasSwitchUsageTimes(
            to: linkedTanks,
            gasMixToTankIndex: gasMixToTankIndex,
            initialGasMixIndex: initialGasMixIndex,
            profileSamples: profileSamples
        )
        dive.rawDiveComputerData = diveData.rawData
        dive.fingerprintData = diveData.fingerprint
        dive.decoStops = diveData.decoStop.map { stop in
            [DecoStop(depth: stop.depth, time: stop.time, type: stop.type)]
        } ?? []

        if let exitLoc = diveData.exitLocation,
           (-90...90).contains(exitLoc.latitude),
           (-180...180).contains(exitLoc.longitude),
           !(exitLoc.latitude == 0 && exitLoc.longitude == 0) {
            dive.exitLatitude = exitLoc.latitude
            dive.exitLongitude = exitLoc.longitude
        }

        return dive
    }
}
