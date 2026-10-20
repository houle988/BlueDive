import Foundation
import SwiftData

// MARK: - Gear Group Model

@Model
final class GearGroup {
    var id: UUID = UUID()
    var name: String = ""

    @Relationship(deleteRule: .nullify)
    var gear: [Gear]? = []

    init(
        id: UUID = UUID(),
        name: String,
        gear: [Gear] = []
    ) {
        self.id = id
        self.name = name
        self.gear = gear
    }
}

// MARK: - Computed Properties

extension GearGroup {
    /// Number of gear items in this group.
    var gearCount: Int {
        (gear ?? []).count
    }

}
