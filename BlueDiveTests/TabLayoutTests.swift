import Foundation
import Testing
@testable import BlueDive

/// Settings → Dive Profile → Dive Detail Tabs: the order of the dive detail tabs.
struct TabLayoutTests {

    private let defaults = ["first", "a", "b", "c", "d"]

    @Test func noStoredOrderGivesTheDefaultOrder() {
        #expect(TabLayout.resolvedOrder(stored: [], defaults: defaults, locked: "first") == defaults)
    }

    @Test func theStoredOrderIsKeptWithTheLockedTabFirst() {
        let order = TabLayout.resolvedOrder(stored: ["c", "first", "a", "d", "b"],
                                            defaults: defaults, locked: "first")
        #expect(order == ["first", "c", "a", "d", "b"])
    }

    @Test func unknownAndRepeatedIdentifiersAreDropped() {
        let order = TabLayout.resolvedOrder(stored: ["d", "gone", "c", "d", "b", "a"],
                                            defaults: defaults, locked: "first")
        #expect(order == ["first", "d", "c", "b", "a"])
    }

    @Test func aTabAddedLaterGoesAfterItsDefaultPredecessor() {
        // "c" is new: stored before it existed, in a custom order.
        let order = TabLayout.resolvedOrder(stored: ["d", "b", "a"], defaults: defaults, locked: "first")
        #expect(order == ["first", "d", "b", "c", "a"])
    }

    @Test func aTabAddedLaterRightAfterTheLockedTabGoesFirst() {
        let order = TabLayout.resolvedOrder(stored: ["d", "c", "b"], defaults: defaults, locked: "first")
        #expect(order == ["first", "a", "d", "c", "b"])
    }

    @Test func aMoveCannotPutATabBeforeTheLockedTab() {
        let moved = TabLayout.moved(defaults, from: IndexSet(integer: 3), to: 0, locked: "first")
        #expect(moved == ["first", "c", "a", "b", "d"])
    }

    @Test func aMoveReordersTheOtherTabs() {
        let moved = TabLayout.moved(defaults, from: IndexSet(integer: 1), to: 5, locked: "first")
        #expect(moved == ["first", "b", "c", "d", "a"])
    }

    @Test func diveTabRawValuesAreStable() {
        // Saved layouts store these strings: changing one would lose the user's layout.
        #expect(DiveTab.allCases.map(\.rawValue) == [
            "Overview", "Site Details", "Conditions", "Gas", "Equipment", "Photos",
            "Marine Life", "Notes", "Samples", "XML Export", "UDDF Export",
        ])
    }

    @Test func diveTabDefaultOrderStartsWithOverviewAndHasNoExportTab() {
        #expect(DiveTab.visibleCases.first == .menu)
        #expect(!DiveTab.visibleCases.contains(.xmlExport))
        #expect(!DiveTab.visibleCases.contains(.uddfExport))
    }
}
