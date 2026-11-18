import Foundation
import DiveComputerKit
import Testing
@testable import BlueDive

/// Time to surface (TTS) and remaining bottom time (RBT) on the dive profile: the storage
/// rules, the Bluetooth mapping, and the BlueDive XML, Subsurface and UDDF formats.
@MainActor
struct ProfileTimeTests {

    // MARK: Storage rules

    @Test func aTTSOfZeroIsNotAReading() {
        // libdivecomputer backends write 0 when the computer reports no TTS.
        #expect(DiveProfilePoint(time: 1, depth: 10, tts: 0).tts == nil)
        #expect(DiveProfilePoint(time: 1, depth: 10, tts: .nan).tts == nil)
        #expect(DiveProfilePoint(time: 1, depth: 10, tts: 12).tts == 12)
    }

    @Test func anRBTOfZeroIsAReading() {
        #expect(DiveProfilePoint(time: 1, depth: 10, rbt: 0).rbt == 0)
        #expect(DiveProfilePoint(time: 1, depth: 10, rbt: -1).rbt == nil)
        #expect(DiveProfilePoint(time: 1, depth: 10, rbt: .infinity).rbt == nil)
    }

    @Test func shownMinutesAreRoundedUp() {
        let stored: [Double] = [1.0 / 60, 30.0 / 60, 37.0 / 60, 1, 61.0 / 60, 4.5, 5, 0]
        let expected: [Double] = [1, 1, 1, 1, 2, 5, 5, 0]
        let shown = stored.map(DiveProfilePoint.displayedMinutes)
        #expect(shown == expected)
    }

    @Test func profilesStoredBeforeTTSAndRBTDecodeWithout() throws {
        let old = #"[{"id":"7C1B6E2A-4D0E-4A8B-9D3A-1F2E3D4C5B6A","time":1,"depth":10,"events":[]}]"#
        let points = try JSONDecoder().decode([DiveProfilePoint].self, from: Data(old.utf8))
        #expect(points.first?.tts == nil && points.first?.rbt == nil)
    }

    @Test func ttsAndRBTSurviveEncoding() throws {
        let point = DiveProfilePoint(time: 1, depth: 10, tts: 7, rbt: 0)
        let decoded = try JSONDecoder().decode(DiveProfilePoint.self, from: JSONEncoder().encode(point))
        #expect(decoded.tts == 7 && decoded.rbt == 0)
    }

    // MARK: Bluetooth

    private func context() -> DiveImportContext {
        DiveImportContext(deviceFamily: .shearwaterPetrel, catalogComputerName: nil, connectedDeviceName: nil,
                          computerSerial: "00001234", filterUnusedTanks: false, importWeightUnit: "kg")
    }

