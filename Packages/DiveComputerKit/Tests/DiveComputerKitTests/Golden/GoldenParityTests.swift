import Foundation
import Testing
@testable import DiveComputerKit

/// Private golden files produced by the old LibDCSwift (Docs/GOLDEN_FORMAT.md).
/// Set `DCK_GOLDEN_DIR` (e.g. `~/BlueDive-Fixtures/golden`) to run the parity tests;
/// they are skipped when it is unset.
enum GoldenFixtures {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DCK_GOLDEN_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var files: [URL] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && $0 != "manifest.json" }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Pins the time zone the goldens were produced in (the parser reads local time).
    static func pinTimeZone() throws {
        guard let directory else { return }
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard let identifier = manifest?["timeZone"] as? String, let zone = TimeZone(identifier: identifier) else {
            throw GoldenError.badManifest
        }
        setenv("TZ", identifier, 1)
        tzset()
        NSTimeZone.default = zone
    }

    enum GoldenError: Error { case badManifest, badFile(String) }
}

@Suite(.enabled(if: GoldenFixtures.directory != nil, "Set DCK_GOLDEN_DIR to run golden parity tests"))
struct GoldenParityTests {

    init() throws { try GoldenFixtures.pinTimeZone() }

    /// Byte-for-byte parity of the parser output with the old library, zero tolerance.
    @Test(arguments: GoldenFixtures.files)
    func matchesGolden(_ file: URL) throws {
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let golden, let input = golden["input"] as? [String: Any],
              let familyRaw = input["family"] as? String, let family = DeviceFamily(rawValue: familyRaw),
              let modelID = (input["modelID"] as? NSNumber)?.uint32Value,
              let rawBase64 = input["rawData"] as? String, let raw = Data(base64Encoded: rawBase64)
        else { throw GoldenFixtures.GoldenError.badFile(file.lastPathComponent) }

        let produced: GValue
        let expectedKey: String
        do {
            produced = GoldenEncoding.encode(try DiveParser.parse(family: family, modelID: modelID, data: raw, diveNumber: 1))
            expectedKey = "output"
        } catch {
            produced = GoldenEncoding.encodeError(error)
            expectedKey = "error"
        }
        let expected = golden[expectedKey] ?? NSNull()
        var actual = try JSONSerialization.jsonObject(with: Data(produced.render().utf8), options: .fragmentsAllowed)
        if expectedKey == "output" { actual = GoldenDiff.applyAcceptedDeviations(expected: expected, actual: actual) }
        if let difference = GoldenDiff.first(expected, actual, path: expectedKey) {
            Issue.record("\(file.lastPathComponent) (\(input["computerName"] ?? "")): \(difference)")
        }
    }
}

/// First difference between two JSON values, as "path: expected … got …".
enum GoldenDiff {

    /// The only accepted differences from the old library (Docs/GOLDEN_FORMAT.md,
    /// "Accepted deviations"): `gasMixCount` / `tankCount` are nil when the computer does
    /// not report them, where the old library stored 0. Neither value is read by the app.
    static func applyAcceptedDeviations(expected: Any, actual: Any) -> Any {
        guard let expected = expected as? [String: Any], var actual = actual as? [String: Any] else { return actual }
        for key in ["gasMixCount", "tankCount"] {
            if (expected[key] as? NSNumber)?.intValue == 0, actual[key] is NSNull {
                actual[key] = expected[key]
            }
        }
        return actual
    }

    static func first(_ expected: Any, _ actual: Any, path: String) -> String? {
        switch (expected, actual) {
        case let (e as [String: Any], a as [String: Any]):
            for key in Set(e.keys).union(a.keys).sorted() {
                guard let ev = e[key] else { return "\(path).\(key): unexpected key" }
                guard let av = a[key] else { return "\(path).\(key): missing" }
                if let d = first(ev, av, path: "\(path).\(key)") { return d }
            }
            return nil
        case let (e as [Any], a as [Any]):
            if e.count != a.count { return "\(path): expected \(e.count) elements, got \(a.count)" }
            for (index, pair) in zip(e, a).enumerated() {
                if let d = first(pair.0, pair.1, path: "\(path)[\(index)]") { return d }
            }
            return nil
        default:
            let e = expected as AnyObject, a = actual as AnyObject
            return e.isEqual(a) ? nil : "\(path): expected \(expected), got \(actual)"
        }
    }
}
