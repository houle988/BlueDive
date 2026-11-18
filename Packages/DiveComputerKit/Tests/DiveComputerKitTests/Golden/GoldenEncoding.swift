import Foundation
@testable import DiveComputerKit

/// Maps DiveComputerKit's `DiveData` onto the canonical golden schema
/// (Docs/GOLDEN_FORMAT.md). Must stay field-for-field identical to the harness encoder.
enum GoldenEncoding {

    static func encode(_ dive: DiveData) -> GValue {
        var o: [String: GValue] = [:]
        o["number"] = .int(Int64(dive.number))
        o["datetime"] = .double(dive.datetime.timeIntervalSince1970)
        o["maxDepth"] = .double(dive.maxDepth)
        o["avgDepth"] = .double(dive.avgDepth)
        o["divetime"] = .double(dive.divetime)
        o["reportedDivetime"] = .opt(dive.reportedDivetime) { .double($0) }
        o["temperature"] = .double(dive.temperature)
        o["profile"] = .array(dive.profile.map(encodePoint))
        o["tankPressure"] = .array(dive.tankPressure.map { .double($0) })
        o["gasMix"] = .opt(dive.gasMix) { .int(Int64($0)) }
        o["gasMixCount"] = .opt(dive.gasMixCount) { .int(Int64($0)) }
        o["gasMixes"] = .opt(dive.gasMixes) { .array($0.map(encodeGasMix)) }
        o["salinity"] = .opt(dive.salinity) { .double($0) }
        o["atmospheric"] = .opt(dive.atmospheric) { .double($0) }
        o["surfaceTemperature"] = .opt(dive.surfaceTemperature) { .double($0) }
        o["measuredSurfaceTemperature"] = .opt(dive.measuredSurfaceTemperature) { .double($0) }
        o["minTemperature"] = .opt(dive.minTemperature) { .double($0) }
        o["maxTemperature"] = .opt(dive.maxTemperature) { .double($0) }
        o["tankCount"] = .opt(dive.tankCount) { .int(Int64($0)) }
        o["tanks"] = .opt(dive.tanks) { .array($0.map(encodeTank)) }
        o["diveMode"] = .opt(dive.diveMode) { .string(diveModeName($0)) }
        o["decoModel"] = .opt(dive.decoModel, encodeDecoModel)
        o["location"] = .opt(dive.location, encodeLocation)
        o["exitLocation"] = .opt(dive.exitLocation, encodeLocation)
        o["rbt"] = .opt(dive.rbt) { .int(Int64($0)) }
        o["heartbeat"] = .opt(dive.heartbeat) { .int(Int64($0)) }
        o["bearing"] = .opt(dive.bearing) { .int(Int64($0)) }
        o["setpoint"] = .opt(dive.setpoint) { .double($0) }
        o["ppo2Readings"] = .array(dive.ppo2Readings.map {
            .object(["sensor": .int(Int64($0.sensor)), "value": .double($0.value)])
        })
        o["cns"] = .opt(dive.cns) { .double($0) }
        o["decoStop"] = .opt(dive.decoStop) {
            .object(["depth": .double($0.depth), "time": .double($0.time), "type": .int(Int64($0.type))])
        }
        return .object(o)
    }

    static func encodePoint(_ p: ProfileSample) -> GValue {
        var o: [String: GValue] = [:]
        o["time"] = .double(p.time)
        o["depth"] = .double(p.depth)
        o["temperature"] = .opt(p.temperature) { .double($0) }
        o["pressure"] = .opt(p.pressure) { .double($0) }
        o["pressures"] = intKeyed(p.pressures)
        o["po2"] = .opt(p.po2) { .double($0) }
        o["sensorPPO2"] = intKeyed(p.sensorPPO2)
        o["pn2"] = .opt(p.pn2) { .double($0) }
        o["phe"] = .opt(p.phe) { .double($0) }
        o["events"] = .array(p.events.map { .string(eventName($0)) })
        o["ndl"] = .opt(p.ndl) { .int(Int64($0)) }
        o["decoStop"] = .opt(p.decoStop) { .double($0) }
        o["decoTime"] = .opt(p.decoTime) { .int(Int64($0)) }
        o["tts"] = .opt(p.tts) { .int(Int64($0)) }
        o["currentGas"] = .opt(p.currentGas) { .int(Int64($0)) }
        o["cns"] = .opt(p.cns) { .double($0) }
        o["rbt"] = .opt(p.rbt) { .int(Int64($0)) }
        o["heartbeat"] = .opt(p.heartbeat) { .int(Int64($0)) }
        o["bearing"] = .opt(p.bearing) { .int(Int64($0)) }
        o["setpoint"] = .opt(p.setpoint) { .double($0) }
        return .object(o)
    }