    private func dive(_ profile: [ProfileSample]) -> DiveData {
        var data = DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                            maxDepth: 30, avgDepth: 15, divetime: 1800, temperature: 12)
        data.profile = profile
        return data
    }

    @Test func bluetoothTTSIsConvertedToMinutesAndRBTKeptOnlyWhereReported() {
        let data = dive([
            ProfileSample(time: 0, depth: 0),
            // TTS 5 min, RBT 40 min reported in this interval.
            ProfileSample(time: 60, depth: 20, tts: 300, rbt: 40, reportedRBT: 40),
            // Deco: no RBT reported (carried-forward `rbt` must not be used), TTS 0 = none.
            ProfileSample(time: 120, depth: 30, tts: 0, rbt: 40, reportedRBT: nil),
        ])
        let points = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                               context: context()).profileSamples
        #expect(points.map(\.tts) == [nil, 5, nil])
        #expect(points.map(\.rbt) == [nil, 40, nil])
    }

    @Test func anEventPointAtTheSameTimeKeepsTheIntervalsValues() {
        // An event point built before the interval's RBT arrived, then the interval's flush.
        let data = dive([
            ProfileSample(time: 0, depth: 0),
            ProfileSample(time: 60, depth: 20, events: [.bookmark]),
            ProfileSample(time: 60, depth: 20, tts: 240, rbt: 30, reportedRBT: 30),
        ])
        let points = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                               context: context()).profileSamples
        #expect(points.count == 2)
        #expect(points[1].tts == 4 && points[1].rbt == 30)
        #expect(points[1].events.contains(.bookmark))
    }

    @Test func aReDownloadKeepsTTSAndRBT() {
        let data = dive([ProfileSample(time: 0, depth: 0),
                         ProfileSample(time: 60, depth: 20, tts: 120, rbt: 25, reportedRBT: 25)])
        let stored = DiveImportMapper.makeDive(from: data, diveNumber: 1, previousDiveEndTime: nil, diverName: "",
                                               context: context())
        DiveImportMapper.merge(data, into: stored, context: context())
        #expect(stored.profileSamples.last?.tts == 2 && stored.profileSamples.last?.rbt == 25)
    }

    // MARK: BlueDive XML

    @Test func blueDiveXMLRoundTripKeepsTTSAndRBT() throws {
        let dive = Dive(profileSamples: [DiveProfilePoint(time: 0, depth: 0),
                                         DiveProfilePoint(time: 1, depth: 12, tts: 3.5, rbt: 0)])
        let xml = BlueDiveXMLExporter.generateXML(for: dive)
        #expect(xml.contains(#"tts="3.5""#) && xml.contains(#"rbt="0.0""#))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.samples.map(\.tts) == [nil, 3.5])
        #expect(parsed.samples.map(\.rbt) == [nil, 0])
    }

    /// Times reported in seconds are not whole minutes: the export keeps them exactly.
    @Test func blueDiveXMLKeepsTimesInSecondsExactly() throws {
        let tts = 37.0 / 60, rbt = 61.0 / 60
        let dive = Dive(profileSamples: [DiveProfilePoint(time: 1, depth: 12, tts: tts, rbt: rbt),
                                         DiveProfilePoint(time: 2, depth: 12, tts: 5, rbt: 20)])
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(BlueDiveXMLExporter.generateXML(for: dive).utf8))?.first)
        #expect(parsed.samples.map(\.tts) == [tts, 5])
        #expect(parsed.samples.map(\.rbt) == [rbt, 20])
    }

    @Test func blueDiveXMLWithoutTheAttributesGivesNil() throws {
        let xml = BlueDiveXMLExporter.generateXML(for: Dive(profileSamples: [DiveProfilePoint(time: 1, depth: 12)]))
        #expect(!xml.contains(" tts=") && !xml.contains(" rbt="))
        let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
        #expect(parsed.samples.allSatisfy { $0.tts == nil && $0.rbt == nil })
    }

    // MARK: Subsurface

    @Test func subsurfaceTTSAndRBTAreForwardFilled() throws {
        // Subsurface writes tts and rbt only when they change; an RBT of 0 there means the
        // computer stopped reporting one (Subsurface has no "not reported" value).
        let xml = Data("""
        <divelog program='subsurface' version='3'><dives>\
        <dive number='1' date='2026-10-01' time='08:36:18' duration='3:00 min'>\
        <divecomputer model='Test'>\
        <sample time='0:00 min' depth='0.0 m' />\
        <sample time='1:00 min' depth='20.0 m' tts='4:30 min' rbt='35:00 min' />\
        <sample time='2:00 min' depth='21.0 m' />\
        <sample time='3:00 min' depth='5.0 m' rbt='0:00 min' />\
        </divecomputer></dive></dives></divelog>
        """.utf8)
        let parsed = try #require(SubsurfaceXMLParser().parse(data: xml)?.first)
        #expect(parsed.samples.map(\.tts) == [nil, 4.5, 4.5, 4.5])
        #expect(parsed.samples.map(\.rbt) == [nil, 35, 35, nil])
    }

    // MARK: UDDF

    @Test func uddfRoundTripKeepsRBT() throws {
        let dive = Dive(profileSamples: [DiveProfilePoint(time: 0, depth: 0),
                                         DiveProfilePoint(time: 1, depth: 12, tts: 3, rbt: 20)])
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dive)
        #expect(uddf.contains("<remainingbottomtime>1200</remainingbottomtime>"))
        let parsed = try #require(UDDFXMLParser().parse(data: Data(uddf.utf8))?.first)
        #expect(parsed.samples.map(\.rbt) == [nil, 20])
        // UDDF has no time-to-surface element.
        #expect(parsed.samples.allSatisfy { $0.tts == nil })
    }
}
