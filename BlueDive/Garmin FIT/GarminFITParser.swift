import Foundation
import FITSwiftSDK

// MARK: - Garmin FIT Parser
//
// Parses Garmin FIT activity files and outputs [BlueDiveGlobalData] for import.
//
// FIT uses scaled SI units internally:
//   - Depth:       metres (Float64, scale applied by SDK)
//   - Temperature: °C (Int8)
//   - Pressure:    Pa (UInt32, ambient water pressure — not tank)
//   - NDL:         seconds (UInt32)
//   - Time:        FIT epoch seconds (1989-12-31 00:00:00 UTC)
//
// All values are output in metric (matching UDDF output contract):
//   distanceFormat: "meters", temperatureFormat: "°c", pressureFormat: "bar"

final class GarminFITParser: MesgListener, @unchecked Sendable {

    // MARK: - Public Result

    private(set) var dives: [BlueDiveGlobalData] = []

    // MARK: - Accumulators (filled during decode, then assembled)

    private var fileSerial: UInt32?
    private var deviceSerial: UInt32?
    private var deviceName: String?
    private var userName: String?

    /// All DiveGasMesg keyed by FIT messageIndex (the gas slot number used by gas-switch events).
    private var gasMap: [UInt16: DiveGasMesg] = [:]

    private var sessions: [SessionMesg] = []
    private var diveSummaries: [DiveSummaryMesg] = []
    private var records: [RecordMesg] = []
    private var events: [EventMesg] = []
    private var tankSummaries: [TankSummaryMesg] = []
    private var tankUpdates: [TankUpdateMesg] = []
    private var diveSettings: [DiveSettingsMesg] = []

    // MARK: - Public API

    func parse(data: Data) -> [BlueDiveGlobalData]? {
        let stream = FITSwiftSDK.InputStream(data: data)
        let decoder = Decoder(stream: stream)
        decoder.addMesgListener(self)
        do { try decoder.read() } catch { return nil }
        assembleDives()
        return dives.isEmpty ? nil : dives
    }

    // MARK: - MesgListener

    func onMesg(_ mesg: Mesg) throws {
        switch mesg.mesgNum {
        case Profile.MesgNum.fileId:
            let m = FileIdMesg(mesg: mesg)
            fileSerial = m.getSerialNumber()

        case Profile.MesgNum.userProfile:
            let m = UserProfileMesg(mesg: mesg)
            if userName == nil { userName = m.getFriendlyName() }

        case Profile.MesgNum.deviceInfo:
            let m = DeviceInfoMesg(mesg: mesg)
            if deviceSerial == nil { deviceSerial = m.getSerialNumber() }
            if deviceName == nil {
                deviceName = m.getProductName() ?? garminProductDisplayName(try? m.getGarminProduct())
            }

        case Profile.MesgNum.diveGas:
            let m = DiveGasMesg(mesg: mesg)
            if let idx = m.getMessageIndex() { gasMap[idx] = m }

        case Profile.MesgNum.session:
            sessions.append(SessionMesg(mesg: mesg))

        case Profile.MesgNum.diveSummary:
            diveSummaries.append(DiveSummaryMesg(mesg: mesg))

        case Profile.MesgNum.record:
            records.append(RecordMesg(mesg: mesg))

        case Profile.MesgNum.event:
            events.append(EventMesg(mesg: mesg))

        case Profile.MesgNum.tankSummary:
            tankSummaries.append(TankSummaryMesg(mesg: mesg))

        case Profile.MesgNum.tankUpdate:
            tankUpdates.append(TankUpdateMesg(mesg: mesg))

        case Profile.MesgNum.diveSettings:
            diveSettings.append(DiveSettingsMesg(mesg: mesg))

        default:
            break
        }
    }

    // MARK: - Assembly