    static func intKeyed(_ dict: [Int: Double]) -> GValue {
        .array(dict.keys.sorted().map { .array([.int(Int64($0)), .double(dict[$0]!)]) })
    }

    static func encodeGasMix(_ g: GasMix) -> GValue {
        .object(["helium": .double(g.helium), "oxygen": .double(g.oxygen),
                 "nitrogen": .double(g.nitrogen), "usage": .string(usageName(g.usage))])
    }

    static func encodeTank(_ t: DiveData.Tank) -> GValue {
        .object(["volume": .double(t.volume), "workingPressure": .double(t.workingPressure),
                 "beginPressure": .double(t.beginPressure), "endPressure": .double(t.endPressure),
                 "gasMix": .int(Int64(t.gasMix)), "usage": .string(usageName(t.usage))])
    }

    static func encodeDecoModel(_ d: DiveData.DecoModel) -> GValue {
        .object(["type": .string(decoTypeName(d.type)), "conservatism": .int(Int64(d.conservatism)),
                 "gfLow": .opt(d.gfLow) { .int(Int64($0)) }, "gfHigh": .opt(d.gfHigh) { .int(Int64($0)) },
                 "description": .string(d.description)])
    }

    static func encodeLocation(_ l: DiveData.Location) -> GValue {
        .object(["latitude": .double(l.latitude), "longitude": .double(l.longitude),
                 "altitude": .opt(l.altitude) { .double($0) }])
    }

    static func eventName(_ e: SampleEvent) -> String {
        switch e {
        case .ascent: return "ascent"
        case .violation: return "violation"
        case .decoStop: return "decoStop"
        case .gasChange: return "gasChange"
        case .bookmark: return "bookmark"
        case .safetyStop(let mandatory): return mandatory ? "safetyStopMandatory" : "safetyStop"
        case .ceiling: return "ceiling"
        case .po2: return "po2"
        case .deepStop: return "deepStop"
        }
    }

    static func diveModeName(_ m: DiveData.DiveMode) -> String {
        switch m {
        case .freedive: return "freedive"
        case .gauge: return "gauge"
        case .openCircuit: return "openCircuit"
        case .closedCircuit: return "closedCircuit"
        case .semiClosedCircuit: return "semiClosedCircuit"
        }
    }

    static func decoTypeName(_ t: DiveData.DecoModel.DecoType) -> String {
        switch t {
        case .none: return "none"
        case .buhlmann: return "buhlmann"
        case .vpm: return "vpm"
        case .rgbm: return "rgbm"
        case .dciem: return "dciem"
        }
    }

    static func usageName(_ u: GasUsage) -> String {
        switch u {
        case .none: return "none"
        case .oxygen: return "oxygen"
        case .diluent: return "diluent"
        case .sidemount: return "sidemount"
        }
    }

    static func encodeError(_ error: ParseError) -> GValue {
        switch error {
        case .parserCreationFailed(let s): return .object(["kind": .string("parserCreationFailed"), "status": .int(Int64(s.rawValue))])
        case .datetimeRetrievalFailed(let s): return .object(["kind": .string("datetimeRetrievalFailed"), "status": .int(Int64(s.rawValue))])
        case .sampleProcessingFailed(let s): return .object(["kind": .string("sampleProcessingFailed"), "status": .int(Int64(s.rawValue))])
        case .invalidDate: return .object(["kind": .string("invalidDate"), "status": .null])
        }
    }
}
