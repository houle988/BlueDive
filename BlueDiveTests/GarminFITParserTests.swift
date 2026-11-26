import Foundation
import Testing
import FITSwiftSDK
@testable import BlueDive

/// `GarminFITParser` over FIT files built in code with the SDK's encoder (made-up values):
/// a two-gas dive with its summary, settings, tank pressures and time-zone offset, which
/// dive summary is used when the file also has lap or untagged summaries (one dive and two),
/// the device name and serial (Descent models, other Garmin watches, other brands, a paired
/// transmitter, incomplete or missing DeviceInfo messages), and files that are not dives or
/// are damaged. Guards the importer against behaviour changes when
/// FITSwiftSDK is updated.
@MainActor
struct GarminFITParserTests {

    // MARK: Fixture

    /// FIT timestamp of the dive start (seconds since 1989-12-31 00:00 UTC).
    private static let startFIT: UInt32 = 1_100_000_000
    nonisolated private static let serial: UInt32 = 123_456
    /// Watch time-zone offset written in the Activity message (local − UTC).
    private static let localOffset: UInt32 = 3600
    private static let elapsed: Float64 = 600
    /// Gas switch from the first gas (21 %) to the second (50 %), seconds after the start.
    nonisolated private static let switchAt: UInt32 = 300

    /// Degrees → FIT semicircles (exact for the values used here).
    private static func semicircles(_ degrees: Double) -> Int32 {
        Int32(degrees * 2_147_483_648.0 / 180.0)
    }

    /// Serial of a paired tank transmitter in the fixtures.
    nonisolated private static let transmitterSerial: UInt32 = 999

    /// One DeviceInfo message of a fixture; a nil value leaves that field out of the message.
    private struct Device {
        var index: DeviceIndex? = DeviceIndexValues.creator
        var manufacturer: Manufacturer? = .garmin
        var product: GarminProduct? = .descentX10
        /// A raw product number written instead of `product` (e.g. one the SDK does not know).
        var productNumber: UInt16? = nil
        var productName: String? = nil
        var serial: UInt32? = nil

        /// A paired Descent T2 tank transmitter as Descent watches list it: a device index of
        /// 2 or more, a product and a serial, but no manufacturer.
        static let transmitter = Device(
            index: 2, manufacturer: nil, product: .descentT2, serial: GarminFITParserTests.transmitterSerial)
        /// A Garmin entry at device index 1 (Descent watches list one beside the watch's own).
        static func indexOne(_ product: GarminProduct) -> Device { Device(index: 1, product: product) }
    }

    /// FileId (manufacturer, product, serial) and the DeviceInfo messages of a fixture.
    private static func deviceMessages(
        manufacturer: Manufacturer, product: GarminProduct, fileIdProductName: String? = nil,
        fileIdSerial: UInt32?, devices: [Device]?
    ) throws -> [Mesg] {
        var mesgs: [Mesg] = []
        let fileId = FileIdMesg()
        try fileId.setType(.activity)
        try fileId.setManufacturer(manufacturer)
        // The raw product number: the SDK writes `garminProduct` only for Garmin manufacturers.
        try fileId.setProduct(product.rawValue)
        if let fileIdProductName { try fileId.setProductName(fileIdProductName) }
        if let fileIdSerial { try fileId.setSerialNumber(fileIdSerial) }
        mesgs.append(fileId)

        let watch = Device(manufacturer: manufacturer, product: product, serial: serial)
        for spec in devices ?? [watch] {
            let device = DeviceInfoMesg()
            try device.setTimestamp(DateTime(timestamp: startFIT))
            if let index = spec.index { try device.setDeviceIndex(index) }
            if let manufacturer = spec.manufacturer { try device.setManufacturer(manufacturer) }
            if let number = spec.productNumber ?? spec.product?.rawValue { try device.setProduct(number) }
            if let productName = spec.productName { try device.setProductName(productName) }
            if let serial = spec.serial { try device.setSerialNumber(serial) }
            mesgs.append(device)
        }
        return mesgs
    }

