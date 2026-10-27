import Foundation
import LibDCSwift
import SwiftData
import Testing
@testable import BlueDive

/// `duration` (whole minutes, always set) and `durationSeconds` (the computer's or file's dive
/// time): rounding, the write paths, the consistency guard, the readers, the BlueDive XML
/// round-trip, and the separate "Profile Time" (last sample).
///
/// The few direct `dive.duration = …` assignments below are deliberate: they simulate what
/// the setDuration helpers can never produce — an older app version on another device editing
/// only the minutes (stale seconds), or an old importer that stored seconds in `duration`.
/// Everywhere else, write through `setDuration(seconds:)` / `setDuration(minutes:)`.
@MainActor
struct DiveDurationTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        return ModelContext(container)
    }

    /// Dive #2134 of Simone's logbook: Garmin 68:34, profile ends at 70:34.
    private func garminSamples() -> [BlueDive.DiveProfilePoint] {
        [BlueDive.DiveProfilePoint(time: 0, depth: 1.2), BlueDive.DiveProfilePoint(time: 4234.0 / 60.0, depth: 0)]
    }

    // MARK: Rounding

    @Test func roundedMinutesRoundsHalfUp() {
        #expect(Dive.roundedMinutes(fromSeconds: 0) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: 29) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: 30) == 1)
        #expect(Dive.roundedMinutes(fromSeconds: 2549) == 42)        // 42:29
        #expect(Dive.roundedMinutes(fromSeconds: 2550) == 43)        // 42:30
        #expect(Dive.roundedMinutes(fromSeconds: 4114) == 69)        // Garmin 68:34
    }

    @Test func roundedMinutesRejectsGarbage() {
        #expect(Dive.roundedMinutes(fromSeconds: -1159788526) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: 1159792640) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: Int.max) == 0)
        // Never reaches 3600, which the legacy rule would read as seconds.
        #expect(Dive.roundedMinutes(fromSeconds: 3600 * 60 - 31) == 3599)
        #expect(Dive.roundedMinutes(fromSeconds: 3600 * 60 - 30) == 0)
    }

    @Test func roundedMinutesFromTimeInterval() {
        #expect(Dive.roundedMinutes(fromSeconds: 4113.73 as TimeInterval) == 69)
        #expect(Dive.roundedMinutes(fromSeconds: 29.6 as TimeInterval) == 1)   // 30 s → 1 min
        #expect(Dive.roundedMinutes(fromSeconds: -5.0 as TimeInterval) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: TimeInterval.nan) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: TimeInterval.infinity) == 0)
        #expect(Dive.roundedMinutes(fromSeconds: 1e30 as TimeInterval) == 0)
    }

    // MARK: Write paths

    @Test func setDurationSecondsStoresBoth() {
        let dive = Dive()
        dive.setDuration(seconds: 4114)
        #expect(dive.durationSeconds == 4114)
        #expect(dive.duration == 69)
        #expect(dive.consistentDurationSeconds == 4114)
        #expect(dive.resolvedDurationSeconds == 4114)
    }

    @Test func setDurationSecondsRejectsOutOfRange() {
        let dive = Dive()
        dive.setDuration(seconds: 4114)
        dive.setDuration(seconds: 0)
        #expect(dive.durationSeconds == nil && dive.duration == 0)
        dive.setDuration(seconds: -60)
        #expect(dive.durationSeconds == nil && dive.duration == 0)
        dive.setDuration(seconds: 1159792640)
        #expect(dive.durationSeconds == nil && dive.duration == 0)
    }

    @Test func setDurationMinutesClearsSeconds() {
        let dive = Dive()
        dive.setDuration(seconds: 4114)
        dive.setDuration(minutes: 70)
        #expect(dive.durationSeconds == nil)
        #expect(dive.duration == 70)
        #expect(dive.resolvedDurationSeconds == 4200)
    }

    @Test func initTakesMinutesOnly() {
        // Manual dives, Add Dive and every importer: init stores minutes, no seconds.
        let manual = Dive(duration: 40)
        #expect(manual.duration == 40 && manual.durationSeconds == nil)
        // A computer/file time is set afterwards, and the minutes follow it.
        manual.setDuration(seconds: 4114)
        #expect(manual.duration == 69 && manual.durationSeconds == 4114)
    }

    @Test func diveUnderThirtySecondsKeepsItsSeconds() {
        let dive = Dive()
        dive.setDuration(seconds: 25)
        #expect(dive.duration == 0)
        #expect(dive.consistentDurationSeconds == 25)
        #expect(dive.resolvedDurationSeconds == 25)
    }

    // MARK: Consistency guard

    @Test func guardIgnoresSecondsThatNoLongerMatchTheMinutes() {
        let dive = Dive()
        dive.setDuration(seconds: 4114)
        // An older app version on another device edits only the minutes.
        dive.duration = 75
        #expect(dive.consistentDurationSeconds == nil)
        #expect(dive.resolvedDurationSeconds == 4500)
    }

    @Test func legacySecondsInDurationAreKept() {
        let dive = Dive()
        dive.duration = 3600                                         // stored in seconds by an old importer
        #expect(dive.resolvedDurationSeconds == 3600)
    }

    // MARK: Readers

    @Test func durationCardShowsSecondsElseMinutesNeverProfile() {
        let samples = garminSamples()
        let withComputerTime = Dive(profileSamples: samples)
        withComputerTime.setDuration(seconds: 4114)
        // Exactly as the minutes-and-seconds formatter would write 68:34.
        #expect(withComputerTime.formattedDuration != withComputerTime.shortFormattedDuration)
        #expect(withComputerTime.formattedDuration.contains("08") && withComputerTime.formattedDuration.contains("34"))

        let minutesOnly = Dive(duration: 69, profileSamples: samples)
        #expect(minutesOnly.formattedDuration == minutesOnly.shortFormattedDuration)  // 1h 09m, not the profile
    }

    @Test func profileTimeIsTheLastSample() {
        let dive = Dive(profileSamples: garminSamples())
        dive.setDuration(seconds: 4114)
        #expect(dive.hasProfileTime)
        #expect(dive.profileDurationSeconds == 4234)                 // photo matching keeps the profile
        #expect(!Dive(duration: 40).hasProfileTime)
    }

    @Test func gasDurationUsesProfileThenSecondsThenMinutes() {
        let samples = garminSamples()
        let dive = Dive(profileSamples: samples)
        dive.setDuration(minutes: 69)
        #expect(dive.gasDurationMinutes(using: samples) == 4234.0 / 60.0)   // profile
        dive.setDuration(seconds: 4140)
        #expect(dive.gasDurationMinutes(using: samples) == 4234.0 / 60.0)   // still the profile
        let noProfile = Dive()
        noProfile.setDuration(seconds: 4114)
        #expect(noProfile.gasDurationMinutes(using: []) == 4114.0 / 60.0)   // computer/file time
        let manual = Dive(duration: 40)
        #expect(manual.gasDurationMinutes(using: []) == 40)
    }

    @Test func rmvStaysOnTheProfileClock() {
        // 10 m for 50 min (2 ATA), 12 L tank, 200 → 50 bar: 1800 L / 50 min / 2 = 18 L/min.
        let samples = [BlueDive.DiveProfilePoint(time: 0, depth: 10), BlueDive.DiveProfilePoint(time: 50, depth: 10)]
        let tank = TankData(volume: 12, startPressure: 200, endPressure: 50)

        let minutesOnly = Dive(duration: 50, profileSamples: samples)
        minutesOnly.tanks = [tank]
        #expect(abs(minutesOnly.combinedRMV - 18) < 0.001)
        #expect(abs(minutesOnly.calculatedRMV(forTankAt: 0) - 18) < 0.001)

        // A computer time does not change the result: the depth is on the profile's clock.
        let computerTime = Dive(profileSamples: samples)
        computerTime.tanks = [tank]
        computerTime.setDuration(seconds: 40 * 60)
        #expect(abs(computerTime.combinedRMV - 18) < 0.001)
        #expect(abs(computerTime.calculatedRMV(forTankAt: 0) - 18) < 0.001)

        // A Bluetooth single-tank dive: usage window 0 → last sample, computer time shorter.
        // The tank's own RMV and the combined RMV agree.
        let bluetooth = Dive(profileSamples: samples)
        bluetooth.tanks = [TankData(volume: 12, startPressure: 200, endPressure: 50, usageStartTime: 0, usageEndTime: 50 * 60)]
        bluetooth.setDuration(seconds: 40 * 60)
        #expect(abs(bluetooth.calculatedRMV(forTankAt: 0) - 18) < 0.001)
        #expect(abs(bluetooth.combinedRMV - 18) < 0.001)

        // Used from minute 10 with no end: the window ends at the last sample (10–50 min).
        let window = Dive(profileSamples: samples)
        window.tanks = [TankData(volume: 12, startPressure: 200, endPressure: 50, usageStartTime: 600)]
        window.setDuration(seconds: 40 * 60)
        #expect(abs(window.calculatedRMV(forTankAt: 0) - 1800.0 / 40.0 / 2.0) < 0.001)

        // Without a profile, the computer/file time is the divisor (not the rounded minutes).
        let noProfile = Dive(averageDepth: 10)
        noProfile.tanks = [tank]
        noProfile.setDuration(seconds: 40 * 60 + 20)
        #expect(abs(noProfile.combinedRMV - 1800.0 / (2420.0 / 60.0) / 2.0) < 0.001)
        #expect(abs(noProfile.calculatedRMV(forTankAt: 0) - 1800.0 / (2420.0 / 60.0) / 2.0) < 0.001)
    }

    @Test func minuteTiesAreBrokenBySeconds() {
        let a = Dive(); a.setDuration(seconds: 4110)                 // 68:30 → 69
        let b = Dive(); b.setDuration(seconds: 4130)                 // 68:50 → 69
        #expect([a, b].max(by: Dive.isShorterDuration) === b)
        #expect([a, b].min(by: Dive.isShorterDuration) === a)
    }

    @Test func surfaceIntervalUsesComputerSeconds() throws {
        let context = try makeContext()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Dive(timestamp: start, diverName: "Test")
        first.setDuration(seconds: 4114)                             // ends at 68:34
        // Starts 2 min after the computer's end: 1 min 34 s after the rounded 69 minutes.
        let second = Dive(timestamp: start.addingTimeInterval(4114 + 120), diverName: "Test")
        second.setDuration(minutes: 30)
        context.insert(first)
        context.insert(second)
        let updates = Dive.recalculateSurfaceIntervals(in: context, diverName: "Test")
        #expect(updates[second.id] == "0h 02m")                      // minutes alone would give 0h 01m
    }

    // MARK: File imports

    @Test func externalFileSetsSecondsAndRoundedMinutes() {
        let dive = Dive()
        dive.setImportedDuration(fileSeconds: 4114, exportedSeconds: nil, isBlueDiveXML: false)
        #expect(dive.durationSeconds == 4114 && dive.duration == 69)
    }

    @Test func olderBlueDiveXMLGivesMinutesOnly() {
        let dive = Dive()
        dive.setImportedDuration(fileSeconds: 4114, exportedSeconds: nil, isBlueDiveXML: true)
        #expect(dive.durationSeconds == nil && dive.duration == 69)
    }

    @Test func blueDiveXMLUsesMatchingComputerSecondsOnly() {
        let dive = Dive()
        dive.setImportedDuration(fileSeconds: 4500, exportedSeconds: 4114, isBlueDiveXML: true)
        #expect(dive.durationSeconds == nil && dive.duration == 75)  // mismatch: ignored
        dive.setImportedDuration(fileSeconds: 4114, exportedSeconds: 4114, isBlueDiveXML: true)
        #expect(dive.durationSeconds == 4114 && dive.duration == 69)
    }

    @Test func blueDiveXMLRoundTrip() throws {
        func roundTrip(_ dive: Dive) throws -> Dive {
            let xml = BlueDiveXMLExporter.generateXML(for: dive)
            let parsed = try #require(BlueDiveXMLParser().parse(data: Data(xml.utf8))?.first)
            let imported = Dive()
            imported.setImportedDuration(fileSeconds: parsed.duration,
                                         exportedSeconds: parsed.exportedDurationSeconds,
                                         isBlueDiveXML: parsed.isBlueDiveXMLImport)
            return imported
        }

        let computer = Dive(); computer.setDuration(seconds: 4114)
        let back = try roundTrip(computer)
        #expect(back.durationSeconds == 4114 && back.duration == 69)

        let manual = Dive(); manual.setDuration(minutes: 45)
        #expect(!BlueDiveXMLExporter.generateXML(for: manual).contains("<durationSeconds>"))
        let manualBack = try roundTrip(manual)
        #expect(manualBack.durationSeconds == nil && manualBack.duration == 45)

        // Guard failed (minutes edited elsewhere): no stale seconds exported.
        let stale = Dive(); stale.setDuration(seconds: 4114); stale.duration = 75
        #expect(!BlueDiveXMLExporter.generateXML(for: stale).contains("<durationSeconds>"))
        let staleBack = try roundTrip(stale)
        #expect(staleBack.durationSeconds == nil && staleBack.duration == 75)
    }

    // MARK: Bluetooth (LibDCSwift)

    /// A downloaded dive with only the fields `applyDuration` reads set meaningfully.
    private func diveData(divetime: TimeInterval, reported: TimeInterval?) -> DiveData {
        DiveData(number: 1, datetime: Date(timeIntervalSince1970: 1_800_000_000),
                 maxDepth: 11.4, avgDepth: 7.7, divetime: divetime, reportedDivetime: reported,
                 temperature: 19, profile: [], tankPressure: [], gasMix: nil, gasMixCount: nil,
                 gasMixes: nil, salinity: nil, atmospheric: nil, surfaceTemperature: nil,
                 minTemperature: nil, maxTemperature: nil, tankCount: nil, tanks: nil,
                 diveMode: nil, decoModel: nil, location: nil, rbt: nil, heartbeat: nil,
                 bearing: nil, setpoint: nil, ppo2Readings: [], cns: nil, decoStop: nil)
    }

    @Test func bluetoothStoresTheComputersTimeWithItsSeconds() {
        let dive = Dive()
        // Garmin: computer 68:34, profile (last sample) 70:34.
        BluetoothScannerView.applyDuration(from: diveData(divetime: 4234, reported: 4114), to: dive)
        #expect(dive.durationSeconds == 4114 && dive.duration == 69)
    }

    @Test func bluetoothWithoutComputerTimeStoresMinutesFromTheLastSample() {
        let dive = Dive()
        dive.setDuration(seconds: 4114)                              // a re-download replaces it
        BluetoothScannerView.applyDuration(from: diveData(divetime: 4234, reported: nil), to: dive)
        #expect(dive.durationSeconds == nil && dive.duration == 71)  // 70:34 → 71, no seconds
    }

    @Test func bluetoothIgnoresANonFiniteComputerTime() {
        let dive = Dive()
        BluetoothScannerView.applyDuration(from: diveData(divetime: 4234, reported: .infinity), to: dive)
        #expect(dive.durationSeconds == nil && dive.duration == 71)
        BluetoothScannerView.applyDuration(from: diveData(divetime: .nan, reported: nil), to: dive)
        #expect(dive.durationSeconds == nil && dive.duration == 0)
    }

    // MARK: File parsers (duration only)

    /// Parses `xml` with `parse` and stores the first dive's duration as the import does.
    private func importedDive(_ parsed: [BlueDiveGlobalData]?) throws -> Dive {
        let data = try #require(parsed?.first)
        let dive = Dive()
        dive.setImportedDuration(fileSeconds: data.duration,
                                 exportedSeconds: data.exportedDurationSeconds,
                                 isBlueDiveXML: data.isBlueDiveXMLImport)
        return dive
    }

    private func macDiveXML(_ duration: String) -> Data {
        Data("<dives><dive><duration>\(duration)</duration></dive></dives>".utf8)
    }

    @Test func macDiveDurationKeepsTheFileSeconds() throws {
        let dive = try importedDive(MacDiveXMLParser().parse(data: macDiveXML("4113.73")))
        #expect(dive.durationSeconds == 4113 && dive.duration == 69)   // fraction truncated, as before
        let whole = try importedDive(MacDiveXMLParser().parse(data: macDiveXML("2700")))
        #expect(whole.durationSeconds == 2700 && whole.duration == 45)
    }

    @Test func macDiveGarbageDurationStoresNoDurationAndDoesNotCrash() throws {
        for garbage in ["1159792640", "-1159788526", "1e30", "inf"] {
            let dive = try importedDive(MacDiveXMLParser().parse(data: macDiveXML(garbage)))
            #expect(dive.durationSeconds == nil && dive.duration == 0, "\(garbage)")
        }
    }

    private func uddfXML(_ duration: String) -> Data {
        Data("""
        <uddf><profiledata><repetitiongroup><dive>\
        <informationafterdive><diveduration>\(duration)</diveduration></informationafterdive>\
        </dive></repetitiongroup></profiledata></uddf>
        """.utf8)
    }

    @Test func uddfDurationKeepsTheFileSeconds() throws {
        let dive = try importedDive(UDDFXMLParser().parse(data: uddfXML("4114")))
        #expect(dive.durationSeconds == 4114 && dive.duration == 69)
        let fraction = try importedDive(UDDFXMLParser().parse(data: uddfXML("2712.6")))
        #expect(fraction.durationSeconds == 2712 && fraction.duration == 45)
        let garbage = try importedDive(UDDFXMLParser().parse(data: uddfXML("1e30")))
        #expect(garbage.durationSeconds == nil && garbage.duration == 0)
    }

    private func subsurfaceXML(_ duration: String) -> Data {
        Data("""
        <divelog program='subsurface' version='3'><dives>\
        <dive number='1' date='2026-10-01' time='08:36:18' duration='\(duration)'></dive>\
        </dives></divelog>
        """.utf8)
    }

    @Test func subsurfaceDurationKeepsTheFileSeconds() throws {
        let dive = try importedDive(SubsurfaceXMLParser().parse(data: subsurfaceXML("68:34 min")))
        #expect(dive.durationSeconds == 4114 && dive.duration == 69)
        let long = try importedDive(SubsurfaceXMLParser().parse(data: subsurfaceXML("1:08:34 min")))
        #expect(long.durationSeconds == 4114 && long.duration == 69)
    }

    // MARK: UDDF export

    @Test func uddfExportWritesTheComputerTimeElseTheMinutes() {
        let computer = Dive(); computer.setDuration(seconds: 4114)
        #expect(BlueDiveUDDFExporter.generateUDDF(for: computer).contains("<diveduration>4114</diveduration>"))
        let manual = Dive(); manual.setDuration(minutes: 45)
        #expect(BlueDiveUDDFExporter.generateUDDF(for: manual).contains("<diveduration>2700</diveduration>"))
        // Guard failed (minutes edited elsewhere): the minutes, not the stale seconds.
        let stale = Dive(); stale.setDuration(seconds: 4114); stale.duration = 75
        #expect(BlueDiveUDDFExporter.generateUDDF(for: stale).contains("<diveduration>4500</diveduration>"))
    }

    @Test func uddfRoundTripOfAManualDiveGainsSecondsAsDocumented() throws {
        // UDDF has a single duration in seconds: minutes × 60 comes back as the file's time.
        let manual = Dive(); manual.setDuration(minutes: 45)
        let back = try importedDive(UDDFXMLParser().parse(data: Data(BlueDiveUDDFExporter.generateUDDF(for: manual).utf8)))
        #expect(back.durationSeconds == 2700 && back.duration == 45)
    }

    @Test func secondsOnlyChangeChangesTheSummary() {
        // A re-download on another device with the same minutes but other seconds must change
        // the summary, so views keyed on cachedSummaries refresh.
        let dive = Dive()
        dive.setDuration(seconds: 4114)
        let before = DiveSummary(from: dive)
        dive.setDuration(seconds: 4130)                              // still 69 min
        let after = DiveSummary(from: dive)
        #expect(before.duration == after.duration)
        #expect(before != after)
        #expect(after.durationSeconds == 4130)
        // Seconds ignored by the guard are not carried either.
        dive.duration = 75
        #expect(DiveSummary(from: dive).durationSeconds == nil)
    }

    @Test func uddfRoundTripKeepsTheSeconds() throws {
        let computer = Dive(); computer.setDuration(seconds: 4114)
        let back = try importedDive(UDDFXMLParser().parse(data: Data(BlueDiveUDDFExporter.generateUDDF(for: computer).utf8)))
        #expect(back.durationSeconds == 4114 && back.duration == 69)
    }

    // MARK: Statistics CSV

    @Test func statisticsCSVWritesTheSecondsBesideTheMinutes() throws {
        let computer = Dive(); computer.setDuration(seconds: 4114)
        let manual = Dive(duration: 45)
        let rows = [computer, manual].map { StatisticsCSVRow.read(from: $0, pressureUnit: .bar) }
        #expect(rows[0].durationMinutes == 69 && rows[0].durationSeconds == 4114)
        #expect(rows[1].durationMinutes == 45 && rows[1].durationSeconds == nil)   // never 2700

        let labels = StatisticsCSVExport.Labels(headers: [], yes: "Yes", no: "No", rmvDecimals: 2)
        let text = try #require(String(data: StatisticsCSVExport.build(rows: rows, labels: labels), encoding: .utf8))
        let lines = Array(text.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty })
        // The minutes cell, then the seconds cell (empty without a computer time).
        #expect(lines.count == 2)
        #expect(lines.first?.contains(",69,4114,") == true)
        #expect(lines.last?.contains(",45,,") == true)
    }
}
