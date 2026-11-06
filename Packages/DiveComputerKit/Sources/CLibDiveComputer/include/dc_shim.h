/*
 * DiveComputerKit — C shim over libdivecomputer.
 *
 * Exposes to Swift only what the Swift importer cannot import by itself:
 * function-like macros (the DC_IOCTL_BLE_* request codes and the
 * dc_descriptor_iterator() macro). The values are the macros themselves,
 * so they follow libdivecomputer on every upstream sync.
 *
 * Part of DiveComputerKit (BlueDive Source Available License); the
 * libdivecomputer headers it includes are LGPL 2.1.
 */

#ifndef DC_SHIM_H
#define DC_SHIM_H

#include <stddef.h>
#include <libdivecomputer/common.h>
#include <libdivecomputer/descriptor.h>
#include <libdivecomputer/iterator.h>

#ifdef __cplusplus
extern "C" {
#endif

/* BLE ioctl request codes (ble.h, built with the DC_IOCTL_IOR/IOW macros of ioctl.h). */
unsigned int dc_shim_ioctl_ble_get_name (void);
unsigned int dc_shim_ioctl_ble_get_pincode (void);
unsigned int dc_shim_ioctl_ble_get_accesscode (void);
unsigned int dc_shim_ioctl_ble_set_accesscode (void);
unsigned int dc_shim_ioctl_ble_characteristic_read (void);
unsigned int dc_shim_ioctl_ble_characteristic_write (void);

/* Size of dc_ble_uuid_t (the UUID prefix of the characteristic ioctls). */
size_t dc_shim_sizeof_ble_uuid (void);

/* The dc_descriptor_iterator() macro of descriptor.h (no context). */
dc_status_t dc_shim_descriptor_iterator (dc_iterator_t **iterator);

#ifdef __cplusplus
}
#endif

#endif /* DC_SHIM_H */
