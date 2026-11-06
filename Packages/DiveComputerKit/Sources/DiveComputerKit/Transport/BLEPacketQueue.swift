import Foundation

/// Received BLE notifications, one element per notification (Shearwater's SLIP framing
/// needs one notification per read). Not thread-safe: guarded by the link's lock.
struct BLEPacketQueue {
    private var packets: [Data] = []
    private var partial = Data()

    var isEmpty: Bool { packets.isEmpty && partial.isEmpty }

    /// Queued bytes, unread parts included.
    var byteCount: Int { packets.reduce(partial.count) { $0 + $1.count } }

    mutating func append(_ packet: Data) {
        packets.append(packet)
    }

    /// The next bytes for a read of at most `maximum`: the rest of a partly read packet,
    /// else the next whole packet; a packet longer than `maximum` is split and its rest
    /// kept for the next read. Nil when nothing is queued.
    mutating func take(maximum: Int) -> Data? {
        guard maximum > 0 else { return nil }
        if !partial.isEmpty {
            let chunk = partial.prefix(maximum)
            partial = Data(partial.dropFirst(chunk.count))
            return Data(chunk)
        }
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        if packet.count <= maximum { return packet }
        partial = Data(packet.dropFirst(maximum))
        return Data(packet.prefix(maximum))
    }

    mutating func removeAll() {
        packets.removeAll()
        partial = Data()
    }
}
