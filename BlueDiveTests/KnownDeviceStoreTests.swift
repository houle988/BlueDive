import Foundation
import DiveComputerKit
import Testing
@testable import BlueDive

/// `DeviceStorage` keeps the known-device entries it cannot decode (a family added by a
/// newer build), so an older build's saves never wipe them. Made-up devices only.
@MainActor
struct KnownDeviceStoreTests {

    private static let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private static let deviceA = StoredDevice(uuid: "00000000-0000-4000-8000-00000000000A", name: "Test Computer A",
                                              family: .shearwaterPetrel, model: 1, lastConnected: date, serial: "0000aaaa")
    private static let deviceB = StoredDevice(uuid: "00000000-0000-4000-8000-00000000000B", name: "Test Computer B",
                                              family: .oceanicAtom2, model: 2, lastConnected: date, serial: nil)
    private static let futureUUID = "00000000-0000-4000-8000-0000000000FF"
    private static let futureElement: [String: Any] = [
        "uuid": futureUUID, "name": "Future Computer", "family": "someFutureFamily",
        "model": 7, "lastConnected": 700_000_000.0, "serial": "0000ffff"
    ]

    /// A store over its own defaults suite, removed when `body` returns.
    private func withStore(_ name: String, _ body: (DeviceStorage, UserDefaults) throws -> Void) rethrows {
        let suite = "BlueDiveTests.KnownDeviceStore.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DeviceStorage(defaults: defaults), defaults)
    }

