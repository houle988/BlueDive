/*
 * DiveComputerKit — umbrella header of the CLibDiveComputer module.
 *
 * Lists only the libdivecomputer headers DiveComputerKit uses, so transport
 * headers for serial/USB/IrDA/classic Bluetooth are not imported into Swift.
 */

#include <libdivecomputer/version.h>
#include <libdivecomputer/common.h>
#include <libdivecomputer/context.h>
#include <libdivecomputer/iterator.h>
#include <libdivecomputer/descriptor.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/custom.h>
#include <libdivecomputer/ioctl.h>
#include <libdivecomputer/ble.h>
#include <libdivecomputer/device.h>
#include <libdivecomputer/parser.h>
#include <libdivecomputer/datetime.h>
#include <libdivecomputer/buffer.h>
#include <libdivecomputer/units.h>
#include "dc_shim.h"
