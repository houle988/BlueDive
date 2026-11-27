import Foundation
import SwiftData
import DiveComputerKit
import Testing
@testable import BlueDive

/// The pieces of Edit Dive Computer that hold logic: the fingerprint hex decoder (shared with
/// Sync Fingerprints and the fingerprint XML import) and the catalog model a known-device record
/// stands for (the model picker's checkmark and the icon). Made-up devices only.
@MainActor
struct KnownDeviceEditTests {

    // MARK: Fingerprint hex

    @Test func decodesHexBytes() throws {
        #expect(try #require(Data(fingerprintHex: "0a1B2c3D")) == Data([0x0A, 0x1B, 0x2C, 0x3D]))
    }

    @Test func emptyTextIsAnEmptyFingerprint() throws {
        #expect(try #require(Data(fingerprintHex: "")) == Data())
        #expect(try #require(Data(fingerprintHex: " \n\t ")) == Data())
    }

    /// Spaces, tabs and line breaks are ignored, so hex pasted from a wrapped log decodes.
    @Test func ignoresWhitespace() throws {
        #expect(try #require(Data(fingerprintHex: "0a 1b\t2c\n3d\r\n")) == Data([0x0A, 0x1B, 0x2C, 0x3D]))
    }

    @Test(arguments: ["abc", "0a1", "zz", "0x1a", "+1", "-1", "0a+1", "１２", "ａｂ", "é1"])
    func refusesInvalidHex(_ text: String) {
        #expect(Data(fingerprintHex: text) == nil)
    }

    @Test func hexStringRoundTrips() throws {
        let bytes = Data([0x00, 0x0F, 0xA5, 0xFF])
        #expect(bytes.fingerprintHexString == "000fa5ff")
        #expect(try #require(Data(fingerprintHex: bytes.fingerprintHexString)) == bytes)
    }