    private func assembleDives() {
        let serial = fileSerial ?? deviceSerial

        // Map DiveSummaryMesg by the messageIndex of the SessionMesg it references.
        // DiveSummaryMesg.referenceIndex is the target session's own messageIndex field,
        // NOT its position in the sessions array. Using array position is wrong for
        // multi-session files where referenceIndex values may not be 0-based sequential.
        var summaryBySessionMsgIdx: [UInt16: DiveSummaryMesg] = [:]
        for summary in diveSummaries {
            if let refIdx = summary.getReferenceIndex() {
                summaryBySessionMsgIdx[refIdx] = summary
            }
        }

        // Accept sessions that are explicitly tagged as diving, or that have a
        // correlated DiveSummaryMesg (handles computers that omit the sport field).
        let diveSessions: [(index: Int, session: SessionMesg)] = sessions.enumerated().compactMap { i, s in
            let hasSummary = s.getMessageIndex().flatMap { summaryBySessionMsgIdx[$0] } != nil
            guard s.getSport() == .diving || hasSummary else { return nil }
            return (i, s)
        }
        guard !diveSessions.isEmpty else { return }

        // Build the global tank array from all DiveGasMesg, ordered by messageIndex.
        // Gas-switch events reference gases by messageIndex; we build a lookup map
        // to translate FIT gas index → position in the tanks array.
        let sortedGasIndices = gasMap.keys.sorted()
        var gasIndexToTankPos: [UInt16: Int] = [:]
        var globalTanks: [BlueDiveTankData] = []
        for (pos, idx) in sortedGasIndices.enumerated() {
            gasIndexToTankPos[idx] = pos
            let gas = gasMap[idx]!
            globalTanks.append(BlueDiveTankData(
                id: nil,
                oxygen: gas.getOxygenContent().map { Int($0) },
                helium: gas.getHeliumContent().map { Int($0) },
                double: false,
                volume: nil,
                startPressure: nil,
                endPressure: nil,
                workingPressure: nil,
                tankMaterial: nil,
                tankType: gas.getMode() == .closedCircuitDiluent ? "CCR" : nil
            ))
        }

        for (_, session) in diveSessions {
            guard let startDateTime = session.getStartTime(),
                  let totalElapsed = session.getTotalElapsedTime() else { continue }

            let startDate = startDateTime.date
            let durationSec = Int(totalElapsed.rounded())
            let endDate = startDate.addingTimeInterval(totalElapsed)
            let summary = session.getMessageIndex().flatMap { summaryBySessionMsgIdx[$0] }

            // Slice records and events to this session's time window.
            // Strict upper bound (<) prevents the first sample of session N+1 from
            // bleeding into session N when sessions are back-to-back.
            let sessionRecords = records.filter { r in
                guard let ts = r.getTimestamp()?.date else { return false }
                return ts >= startDate && ts < endDate
            }
            let sessionEvents = events.filter { e in
                guard let ts = e.getTimestamp()?.date else { return false }
                return ts >= startDate && ts < endDate
            }

            // Build gas-switch timeline for this session.
            // EventMesg.getData() for a diveGasSwitched event carries the FIT gas messageIndex.
            var gasSwitches: [(date: Date, tankIndex: Int)] = []
            for event in sessionEvents {
                guard event.getEvent() == .diveGasSwitched,
                      let ts = event.getTimestamp()?.date,
                      let rawData = event.getData() else { continue }
                let gasIdx = UInt16(rawData & 0xFFFF)
                if let tankPos = gasIndexToTankPos[gasIdx] {
                    gasSwitches.append((date: ts, tankIndex: tankPos))
                }
            }
            gasSwitches.sort { $0.date < $1.date }

            // Tank start/end pressures from TankSummaryMesg (one per transmitter per session).
            // Sensor IDs are mapped positionally to tank slots (first sensor → tank[0], etc.)
            // since DiveGasMesg carries no transmitter reference.
            // Upper bound extended by 120 s: TankSummaryMesg is a post-dive message and is
            // commonly emitted 1–2 s after the computed endDate.
            let sessionTankSummaries = tankSummaries.filter { ts in
                guard let tsDate = ts.getTimestamp()?.date else { return false }
                return tsDate >= startDate && tsDate <= endDate.addingTimeInterval(120)
            }
            var sensorOrder: [UInt32] = []
            var sensorPressures: [UInt32: (start: Double?, end: Double?)] = [:]
            for ts in sessionTankSummaries {
                guard let sensor = ts.getSensor() else { continue }
                if sensorPressures[sensor] == nil {
                    let startP = ts.getStartPressure().flatMap { $0 > 0 ? $0 : nil }
                    let endP   = ts.getEndPressure().flatMap   { $0 > 0 ? $0 : nil }
                    sensorPressures[sensor] = (startP, endP)
                    sensorOrder.append(sensor)
                }
            }
            // Restrict sessionTanks to gases referenced by this session's gas-switch events.
            // Single-gas dives with no switch events default to the first global gas (position 0).
            let referencedPositions: [Int]
            if gasSwitches.isEmpty {
                referencedPositions = globalTanks.isEmpty ? [] : [0]
            } else {
                referencedPositions = Array(Set(gasSwitches.map { $0.tankIndex })).sorted()
            }
            var posRemap: [Int: Int] = [:]
            for (newIdx, oldIdx) in referencedPositions.enumerated() {
                posRemap[oldIdx] = newIdx
            }
            gasSwitches = gasSwitches.map { (date: $0.date, tankIndex: posRemap[$0.tankIndex] ?? 0) }
            var sessionTanks = referencedPositions.map { globalTanks[$0] }
            for (pos, sensor) in sensorOrder.enumerated() where pos < sessionTanks.count {
                let p = sensorPressures[sensor]!
                let orig = sessionTanks[pos]
                sessionTanks[pos] = BlueDiveTankData(
                    id: orig.id,
                    oxygen: orig.oxygen,
                    helium: orig.helium,
                    double: orig.double,
                    volume: orig.volume,
                    startPressure: p.start,
                    endPressure: p.end,
                    workingPressure: orig.workingPressure,
                    tankMaterial: orig.tankMaterial,
                    tankType: orig.tankType
                )
            }

            // Per-sample tank pressure lookup from TankUpdateMesg.
            // Sensor IDs use the same ordering as TankSummaryMesg.
            // Updates fire every ~4–8 s; only samples coinciding with an update get a reading
            // (no step-hold interpolation — sparse data is expected).
            var sensorToTankPos: [UInt32: Int] = [:]
            for (pos, sensor) in sensorOrder.enumerated() {
                sensorToTankPos[sensor] = pos
            }
            let sessionTankUpdates = tankUpdates.filter { tu in
                guard let tuDate = tu.getTimestamp()?.date else { return false }
                return tuDate >= startDate && tuDate <= endDate
            }
            // Assign positions to any sensors seen only in updates (no paired TankSummaryMesg).
            // Cap at sessionTanks.count: indices beyond the tank array are orphaned and unusable.
            var nextSensorPos = sensorToTankPos.count
            for tu in sessionTankUpdates {
                guard let sensor = tu.getSensor(), sensorToTankPos[sensor] == nil else { continue }
                guard nextSensorPos < sessionTanks.count else { continue }
                sensorToTankPos[sensor] = nextSensorPos
                nextSensorPos += 1
            }
            // Build FIT-timestamp keyed lookup: rawTimestamp → [tankPos: bar].
            var updatesByTimestamp: [UInt32: [Int: Double]] = [:]
            for tu in sessionTankUpdates {
                guard let ts = tu.getTimestamp(),
                      let sensor = tu.getSensor(),
                      let pressure = tu.getPressure(), pressure > 0,
                      let tankPos = sensorToTankPos[sensor] else { continue }
                updatesByTimestamp[ts.timestamp, default: [:]][tankPos] = pressure
            }

            // Build dive profile samples with per-sample currentGas tracking.
            var sampleList: [BlueDiveSamplesData] = []
            var currentTankIndex: Int? = sessionTanks.isEmpty ? nil : 0
            var switchIterator = gasSwitches.makeIterator()
            var nextSwitch = switchIterator.next()
            // Track NDL history so we can extend the deco event flag into the final stop.
            // Some Descent firmware versions drop both ndlTime AND nextStopDepth when the diver
            // transitions to the last scheduled stop (e.g. 3 m), so we can't rely on either field
            // being present. We continue flagging samples as deco whenever NDL was last seen as 0
            // and the diver is still at meaningful depth (> 1.5 m), stopping when NDL recovers
            // to a positive value or the diver reaches the surface.
            var sampleNdlWasZero = false

            for record in sessionRecords {
                guard let ts = record.getTimestamp()?.date else { continue }
                let elapsed = ts.timeIntervalSince(startDate)
                guard elapsed >= 0, let depthM = record.getDepth() else { continue }

                // Advance active gas for any switches that occurred at or before this sample.
                while let sw = nextSwitch, sw.date <= ts {
                    currentTankIndex = sw.tankIndex
                    nextSwitch = switchIterator.next()
                }

                // NDL: FIT stores in seconds; BlueDiveSamplesData.ndt is minutes.
                let ndlTime = record.getNdlTime()
                if let n = ndlTime {
                    sampleNdlWasZero = (n == 0)   // resets to false when NDL recovers
                }
                let ndlMin = ndlTime.map { Int($0) / 60 }
                // Po2: SDK returns scaled value (raw UINT8 / 100); represents partial pressure.
                let ppo2 = record.getPo2()
                let tempC = record.getTemperature().map { Double($0) }

                // Mark sample as mandatory deco when:
                // • NDL is explicitly 0 (computer confirmed deco obligation), OR
                // • NDL was zero and Garmin dropped the field (nil) while the diver is still at
                //   depth — this covers the final deco stop where the watch stops reporting both
                //   ndlTime and nextStopDepth (firmware limitation on some Descent models).
                let isMandatoryDeco = (ndlTime == 0)
                    || (ndlTime == nil && sampleNdlWasZero && depthM > 1.5)

                sampleList.append(BlueDiveSamplesData(
                    time: elapsed,
                    depth: depthM,
                    pressure: nil,          // absolutePressure is ambient water, not tank
                    tankPressures: record.getTimestamp().flatMap { dt -> [Int: Double]? in
                        let t = dt.timestamp
                        // Exact match first; fall back ±1 s to handle independent clocks between
                        // the transmitter and the dive computer's record stream.
                        return updatesByTimestamp[t] ?? updatesByTimestamp[t - 1] ?? updatesByTimestamp[t + 1]
                    },
                    temperature: tempC,
                    ppo2: ppo2,
                    sensorPPO2: nil,
                    ndt: ndlMin,
                    events: isMandatoryDeco ? [.decoStop] : [],
                    currentGas: currentTankIndex
                ))
            }

            // Deco stops from the next-stop schedule recorded in profile samples.
            // nextStopDepth = stop the computer is scheduling (metres, Float64).
            // nextStopTime  = remaining required time at that stop (seconds, UInt32).
            // Classify by NDL: NDL == 0 → mandatory deco (type 2); NDL > 0 → safety stop (type 1).
            // Garmin emits nextStopDepth > 0 for safety stops on NDL dives too, so NDL is the
            // only reliable distinguisher. Some Descent firmware versions drop the ndlTime field
            // entirely once deco is entered (nil rather than 0); track whether NDL was previously
            // reported and treat nil-after-reported as exhausted (mandatory).
            var ndlWasReported = false
            var stopsByDepth: [Int: (depth: Double, time: TimeInterval, type: Int)] = [:]
            for record in sessionRecords {
                let ndl = record.getNdlTime()
                if ndl != nil { ndlWasReported = true }
                guard let stopDepth = record.getNextStopDepth(), stopDepth > 0,
                      let stopTimeSec = record.getNextStopTime(), stopTimeSec > 0 else { continue }
                let key = Int(stopDepth.rounded())
                let t = TimeInterval(stopTimeSec)
                let isMandatory = ndl == 0 || (ndl == nil && ndlWasReported)
                let stopType = isMandatory ? 2 : 1
                if let existing = stopsByDepth[key] {
                    let upgradedType = (existing.type == 2 || isMandatory) ? 2 : 1
                    stopsByDepth[key] = (depth: existing.depth, time: max(t, existing.time), type: upgradedType)
                } else {
                    stopsByDepth[key] = (depth: Double(stopDepth), time: t, type: stopType)
                }
            }
            let sessionDecoStops: [DecoStop] = stopsByDepth.values
                .sorted { $0.depth > $1.depth }
                .map { DecoStop(depth: $0.depth, time: $0.time, type: $0.type) }

            // Depth and duration: prefer DiveSummary over Session (summary is more precise).
            let maxDepth = summary?.getMaxDepth() ?? session.getMaxDepth() ?? 0.0
            let avgDepth = summary?.getAvgDepth() ?? session.getAvgDepth()
            // getBottomTime() from DiveSummary is the Descent's recorded dive time and matches
            // what the watch displays. totalElapsedTime is the broader session time and may
            // include pre-entry surface time if the diver activated dive mode early.
            let finalDuration = summary?.getBottomTime().map { Int($0.rounded()) } ?? durationSec
            let endCns = (summary?.getEndCns()
                ?? session.getEndCns()
                ?? sessionRecords.last(where: { $0.getCnsLoad() != nil })?.getCnsLoad()
            ).map { Double($0) }
            let surfaceIntervalMin = summary?.getSurfaceInterval().map { Int($0) / 60 }
            let diveNumber = summary?.getDiveNumber().map { Int($0) }
            let tempLow = session.getMinTemperature().map { Double($0) }
            let tempHigh = session.getMaxTemperature().map { Double($0) }

            // Stable identifier for duplicate detection: serial-startFITTimestamp.
            // Not a UUID, so the dedup engine routes it to the identifier path (not Path A/A-L).
            // Stable across re-imports of the same file.
            let startFIT = startDateTime.timestamp
            let identifier: String?
            if let s = serial {
                identifier = "\(s)-\(startFIT)"
            } else if startFIT > DateTime.min {
                identifier = "\(startFIT)"
            } else {
                identifier = nil
            }

            // Derived from classified stops — any mandatory stop (type 2) confirms a deco dive.
            // Consistent with BLE which checks decoStop.type == 2.
            let isDecompressionDive = sessionDecoStops.contains { $0.type == 2 }

            // GPS coordinates: FIT stores positions as signed 32-bit semicircles.
            // Conversion: degrees = semicircles × (180 / 2^31).
            let entryLat = session.getStartPositionLat().map { fitSemiToDeg($0) }
            let entryLon = session.getStartPositionLong().map { fitSemiToDeg($0) }
            let exitLat  = session.getEndPositionLat().map { fitSemiToDeg($0) }
            let exitLon  = session.getEndPositionLong().map { fitSemiToDeg($0) }

            // DiveSettingsMesg: gradient factors and water type.
            // Settings are global (not per-session) — pick the most recent one before this session.
            // A nil timestamp means the message has no time context and applies to all sessions.
            let settings: DiveSettingsMesg? = diveSettings.filter {
                guard let tsDate = $0.getTimestamp()?.date else { return true }
                return tsDate <= startDate
            }.last ?? diveSettings.first

            // Deco model string: "Bühlmann ZH-L16C GF lo/hi" or just the model name.
            let decoModel: String? = {
                guard let s = settings, let model = s.getModel() else { return nil }
                let base: String
                switch model {
                case .zhl16c:  base = "Bühlmann ZH-L16C"
                case .invalid: return nil
                }
                if let lo = s.getGfLow(), let hi = s.getGfHigh() {
                    return "\(base) GF \(lo)/\(hi)"
                }
                return base
            }()

            // Water type from dive settings (Fresh → "Fresh", Salt → "Salt", EN13319 → "EN13319").
            let fitWaterType: String? = settings.flatMap { s in
                switch s.getWaterType() {
                case .fresh:   return "Fresh"
                case .salt:    return "Salt"
                case .en13319: return "EN13319"
                default:       return nil
                }
            }

            let siteData: BlueDiveSiteData? = (entryLat != nil && entryLon != nil) || fitWaterType != nil ?
                BlueDiveSiteData(name: "", location: nil, country: nil, bodyOfWater: nil,
                                 waterType: fitWaterType, difficulty: nil, altitude: nil,
                                 latitude: entryLat, longitude: entryLon,
                                 exitLatitude: exitLat, exitLongitude: exitLon) : nil

            dives.append(BlueDiveGlobalData(
                distanceFormat: "meters",
                temperatureFormat: "°c",
                pressureFormat: "bar",
                volumeFormat: "liters",
                weightFormat: "kg",
                sourceImport: "Garmin FIT",
                isBlueDiveXMLImport: false,
                date: startDate,
                identifier: identifier,
                recordID: nil,
                diveNumber: diveNumber,
                rating: nil,
                repetitiveDive: nil,
                diver: userName,
                computer: deviceName,
                serial: serial.map { String($0) },
                maxDepth: maxDepth,
                averageDepth: avgDepth,
                duration: finalDuration,
                interval: nil,
                cns: endCns,
                decoModel: decoModel,
                isDecompressionDive: isDecompressionDive,
                tempAir: nil,
                tempHigh: tempHigh,
                tempLow: tempLow,
                visibility: nil,
                weight: nil,
                weather: nil,
                current: nil,
                surfaceConditions: nil,
                entryType: nil,
                diveMaster: nil,
                diveOperator: nil,
                skipper: nil,
                boat: nil,
                surfaceInterval: surfaceIntervalMin,
                notes: nil,
                tags: nil,
                site: siteData,
                types: [],
                buddies: [],
                gases: [],
                tanks: sessionTanks,
                gear: [],
                samples: sampleList,
                marineLifeSeen: [],
                decoStops: sessionDecoStops,
                rawDiveComputerData: nil,
                fingerprintData: nil
            ))
        }
    }

    // MARK: - Coordinate Conversion

    private func fitSemiToDeg(_ semicircles: Int32) -> Double {
        Double(semicircles) * (180.0 / 2_147_483_648.0)
    }

    // MARK: - Device Name

    private func garminProductDisplayName(_ product: GarminProduct?) -> String {
        guard let product else { return "Garmin Descent" }
        switch product {
        case .descent:         return "Garmin Descent"
        case .descentT1:       return "Garmin Descent T1"
        case .descentMk2:      return "Garmin Descent Mk2"
        case .descentMk2s:     return "Garmin Descent Mk2s"
        case .descentG1:       return "Garmin Descent G1"
        case .descentMk3:      return "Garmin Descent Mk3"
        case .descentMk3i:     return "Garmin Descent Mk3i"
        default:               return "Garmin Descent"
        }
    }
}
