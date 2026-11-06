import Foundation

/// Minimal JSON value with a fully deterministic rendering (see GOLDEN_FORMAT.md in
/// Packages/DiveComputerKit/Docs). The new package's tests render the same way.
indirect enum GValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([GValue])
    case object([String: GValue])

    static func opt<T>(_ value: T?, _ transform: (T) -> GValue) -> GValue {
        value.map(transform) ?? .null
    }

    /// Doubles are rendered as JSON strings with 17 significant digits, which
    /// round-trips every IEEE-754 double exactly; non-finite values are explicit.
    static func canonical(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d == .infinity { return "inf" }
        if d == -.infinity { return "-inf" }
        if d == 0 { return d.sign == .minus ? "-0" : "0" }
        return String(format: "%.17g", d)
    }

    func render(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return "\"" + GValue.canonical(d) + "\""
        case .string(let s): return GValue.quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.render(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted()   // byte order of UTF-8 keys (all ASCII here)
            return "{\n" + keys.map { inner + GValue.quote($0) + ": " + dict[$0]!.render(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
