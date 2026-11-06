import Foundation
import CLibDiveComputer

/// Why a dive's raw bytes could not be parsed.
public enum ParseError: Error, Sendable, Equatable {
    /// No libdivecomputer descriptor for (family, model), or the parser rejected the data.
    case parserCreationFailed(DCStatus)
    case datetimeRetrievalFailed(DCStatus)
    case sampleProcessingFailed(DCStatus)
    /// The dive's date components do not form a valid date.
    case invalidDate
}

/// Parses one dive's raw bytes with libdivecomputer (Docs/BEHAVIOURAL_SPEC.md §6).
///
/// Thread-safe: each call creates and destroys its own parser.
public enum DiveParser {

    /// Surface pressure values outside this range are not stored (bar). Some computers
    /// report 0 when they have no reading.
    public static let validAtmosphericRange: ClosedRange<Double> = 0.4...1.2

    /// `DC_FIELD_DIVETIME` above this is discarded (an unsigned fallback can wrap).
    static let maximumReportedDivetime: UInt32 = 48 * 3600

    /// Parses `data` as a dive of (family, modelID).
    /// - Parameter diveNumber: stored as `DiveData.number` (provisional numbering).
    public static func parse(family: DeviceFamily, modelID: UInt32, data: Data,
                             diveNumber: Int) throws(ParseError) -> DiveData {
        var parserPointer: OpaquePointer?
        let created = DescriptorLookup.withDescriptor(family: family.dcFamily, model: modelID) { descriptor in
            data.withUnsafeBytes { buffer in
                dc_parser_new2(&parserPointer, nil, descriptor,
                               buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            }
        } ?? DC_STATUS_UNSUPPORTED
        guard created == DC_STATUS_SUCCESS, let parser = parserPointer else {
            throw .parserCreationFailed(DCStatus(created))
        }
        defer { dc_parser_destroy(parser) }

        var datetime = dc_datetime_t()
        let dateStatus = dc_parser_get_datetime(parser, &datetime)
        guard dateStatus == DC_STATUS_SUCCESS else { throw .datetimeRetrievalFailed(DCStatus(dateStatus)) }

        let fields = FieldReader(parser: parser)
        let gasMixes = fields.gasMixes()

        // Setpoint handling (Docs/BEHAVIOURAL_SPEC.md §6 step 3).
        let setpointPerSample = reportsSetpointEverySample(family)
        var diluents = Set<UInt32>()
        var oxygens = Set<UInt32>()
        if !setpointPerSample {
            for (index, mix) in gasMixes.mixes.enumerated() {
                if mix.usage == .diluent { diluents.insert(UInt32(index)) }
                if mix.usage == .oxygen { oxygens.insert(UInt32(index)) }
            }
            if diluents.isEmpty { oxygens = [] }
        }
        let accumulator = SampleAccumulator(setpointPerSample: setpointPerSample,
                                            diluentIndices: diluents, oxygenIndices: oxygens)

        let unmanaged = Unmanaged.passUnretained(accumulator)
        let sampleStatus = dc_parser_samples_foreach(parser, sampleCallback, unmanaged.toOpaque())
        guard sampleStatus == DC_STATUS_SUCCESS else { throw .sampleProcessingFailed(DCStatus(sampleStatus)) }
        accumulator.finish()

        // Fields (§6 step 5). The computer's temperatures override the profile's.
        if let minimum = fields.double(DC_FIELD_TEMPERATURE_MINIMUM) { accumulator.tempMinimum = minimum }
        if let maximum = fields.double(DC_FIELD_TEMPERATURE_MAXIMUM) { accumulator.tempMaximum = maximum }
        var measuredSurface: Double = .infinity
        if let surface = fields.double(DC_FIELD_TEMPERATURE_SURFACE) {
            accumulator.tempSurface = surface
            measuredSurface = surface
        }

        let reportedDivetime = fields.uint32(DC_FIELD_DIVETIME)
            .flatMap { $0 > 0 && $0 <= maximumReportedDivetime ? TimeInterval($0) : nil }
        let pnf = isShearwaterPNF(family: family, data: data)

        let avgDepth: Double
        if let field = fields.double(DC_FIELD_AVGDEPTH), field.isFinite, field > 0 {
            avgDepth = field
        } else {
            avgDepth = AverageDepth.of(accumulator.profile, until: pnf ? reportedDivetime : nil)
        }

        // Legacy Shearwater logs record the maximum in whole metres/feet: use the samples.
        let maxDepth: Double
        if family != .shearwaterPetrel || pnf,
           let field = fields.double(DC_FIELD_MAXDEPTH), field.isFinite, field > 0 {
            maxDepth = field
        } else {
            maxDepth = accumulator.maxDepth
        }

        let atmospheric = fields.double(DC_FIELD_ATMOSPHERIC)
            .flatMap { $0.isFinite && validAtmosphericRange.contains($0) ? $0 : nil }

        guard let date = localDate(datetime) else { throw .invalidDate }
        let tanks = fields.tanks()

        return DiveData(
            number: diveNumber,
            datetime: date,
            maxDepth: maxDepth,
            avgDepth: avgDepth,
            divetime: accumulator.maxTime,
            reportedDivetime: reportedDivetime,
            temperature: accumulator.tempMinimum,
            profile: accumulator.profile,
            tankPressure: accumulator.pressureValues,
            gasMix: accumulator.lastGasMix,
            gasMixCount: gasMixes.count,
            gasMixes: gasMixes.mixes.isEmpty ? nil : gasMixes.mixes,
            salinity: fields.salinity(),
            atmospheric: atmospheric,
            surfaceTemperature: finite(accumulator.tempSurface),
            measuredSurfaceTemperature: finite(measuredSurface),
            minTemperature: finite(accumulator.tempMinimum),
            maxTemperature: finite(accumulator.tempMaximum),
            tankCount: tanks.count,
            tanks: tanks.tanks,
            diveMode: fields.diveMode(),
            decoModel: fields.decoModel(),
            location: accumulator.location,
            exitLocation: accumulator.exitLocation,
            rbt: accumulator.rbt,
            heartbeat: accumulator.heartbeat,
            bearing: accumulator.bearing,
            setpoint: accumulator.setpoint,
            ppo2Readings: accumulator.ppo2Readings,
            cns: accumulator.cns,
            decoStop: accumulator.lastDeco.map {
                DiveData.DecoStop(depth: $0.depth, time: TimeInterval($0.time), type: Int($0.type))
            }
        )
    }

    /// Families that report the CCR setpoint on every sample (no value = open circuit).
    static func reportsSetpointEverySample(_ family: DeviceFamily) -> Bool {
        switch family {
        case .shearwaterPetrel, .diveSystem, .mcleanExtreme: return true
        default: return false
        }
    }

    /// Shearwater Petrel-family logs in the newer PNF format do not start with the
    /// legacy 0xFF 0xFF opening-block marker.
    static func isShearwaterPNF(family: DeviceFamily, data: Data) -> Bool {
        guard family == .shearwaterPetrel, data.count >= 2 else { return false }
        let start = data.startIndex
        return !(data[start] == 0xFF && data[data.index(after: start)] == 0xFF)
    }

    /// The dive's local date and time, read in the device's current time zone
    /// (`dc_datetime_t.timezone` is ignored).
    static func localDate(_ value: dc_datetime_t) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: Int(value.year), month: Int(value.month), day: Int(value.day),
                                        hour: Int(value.hour), minute: Int(value.minute), second: Int(value.second))
        return calendar.date(from: components)
    }

    private static func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
}

