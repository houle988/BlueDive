import Foundation
import Testing
@testable import BlueDive

/// `SiteIndex`: the Recent and search lists of Edit Site Details → Copy from Existing Site.
/// All site names and dates are made up.
@MainActor
struct SiteIndexTests {

    private func summary(_ name: String, daysAgo: Double, id: UUID = UUID()) -> DiveSummary {
        let dive = Dive()
        dive.id = id
        dive.siteName = name
        dive.timestamp = Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400)
        return DiveSummary(from: dive)
    }

    @Test func keepsOneDivePerNameTheMostRecent() {
        let newest = UUID()
        let index = SiteIndex(summaries: [
            summary("Reef", daysAgo: 10),
            summary(" reef ", daysAgo: 1, id: newest),
            summary("REEF", daysAgo: 5),
        ], excluding: UUID())
        #expect(index.all.map(\.id) == [newest])
        #expect(index.byDate.map(\.id) == [newest])
    }

    @Test func sortsTheSearchListByNameAndRecentByDate() {
        // Given in neither order: the index sorts both itself.
        let index = SiteIndex(summaries: [
            summary("Arch", daysAgo: 3),
            summary("Wall", daysAgo: 1),
            summary("cove", daysAgo: 2),
        ], excluding: UUID())
        #expect(index.all.map(\.siteName) == ["Arch", "cove", "Wall"])
        #expect(index.byDate.map(\.siteName) == ["Wall", "cove", "Arch"])
    }

    @Test func excludesTheEditedDiveAndEmptyNames() {
        let edited = UUID()
        let older = UUID()
        let index = SiteIndex(summaries: [
            summary("Reef", daysAgo: 1, id: edited),
            summary("Reef", daysAgo: 4, id: older),
            summary("   ", daysAgo: 2),
        ], excluding: edited)
        // The edited dive is left out, so the site is represented by its other dive.
        #expect(index.all.map(\.id) == [older])
    }
}
