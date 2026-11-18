import CLibDiveComputer

/// Typed `dc_parser_get_field` reads. A field the dive or model does not report
/// (`DC_STATUS_UNSUPPORTED`, or any other failure) reads as nil.
struct FieldReader {
    let parser: OpaquePointer

    private func read<T>(_ type: dc_field_type_t, index: UInt32 = 0, into initial: T) -> T? {
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { dc_parser_get_field(parser, type, index, $0) }
        return status == DC_STATUS_SUCCESS ? value : nil
    }

    func double(_ type: dc_field_type_t) -> Double? { read(type, into: 0.0) }
    func uint32(_ type: dc_field_type_t) -> UInt32? { read(type, into: UInt32(0)) }

    /// `DC_FIELD_GASMIX_COUNT` (nil when not reported) and every readable `DC_FIELD_GASMIX`.
    /// `fieldIndices[i]` is the `DC_FIELD_GASMIX` index of `mixes[i]` (they differ when a mix
    /// cannot be read), the index gas-mix samples refer to.
    func gasMixes() -> (count: Int?, mixes: [GasMix], fieldIndices: [UInt32]) {
        guard let count = uint32(DC_FIELD_GASMIX_COUNT) else { return (nil, [], []) }
        let read = (0..<count).compactMap { index -> (UInt32, GasMix)? in
            read(DC_FIELD_GASMIX, index: index, into: dc_gasmix_t()).map {
                (index, GasMix(helium: $0.helium, oxygen: $0.oxygen, nitrogen: $0.nitrogen, usage: GasUsage($0.usage)))
            }
        }
        return (Int(count), read.map(\.1), read.map(\.0))
    }

    /// `DC_FIELD_TANK_COUNT` (nil when not reported) and every readable `DC_FIELD_TANK`.
    /// The tank volume type (metric / imperial) is not kept.
    func tanks() -> (count: Int?, tanks: [DiveData.Tank]) {
        guard let count = uint32(DC_FIELD_TANK_COUNT) else { return (nil, []) }
        let tanks = (0..<count).compactMap { index -> DiveData.Tank? in
            read(DC_FIELD_TANK, index: index, into: dc_tank_t()).map {
                DiveData.Tank(volume: $0.volume, workingPressure: $0.workpressure,
                              beginPressure: $0.beginpressure, endPressure: $0.endpressure,
                              gasMix: Int($0.gasmix), usage: GasUsage($0.usage))
            }
        }
        return (Int(count), tanks)
    }

    /// g/cm³: the reported density / 1000 (kg/m³), else 1.025 salt / 1.000 fresh.
    func salinity() -> Double? {
        guard let value = read(DC_FIELD_SALINITY, into: dc_salinity_t()) else { return nil }
        if value.density > 0 { return value.density / 1000 }
        return value.type == DC_WATER_SALT ? 1.025 : 1.000
    }

    /// Open circuit when the field is missing or unknown.
    func diveMode() -> DiveData.DiveMode {
        switch read(DC_FIELD_DIVEMODE, into: dc_divemode_t(rawValue: 0)) {
        case DC_DIVEMODE_FREEDIVE?: return .freedive
        case DC_DIVEMODE_GAUGE?: return .gauge
        case DC_DIVEMODE_CCR?: return .closedCircuit
        case DC_DIVEMODE_SCR?: return .semiClosedCircuit
        default: return .openCircuit
        }
    }

    /// Gradient factors only for Bühlmann; 0 for the other models.
    func decoModel() -> DiveData.DecoModel? {
        guard let value = read(DC_FIELD_DECOMODEL, into: dc_decomodel_t()) else { return nil }
        let type: DiveData.DecoModel.DecoType
        switch value.type {
        case DC_DECOMODEL_BUHLMANN: type = .buhlmann
        case DC_DECOMODEL_VPM: type = .vpm
        case DC_DECOMODEL_RGBM: type = .rgbm
        case DC_DECOMODEL_DCIEM: type = .dciem
        default: type = .none
        }
        let isBuhlmann = type == .buhlmann
        return DiveData.DecoModel(type: type, conservatism: Int(value.conservatism),
                                  gfLow: isBuhlmann ? value.params.gf.low : 0,
                                  gfHigh: isBuhlmann ? value.params.gf.high : 0)
    }
}

extension GasUsage {
    init(_ usage: dc_usage_t) {
        switch usage {
        case DC_USAGE_OXYGEN: self = .oxygen
        case DC_USAGE_DILUENT: self = .diluent
        case DC_USAGE_SIDEMOUNT: self = .sidemount
        default: self = .none
        }
    }
}
