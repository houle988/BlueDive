/*
 * DiveComputerKit — C shim over libdivecomputer (see dc_shim.h).
 */

#include "dc_shim.h"

#include <libdivecomputer/ble.h>
#include <libdivecomputer/ioctl.h>

unsigned int dc_shim_ioctl_ble_get_name (void) { return DC_IOCTL_BLE_GET_NAME; }
unsigned int dc_shim_ioctl_ble_get_pincode (void) { return DC_IOCTL_BLE_GET_PINCODE; }
unsigned int dc_shim_ioctl_ble_get_accesscode (void) { return DC_IOCTL_BLE_GET_ACCESSCODE; }
unsigned int dc_shim_ioctl_ble_set_accesscode (void) { return DC_IOCTL_BLE_SET_ACCESSCODE; }
unsigned int dc_shim_ioctl_ble_characteristic_read (void) { return DC_IOCTL_BLE_CHARACTERISTIC_READ; }
unsigned int dc_shim_ioctl_ble_characteristic_write (void) { return DC_IOCTL_BLE_CHARACTERISTIC_WRITE; }

size_t dc_shim_sizeof_ble_uuid (void) { return sizeof (dc_ble_uuid_t); }

dc_status_t dc_shim_descriptor_iterator (dc_iterator_t **iterator)
{
	return dc_descriptor_iterator_new (iterator, NULL);
}