    /// A DiveGasMesg: FIT gas slot, O₂ %, status and mode.
    struct Gas: Sendable {
        let index: UInt16, oxygen: UInt8, status: DiveGasStatus, mode: DiveGasMode
        init(_ index: UInt16, _ oxygen: UInt8, _ status: DiveGasStatus = .enabled, _ mode: DiveGasMode = .openCircuit) {
            (self.index, self.oxygen, self.status, self.mode) = (index, oxygen, status, mode)
        }
    }

    /// Air then EAN50, both enabled open-circuit gases.
    nonisolated private static let defaultGases = [Gas(0, 21), Gas(1, 50)]

    /// A one-session dive: records every 10 s, by default two open-circuit gases with a switch
    /// at `switchAt` and one tank transmitter, dive settings, a dive summary and an Activity
    /// message carrying the watch's local time.
    /// - `manufacturer`, `product`: the FileId's, and the watch DeviceInfo's when `devices` is nil.
    /// - `fileIdProductName`: a product name in the FileId (none by default).
    /// - `fileIdSerial`: the FileId serial (`serial` by default; nil leaves it out).
    /// - `devices`: the DeviceInfo messages, in order (default: the watch, with `serial`).
    /// - `summaryReferences`: one DiveSummary per entry, in order, all with reference index 0:
    ///   `.session` (dive 42), `.lap` (no dive number, as Descent watches write it beside the
    ///   session's) or `nil` (no reference message, dive 7); see `SummaryValues`.
    /// - `subSport`: the session's sub-sport (none by default).
    /// - `gases`: the DiveGasMesg slots (default: `defaultGases`).
    /// - `gasSwitches`: the gas-switch events, seconds after the start and FIT gas slot
    ///   (default: slot 0 at the start, slot 1 at `switchAt`; empty for a single-gas dive).
    /// - `transmitters`: one TankSummaryMesg per entry, sensor and start/end pressure in bar.
    private static func makeDiveFile(
        manufacturer: Manufacturer = .garmin,
        product: GarminProduct = .descentX10,
        fileIdProductName: String? = nil,
        fileIdSerial: UInt32? = serial,
        devices: [Device]? = nil,
        sport: Sport = .diving,
        subSport: SubSport? = nil,
        gases: [Gas] = defaultGases,
        gasSwitches: [(offset: UInt32, gasIndex: UInt32)] = [(0, 0), (switchAt, 1)],
        transmitters: [(sensor: UInt32, start: Float64, end: Float64)] = [(1111, 200, 120)],
        summaryReferences: [MesgNum?] = [.session]
    ) throws -> Data {
        let start = DateTime(timestamp: startFIT)
        var mesgs = try deviceMessages(
            manufacturer: manufacturer, product: product, fileIdProductName: fileIdProductName,
            fileIdSerial: fileIdSerial, devices: devices)

        let settings = DiveSettingsMesg()
        try settings.setTimestamp(DateTime(timestamp: startFIT - 60))
        try settings.setModel(.zhl16c)
        try settings.setGfLow(40)
        try settings.setGfHigh(85)
        try settings.setWaterType(.salt)
        mesgs.append(settings)

        for gas in gases {
            let mesg = DiveGasMesg()
            try mesg.setMessageIndex(gas.index)
            try mesg.setOxygenContent(gas.oxygen)
            try mesg.setHeliumContent(0)
            try mesg.setStatus(gas.status)
            try mesg.setMode(gas.mode)
            mesgs.append(mesg)
        }

        for (offset, gasIndex) in gasSwitches {
            let event = EventMesg()
            try event.setTimestamp(DateTime(timestamp: startFIT + offset))
            try event.setEvent(.diveGasSwitched)
            try event.setEventType(.marker)
            try event.setData(gasIndex)
            mesgs.append(event)
        }

        for second in stride(from: UInt32(0), to: UInt32(elapsed), by: 10) {
            let record = RecordMesg()
            try record.setTimestamp(DateTime(timestamp: startFIT + second))
            try record.setDepth(min(Float64(second) / 10, 20))
            try record.setTemperature(20)
            try record.setNdlTime(900)
            mesgs.append(record)
        }

        for transmitter in transmitters {
            let tank = TankSummaryMesg()
            try tank.setTimestamp(DateTime(timestamp: startFIT + UInt32(elapsed) + 2))
            try tank.setSensor(transmitter.sensor)
            try tank.setStartPressure(transmitter.start)
            try tank.setEndPressure(transmitter.end)
            mesgs.append(tank)
        }

        let session = SessionMesg()
        try session.setMessageIndex(0)
        try session.setTimestamp(DateTime(timestamp: startFIT + UInt32(elapsed)))
        try session.setStartTime(start)
        try session.setTotalElapsedTime(elapsed)
        try session.setSport(sport)
        if let subSport { try session.setSubSport(subSport) }
        try session.setMaxDepth(20)
        try session.setMinTemperature(18)
        try session.setMaxTemperature(24)
        try session.setStartPositionLat(semicircles(45))
        try session.setStartPositionLong(semicircles(-90))
        mesgs.append(session)

        for reference in summaryReferences {
            let values = SummaryValues(reference)
            let summary = DiveSummaryMesg()
            try summary.setTimestamp(DateTime(timestamp: startFIT + UInt32(elapsed)))
            if let reference { try summary.setReferenceMesg(reference) }
            try summary.setReferenceIndex(0)
            try summary.setMaxDepth(values.maxDepth)
            try summary.setAvgDepth(values.avgDepth)
            try summary.setBottomTime(values.bottomTime)
            if let diveNumber = values.diveNumber { try summary.setDiveNumber(diveNumber) }
            if let endCns = values.endCns { try summary.setEndCns(endCns) }
            mesgs.append(summary)
        }

        let activity = ActivityMesg()
        try activity.setTimestamp(DateTime(timestamp: startFIT + UInt32(elapsed)))
        try activity.setLocalTimestamp(startFIT + UInt32(elapsed) + localOffset)
        mesgs.append(activity)

        let encoder = FITSwiftSDK.Encoder()
        encoder.write(mesgs: mesgs)
        return encoder.close()
    }

