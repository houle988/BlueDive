import Foundation
import DiveComputerKit
import SwiftData
import Testing
@testable import BlueDive

/// `DiveImportMapper` against dives the former LibDCSwift version downloaded over Bluetooth.
///
/// Each fixture folder holds a BlueDive XML export made by that version (`export.bluedive`,
/// raw dive-computer bytes included) and its Fingerprint XML (`fingerprints.bluedive`, the
/// stored family and model). Every dive's raw bytes go through `DiveParser` and
/// `DiveImportMapper.makeDive`; the result, exported again as BlueDive XML, must match the old
/// export in every value the dive computer provides. The folders are private dive data
/// (Packages/DiveComputerKit/Docs/DECISIONS.md, Q3): set `BLUEDIVE_PARITY_DIR` (with
/// xcodebuild, `TEST_RUNNER_BLUEDIVE_PARITY_DIR`) to the folder that contains them.
@MainActor
@Suite(.enabled(if: MapperParityFixtures.directory != nil, "Set BLUEDIVE_PARITY_DIR to run the mapper parity tests"))
struct DiveImportMapperParityTests {

    init() {
        // The exports were made in this zone; the parser and the exporter both use local time.
        NSTimeZone.default = TimeZone(identifier: "America/Toronto")!
    }

    @Test(arguments: MapperParityFixtures.computers)
    func newDivesMatchTheFormerVersion(_ folder: URL) throws {
        let fixture = try MapperParityFixtures.load(folder)
        var previousDiveEndTime: Date?
        var compared = 0
        for (index, old) in fixture.dives.enumerated() {
            let diveData = try fixture.diveData(old)
            let dive = DiveImportMapper.makeDive(from: diveData, diveNumber: 1, previousDiveEndTime: previousDiveEndTime,
                                                 diverName: "", context: fixture.context)
            let produced = try MapperParityFixtures.diveElement(BlueDiveXMLExporter.generateXML(for: dive))
            // The first dive's surface interval was computed against the logbook's previous dive.
            let skip = index == 0 ? MapperParityFixtures.notFromTheMapper.union(["surfaceInterval", "repetitiveDive"])
                                  : MapperParityFixtures.notFromTheMapper
            if let difference = MapperParityFixtures.firstDifference(old, produced, ignoring: skip) {
                Issue.record("\(folder.lastPathComponent) \(old.value("date") ?? ""): \(difference)")
            }
            previousDiveEndTime = diveData.datetime.addingTimeInterval(diveData.reportedDivetime ?? diveData.divetime)
            compared += 1
        }
        #expect(compared == fixture.dives.count && compared > 0)
    }

    /// A re-download merged into the dive it created changes no value; only the IDs of tanks
    /// built from gas mixes alone change (known, pre-existing: those branches do not reuse IDs).
    @Test(arguments: MapperParityFixtures.computers)
    func mergingTheSameDownloadChangesNothing(_ folder: URL) throws {
        let fixture = try MapperParityFixtures.load(folder)
        for old in fixture.dives {
            let diveData = try fixture.diveData(old)
            let dive = DiveImportMapper.makeDive(from: diveData, diveNumber: 1, previousDiveEndTime: nil,
                                                 diverName: "", context: fixture.context)
            let before = try MapperParityFixtures.diveElement(BlueDiveXMLExporter.generateXML(for: dive))
            DiveImportMapper.merge(diveData, into: dive, context: fixture.context)
            let after = try MapperParityFixtures.diveElement(BlueDiveXMLExporter.generateXML(for: dive))
            if let difference = MapperParityFixtures.firstDifference(before, after, ignoring: ["tanks/tank/id"]) {
                Issue.record("\(folder.lastPathComponent) \(old.value("date") ?? ""): \(difference)")
            }
        }
    }
}

// MARK: - Fixtures

