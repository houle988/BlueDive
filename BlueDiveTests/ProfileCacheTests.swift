import Foundation
import SwiftData
import Testing
@testable import BlueDive

/// `Dive.profileSamples`' decode cache: a profile changed by another context (as an iCloud
/// import merges another device's edit) must be read again even when the stored JSON keeps its
/// length (a Tank Tools swap rewrites every sample under a new id with the same byte count).
/// Two contexts on one in-memory container stand in for the two devices; re-fetching in the
/// first context refreshes its already-loaded dive, as a merge does. All values are made up.
@MainActor
struct ProfileCacheTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                              cloudKitDatabase: .none))
    }

    /// A dive with two tanks and readings for both, saved in `context`.
    private func insertTwoTankDive(in context: ModelContext) throws -> Dive {
        let dive = Dive(timestamp: Date(timeIntervalSince1970: 1_800_000_000), diverName: "Test")
        dive.tanks = [TankData(o2: 0.32, startPressure: 200, endPressure: 60),
                      TankData(o2: 1.0, startPressure: 190, endPressure: 120)]
        dive.profileSamples = [
            DiveProfilePoint(time: 0, depth: 10, tankPressure: 100, tankPressures: [0: 100, 1: 200], currentGas: 0),
            DiveProfilePoint(time: 1, depth: 20, tankPressure: 110, tankPressures: [0: 110, 1: 210], currentGas: 0)
        ]
        context.insert(dive)
        try context.save()
        return dive
    }

    /// The same dive as seen by another context.
    private func fetchDive(in context: ModelContext) throws -> Dive {
        let dives = try context.fetch(FetchDescriptor<Dive>())
        return try #require(dives.first)
    }

    @Test func sameLengthRewriteFromAnotherContextIsSeen() throws {
        let container = try makeContainer()
        let contextA = ModelContext(container)
        let diveA = try insertTwoTankDive(in: contextA)
        let before = diveA.profileSamples                       // warms A's cache

        let contextB = ModelContext(container)
        let diveB = try fetchDive(in: contextB)
        #expect(diveB.swapTankReadings(0, 1))
        // The rewrite keeps the stored length: a byte-count key cannot see it.
        let lengthBefore = try JSONEncoder().encode(before).count
        let lengthAfter = try JSONEncoder().encode(diveB.profileSamples).count
        #expect(lengthBefore == lengthAfter)
        try contextB.save()

        // A refreshes its loaded dive (as a merge does).
        _ = try contextA.fetch(FetchDescriptor<Dive>())
        // The tanks (content-keyed) already showed the change; the samples must too.
        #expect(diveA.tanks[0].startPressure == 190)
        #expect(diveA.profileSamples.map(\.tankPressures) == [[0: 200, 1: 100], [0: 210, 1: 110]])
        #expect(diveA.profileSamples.count == before.count)
        #expect(Set(before.map(\.id)).isDisjoint(with: diveA.profileSamples.map(\.id)))
    }

    @Test func identicalRewriteKeepsTheSamples() throws {
        let container = try makeContainer()
        let contextA = ModelContext(container)
        let diveA = try insertTwoTankDive(in: contextA)
        let before = diveA.profileSamples

        let contextB = ModelContext(container)
        let diveB = try fetchDive(in: contextB)
        diveB.profileSamples = diveB.profileSamples             // same samples, same ids
        try contextB.save()

        _ = try contextA.fetch(FetchDescriptor<Dive>())
        #expect(diveA.profileSamples == before)
    }

    @Test func clearedProfileFromAnotherContextIsSeen() throws {
        let container = try makeContainer()
        let contextA = ModelContext(container)
        let diveA = try insertTwoTankDive(in: contextA)
        #expect(diveA.profileSamples.count == 2)

        let contextB = ModelContext(container)
        let diveB = try fetchDive(in: contextB)
        diveB.profileSamples = []
        try contextB.save()

        _ = try contextA.fetch(FetchDescriptor<Dive>())
        #expect(diveA.profileSamples.isEmpty)
    }

    @Test func localWritesAreReadBackFromTheCache() {
        let dive = Dive()
        #expect(dive.profileSamples.isEmpty)
        let samples = [DiveProfilePoint(time: 0, depth: 5), DiveProfilePoint(time: 1, depth: 12)]
        dive.profileSamples = samples
        #expect(dive.profileSamples == samples)
        #expect(dive.profileSamples == samples)                 // second read: cache hit
        dive.profileSamples = []
        #expect(dive.profileSamples.isEmpty)
    }
}