/// libdivecomputer sample callback: forwards each sample to the accumulator in `userdata`.
private let sampleCallback: dc_sample_callback_t = { type, value, userdata in
    guard let value, let userdata else { return }
    let accumulator = Unmanaged<SampleAccumulator>.fromOpaque(userdata).takeUnretainedValue()
    accumulator.add(SampleInput(type: type, value: value.pointee))
}

extension SampleInput {
    init(type: dc_sample_type_t, value: dc_sample_value_t) {
        switch type {
        case DC_SAMPLE_TIME: self = .time(milliseconds: value.time)
        case DC_SAMPLE_DEPTH: self = .depth(value.depth)
        case DC_SAMPLE_PRESSURE: self = .pressure(tank: value.pressure.tank, bar: value.pressure.value)
        case DC_SAMPLE_TEMPERATURE: self = .temperature(value.temperature)
        case DC_SAMPLE_EVENT: self = .event(Self.event(type: value.event.type))
        case DC_SAMPLE_RBT: self = .rbt(value.rbt)
        case DC_SAMPLE_HEARTBEAT: self = .heartbeat(value.heartbeat)
        case DC_SAMPLE_BEARING: self = .bearing(value.bearing)
        case DC_SAMPLE_SETPOINT: self = .setpoint(value.setpoint)
        case DC_SAMPLE_PPO2: self = .ppo2(sensor: value.ppo2.sensor, bar: value.ppo2.value)
        case DC_SAMPLE_CNS: self = .cns(value.cns)
        case DC_SAMPLE_DECO:
            self = .deco(type: value.deco.type, time: value.deco.time, depth: value.deco.depth, tts: value.deco.tts)
        case DC_SAMPLE_GASMIX: self = .gasmix(value.gasmix)
        case DC_SAMPLE_LOCATION:
            self = .location(latitude: value.location.latitude, longitude: value.location.longitude,
                             altitude: value.location.altitude)
        default: self = .ignored
        }
    }

    /// The `parser_sample_event_t` types BlueDive shows.
    static func event(type: UInt32) -> SampleEvent? {
        switch type {
        case SAMPLE_EVENT_ASCENT.rawValue: return .ascent
        case SAMPLE_EVENT_VIOLATION.rawValue: return .violation
        case SAMPLE_EVENT_DECOSTOP.rawValue: return .decoStop
        case SAMPLE_EVENT_GASCHANGE.rawValue: return .gasChange
        case SAMPLE_EVENT_BOOKMARK.rawValue: return .bookmark
        case SAMPLE_EVENT_SAFETYSTOP.rawValue: return .safetyStop(mandatory: false)
        case SAMPLE_EVENT_SAFETYSTOP_MANDATORY.rawValue: return .safetyStop(mandatory: true)
        case SAMPLE_EVENT_CEILING.rawValue: return .ceiling
        case SAMPLE_EVENT_PO2.rawValue: return .po2
        case SAMPLE_EVENT_DEEPSTOP.rawValue: return .deepStop
        default: return nil
        }
    }
}