enum MapperParityFixtures {

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["BLUEDIVE_PARITY_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var computers: [URL] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted()
            .map { directory.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("export.bluedive").path) }
    }

    /// Values set outside `DiveImportMapper`, as element paths relative to `<dive>`: the IDs
    /// (new on every import) and the dive number and diver (set by the import flow). Everything
    /// else is compared. The fixture dives were never edited and had no weather fetched; a
    /// fixture with edited dives would need the edited fields listed here.
    static let notFromTheMapper: Set<String> = [
        "id", "tanks/tank/id", "diveNumber", "diver",
    ]

    struct Fixture {
        let dives: [XMLElementTree]
        let family: DeviceFamily
        let modelID: UInt32
        let context: DiveImportContext

        func diveData(_ dive: XMLElementTree) throws -> DiveData {
            guard let base64 = dive.value("rawDiveComputerData"),
                  let raw = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw FixtureError.noRawData(dive.value("date") ?? "")
            }
            var data = try DiveParser.parse(family: family, modelID: modelID, data: raw, diveNumber: 1)
            data.rawData = raw
            data.fingerprint = dive.value("fingerprintData").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            return data
        }
    }

    enum FixtureError: Error { case badFixture(String), noRawData(String) }

    static func load(_ folder: URL) throws -> Fixture {
        let export = try XMLElementTree.parse(Data(contentsOf: folder.appendingPathComponent("export.bluedive")))
        let devices = try XMLElementTree.parse(Data(contentsOf: folder.appendingPathComponent("fingerprints.bluedive")))
        guard let device = devices.descendants("device").first,
              let familyRaw = device.value("familyID"), let family = DeviceFamily(rawValue: familyRaw),
              let modelID = device.value("modelID").flatMap(UInt32.init) else {
            throw FixtureError.badFixture(folder.lastPathComponent)
        }
        let dives = export.descendants("dive").sorted { ($0.value("date") ?? "") < ($1.value("date") ?? "") }
        guard let first = dives.first else { throw FixtureError.badFixture(folder.lastPathComponent) }
        // As the import builds it for a known device: the catalog name for the stored model,
        // the stored serial, the "Filter unused tanks" setting and the weight unit in effect
        // when these dives were downloaded (off; the dives' own import weight unit).
        let context = DiveImportContext(
            deviceFamily: family,
            catalogComputerName: DeviceCatalog.supportedModels.first { $0.family == family && $0.modelID == modelID }?.name,
            connectedDeviceName: nil,
            computerSerial: device.value("serial"),
            filterUnusedTanks: false,
            importWeightUnit: first.value("weightFormat") ?? "kg")
        return Fixture(dives: dives, family: family, modelID: modelID, context: context)
    }

    /// The single `<dive>` of a one-dive export.
    static func diveElement(_ xml: String) throws -> XMLElementTree {
        guard let dive = try XMLElementTree.parse(Data(xml.utf8)).descendants("dive").first else {
            throw FixtureError.badFixture("export without a dive")
        }
        return dive
    }

    /// The first differing value, as "path: expected … got …"; nil when equal.
    static func firstDifference(_ expected: XMLElementTree, _ actual: XMLElementTree, ignoring: Set<String>) -> String? {
        let a = expected.flattened(), b = actual.flattened()
        for key in Set(a.keys).union(b.keys).sorted() {
            let path = key.split(separator: "/").map { $0.split(separator: "[").first.map(String.init) ?? "" }
                .joined(separator: "/")
            if ignoring.contains(path) || ignoring.contains(where: { path.hasPrefix($0 + "/") || path.hasPrefix($0 + "@") }) {
                continue
            }
            if a[key] != b[key] {
                return "\(key): expected \(a[key].map { "\"\($0.prefix(80))\"" } ?? "nothing"), got \(b[key].map { "\"\($0.prefix(80))\"" } ?? "nothing")"
            }
        }
        return nil
    }
}

// MARK: - A minimal XML tree (Foundation's XMLDocument is macOS-only)

final class XMLElementTree {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLElementTree] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Trimmed text of the first direct child named `name`.
    func value(_ name: String) -> String? {
        children.first { $0.name == name }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func descendants(_ name: String) -> [XMLElementTree] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    /// Every leaf text and attribute, keyed by an indexed path ("tanks[1]/tank[1]/o2[1]").
    func flattened() -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ element: XMLElementTree, _ path: String) {
            for (key, value) in element.attributes { result["\(path)@\(key)"] = value }
            if element.children.isEmpty {
                result[path] = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var counts: [String: Int] = [:]
            for child in element.children {
                counts[child.name, default: 0] += 1
                let childPath = path.isEmpty ? "\(child.name)[\(counts[child.name]!)]" : "\(path)/\(child.name)[\(counts[child.name]!)]"
                walk(child, childPath)
            }
        }
        var counts: [String: Int] = [:]
        for child in children {
            counts[child.name, default: 0] += 1
            walk(child, "\(child.name)[\(counts[child.name]!)]")
        }
        for (key, value) in attributes { result["@\(key)"] = value }
        return result
    }

    static func parse(_ data: Data) throws -> XMLElementTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw MapperParityFixtures.FixtureError.badFixture(parser.parserError?.localizedDescription ?? "XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElementTree?
        private var stack: [XMLElementTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = XMLElementTree(name: elementName, attributes: attributeDict)
            stack.last?.children.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}