    // MARK: Catalog model

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return ModelContext(container)
    }

    private func record(name: String, family: DeviceFamily?, model: UInt32, in context: ModelContext) -> DeviceFingerprint {
        let record = DeviceFingerprint(serial: "0000abcd", computerName: name, fingerprintData: Data([1, 2, 3, 4]),
                                       family: family, model: model)
        context.insert(record)
        return record
    }

    /// The catalog grouped by family and model number.
    private var modelGroups: [[ComputerModel]] {
        Array(Dictionary(grouping: DeviceCatalog.supportedModels) { "\($0.family.rawValue)#\($0.modelID)" }.values)
    }

    /// Two catalog models sharing one family and model number, so the name must tell them apart.
    private func siblingModels() throws -> (ComputerModel, ComputerModel) {
        let siblings = try #require(modelGroups.first { $0.count > 1 })
        return (siblings[0], siblings[1])
    }

    /// A model no other model shares its family and number with.
    private func uniqueModel(otherThan excluded: ComputerModel? = nil) throws -> ComputerModel {
        try #require(modelGroups.first { $0.count == 1 && $0[0].name != excluded?.name }?.first)
    }

    @Test func namedSiblingIsKept() throws {
        let context = try makeContext()
        let (first, second) = try siblingModels()
        let device = record(name: second.name, family: second.family, model: second.modelID, in: context)
        #expect(device.catalogModel?.name == second.name)
        #expect(device.iconName == second.name)
        #expect(first.name != second.name)
    }

    /// A name that is not a catalog name (e.g. the advertised one) falls back to the only model
    /// with the record's family and number.
    @Test func otherNameFallsBackToTheOnlyMatchingModel() throws {
        let context = try makeContext()
        let model = try uniqueModel()
        let device = record(name: "Test Computer", family: model.family, model: model.modelID, in: context)
        #expect(device.catalogModel?.name == model.name)
        #expect(device.iconName == model.name)
    }

    /// Siblings that the name does not tell apart give no catalog model: the stored name is shown
    /// and picks the icon, rather than the first sibling.
    @Test func ambiguousSiblingsGiveNoCatalogModel() throws {
        let context = try makeContext()
        let (first, _) = try siblingModels()
        let device = record(name: "Test Computer", family: first.family, model: first.modelID, in: context)
        #expect(device.catalogModel == nil)
        #expect(device.iconName == "Test Computer")
    }

    /// A catalog name whose family or number differs from the record's is not trusted.
    @Test func catalogNameWithOtherModelNumberIsNotTrusted() throws {
        let context = try makeContext()
        let named = try #require(DeviceCatalog.supportedModels.first)
        let other = try uniqueModel(otherThan: named)
        let device = record(name: named.name, family: other.family, model: other.modelID, in: context)
        #expect(device.catalogModel?.name == other.name)
    }

    @Test func legacyRecordHasNoCatalogModel() throws {
        let context = try makeContext()
        let device = record(name: "Test Computer", family: nil, model: 0, in: context)
        #expect(device.catalogModel == nil)
        #expect(device.iconName == "Test Computer")
        #expect(!device.hasStoredIdentity)
    }

    // MARK: Stored identity

    /// Model number 0 is a real model in some families: a download keeps it.
    @Test func modelZeroIsAnIdentityWhereTheCatalogHasIt() throws {
        let context = try makeContext()
        let model = try #require(DeviceCatalog.supportedModels.first { $0.modelID == 0 })
        let device = record(name: model.name, family: model.family, model: 0, in: context)
        #expect(device.hasStoredIdentity)
    }

    /// Elsewhere model number 0 means "not set yet": a download seeds its detected model.
    @Test func modelZeroIsNotSetWhereTheCatalogHasNone() throws {
        let context = try makeContext()
        let family = try #require(DeviceFamily.allCases.first { family in
            DeviceCatalog.supportedModels.contains { $0.family == family }
                && DeviceCatalog.model(family: family, modelID: 0) == nil
        })
        let device = record(name: "Test Computer", family: family, model: 0, in: context)
        #expect(!device.hasStoredIdentity)
        let model = try #require(DeviceCatalog.supportedModels.first { $0.family == family })
        device.modelID = model.modelID
        #expect(device.hasStoredIdentity)
    }

    // MARK: Save rules

    private func record(serial: String, in context: ModelContext) -> DeviceFingerprint {
        let record = DeviceFingerprint(serial: serial, computerName: "Test Computer", fingerprintData: Data([1, 2, 3, 4]),
                                       family: .shearwaterPetrel, model: 1)
        context.insert(record)
        return record
    }

    /// Every record of the serial, whatever its case or surrounding spaces (iCloud-merged
    /// duplicates), and no other computer's.
    @Test func editAppliesToEveryRecordOfTheSerial() throws {
        let context = try makeContext()
        let edited = record(serial: "0000abcd", in: context)
        let duplicate = record(serial: " 0000ABCD ", in: context)
        let other = record(serial: "0000ef01", in: context)
        try context.save()

        let records = KnownDeviceEdit.records(matching: KnownDeviceSnapshot(edited), in: [edited, duplicate, other])
        #expect(Set(records.map(\.persistentModelID)) == [edited.persistentModelID, duplicate.persistentModelID])
    }

    /// A placeholder serial is shared by unrelated computers: only the edited record changes.
    @Test func placeholderSerialEditsOnlyThatRecord() throws {
        let context = try makeContext()
        let edited = record(serial: "0", in: context)
        let unrelated = record(serial: "0", in: context)
        try context.save()

        let records = KnownDeviceEdit.records(matching: KnownDeviceSnapshot(edited), in: [edited, unrelated])
        #expect(records.map(\.persistentModelID) == [edited.persistentModelID])
    }

    /// A record deleted while the sheet was open is not in the fetch: nothing is written.
    @Test func deletedRecordMatchesNothing() throws {
        let context = try makeContext()
        let edited = record(serial: "0", in: context)
        try context.save()
        let snapshot = KnownDeviceSnapshot(edited)
        context.delete(edited)
        try context.save()

        let all = try context.fetch(FetchDescriptor<DeviceFingerprint>())
        #expect(KnownDeviceEdit.records(matching: snapshot, in: all).isEmpty)
    }

    @Test func writeChangesOnlyTheEditedFields() throws {
        let context = try makeContext()
        let device = record(serial: "0000abcd", in: context)
        let lastSynced = device.updatedAt
        let model = try #require(DeviceCatalog.supportedModels.first { $0.family != .shearwaterPetrel })

        KnownDeviceEdit.write(model: model, fingerprint: nil, to: [device])
        #expect(device.computerName == model.name)
        #expect(device.family == model.family)
        #expect(device.modelID == model.modelID)
        #expect(device.fingerprintData == Data([1, 2, 3, 4]))
        #expect(device.updatedAt == lastSynced)

        KnownDeviceEdit.write(model: nil, fingerprint: Data([9, 8]), to: [device])
        #expect(device.computerName == model.name)
        #expect(device.fingerprintData == Data([9, 8]))
        #expect(device.updatedAt == lastSynced)
    }

    /// The backup flag is written only when given, and put back by a failed save.
    @Test func backupFlagIsWrittenAndRestored() throws {
        let context = try makeContext()
        let device = record(serial: "0000abcd", in: context)
        #expect(!device.isBackupComputer)

        KnownDeviceEdit.write(model: nil, fingerprint: nil, to: [device])
        #expect(!device.isBackupComputer)

        let originals = KnownDeviceEdit.write(model: nil, fingerprint: nil, isBackupComputer: true, to: [device])
        #expect(device.isBackupComputer)
        #expect(device.fingerprintData == Data([1, 2, 3, 4]))
        KnownDeviceEdit.restore(originals)
        #expect(!device.isBackupComputer)
    }

    /// A placeholder serial cannot be a backup: the flag on it changes nothing.
    @Test func placeholderSerialIsNeverAnEffectiveBackup() throws {
        let context = try makeContext()
        let real = record(serial: "0000abcd", in: context)
        let placeholder = record(serial: "0", in: context)
        real.isBackupComputer = true
        placeholder.isBackupComputer = true
        #expect(real.isEffectiveBackup)
        #expect(!placeholder.isEffectiveBackup)
        #expect(DeviceFingerprint.canBeBackup(serial: "0000abcd"))
        #expect(!DeviceFingerprint.canBeBackup(serial: "0"))
        #expect(!DeviceFingerprint.canBeBackup(serial: ""))
    }

    /// The connection rules the Bluetooth sheet applies: the session's backup serials, and no
    /// connection to a known backup while Sync device clock is off.
    @Test func backupConnectionRules() throws {
        let context = try makeContext()
        let backup = record(serial: "0000ABCD", in: context)
        backup.isBackupComputer = true
        let main = record(serial: "0000ef01", in: context)
        let placeholder = record(serial: "0", in: context)
        placeholder.isBackupComputer = true
        let records = [backup, main, placeholder]

        #expect(DeviceFingerprint.backupSerials(in: records) == ["0000abcd"])
        #expect(DeviceFingerprint.backupRecord(serial: " 0000abcd ", in: records) === backup)
        #expect(DeviceFingerprint.backupRecord(serial: "0000ef01", in: records) == nil)
        #expect(DeviceFingerprint.backupRecord(serial: "0", in: records) == nil)

        // Clock sync off: the backup is not connected; anything else is.
        #expect(DeviceFingerprint.backupNotToConnect(serial: "0000abcd", syncClock: false, in: records) === backup)
        #expect(DeviceFingerprint.backupNotToConnect(serial: "0000ef01", syncClock: false, in: records) == nil)
        #expect(DeviceFingerprint.backupNotToConnect(serial: nil, syncClock: false, in: records) == nil)
        // Clock sync on: the backup is connected (to set its clock).
        #expect(DeviceFingerprint.backupNotToConnect(serial: "0000abcd", syncClock: true, in: records) == nil)
    }

    /// A completed backup session moves "Last synced" on every record of the serial, and only
    /// on those.
    @Test func backupSessionMovesLastSynced() throws {
        let context = try makeContext()
        let backup = record(serial: "0000abcd", in: context)
        let duplicate = record(serial: "0000ABCD", in: context)
        let other = record(serial: "0000ef01", in: context)
        let otherDate = other.updatedAt
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        #expect(KnownDeviceEdit.markBackupSynced(serial: "0000abcd", in: [backup, duplicate, other], at: now) == 2)
        #expect(backup.updatedAt == now)
        #expect(duplicate.updatedAt == now)
        #expect(other.updatedAt == otherDate)
        #expect(KnownDeviceEdit.markBackupSynced(serial: "0", in: [backup], at: now) == 0)
    }

    /// The fingerprint export carries the backup flag through an import; a file without it
    /// (older exports) or with an unreadable value reads as a main dive computer.
    @Test func fingerprintXMLCarriesTheBackupFlag() throws {
        let context = try makeContext()
        let backup = record(serial: "0000abcd", in: context)
        backup.isBackupComputer = true
        let main = record(serial: "0000ef01", in: context)

        let xml = FingerprintXMLExporter.generateXML(for: [backup, main])
        let parsed = try FingerprintXMLParser().parse(data: Data(xml.utf8)).get()
        #expect(parsed.map(\.isBackupComputer) == [true, false])
        #expect(xml.components(separatedBy: "<isBackupComputer>").count == 2)   // written once, for the backup only

        let garbled = xml.replacingOccurrences(of: "<isBackupComputer>true</isBackupComputer>",
                                               with: "<isBackupComputer>maybe</isBackupComputer>")
        let lenient = try FingerprintXMLParser().parse(data: Data(garbled.utf8)).get()
        #expect(lenient.map(\.isBackupComputer) == [false, false])
    }

    /// A failed save puts every edited record back as it was, the raw family string included.
    @Test func restorePutsBackTheValuesFromBeforeTheEdit() throws {
        let context = try makeContext()
        let device = record(serial: "0000abcd", in: context)
        device.familyID = "someFutureFamily"
        let model = try #require(DeviceCatalog.supportedModels.first { $0.family != .shearwaterPetrel })

        let originals = KnownDeviceEdit.write(model: model, fingerprint: Data([9, 8]), to: [device])
        #expect(device.computerName == model.name)
        KnownDeviceEdit.restore(originals)
        #expect(device.computerName == "Test Computer")
        #expect(device.familyID == "someFutureFamily")
        #expect(device.modelID == 1)
        #expect(device.fingerprintData == Data([1, 2, 3, 4]))
    }

    /// The rule the download, the DeviceStorage re-seed and the scan fallback share.
    @Test func modelNumberZeroIsSetOnlyWhereTheCatalogHasIt() throws {
        let withZero = try #require(DeviceCatalog.supportedModels.first { $0.modelID == 0 })
        #expect(DeviceFingerprint.isModelSet(family: withZero.family, modelID: 0))
        let withoutZero = try #require(DeviceFamily.allCases.first { DeviceCatalog.model(family: $0, modelID: 0) == nil })
        #expect(!DeviceFingerprint.isModelSet(family: withoutZero, modelID: 0))
        #expect(DeviceFingerprint.isModelSet(family: withoutZero, modelID: 1))
    }

    /// The serial's entries take the new model and keep their advertised name, identifier,
    /// last connection and order; other entries are unchanged.
    @Test func storedDevicesTakeTheModelAndKeepTheRest() throws {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let entryA = StoredDevice(uuid: "00000000-0000-4000-8000-00000000000A", name: "Test Advertised A",
                                  family: .shearwaterPetrel, model: 1, lastConnected: date, serial: "0000ABCD")
        let entryB = StoredDevice(uuid: "00000000-0000-4000-8000-00000000000B", name: "Test Advertised B",
                                  family: .oceanicAtom2, model: 2, lastConnected: date, serial: "0000ef01")
        let entryC = StoredDevice(uuid: "00000000-0000-4000-8000-00000000000C", name: "Test Advertised C",
                                  family: .shearwaterPetrel, model: 1, lastConnected: date.addingTimeInterval(60), serial: nil)
        let model = try #require(DeviceCatalog.supportedModels.first { $0.family == .shearwaterPetrel && $0.modelID != 1 })

        let result = KnownDeviceEdit.storedDevices([entryA, entryB, entryC], withSerial: "0000abcd", setTo: model)
        #expect(result.updated == 1)
        #expect(result.devices == [
            StoredDevice(uuid: entryA.uuid, name: entryA.name, family: model.family, model: model.modelID,
                         lastConnected: entryA.lastConnected, serial: entryA.serial),
            entryB,
            entryC
        ])
    }
}
