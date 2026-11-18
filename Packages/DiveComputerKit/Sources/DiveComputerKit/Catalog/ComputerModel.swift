/// A dive computer model BlueDive can download over Bluetooth LE.
///
/// `name` is persisted (`Dive.computerName`, `DeviceFingerprint.computerName`) and
/// used for icon lookup, so names must never change. Several models share one
/// libdivecomputer model number (e.g. Tern / Tern TX); equality and hashing use
/// (family, modelID) only, as the protocol cannot tell them apart.
public struct ComputerModel: Hashable, Identifiable, Sendable {
    public let name: String
    public let family: DeviceFamily
    /// libdivecomputer descriptor model number.
    public let modelID: UInt32

    /// Unique within the catalog (names are unique; model numbers are not).
    public var id: String { name }

    public init(name: String, family: DeviceFamily, modelID: UInt32) {
        self.name = name
        self.family = family
        self.modelID = modelID
    }

    public static func == (lhs: ComputerModel, rhs: ComputerModel) -> Bool {
        lhs.family == rhs.family && lhs.modelID == rhs.modelID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(modelID)
    }
}