    /// The two readable devices followed by the element of an unknown family.
    private func storeMixedList(in defaults: UserDefaults) throws {
        let readable = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Self.deviceA, Self.deviceB])) as! [Any]
        let data = try JSONSerialization.data(withJSONObject: readable + [Self.futureElement])
        defaults.set(data, forKey: DeviceStorage.storageKey)
    }

    private func rawElements(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try #require(defaults.data(forKey: DeviceStorage.storageKey))
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func futureElements(_ defaults: UserDefaults) throws -> [[String: Any]] {
        try rawElements(defaults).filter { $0["uuid"] as? String == Self.futureUUID }
    }

    private func keepsFutureElement(_ defaults: UserDefaults) throws -> Bool {
        let found = try futureElements(defaults)
        return found.count == 1 && (found[0] as NSDictionary) == (Self.futureElement as NSDictionary)
    }

    @Test func readSkipsUnknownFamily() throws {
        try withStore("read") { store, defaults in
            try storeMixedList(in: defaults)
            #expect(store.getAllStoredDevices() == [Self.deviceA, Self.deviceB])
        }
    }

    @Test func storeDeviceKeepsUnknownEntry() throws {
        try withStore("store") { store, defaults in
            try storeMixedList(in: defaults)
            store.storeDevice(uuid: "00000000-0000-4000-8000-00000000000C", name: "Test Computer C",
                              family: .hwOstc3, model: 3, serial: "0000cccc")
            #expect(try keepsFutureElement(defaults))
            let uuids = store.getAllStoredDevices()?.map(\.uuid)
            #expect(uuids == [Self.deviceA.uuid, Self.deviceB.uuid, "00000000-0000-4000-8000-00000000000C"])
        }
    }

    @Test func removeDeviceKeepsOrRemovesUnknownEntry() throws {
        try withStore("remove") { store, defaults in
            try storeMixedList(in: defaults)
            store.removeDevice(uuid: Self.deviceA.uuid)
            #expect(store.getAllStoredDevices() == [Self.deviceB])
            #expect(try keepsFutureElement(defaults))

            store.removeDevice(uuid: Self.futureUUID)
            #expect(try futureElements(defaults).isEmpty)
            #expect(store.getAllStoredDevices() == [Self.deviceB])
        }
    }

    @Test func removeUnknownEntryWhenNoReadableDevice() throws {
        try withStore("removeOnly") { store, defaults in
            let data = try JSONSerialization.data(withJSONObject: [Self.futureElement])
            defaults.set(data, forKey: DeviceStorage.storageKey)
            #expect(store.getAllStoredDevices() == [])
            store.removeDevice(uuid: Self.futureUUID)
            #expect(try rawElements(defaults).isEmpty)
        }
    }

    @Test func removeUnknownUUIDWritesNothing() throws {
        try withStore("removeNothing") { store, defaults in
            try storeMixedList(in: defaults)
            let before = defaults.data(forKey: DeviceStorage.storageKey)
            store.removeDevice(uuid: "00000000-0000-4000-8000-000000000000")
            #expect(defaults.data(forKey: DeviceStorage.storageKey) == before)
        }
    }

    @Test func explicitWriteReplacesUnknownEntryWithSameUUID() throws {
        try withStore("replace") { store, defaults in
            try storeMixedList(in: defaults)
            store.storeDevice(uuid: Self.futureUUID, name: "Test Computer F", family: .cressiGoa, model: 4)
            let entries = try futureElements(defaults)
            #expect(entries.count == 1)
            #expect(entries.first?["family"] as? String == DeviceFamily.cressiGoa.rawValue)
            #expect(store.getAllStoredDevices()?.filter { $0.uuid == Self.futureUUID }.count == 1)
            // The whole list is readable again: the fast path decodes it.
            let data = try #require(defaults.data(forKey: DeviceStorage.storageKey))
            #expect((try? JSONDecoder().decode([StoredDevice].self, from: data))?.count == 3)
        }
    }

    /// The stored list is the same JSON value as `JSONEncoder` gives (compared by value: the
    /// encoder's key order is not stable between encodes) and decodes to the same devices.
    @Test func readableListKeepsTodaysFormat() throws {
        try withStore("format") { store, defaults in
            let devices = [Self.deviceA, Self.deviceB]
            store.updateStoredDevices(devices)
            let stored = try #require(defaults.data(forKey: DeviceStorage.storageKey))
            let storedValue = try #require(JSONSerialization.jsonObject(with: stored) as? NSArray)
            let expectedValue = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(devices)) as? NSArray)
            #expect(storedValue == expectedValue)
            #expect(try JSONDecoder().decode([StoredDevice].self, from: stored) == devices)

            defaults.set(try JSONEncoder().encode([Self.deviceB]), forKey: DeviceStorage.storageKey)
            #expect(store.getAllStoredDevices() == [Self.deviceB])
        }
    }

    /// Stores `elements` (each a JSON value) as the raw list.
    private func storeRaw(_ elements: [Any], in defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: elements), forKey: DeviceStorage.storageKey)
    }

    private func jsonValue(_ device: StoredDevice) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))
    }

    @Test func writeKeepsReadableOrderThenUnknownLast() throws {
        try withStore("order") { store, defaults in
            try storeRaw([jsonValue(Self.deviceA), Self.futureElement, jsonValue(Self.deviceB)], in: defaults)
            let newUUID = "00000000-0000-4000-8000-00000000000C"
            store.storeDevice(uuid: newUUID, name: "Test Computer C", family: .hwOstc3, model: 3, serial: "0000cccc")
            let uuids = try rawElements(defaults).map { $0["uuid"] as? String }
            #expect(uuids == [Self.deviceA.uuid, Self.deviceB.uuid, newUUID, Self.futureUUID])
            #expect(try keepsFutureElement(defaults))
        }
    }

    @Test func unknownEntryFirstIsSkippedAndKept() throws {
        try withStore("unknownFirst") { store, defaults in
            try storeRaw([Self.futureElement, jsonValue(Self.deviceA)], in: defaults)
            #expect(store.getAllStoredDevices() == [Self.deviceA])
            store.updateStoredDevices([Self.deviceA])
            let uuids = try rawElements(defaults).map { $0["uuid"] as? String }
            #expect(uuids == [Self.deviceA.uuid, Self.futureUUID])
            #expect(try keepsFutureElement(defaults))
        }
    }

    @Test func emptyWriteKeepsOnlyUnknownEntry() throws {
        try withStore("emptyWrite") { store, defaults in
            try storeRaw([Self.futureElement], in: defaults)
            store.updateStoredDevices([])
            let elements = try rawElements(defaults)
            #expect(elements.count == 1)
            #expect(try keepsFutureElement(defaults))
        }
    }

    @Test func malformedElementsAreSkippedAndDropped() throws {
        try withStore("malformed") { store, defaults in
            try storeRaw([jsonValue(Self.deviceA), NSNull(), 42, ["name": "x"], Self.futureElement], in: defaults)
            #expect(store.getAllStoredDevices() == [Self.deviceA])
            store.updateStoredDevices([Self.deviceA])
            let data = try #require(defaults.data(forKey: DeviceStorage.storageKey))
            let raw = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
            #expect(raw.count == 2)
            let uuids = try rawElements(defaults).map { $0["uuid"] as? String }
            #expect(uuids == [Self.deviceA.uuid, Self.futureUUID])
            #expect(try keepsFutureElement(defaults))
        }
    }

    @Test(arguments: [Data("not json".utf8), Data(#"{"uuid":"00000000-0000-4000-8000-00000000000A"}"#.utf8)])
    func corruptBlobReadsAsNil(blob: Data) throws {
        try withStore("corrupt.\(blob.count)") { store, defaults in
            defaults.set(blob, forKey: DeviceStorage.storageKey)
            #expect(store.getAllStoredDevices() == nil)
            store.storeDevice(uuid: Self.deviceA.uuid, name: Self.deviceA.name, family: Self.deviceA.family,
                              model: Self.deviceA.model, serial: Self.deviceA.serial)
            let devices = try #require(store.getAllStoredDevices())
            #expect(devices.map(\.uuid) == [Self.deviceA.uuid])
            #expect(try rawElements(defaults).count == 1)
        }
    }

    @Test func updateDeviceSerialOfUnknownEntryWritesNothing() throws {
        try withStore("serialUnknown") { store, defaults in
            try storeMixedList(in: defaults)
            let before = defaults.data(forKey: DeviceStorage.storageKey)
            store.updateDeviceSerial(uuid: Self.futureUUID, serial: "0000ffff")
            #expect(defaults.data(forKey: DeviceStorage.storageKey) == before)
        }
    }

    @Test func updateDeviceSerialKeepsUnknownEntry() throws {
        try withStore("serial") { store, defaults in
            try storeMixedList(in: defaults)
            store.updateDeviceSerial(uuid: Self.deviceB.uuid, serial: "0000bbbb")
            #expect(store.getAllStoredDevices()?.first { $0.uuid == Self.deviceB.uuid }?.serial == "0000bbbb")
            #expect(try keepsFutureElement(defaults))
        }
    }
}
