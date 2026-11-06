import Testing
import CLibDiveComputer
@testable import DiveComputerKit

/// Phase 1 checks: the vendored libdivecomputer builds, links and exposes what
/// DiveComputerKit needs through the shim.
struct LibraryBuildTests {

    @Test func versionMatchesVendoredSnapshot() {
        #expect(DiveComputerKitInfo.libdivecomputerVersion == "0.10.0")
    }

    /// Values of the DC_IOCTL_BLE_* macros (ble.h / ioctl.h): DC_IOCTL_IOR/IOW('b', n, size)
    /// with a variable size (0).
    @Test func bleIoctlCodes() {
        #expect(dc_shim_ioctl_ble_get_name() == 0x4000_6200)
        #expect(dc_shim_ioctl_ble_get_pincode() == 0x4000_6201)
        #expect(dc_shim_ioctl_ble_get_accesscode() == 0x4000_6202)
        #expect(dc_shim_ioctl_ble_set_accesscode() == 0x8000_6202)
        #expect(dc_shim_ioctl_ble_characteristic_read() == 0x4000_6203)
        #expect(dc_shim_ioctl_ble_characteristic_write() == 0x8000_6203)
        #expect(dc_shim_sizeof_ble_uuid() == 16)
    }

    /// The descriptor table is reachable and contains BLE-capable models.
    @Test func descriptorTableHasBLEModels() throws {
        var iterator: OpaquePointer?
        #expect(dc_shim_descriptor_iterator(&iterator) == DC_STATUS_SUCCESS)
        defer { dc_iterator_free(iterator) }
        var total = 0
        var ble = 0
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS {
            total += 1
            if dc_descriptor_get_transports(descriptor) & DC_TRANSPORT_BLE.rawValue != 0 { ble += 1 }
            dc_descriptor_free(descriptor)
        }
        #expect(total > 300)
        #expect(ble > 50)
    }

    /// The public custom-iostream entry point used by the BLE bridge links.
    @Test func customIOStreamLinks() {
        var context: OpaquePointer?
        #expect(dc_context_new(&context) == DC_STATUS_SUCCESS)
        defer { dc_context_free(context) }
        var callbacks = dc_custom_cbs_t()
        var stream: OpaquePointer?
        #expect(dc_custom_open(&stream, context, DC_TRANSPORT_BLE, &callbacks, nil) == DC_STATUS_SUCCESS)
        #expect(dc_iostream_get_transport(stream) == DC_TRANSPORT_BLE)
        #expect(dc_iostream_close(stream) == DC_STATUS_SUCCESS)
    }
}