    /// The values written in a DiveSummary, distinct per reference so a test can tell which
    /// summary the parser used.
    private struct SummaryValues {
        let maxDepth: Float64, avgDepth: Float64, bottomTime: Float64
        let diveNumber: UInt32?, endCns: UInt8?

        init(_ reference: MesgNum?) {
            switch reference {
            case .lap:
                (maxDepth, avgDepth, bottomTime, diveNumber, endCns) = (19, 11, 580, nil, nil)
            case nil:
                (maxDepth, avgDepth, bottomTime, diveNumber, endCns) = (18, 10, 570, 7, 5)
            default:
                (maxDepth, avgDepth, bottomTime, diveNumber, endCns) = (20.5, 12.25, 590, 42, 12)
            }
        }
    }

    private static func parseOne(_ data: Data) throws -> BlueDiveGlobalData {
        let dives = try #require(GarminFITParser().parse(data: data))
        #expect(dives.count == 1)
        return try #require(dives.first)
    }

    // MARK: Dive

    @Test func parsesTheDiveSummaryAndDevice() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile())

        #expect(dive.sourceImport == "Garmin FIT")
        #expect(dive.distanceFormat == "meters")
        #expect(dive.temperatureFormat == "°c")
        #expect(dive.pressureFormat == "bar")
        #expect(dive.computer == "Garmin Descent X10")
        #expect(dive.serial == "123456")
        #expect(dive.identifier == "123456-\(Self.startFIT)")
        // The dive summary wins over the session for depths and duration.
        #expect(dive.maxDepth == 20.5)
        #expect(dive.averageDepth == 12.25)
        #expect(dive.duration == 590)
        #expect(dive.diveNumber == 42)
        #expect(dive.cns == 12)
        #expect(dive.tempLow == 18)
        #expect(dive.tempHigh == 24)
        #expect(dive.decoModel == "Bühlmann ZH-L16C GF 40/85")
        #expect(dive.isDecompressionDive == false)
        #expect(dive.site?.waterType == "Salt")
        #expect(dive.site?.latitude == 45)
        #expect(dive.site?.longitude == -90)
        #expect(dive.site?.exitLatitude == nil)
    }

    // MARK: Dive summary choice

    @Test(arguments: [
        [MesgNum?.some(.session), .lap],
        [.lap, .session],
        [nil, .session],
        [.session, nil],
    ])
    func theSessionSummaryWinsOverLapAndUntaggedOnes(_ references: [MesgNum?]) throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(summaryReferences: references))
        #expect(dive.diveNumber == 42)
        #expect(dive.cns == 12)
        #expect(dive.maxDepth == 20.5)
        #expect(dive.averageDepth == 12.25)
        #expect(dive.duration == 590)
    }

    /// Two dives in one file, each with a session summary and lap summaries. Lap indices run
    /// across the file (dive 1 has laps 0 and 1, dive 2 has lap 2), so lap 1's summary has the
    /// second session's index. The lap summaries come after the session ones.
    @Test func lapSummariesDoNotReplaceAnotherDivesSessionSummary() throws {
        var mesgs = try Self.deviceMessages(
            manufacturer: .garmin, product: .descentX10, fileIdSerial: Self.serial, devices: nil)
        let secondStart = Self.startFIT + 3600
        for (index, start) in [(UInt16(0), Self.startFIT), (UInt16(1), secondStart)] {
            let session = SessionMesg()
            try session.setMessageIndex(index)
            try session.setStartTime(DateTime(timestamp: start))
            try session.setTotalElapsedTime(Self.elapsed)
            try session.setSport(.diving)
            try session.setMaxDepth(5)
            mesgs.append(session)
        }
        let summaries: [(MesgNum, UInt16, Float64, UInt32?)] = [
            (.session, 0, 20.5, 42), (.session, 1, 30, 43),
            (.lap, 0, 19, nil), (.lap, 1, 18, nil), (.lap, 2, 29, nil),
        ]
        for (reference, index, maxDepth, diveNumber) in summaries {
            let summary = DiveSummaryMesg()
            try summary.setReferenceMesg(reference)
            try summary.setReferenceIndex(index)
            try summary.setMaxDepth(maxDepth)
            if let diveNumber { try summary.setDiveNumber(diveNumber) }
            mesgs.append(summary)
        }
        let encoder = FITSwiftSDK.Encoder()
        encoder.write(mesgs: mesgs)

        let dives = try #require(GarminFITParser().parse(data: encoder.close()))
        try #require(dives.count == 2)
        #expect(dives[0].diveNumber == 42)
        #expect(dives[0].maxDepth == 20.5)
        #expect(dives[1].diveNumber == 43)
        #expect(dives[1].maxDepth == 30)
    }

    @Test func anUntaggedSummaryIsUsedWhenItIsTheOnlyOne() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(summaryReferences: [nil]))
        #expect(dive.diveNumber == 7)
        #expect(dive.cns == 5)
        #expect(dive.maxDepth == 18)
        #expect(dive.duration == 570)
    }

    @Test func aLapSummaryAloneIsNotUsedForTheSession() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(summaryReferences: [.lap]))
        // Depths and duration come from the session; it has no dive number or CNS.
        #expect(dive.diveNumber == nil)
        #expect(dive.cns == nil)
        #expect(dive.maxDepth == 20)
        #expect(dive.averageDepth == nil)
        #expect(dive.duration == Int(Self.elapsed))
    }

    @Test func storesTheWatchWallClockStart() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile())

        let utcStart = DateTime(timestamp: Self.startFIT).date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: Int(Self.localOffset)))
        let watchTime = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utcStart)
        #expect(dive.date == WallClock.storedDate(from: watchTime))
    }

    @Test func buildsTanksAndUsageWindowsFromTheGasSwitch() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile())

        try #require(dive.tanks.count == 2)
        #expect(dive.tanks[0].oxygen == 21)
        #expect(dive.tanks[1].oxygen == 50)
        #expect(dive.tanks[0].helium == 0)
        // One transmitter and no pressure updates: it goes to the first tank.
        #expect(dive.tanks[0].startPressure == 200)
        #expect(dive.tanks[0].endPressure == 120)
        #expect(dive.tanks[1].startPressure == nil)
        #expect(dive.tanks[0].usageStartTime == 0)
        #expect(dive.tanks[0].usageEndTime == Double(Self.switchAt))
        #expect(dive.tanks[1].usageStartTime == Double(Self.switchAt))
        #expect(dive.tanks[1].usageEndTime == Self.elapsed)
    }

    // MARK: Backup gases

    @Test func anUnbreathedBackupGasIsKeptAsAGasOnlyTank() throws {
        let dive = try Self.parseOne(Self.makeDiveFile(gases: Self.defaultGases + [Gas(2, 29, .backupOnly)]))

        try #require(dive.tanks.count == 3)
        // The breathed tanks are unchanged.
        #expect(dive.tanks[0].oxygen == 21 && dive.tanks[0].startPressure == 200 && dive.tanks[0].endPressure == 120)
        #expect(dive.tanks[1].oxygen == 50 && dive.tanks[1].usageStartTime == Double(Self.switchAt))
        // The backup gas: no pressures, no usage window, no format.
        #expect(dive.tanks[2].oxygen == 29)
        #expect(dive.tanks[2].startPressure == nil && dive.tanks[2].endPressure == nil)
        #expect(dive.tanks[2].usageStartTime == nil && dive.tanks[2].usageEndTime == nil)
        #expect(dive.tanks[2].tankType == nil)
    }

    @Test(arguments: [DiveGasStatus.enabled, .disabled])
    func anUnbreathedGasThatIsNotBackupIsNotKept(status: DiveGasStatus) throws {
        let dive = try Self.parseOne(Self.makeDiveFile(gases: Self.defaultGases + [Gas(2, 29, status)]))
        #expect(dive.tanks.map(\.oxygen) == [21, 50])
    }

    /// A CCR dive: the diluent breathed all dive (no gas switch), an open-circuit bailout
    /// carried, a second transmitter (the O₂ supply) that reported nothing.
    @Test func aCCRBailoutIsKeptAndTheSpareTransmitterStaysOffIt() throws {
        let dive = try Self.parseOne(Self.makeDiveFile(
            subSport: .ccrDiving,
            gases: [Gas(0, 21, .enabled, .closedCircuitDiluent), Gas(1, 29, .backupOnly)],
            gasSwitches: [],
            transmitters: [(1111, 196, 195.5), (2222, 0, 0)]))

        try #require(dive.tanks.count == 2)
        #expect(dive.tanks[0].oxygen == 21 && dive.tanks[0].tankType == "Diluent")
        #expect(dive.tanks[0].startPressure == 196 && dive.tanks[0].endPressure == 195.5)
        #expect(dive.tanks[0].usageStartTime == 0)
        #expect(dive.tanks[1].oxygen == 29 && dive.tanks[1].tankType == nil)
        #expect(dive.tanks[1].startPressure == nil && dive.tanks[1].usageStartTime == nil)
        #expect(dive.samples.allSatisfy { $0.currentGas == nil || $0.currentGas == 0 })
    }

    /// A transmitter with readings but no breathed gas left for it is not put on the bailout.
    @Test func aSecondTransmitterWithReadingsNeverLandsOnTheBailout() throws {
        let dive = try Self.parseOne(Self.makeDiveFile(
            gases: [Gas(0, 21, .enabled, .closedCircuitDiluent), Gas(1, 29, .backupOnly)],
            gasSwitches: [],
            transmitters: [(1111, 196, 195.5), (2222, 200, 170)]))

        try #require(dive.tanks.count == 2)
        #expect(dive.tanks[1].startPressure == nil && dive.tanks[1].endPressure == nil)
    }

    // MARK: Dive type

    @Test(arguments: [
        (SubSport?.some(.ccrDiving), ["Rebreather"]),
        (.singleGasDiving, ["Open Circuit"]),
        (.multiGasDiving, ["Open Circuit"]),
        (.gaugeDiving, ["Gauge"]),
        (.apneaDiving, ["Freediving"]),
        (.apneaHunting, ["Freediving"]),
        (nil, []),
    ])
    func theDiveTypeFollowsTheSubSport(subSport: SubSport?, types: [String]) throws {
        let dive = try Self.parseOne(Self.makeDiveFile(subSport: subSport))
        #expect(dive.types == types)
    }

    @Test func buildsTheProfileSamples() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile())

        #expect(dive.samples.count == 60)
        let first = try #require(dive.samples.first)
        #expect(first.time == 0)
        #expect(first.depth == 0)
        #expect(first.temperature == 20)
        #expect(first.ndt == 15)
        #expect(first.currentGas == 0)
        #expect(first.events.isEmpty)

        let atSwitch = try #require(dive.samples.first { $0.time == Double(Self.switchAt) })
        #expect(atSwitch.depth == 20)
        #expect(atSwitch.currentGas == 1)
        #expect(atSwitch.events == [.gasChange])

        #expect(dive.samples.filter { $0.events.contains(.gasChange) }.count == 1)
        #expect(dive.samples.last?.currentGas == 1)
        #expect(dive.samples.allSatisfy { !$0.events.contains(.decoStop) })
        #expect(dive.decoStops.isEmpty)
    }

    // MARK: Device names

    @Test(arguments: [
        (GarminProduct.descent, "Garmin Descent"),
        (.descentMk2, "Garmin Descent Mk2"),
        (.descentMk2Asia, "Garmin Descent Mk2"),
        (.descentMk2s, "Garmin Descent Mk2s"),
        (.descentMk2sAsia, "Garmin Descent Mk2s"),
        (.descentG1, "Garmin Descent G1"),
        (.descentG1Asia, "Garmin Descent G1"),
        (.descentG2, "Garmin Descent G2"),
        (.descentMk3, "Garmin Descent Mk3"),
        (.descentMk3i, "Garmin Descent Mk3i"),
        (.descentX10, "Garmin Descent X10"),
        // Not a known Descent: the brand only, not a Descent model it may not be.
        (.fenix8, "Garmin"),
    ])
    func namesTheDescentModel(product: GarminProduct, name: String) throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(product: product))
        #expect(dive.computer == name)
    }

    @Test func anotherBrandWithoutAProductNameGetsNoName() throws {
        // A product ID that would be a Descent for Garmin means nothing for another brand.
        let dive = try Self.parseOne(try Self.makeDiveFile(manufacturer: .suunto, product: .descentMk3i))
        #expect(dive.computer == nil)
    }

    @Test func anUnknownGarminProductIsNamedGarmin() throws {
        // 65000 is not in the SDK's GarminProduct list (the SDK reads it as `.invalid`). The
        // FileId has no product, so only the watch's unknown ID can give the name.
        let dive = try Self.parseOne(try Self.makeDiveFile(product: .invalid, devices: [Device(productNumber: 65000)]))
        #expect(dive.computer == "Garmin")
    }

    @Test func aGarminDeviceInfoWithoutAProductGivesNoName() throws {
        // No product in the DeviceInfo or the FileId: no model to name.
        let dive = try Self.parseOne(try Self.makeDiveFile(product: .invalid, devices: [Device(product: nil)]))
        #expect(dive.computer == nil)
    }

    @Test func aDynastreamDeviceUsesGarminProductIDs() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(manufacturer: .dynastream, product: .descentMk3i))
        #expect(dive.computer == "Garmin Descent Mk3i")
    }

    @Test func onlyTheWatchsDeviceInfoNamesTheDive() throws {
        // Real files list sensors and other entries before or after the watch's own message.
        let devices = [Device.transmitter, Device.indexOne(.descentMk3), Device(product: .descentG2)]
        let dive = try Self.parseOne(try Self.makeDiveFile(devices: devices))
        #expect(dive.computer == "Garmin Descent G2")
    }

    @Test func aProductNameWinsOverTheProductID() throws {
        let fromWatch = try Self.parseOne(try Self.makeDiveFile(
            fileIdProductName: "File Name", devices: [Device(productName: "Watch Name")]))
        #expect(fromWatch.computer == "Watch Name")

        // An unknown Garmin product ID on the watch would give only "Garmin".
        let fromFileId = try Self.parseOne(try Self.makeDiveFile(
            fileIdProductName: "File Name", devices: [Device(productNumber: 65000)]))
        #expect(fromFileId.computer == "File Name")
    }

    @Test func aKnownDescentModelWinsOverAGenericGarminName() throws {
        // The watch's product ID is unknown; the FileId's is a known Descent.
        let dive = try Self.parseOne(try Self.makeDiveFile(
            product: .descentMk3i, devices: [Device(productNumber: 65000)]))
        #expect(dive.computer == "Garmin Descent Mk3i")
    }

    @Test func aDeviceInfoWithoutAnIndexIsTakenAsTheWatch() throws {
        let dive = try Self.parseOne(try Self.makeDiveFile(devices: [Device(index: nil, product: .descentG2)]))
        #expect(dive.computer == "Garmin Descent G2")
    }

    @Test func anIncompleteWatchDeviceInfoDoesNotHideALaterOne() throws {
        let devices = [Device(manufacturer: nil, product: nil), Device(product: .descentG2)]
        let dive = try Self.parseOne(try Self.makeDiveFile(devices: devices))
        #expect(dive.computer == "Garmin Descent G2")
    }

    @Test func theFileIdNamesTheDiveWhenNoDeviceInfoDoes() throws {
        // Without a manufacturer the SDK reads no Garmin product from the DeviceInfo.
        let withoutManufacturer = try Self.parseOne(try Self.makeDiveFile(
            devices: [Device(manufacturer: nil, product: .descentG2)]))
        #expect(withoutManufacturer.computer == "Garmin Descent X10")

        let withoutDeviceInfo = try Self.parseOne(try Self.makeDiveFile(devices: []))
        #expect(withoutDeviceInfo.computer == "Garmin Descent X10")
    }

    // MARK: Serial

    // Also a guard for SDK updates: the FileId serial already won before the watch-only rule.
    @Test func theFileIdSerialWins() throws {
        let devices = [Device.transmitter, Device(serial: 555)]
        let dive = try Self.parseOne(try Self.makeDiveFile(devices: devices))
        #expect(dive.serial == "123456")
    }

    @Test func withoutAFileIdSerialTheWatchSerialIsUsedNotATransmitters() throws {
        let devices = [Device.transmitter, Device(serial: 555)]
        let dive = try Self.parseOne(try Self.makeDiveFile(fileIdSerial: nil, devices: devices))
        #expect(dive.serial == "555")
        #expect(dive.identifier == "555-\(Self.startFIT)")
    }

    @Test func aTransmitterSerialAloneIsNotTheDiveSerial() throws {
        let devices = [Device.transmitter, Device(serial: nil)]
        let dive = try Self.parseOne(try Self.makeDiveFile(fileIdSerial: nil, devices: devices))
        #expect(dive.serial == nil)
        #expect(dive.identifier == "\(Self.startFIT)")
    }

    @Test func aFileWithOnlySensorDeviceInfosHasNoSerial() throws {
        // No watch DeviceInfo and no FileId serial: no serial, and the name comes from the FileId.
        let dive = try Self.parseOne(try Self.makeDiveFile(fileIdSerial: nil, devices: [Device.transmitter]))
        #expect(dive.serial == nil)
        #expect(dive.identifier == "\(Self.startFIT)")
        #expect(dive.computer == "Garmin Descent X10")
    }

    // MARK: Files that give no dive

    @Test func aFileWithoutADiveSessionGivesNoDive() throws {
        // A running session with no dive summary is not a dive.
        let data = try Self.makeDiveFile(sport: .running)
        let withoutSummary = try Self.removingDiveSummary(from: data)
        #expect(GarminFITParser().parse(data: withoutSummary) == nil)
    }

    @Test func damagedDataGivesNoDiveWithoutCrashing() throws {
        let data = try Self.makeDiveFile()
        for length in [0, 1, 12, 14, data.count / 2, data.count - 1] {
            #expect(GarminFITParser().parse(data: data.prefix(length)) == nil, "length \(length)")
        }
        #expect(GarminFITParser().parse(data: Data("not a FIT file".utf8)) == nil)
    }

    /// Re-encodes a file without its DiveSummary message.
    private static func removingDiveSummary(from data: Data) throws -> Data {
        let decoder = FITSwiftSDK.Decoder(stream: FITSwiftSDK.InputStream(data: data))
        let collector = MesgCollector()
        decoder.addMesgListener(collector)
        try decoder.read()
        let encoder = FITSwiftSDK.Encoder()
        encoder.write(mesgs: collector.mesgs.filter { $0.mesgNum != Profile.MesgNum.diveSummary })
        return encoder.close()
    }

    private final class MesgCollector: MesgListener {
        var mesgs: [Mesg] = []
        func onMesg(_ mesg: Mesg) throws { mesgs.append(mesg) }
    }
}
