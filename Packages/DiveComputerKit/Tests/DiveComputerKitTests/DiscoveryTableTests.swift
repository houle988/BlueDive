import Foundation
import Testing
@testable import DiveComputerKit

/// The scan list's rule (`DiscoveryTable`), shared by advertised peripherals and those
/// already connected to the system. Made-up identifiers and names; the entry is an Int.
@Suite struct DiscoveryTableTests {

    private let first = UUID()
    private let second = UUID()

    @Test func aNewPeripheralIsListedAndPublished() {
        var table = DiscoveryTable<Int>()
        let added = table.register(id: first, name: "Perdix", entry: 1) { _, _ in true }
        #expect(added)
        #expect(table.entry(for: first) == 1)
        #expect(table.device(for: first)?.name == "Perdix")
    }

    @Test func aNilOrEmptyNameIsSkipped() {
        var table = DiscoveryTable<Int>()
        var asked = false
        #expect(!table.register(id: first, name: nil, entry: 1) { _, _ in asked = true; return true })
        #expect(!table.register(id: second, name: "", entry: 2) { _, _ in asked = true; return true })
        #expect(!asked)
        #expect(table.sortedDevices.isEmpty)
    }

    @Test func aRejectedPeripheralIsNotListed() {
        var table = DiscoveryTable<Int>()
        #expect(!table.register(id: first, name: "Headphones", entry: 1) { _, _ in false })
        #expect(table.entry(for: first) == nil)
    }

    @Test func aListedPeripheralIsRefreshedWithoutTheFilterOrAPublish() {
        var table = DiscoveryTable<Int>()
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        _ = table.register(id: first, name: "Perdix", entry: 1, now: earlier) { _, _ in true }
        var asked = false
        let republished = table.register(id: first, name: "Perdix 2", entry: 2, now: later) { _, _ in
            asked = true
            return false
        }
        #expect(!republished)
        #expect(!asked)
        #expect(table.entry(for: first) == 2)
        #expect(table.device(for: first)?.name == "Perdix 2")
        #expect(table.device(for: first)?.lastSeen == later)
    }

    @Test func theListIsSortedByNameAndCanBeCleared() {
        var table = DiscoveryTable<Int>()
        _ = table.register(id: first, name: "Teric", entry: 1) { _, _ in true }
        _ = table.register(id: second, name: "Perdix", entry: 2) { _, _ in true }
        #expect(table.sortedDevices.map(\.name) == ["Perdix", "Teric"])
        table.removeAll()
        #expect(table.sortedDevices.isEmpty)
        #expect(table.entry(for: first) == nil)
    }
}
