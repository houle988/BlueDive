import CLibDiveComputer

/// A snapshot of one libdivecomputer descriptor (the static device table in descriptor.c).
struct LibraryDescriptor: Sendable, Equatable {
    let vendor: String
    let product: String
    /// `dc_family_t` raw value.
    let familyRaw: UInt32
    let model: UInt32
    /// `dc_transport_t` bit mask.
    let transports: UInt32

    var supportsBLE: Bool { transports & DC_TRANSPORT_BLE.rawValue != 0 }
    var family: DeviceFamily? { DeviceFamily(dcFamily: dc_family_t(rawValue: familyRaw)) }
}

/// Iteration over libdivecomputer's descriptor table.
enum DescriptorLookup {

    /// Calls `body` for each descriptor in table order until it returns false. The
    /// pointer is only valid inside `body` (libdivecomputer's table is static, but the
    /// iterator contract says to free each descriptor).
    static func forEach(_ body: (OpaquePointer, LibraryDescriptor) -> Bool) {
        var iterator: OpaquePointer?
        guard dc_shim_descriptor_iterator(&iterator) == DC_STATUS_SUCCESS else { return }
        defer { dc_iterator_free(iterator) }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS, let pointer = descriptor {
            let snapshot = LibraryDescriptor(
                vendor: String(cString: dc_descriptor_get_vendor(pointer)),
                product: String(cString: dc_descriptor_get_product(pointer)),
                familyRaw: dc_descriptor_get_type(pointer).rawValue,
                model: dc_descriptor_get_model(pointer),
                transports: dc_descriptor_get_transports(pointer)
            )
            let keepGoing = body(pointer, snapshot)
            dc_descriptor_free(pointer)
            if !keepGoing { break }
        }
    }

    /// Every descriptor, in table order.
    static var all: [LibraryDescriptor] {
        var result: [LibraryDescriptor] = []
        forEach { _, descriptor in result.append(descriptor); return true }
        return result
    }

    /// The first descriptor with this vendor and product (exact, case-sensitive).
    static func first(vendor: String, product: String) -> LibraryDescriptor? {
        var found: LibraryDescriptor?
        forEach { _, descriptor in
            if descriptor.vendor == vendor && descriptor.product == product { found = descriptor; return false }
            return true
        }
        return found
    }

    /// The first BLE descriptor whose libdivecomputer filter accepts this advertised name
    /// (`dc_descriptor_filter(…, DC_TRANSPORT_BLE, name)`). Most vendor filters are
    /// family-wide, so this is the family's first BLE descriptor, not necessarily the model.
    static func firstBLEMatch(forAdvertisedName name: String) -> LibraryDescriptor? {
        var found: LibraryDescriptor?
        name.withCString { cName in
            forEach { pointer, descriptor in
                guard descriptor.supportsBLE else { return true }
                if dc_descriptor_filter(pointer, DC_TRANSPORT_BLE, cName) != 0 {
                    found = descriptor
                    return false
                }
                return true
            }
        }
        return found
    }
}

extension DescriptorLookup {

    /// Runs `body` with the first descriptor of (family, model); nil when there is none.
    /// The pointer is valid only inside `body`.
    static func withDescriptor<T>(family: dc_family_t, model: UInt32, _ body: (OpaquePointer) -> T) -> T? {
        var result: T?
        forEach { pointer, descriptor in
            guard descriptor.familyRaw == family.rawValue && descriptor.model == model else { return true }
            result = body(pointer)
            return false
        }
        return result
    }
}
