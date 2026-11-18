# Clean-Room Functional Specification — LibDCSwift (BlueDive fork of deepsealabs/libdc-swift, branch `working`, rev fd5b0db)

Source analysed: `/tmp/libdc-analysis/src`. All Swift/ObjC/C wrapper sources, headers, Package.swift, UPSTREAM.md, CHANGELOG.md, RELEASE_NOTES.md, README.md, and the full BlueDive-authored git history (54 commits) were read. The vendored `libdivecomputer/` tree was consulted only for the public C API it exposes (headers) and for its UPSTREAM.md.

Authorship note for the reimplementer: ~155 commits are upstream LibDCSwift's; 54 are BlueDive's. Section 10 lists every BlueDive customization. Everything else is upstream behaviour that the consumer app nevertheless relies on.

---

## 1. Module / target layout and build settings

**Package manifest** (swift-tools-version 5.10). Platforms: iOS 15, macOS 12. Package name `LibDCSwift`.

Products:
- `LibDCSwift` — library (default linkage) from target `LibDCSwift`.
- `LibDCBridge` — **dynamic** library from target `LibDCBridge`.

Targets:

1. **`Clibdivecomputer`** (C): `path: libdivecomputer` (the vendored libdivecomputer snapshot lives at the repo root, not under Sources). Excludes `doc`, `m4`, `src/serial_win32.c`. `publicHeadersPath: include` (so SwiftPM auto-generates the module map over `libdivecomputer/include/libdivecomputer/*.h`). C settings: header search paths `include/libdivecomputer` and `src`; defines `HAVE_PTHREAD_H` and `ENABLE_LOGGING` (the latter added by BlueDive so libdivecomputer's internal logging compiles in). No `config.h` is generated or provided — the few sources that test `HAVE_CONFIG_H` simply compile without it.
   - Vendored snapshot: upstream `libdivecomputer/libdivecomputer` commit `9e6c3c8328562b9b82abce7b476d86e79046d446` (2026-09-11), version 0.10.0. Byte-identical to upstream; no local C patches (the earlier local `SZ_DECOMPRESS_MAX` 20 MB cap from the deepsealabs fork is deliberately NOT applied).
   - `include/libdivecomputer/version.h` is hand-derived from `version.h.in` (autotools not available): `DC_VERSION "0.10.0"`, major 0, minor 10, micro 0, plus the `DC_VERSION_CHECK` macro, `dc_version_t`, `dc_version()`, `dc_version_check()`.
   - Files not copied from upstream: `src/serial_win32.c` (Windows), `src/libdivecomputer.rc` (Windows resource). Files removed upstream and here: `hw_frog.c/.h` and `include/libdivecomputer/hw_frog.h` (merged into hw_ostc3).
   - `Sources/Clibdivecomputer/` contains vestigial files not referenced by the manifest: a `shim.h` including common/context/descriptor/device/parser/iostream/custom/array headers and forward-declaring `dc_parser_new2` and `dc_descriptor_get`; two module maps (one named `Clibdivecomputer [system]` with `link "divecomputer"` and `link "pthread"`; one listing common.h, context.h, descriptor.h, device.h, parser.h, version.h, custom.h, iostream.h). A reimplementation does not need them.

2. **`LibDCBridge`** (C + ObjC): `path: Sources/LibDCBridge`, sources `src/configuredc.c` and `src/BLEBridge.m`, `publicHeadersPath: include`. Depends on `Clibdivecomputer`. C settings: header search paths `include`, `../../libdivecomputer/include`, `../../libdivecomputer/src` (the last one is required because the bridge includes libdivecomputer's private `iostream-private.h` to build a custom iostream vtable); define `OBJC_OLD_DISPATCH_PROTOTYPES=1`. Links frameworks `CoreBluetooth` and `Foundation`.
   - Module map: module `LibDCBridge` with umbrella header `BLEBridge.h`, an `explicit module CoreBluetoothManagerProtocol` (header `CoreBluetoothManagerProtocol.h`, `requires objc`, `export *`), and `module * { export * }`.
   - `BLEBridge.h` includes stdio/stdbool/stdint; under `__OBJC__` imports Foundation and CoreBluetooth (via `@import` when modules are available); includes `libdivecomputer/common.h`, `iostream.h`, `ble.h`, `custom.h`, `parser.h`, `configuredc.h`, `CoreBluetoothManagerProtocol.h`. It also defines four static-inline little/big-endian 16/32-bit array readers (`array_uint16_le/uint32_le/uint16_be/uint32_be`) that nothing in the wrapper uses.
   - `CoreBluetoothManagerProtocol.h`: under `__OBJC__` declares the ObjC protocol (Section 3.1); otherwise `typedef void * CoreBluetoothManagerProtocol`.

3. **`LibDCSwift`** (Swift): `path: Sources/LibDCSwift`; explicit source list: `LibDCSwift.swift` (empty file), `Logger.swift`, `BLEManager.swift`, `Models/DeviceConfiguration.swift`, `Models/DiveData.swift`, `Models/StoredDevice.swift`, `Models/SampleData.swift`, `Models/DeviceFingerprint.swift`, `ViewModels/DiveDataViewModel.swift`, `Parser/GenericParser.swift`, `DiveLogRetriever.swift`. Depends on `LibDCBridge` and `Clibdivecomputer`. cSettings header search paths `../LibDCBridge/include` and `../Clibdivecomputer/include` (ineffective for a Swift target). Links `CoreBluetooth`, `Foundation`. `Sources/LibDCSwift/include/module.modulemap` references an umbrella header `LibDCSwift.h` that does not exist — vestigial.

Swift imports used: `Foundation`, `CoreBluetooth`, `Combine`, `SwiftUI` (only for `Color` in `DiveEvent`), `UIKit` under `canImport(UIKit)` (background tasks), `Clibdivecomputer`, `LibDCBridge`, `LibDCBridge.CoreBluetoothManagerProtocol`.

---

## 2. Public API surface

### 2.1 Swift — `CoreBluetoothManager` (ObjC-exposed name must be exactly `CoreBluetoothManager`)
`public class`, `NSObject`, `ObservableObject`, `CBCentralManagerDelegate`, `CBPeripheralDelegate`, conforms to the ObjC `CoreBluetoothManagerProtocol`. Singleton: `static func shared() -> Any!` (ObjC `+shared`, used by the bridge via `NSClassFromString`) and `static var sharedManager: CoreBluetoothManager`. Private init creates `CBCentralManager(delegate: self, queue: nil)` — **all CoreBluetooth delegate callbacks are delivered on the main queue**.

Published properties (`@Published public var`): `centralManager: CBCentralManager!`, `peripheral: CBPeripheral?` (currently selected), `discoveredPeripherals: [CBPeripheral]`, `isPeripheralReady: Bool`, `connectedDevice: CBPeripheral?` (also `@objc dynamic`), `isScanning`, `isRetrievingLogs` (didSet sends objectWillChange), `currentRetrievalDevice: CBPeripheral?` (same), `isDisconnecting`, `isBluetoothReady`, `isConnecting` (must be mutated on main only).

Public non-published: `openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>?` (NSLock-protected get/set; set sends objectWillChange), `hasValidDeviceDataPtr() -> Bool`.

Public methods: `getPeripheralReadyState() -> Bool`; `setTimeout(_ ms: Int32)`; `discoverServices() -> Bool`; `enableNotifications() -> Bool`; `getDeviceName() -> String`; `write(_ data: Data!) -> Int` (ObjC `writeData:`; returns 0/1/2); `readDataPartial(_ requested: Int32) -> Data?`; `close(clearDevicePtr: Bool = false)`; `close()` (ObjC, = clearDevicePtr false); `startScanning(omitUnsupportedPeripherals: Bool = true)`; `stopScanning()`; `connect(toDevice address: String!) -> Bool` (ObjC `connectToDevice:`); `connectToStoredDevice(_ uuid: String) -> Bool`; `clearRetrievalState()`; `setBackgroundMode(_ enabled: Bool)`; `clearDiscoveredPeripherals()`; `addDiscoveredPeripheral(_:)`; `queueOperation(_ op: @escaping () -> Void)`; `readCharacteristic(byUUID: String, timeout: Double) -> Data?` (ObjC `readCharacteristicByUUID:timeout:`). All CBCentralManagerDelegate / CBPeripheralDelegate methods are public.

Internal `SerialService` class (ObjC `SerialService`): `uuid`, `vendor`, `product` strings. Internal `CBUUID.isStandardBluetooth` (2-byte UUID) — unused. Internal `Data.hexEncodedString()`.

### 2.2 Swift — `DeviceConfiguration` (`@objc public class`, all static)
- `struct ComputerModel: Identifiable, Hashable { id: UUID; name: String; family: DeviceFamily; modelID: UInt32 }` — equality/hash on (family, modelID) only.
- `static let supportedModels: [ComputerModel]` (Section 4.2).
- `enum DeviceFamily: String, Codable, CaseIterable` (16 cases, Section 4.1) with `asDCFamily: dc_family_t` and internal `init?(dcFamily:)`.
- `static func getKnownServiceUUIDs() -> [CBUUID]`.
- `static func openBLEDevice(name: String, deviceAddress: String, forcedModel: (family: DeviceFamily, model: UInt32)? = nil) -> Bool` — blocking; must be called off the main thread.
- `static func fetchDeviceInfo(deviceDataPtr:, completion: @escaping (Bool) -> Void)`.
- `static func updateDeviceConfigurationFromHardware(deviceAddress:, deviceDataPtr:, deviceName:)`.
- `static func fromName(_ name: String) -> (family: DeviceFamily, model: UInt32)?`.
- `static func getDeviceDisplayName(from name: String) -> String`.
- `static func setupContext()`, `cleanupContext()`, `createParser(family: dc_family_t, model: UInt32, data: Data) -> OpaquePointer?`.

### 2.3 Swift — `DiveLogRetriever` (`public class`, static API)
- `public class CallbackContext` (internal members: `logCount`, `viewModel`, `lastFingerprint`, `deviceName`, `deviceUUID`, `deviceSerial`, `deviceTypeFromLibDC`, `hasNewDives`, weak `bluetoothManager`, `devicePtr`, `hasDeviceInfo`, `storedFingerprint`, `isCompleted`, `fingerprintMatched`, `useFingerprint`, `stopBefore`, `cutoffReached`, `detectedFamily`, `detectedModel`).
- `static func retrieveDiveLogs(from devicePtr:, device: CBPeripheral, viewModel: DiveDataViewModel, bluetoothManager: CoreBluetoothManager, syncClock: Bool = false, useFingerprint: Bool = true, stopBefore: Date? = nil, onProgress: ((Int, Int) -> Void)? = nil, completion: @escaping (Bool) -> Void)`.
- `static func getCurrentContext() -> CallbackContext?`.

### 2.4 Swift — `GenericParser` (`public class`, static)
- `enum ParserError: Error { invalidParameters, parserCreationFailed(dc_status_t), datetimeRetrievalFailed(dc_status_t), fieldRetrievalFailed(dc_status_t), sampleProcessingFailed(dc_status_t) }` (fieldRetrievalFailed is never thrown).
- `static let validAtmosphericRange: ClosedRange<Double> = 0.4...1.2` (bar).
- `static func parseDiveData(family: DeviceFamily, model: UInt32, diveNumber: Int, diveData: UnsafePointer<UInt8>, dataSize: Int, context: OpaquePointer? = nil) throws -> DiveData`.
- Internal: `isShearwaterPNF(_:size:)`, `reportsSetpointEverySample(_ family: dc_family_t)`.

### 2.5 Swift — models (Section 7 for fields)
`DiveEvent` (enum, Hashable, with `color: Color`, `description`, `icon`), `DiveProfilePoint`, `GasMix`, `TankInfo` (public but unused), top-level `DecoModel` and `Location` (public, unused duplicates of nested types), `DiveData` (+ nested `Tank`, `Tank.Usage`, `DecoStop`, `Location`, `DiveMode`, `DecoModel`, `DecoModel.DecoType`), `SampleData` (public struct, internal members), `StoredDevice` (Codable class), `DeviceStorage` (`@objc`, singleton `shared`), `DeviceFingerprint` (Codable, Identifiable), `DeviceFingerprintStorage` (singleton), `DiveDataViewModel` (ObservableObject, + `DownloadProgress` enum, `DiveDataPersistence` protocol), `Notification.Name.deviceForgotten` = `"com.libdc.deviceForgotten"`, `extension Data { public var hexString }`.

### 2.6 Swift — `Logger` and globals
`LogLevel` (debug=0, info=1, warning=2, error=3; `prefix` strings "🔍 DEBUG", "ℹ️ INFO", "⚠️ WARN", "❌ ERROR"), `LogEvent { level, message, category (file name), function, timestamp }`, `PacketDirection { inbound, outbound }` (String raw), `PacketEvent { direction, data, characteristicUUID, timestamp; hexDump }`, `Logger.shared` with `onLog`, `onPacket`, `shouldShowRawData`, `minimumLogLevel`, `setMinLevel`, `log(_:level:file:function:)`, `enableDebugMode()`, `disableDebugMode()`, `isDebugMode`, `logPacket(direction:data:characteristicUUID:)`, `setShowRawData`, `resetDataCounters()`. Global functions `logDebug/logInfo/logWarning/logError(_ message:, file:, function:)`.

### 2.7 C — `configuredc.h`
`device_data_t` struct (Section 4.5) and functions: `find_descriptor_by_model`, `find_descriptor_by_name`, `get_device_info_from_name`, `get_alternative_models_for_name` (declared, never implemented), `event_cb` (declared, not implemented — actual handler is static), `get_formatted_device_name`, `open_ble_device`, `reopen_ble_device_with_model` (declared, not implemented), `open_ble_device_with_identification`, `free_device_data`, `create_parser_for_device`, `get_device_data_pointer` (declared, not implemented), `set_libdc_loglevel`, `get_libdc_loglevel`. Also typedefs `dc_sample_callback_t`, `dc_dive_callback_t`, `dc_event_callback_t` mirroring libdivecomputer's callback signatures.

### 2.8 C/ObjC — `BLEBridge.h`
`ble_object_t { void *manager; int timeout_ms; }` (timeout −1 = wait forever/default), `createBLEObject`, `freeBLEObject`, `ble_set_timeout`, `ble_ioctl`, `ble_sleep`, `ble_read`, `ble_write`, `ble_close`, `initializeBLEManager`, `connectToBLEDevice`, `discoverServices`, `enableNotifications`. Also (not in header, defined in configuredc.c) `ble_packet_open(dc_iostream_t **, dc_context_t *, const char *devaddr, void *userdata)`.

---

## 3. BLE transport layer

### 3.1 ObjC protocol contract (`CoreBluetoothManagerProtocol`)
The bridge never links against the Swift class; it resolves the class **by name** (`"CoreBluetoothManager"`) with `NSClassFromString` and calls `+shared` on every operation. The Swift class must expose these selectors: `connectToDevice:` (BOOL), `getPeripheralReadyState` (BOOL), `discoverServices` (BOOL), `enableNotifications` (BOOL), `writeData:` (NSInteger: 0 success, 1 transient with-response confirmation timeout, 2 hard failure), `readDataPartial:` (int → NSData, nil on timeout), `setTimeout:` (int ms), `close`, `getDeviceName` (NSString, empty if none), `readCharacteristicByUUID:timeout:` (NSString uuid, double seconds → NSData or nil). UPSTREAM.md insists `getDeviceName` and the `setTimeout:` selector name must be kept.

### 3.2 Custom `dc_iostream` bridge (configuredc.c)
- A custom vtable with `size = sizeof(vtable)`; implemented: `set_timeout`, `read`, `write`, `ioctl`, `sleep`, `close`. NULL: `set_break`, `set_dtr`, `set_rts`, `get_lines`, `get_available`, `configure`, `poll`, `flush`, `purge`.
- The stream object is a struct embedding the libdivecomputer base (`vtable`, `context`, `transport = DC_TRANSPORT_BLE`) plus a pointer to the `ble_object_t`; allocated with malloc/zeroed. **`close` must NOT free the stream** — libdivecomputer's `dc_iostream_close` calls the vtable close and then `dc_iostream_deallocate`s the same pointer (BlueDive fixed a double-free here). Close releases the `ble_object_t` only.
- `ble_packet_open`: initializes the manager singleton, creates the `ble_object_t` (timeout −1), calls `connectToBLEDevice` (returns `DC_STATUS_IO` on failure, freeing the object), then creates the iostream.
- Logging in the vtable: `set_timeout` logs requested ms (debug only); `read` always prints an error line on non-success, hex-dumps up to 64 bytes on success when debug; `write` hex-dumps (debug) and prints on error; `sleep` logs (debug); `close` always prints.

### 3.3 Status code mapping
- `ble_read`: nil or empty data from `readDataPartial` → `*actual = 0`; if `getPeripheralReadyState` is still true → `DC_STATUS_TIMEOUT` (so Oceanic/Mares retry 3 attempts, DiveSystem 10, per libdivecomputer MAXRETRIES), else `DC_STATUS_IO`. Otherwise copies the packet, `*actual = length`, `DC_STATUS_SUCCESS`. Invalid args → `DC_STATUS_INVALIDARGS`.
- `ble_write`: result 0 → `*actual = size`, SUCCESS; 1 → `*actual = 0`, `DC_STATUS_TIMEOUT`; anything else → `*actual = 0`, `DC_STATUS_IO`.
- `ble_set_timeout`: stores ms in the ble object and forwards to the manager's `setTimeout:`; SUCCESS (INVALIDARGS if io NULL).
- `ble_sleep`: `NSThread sleepForTimeInterval(ms/1000)`; SUCCESS.
- `ble_close`: calls manager `close`; SUCCESS.
- `ble_ioctl`: see 3.4; unknown requests → `DC_STATUS_UNSUPPORTED`.

### 3.4 ioctl handling (exactly two requests implemented)
1. **`DC_IOCTL_BLE_CHARACTERISTIC_READ`** (Cressi Goa/Cartesio/Leonardo read secondary characteristics e.g. `6E400003/4/5-…-10B8` during device open for serial/model/firmware). Requires `data` non-NULL and `size >= 16` (sizeof `dc_ble_uuid_t`), else INVALIDARGS. The first 16 bytes are the UUID (converted to string with `dc_ble_uuid2str`; conversion failure → INVALIDARGS). `want = size − 16` bytes must be filled immediately after the UUID. Timeout passed to the manager = `timeout_ms/1000.0` when `timeout_ms > 0`, else **5.0 s**. If the returned value is nil or shorter than `want` → `DC_STATUS_IO` (logs got/need). Copies exactly `want` bytes; SUCCESS.
2. **`DC_IOCTL_BLE_GET_NAME`** (Oceanic/Aqualung/Sherwood `oceanic_atom2` open embeds the advertised name, e.g. "FH020399", in the READMEMORY handshake; without it the device NAKs with 0xA5). Requires data and size>0. Gets `getDeviceName`; empty → `DC_STATUS_UNSUPPORTED`. Needs `strlen+1` bytes; if larger than `size` → `DC_STATUS_NOMEMORY`. Copies NUL-terminated UTF-8; SUCCESS.
- Not implemented: `DC_IOCTL_BLE_GET_PINCODE`, `GET/SET_ACCESSCODE`, `CHARACTERISTIC_WRITE`.

### 3.5 Connection sequence (`connectToBLEDevice`, runs on libdivecomputer's calling thread — must be a background thread)
1. `connectToDevice:` with the peripheral identifier string; false → fail.
2. Poll `getPeripheralReadyState` every **100 ms** for up to **30 s** (raised from 10 s to allow first-time iOS pairing dialogs that block `didConnect` until the user taps "Pair"). Timeout → manager `close`, fail.
3. `discoverServices` → false → close, fail.
4. `enableNotifications` → false → close, fail.

Swift `connect(toDevice:)`: parse UUID string, `retrievePeripherals(withIdentifiers:)`, none → false. If the peripheral's state is not `.disconnected`, poll every **100 ms** up to **5 s** for `.disconnected` (CoreBluetooth reuses CBPeripheral objects; connecting while a prior teardown is in flight causes "cannot add handler" state-machine errors; critical for Oceanic/Aqualung connect-fail-reconnect cycles); if still not disconnected, warn and proceed anyway. Then (on main, dispatched async if on a background thread): store `peripheral` under the serial queue, set delegate, `centralManager.connect(options: nil)`. Returns true immediately.

`didConnect`: ignored (with warning) if `isDisconnecting` is true (teardown race guard). Otherwise sets delegate, `isPeripheralReady = true` and `connectedDevice` **synchronously** (so the bridge's polling loop sees it immediately).
`didFailToConnect`: logs only (state unchanged → bridge hits its 30 s timeout).

### 3.6 Scanning / filtering
- `startScanning(omitUnsupportedPeripherals: true)`: `scanForPeripherals(withServices: known service UUIDs)`; when false, `withServices: nil`. No options. Sets `isScanning`.
- `didDiscover`: only peripherals **with a non-nil name** are considered; added (deduplicated by identifier, on main) if either a `StoredDevice` exists for its identifier UUID string **or** `DeviceConfiguration.fromName(name)` resolves.

**Known serial service UUIDs** (same list in `CoreBluetoothManager.knownSerialServices` and `DeviceConfiguration.knownServiceUUIDs`; must be kept in sync):
| UUID | Vendor / product |
|---|---|
| `0000fefb-0000-1000-8000-00805f9b34fb` | Heinrichs-Weikamp Telit/Stollmann |
| `2456e1b9-26e2-8f83-e744-f34f01e9d701` | Heinrichs-Weikamp U-Blox |
| `544e326b-5b72-c6b0-1c46-41c1bc448118` | Mares BlueLink Pro |
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic Semi UART (generic) |
| `98ae7120-e62e-11e3-badd-0002a5d5c51b` | Suunto EON Steel/Core |
| `cb3c4555-d670-4670-bc20-b61dbc851e9a` | Pelagic i770R/i200C |
| `ca7b0001-f785-4c38-b599-c7c5fbadb034` | Pelagic i330R/DSX |
| `fdcdeaaa-295d-470e-bf15-04217b7aa0a0` | ScubaPro G2/G3 |
| `fe25c237-0ece-443c-b0aa-e02033e7029d` | Shearwater Perdix/Teric (all pre-Perdix-3) |
| `1aa44039-1667-4b29-87cc-dfecaaf31d97` | Shearwater Perdix 3 (BlueDive addition) |
| `0000fcef-0000-1000-8000-00805f9b34fb` | Divesoft Freedom |
| `6e400001-b5a3-f393-e0a9-e50e24dc10b8` | Cressi Goa (vendor variant of Nordic UART) |
| `00000001-8c3b-4f2c-a59e-8c08224f3253` | Halcyon Symbios |
| `84968ffe-d26d-478a-b953-5010bcf58bca` | Seac Screen |

**Excluded services** (skipped during service selection): `00001530-1212-efde-1523-785feabcd123` (Nordic DFU), `9e5d1e47-5c13-43a0-8635-82ad38a1386f` (Broadcom upgrade 1), `a86abc2d-d44c-442e-99f7-80059a873e36` (Broadcom upgrade 2). UUID comparisons are case-insensitive (lowercased).

### 3.7 Service discovery and characteristic preference rules
`discoverServices()` (background thread): needs a peripheral in `.connected` state; calls `discoverServices(nil)` then polls every **50 ms** up to **5 s** until both a write and a notify characteristic are selected. Returns both-selected.

`didDiscoverServices` (main): resets `preferredService`, `writeCharacteristic`, `notifyCharacteristic`, `characteristicsByUUID` (stale-state fix: a reconnect to a device with no recognised service would otherwise keep dead characteristics and produce "Unknown ATT error"). For each non-excluded service: if it is a known serial service, choose it, **preferring a vendor-specific service over the generic Nordic UART** (Cressi advertises both …CA9E and …10B8 and libdivecomputer needs the vendor one): the first known service is chosen; a later known non-Nordic service replaces a chosen Nordic one. `discoverCharacteristics(nil)` is requested for every non-excluded service (even unknown ones).

`didDiscoverCharacteristics` (main): if a preferred service exists and this service is not it → ignore (prevents GATT 0x1801 "Service Changed" indicate characteristic from hijacking the selection). All characteristics of the accepted service are indexed in `characteristicsByUUID` (lowercased UUID string). **Two-pass selection** under the serial queue: pass 1 picks the FIRST characteristic with `.writeWithoutResponse` as write and the FIRST with `.notify` as notify; pass 2 (only for slots still empty) picks the FIRST `.write` and the FIRST `.indicate`. Rationale: Aqualung i300C/Pelagic OEMs expose one writeWithoutResponse + one write data char plus an auth-nonce notify char in addition to the protocol-data notify char; a single overwrite loop subscribed to the nonce char (UUID starting A60B8E5C…) and dropped all READMEMORY replies. Mares BlueLink Pro has a data and a control channel with write capability. `setNotifyValue` is NOT called here (double subscription confuses Shearwater). In debug mode logs every characteristic UUID and property bits.

`enableNotifications()` (background): snapshot notify char + peripheral; peripheral must be `.connected`; `setNotifyValue(true)`; poll `isNotifying` every **50 ms** up to **30 s** (raised from 5 s for Suunto EON Core / first-time pairing passkey entry); **fast-fails** if the peripheral leaves `.connected`. Returns `isNotifying`.

### 3.8 Writes
`write(_:) -> Int`: snapshot (peripheral, writeCharacteristic) under the serial queue; none → 2. Logs packet outbound via `Logger.logPacket`.
- If the characteristic has `.writeWithoutResponse`: if `canSendWriteWithoutResponse` is false, wait up to **500 ms** total, waking on the `writeReadySemaphore` (signalled by `peripheralIsReady(toSendWriteWithoutResponse:)`) with 50 ms slices; on expiry **write anyway** with a warning (the flag can stick false after connection-parameter renegotiation; CoreBluetooth buffers internally). Then `writeValue(type: .withoutResponse)`. Return 0.
- Else (`.withResponse`): under the queue set `lastWriteError = nil` and increment `pendingWriteCallbackCount`; `writeValue(type: .withResponse)`; loop: wait on `writeConfirmSemaphore` with a **fresh 5 s deadline per iteration** (so draining stale callbacks from earlier timeouts doesn't eat the current budget); a wait timeout → warn, return 1; continue while `pendingWriteCallbackCount > 0`. Then if `isPeripheralReady` is false (close reset the counter) → 2; if `lastWriteError` set → log, 2; else 0. `didWriteValueFor` (main): stores error, decrements the pending count (floor 0), signals the semaphore. FIFO ordering per characteristic makes the last callback belong to the current write.

### 3.9 Receive queue and reads
- `didUpdateValueFor` (main): error → log and return. Logs packet inbound. Under the queue: if `ioctlReadCharUUID` is set and matches this characteristic's UUID → store value in `ioctlReadValue` (do NOT set `hasReceivedFirstPacket`, do NOT signal the data semaphore — avoids spurious semaphore credits and avoids collapsing the 5 s first-read floor during Cressi opens); else **append the notification as one element** of `receivedPackets` (packet boundaries preserved; Shearwater SLIP needs one BLE notification per read; a flat buffer produced "Invalid packet header" when two notifications arrived before a read), set `hasReceivedFirstPacket = true`, then signal `dataAvailableSemaphore` and update transfer stats (EMA 0.7/0.3 of bytes/s; internal only).
- `readDataPartial(requested)`: effective timeout = `bleTimeoutMs`; `<= 0` (i.e. −1 unset) → **3.0 s** default; `> 0` → ms/1000; `== 0` → **poll mode** (check once, return immediately). **First-read floor**: until the first real notification on this connection, a timeout below 5 s is raised to **5.0 s** (unless poll mode) — Aqualung i300C/Pelagic OEMs ignore the first query after a fresh link; shorter floors (2 s) left the module half-initialised and caused later 30 s peripheral-ready timeouts. Dequeue rule (under the queue): first drain `partialPacket` (up to `requested` bytes); else pop the first packet — if its length ≤ requested return it whole, else return the first `requested` bytes and stash the remainder in `partialPacket`. If nothing available: wait on `dataAvailableSemaphore` up to 50 ms; on timeout sleep 1 ms; loop until deadline. On deadline return nil (debug log includes timeout, requested bytes, configured ms, peripheral state, isRetrievingLogs).
- `setTimeout(ms)`: stores `bleTimeoutMs` (debug logs old→new).
- `readCharacteristic(byUUID:timeout:)`: needs peripheral and an indexed characteristic with `.read` property; sets `ioctlReadCharUUID` (lowercased) and clears `ioctlReadValue`; `readValue(for:)`; polls every **20 ms** until the timeout for `ioctlReadValue`; clears the routing on exit (defer). Nil on timeout/missing.

### 3.10 Disconnect / close
`close(clearDevicePtr:)` (any thread):
1. **Re-entrancy guard**: if `isDisconnecting` already true → return. (`free_device_data` → `dc_iostream_close` → vtable close → manager `close` re-enters; without the guard the inner call's 0.5 s reset of `isDisconnecting` fired before `didDisconnectPeripheral`, causing spurious auto-reconnect to a Shearwater that had already left BLE mode → 30 s timeout / frozen UI.)
2. `bleTimeoutMs = −1`.
3. Set `isDisconnecting = true`, `isPeripheralReady = false`, `connectedDevice = nil` — **synchronously on main** (direct if on main, else `main.sync`) so `didDisconnectPeripheral` sees the flag.
4. Under the queue: clear `receivedPackets`, `partialPacket`, `characteristicsByUUID`, `ioctlReadValue`, `ioctlReadCharUUID`.
5. Drain `dataAvailableSemaphore` (non-blocking waits) then signal once; same for `writeReadySemaphore`; set `pendingWriteCallbackCount = 0`, drain and signal `writeConfirmSemaphore` (unblocks a pending `write`, which then returns 2).
6. If `clearDevicePtr` and a device pointer exists: remember whether `device != NULL`; call C `free_device_data` (closes dc device — which sends the protocol exit command, e.g. Shearwater "exit command mode" — closes the iostream (re-enters close, guarded), frees context/descriptor/model/fingerprint, frees the struct); if a device existed **sleep 0.5 s** so the asynchronous BLE write of the shutdown command flushes before the link is torn down (otherwise Shearwater stays stuck on "Sending Dive"/"WAIT CMD"); set `openedDeviceDataPtr = nil`. Never use Swift `deallocate` on this pointer (C calloc).
7. If a peripheral exists: null write/notify characteristics under the queue; on main (async): set `peripheral = nil` under the queue and `cancelPeripheralConnection`.
8. `hasReceivedFirstPacket = false` — deliberately reset only **after** teardown so the exit-command read during `dc_device_close` still uses the short libdc timeout rather than the 5 s floor (i300C auto-disables BT after a sync and never acks its close packet).
9. After **0.5 s** on main: `isDisconnecting = false`.

`didDisconnectPeripheral` (main, work dispatched async to main): `isPeripheralReady = false`, `connectedDevice = nil`. **Auto-reconnect** only if `!isDisconnecting && !isRetrievingLogs && !isConnecting` and a `StoredDevice` exists for the peripheral UUID: immediately set `isConnecting = true` (closes a window where two disconnects within 500 ms both passed the guard and raced two `openBLEDevice` calls on `device_data_t` → double free), then after **500 ms** (lets CoreBluetooth and sleepy devices like the i300C finish tearing down) run `DeviceConfiguration.openBLEDevice(name: stored.name, deviceAddress: stored.uuid)` on a **global userInitiated queue** (never main — it busy-waits for main-queue callbacks and would deadlock). Disconnect during retrieval → warning only (would race the download). Disconnect during connecting → warning only.

### 3.11 Threading model summary
- CoreBluetooth central and all delegate callbacks: main queue.
- Serial queue `com.blemanager.queue` guards: `peripheral` reads from background, `writeCharacteristic`, `notifyCharacteristic`, `receivedPackets`, `partialPacket`, `characteristicsByUUID`, `ioctlRead*`, `lastWriteError`, `pendingWriteCallbackCount`. Never nested.
- `NSLock` for `openedDeviceDataPtr`. `DeviceConfiguration.connectionLock` (NSLock) serialises `openBLEDevice`.
- Semaphores: `dataAvailableSemaphore`, `writeReadySemaphore`, `writeConfirmSemaphore` (all initial 0).
- Blocking waits use `Thread.sleep` polling (never RunLoop) so the main thread stays free. Hence `openBLEDevice`, `connectToBLEDevice`, `discoverServices`, `enableNotifications`, `write`, `readDataPartial`, `readCharacteristic` must run off the main thread.
- Unsynchronised cross-thread fields (fragile): `isPeripheralReady`, `hasReceivedFirstPacket`, `bleTimeoutMs`, `preferredService`, `isRetrievingLogs`.
- `setBackgroundMode(true)` on iOS begins a `UIBackgroundTask` (stored; ended on `setBackgroundMode(false)`). `queueOperation` runs immediately if Bluetooth is powered on, else queues until `centralManagerDidUpdateState(.poweredOn)` flushes the list. `isBluetoothReady` tracks poweredOn vs every other state (each logged).

---

## 4. Device identification and configuration

### 4.1 `DeviceFamily` ↔ `dc_family_t`
`suuntoEonSteel`→`DC_FAMILY_SUUNTO_EONSTEEL`, `shearwaterPetrel`→`DC_FAMILY_SHEARWATER_PETREL`, `hwOstc3`→`DC_FAMILY_HW_OSTC3`, `uwatecSmart`→`DC_FAMILY_UWATEC_SMART`, `oceanicAtom2`→`DC_FAMILY_OCEANIC_ATOM2`, `pelagicI330R`→`DC_FAMILY_PELAGIC_I330R`, `maresIconHD`→`DC_FAMILY_MARES_ICONHD`, `deepsixExcursion`→`DC_FAMILY_DEEPSIX_EXCURSION`, `deepbluCosmiq`→`DC_FAMILY_DEEPBLU_COSMIQ`, `oceansS1`→`DC_FAMILY_OCEANS_S1`, `mcleanExtreme`→`DC_FAMILY_MCLEAN_EXTREME`, `divesoftFreedom`→`DC_FAMILY_DIVESOFT_FREEDOM`, `cressiGoa`→`DC_FAMILY_CRESSI_GOA`, `diveSystem`→`DC_FAMILY_DIVESYSTEM_IDIVE`, `seacScreen`→`DC_FAMILY_SEAC_SCREEN`, `halcyonSymbios`→`DC_FAMILY_HALCYON_SYMBIOS`. Reverse init returns nil for any other family (Shearwater Predator, Suunto D9, TecDiving, Liquivision… are intentionally not reachable: classic-BT/serial-only).

### 4.2 `supportedModels` (name, family, model ID — IDs are libdivecomputer descriptor model numbers)
Shearwater (shearwaterPetrel): Peregrine 9, Peregrine TX 13, Petrel 2 → 3, Petrel 3 → 10, Perdix 5, Perdix AI 6, Perdix 2 → 11, Perdix 3 → 14, Teric 8, Tern 12, Tern TX 12, NERD 2 → 7.
Suunto (suuntoEonSteel): EON Steel 0, EON Core 1, D5 2, EON Steel Black 3.
Scubapro (uwatecSmart): G2 0x32, G2 TEK 0x31, G2 Console 0x32, G2 HUD 0x42, G3 0x34, Aladin A1 0x25, Aladin A2 0x28, Aladin Sport Matrix 0x17, Aladin H Matrix 0x17, Luna 2.0 0x51, Luna 2.0 AI 0x50.
Heinrichs Weikamp (hwOstc3): OSTC 2, OSTC 2 TR, OSTC 3, OSTC cR, OSTC Nano, OSTC Plus, OSTC Sport all 0x00; OSTC 4 0x43; OSTC 5 0x44.
Oceanic/Aqualung/Sherwood (oceanicAtom2): Oceanic Geo 4.0 0x4653, Veo 4.0 0x4654, Pro Plus X 0x4552, Pro Plus 4 0x4656, Atom 3.1 0x4456, Geo Air 0x474B; Aqualung i770R 0x4651, i750TC 0x455A, i550C 0x4652, i470TC 0x4743, i300C 0x4648, i200C 0x4649, i200C (v2) 0x4749; Sherwood Wisdom 3 0x4458, Wisdom 4 0x4655, Sage 0x4647, Beacon 0x4742.
Pelagic (pelagicI330R): Aqualung i330R 0x4744, i330R Console 0x474D, Apeks DSX 0x4741.
Mares (maresIconHD): Icon HD 0x14, Puck Pro 0x18, Puck Pro + 0x18, Smart 0x000010, Smart Apnea 0x010010, Quad 0x29, Quad Air 0x23, Quad Ci 0x31, Quad 2 0x32, Smart Air 0x24, Sirius 0x2F, Sirius L 0x33, Puck Air 2 0x2D, Genius 0x1C, Puck 4 / Puck Lite / Puck Pro EZ / Puck Pro Ultra all 0x35.
Deep Six platform (deepsixExcursion, all 0): Deep Six Excursion, Crest CR-4, Genesis Centauri, Scorpena Alpha.
Deepblu Cosmiq+ (deepbluCosmiq, 0). Oceans S1 (oceansS1, 0). McLean Extreme (mcleanExtreme, 0).
Divesoft (divesoftFreedom): Freedom 19, Liberty 10.
Cressi (cressiGoa): Goa 2, Cartesio 1, Leonardo 2.0 → 3, Donatello 4, Michelangelo 5, Raffaello 6, Neon 9, Nepto 10.
Ratio / DiveSystem (diveSystem): iX3M 2021 GPS Fancy 0x60, Easy 0x61, Pro 0x62, Deep 0x63, Tech+ 0x64, Reb 0x65; iDive 2 Free 0x80, Fancy 0x81, Easy 0x82, Pro 0x83, Deep 0x84, Tech 0x85, Reb 0x86; iX3M 2 GPS Gauge 0x90, Easy 0x91, Pro 0x92, Deep 0x93, Tech 0x94, Reb 0x95; ATOM 0x96; iX3M 2 Gauge 0x100, Easy 0x101, Pro 0x102, Deep 0x103, Tech+ 0x104.
Seac Tablet (seacScreen, 0x10). Halcyon Symbios HUD (halcyonSymbios, 1), Symbios Handset (7).

Important contract: a `ComputerModel.name` is used as the **fingerprint "device type" key** on the Swift side while the C side uses libdivecomputer's `"<vendor> <product>"` string for the same purpose; the two must be identical for a model or fingerprints are saved under one key and looked up under another (this bit the Cressi Raffaello). Several entries share a model ID (listed above) — auto-detected devices may display under the sibling's name.

### 4.3 Name → (family, model) resolution (`fromName`), in order
1. **Oceanic/Pelagic BLE name** (`resolveOceanicBLEName`): name has ≥ 2 Unicode scalars; scalars 0 and 1 must be printable ASCII (0x20–0x7E); every remaining scalar must be an ASCII digit (0x30–0x39); model = (scalar0 << 8) | scalar1; must match a `supportedModels` entry in `oceanicAtom2` or `pelagicI330R` (e.g. "FH12345" → 0x4648 → i300C).
2. **Cressi BLE name** (`resolveCressiBLEName`, mirrors libdivecomputer `dc_match_cressi`): split at the first underscore; the part before, lowercased, must parse as hex AND re-render identically (no leading zeros, lowercase canonical); the part after must be all ASCII hex digits; model must exist in `supportedModels` for `cressiGoa` (e.g. "6_1A2B" → Raffaello). Fixes the C fallback returning Cartesio for every Cressi.
3. **Prefix table** (`resolveByBLENamePrefix`, case-insensitive, anchored at start, first match wins; most specific first): "Mares Genius"→Mares 0x1C; "Sirius L"→0x33; "Sirius"→0x2F; "Quad Ci"→0x31; "Quad Air"→0x23; "Quad2"→0x32; "Puck Pro U"→0x35; "Puck Pro"→0x18; "Puck4"→0x35; "Puck Lite"→0x35; "Puck Air"→0x2D; "Puck"→0x18; "Smart Air"→0x24; "Smart Apnea"→0x010010; "Smart"→0x000010; "Mares bluelink pro"→0x000010; "Tablet"→Seac 0x10 (libdivecomputer's `dc_filter_seac` matches the "Tablet" prefix).
4. **C fallback** `find_descriptor_by_name` (below); if the returned descriptor's family maps to a `DeviceFamily`, return (family, model); descriptor freed.

**C `find_descriptor_by_name`**: first walks a static pattern table (order matters); match modes: `MATCH_PREFIX` = `strncmp` on the prefix; `MATCH_EXACT` and `MATCH_CONTAINS` are both implemented as **substring** (`strstr`) — "exact" is a misnomer. On a match it iterates `dc_descriptor_iterator`/`dc_iterator_next` and returns the first descriptor whose vendor and product strings equal the table's. If no pattern matched (or no descriptor had those strings), falls back to iterating all descriptors and returning the first with `DC_TRANSPORT_BLE` in `dc_descriptor_get_transports` for which `dc_descriptor_filter(descriptor, DC_TRANSPORT_BLE, name)` is true. Else `DC_STATUS_UNSUPPORTED`.

Pattern table (pattern → vendor / product, mode):
- Shearwater: "Predator"→Predator (substr); "Perdix 2"→Perdix 2; "Perdix 3"→Perdix 3; "Petrel 3"→Petrel 3; "Petrel"→Petrel 2 (both Petrel gens advertise "Petrel"); "Perdix"→Perdix; "Teric"→Teric; "Peregrine TX"→Peregrine TX; "Peregrine"→Peregrine (fixed from TX); "NERD 2"→Nerd 2; "NERD"→Nerd (prefix); "Tern SC"→Tern (prefix); "Tern"→Tern (prefix). (Product casing "Nerd"/"Nerd 2" matters.)
- Suunto: "EON Steel"→EON Steel; "Suunto D5"→D5; "EON Core"→EON Core.
- Scubapro: "G2 HUD"→G2 HUD (prefix, before "G2"); "HUD"→G2 HUD (prefix); "G2"→G2 (prefix); "G3"→G3 (prefix); "Aladin A1"→Aladin A1 (prefix); "Aladin A2"→Aladin A2 (prefix); "Aladin"→Aladin Sport Matrix (substr); "A1"→Aladin A1 (prefix); "A2"→Aladin A2 (prefix); "Luna 2.0 AI"→Luna 2.0 AI; "Luna 2.0"→Luna 2.0.
- Mares: "Mares Genius"→Genius; "Sirius L"→Sirius L (prefix); "Sirius"→Sirius (prefix); "Quad Ci"→Quad Ci; "Puck4"→Puck 4.
- Cressi: "CARESIO_"→Cartesio (prefix; note the typo, probably intended "CARTESIO_"); "GOA_"→Goa (prefix); "Leonardo"→Leonardo 2.0 (substr); "Donatello", "Michelangelo" (substr); "Neon", "Nepto" (prefix). (Real Cressi names are hex_hex so these rarely fire; Swift step 2 handles them.)
- Heinrichs Weikamp: "OSTC 3"→OSTC Plus; "OSTC s#"→OSTC Sport; "OSTC s "→OSTC Sport; "OSTC 4-"→OSTC 4; "OSTC 2-"→OSTC 2N; "OSTC + "→OSTC 2; "OSTC"→OSTC 2 (all substr).
- Deepblu: "COSMIQ"→Cosmiq+. Oceans: "S1"→S1 (prefix). McLean: "McLean Extreme"→Extreme. Tecdiving: "DiveComputer"→DiveComputer.eu. Ratio: "DS", "IX5M", "RATIO-" → iX3M 2021 GPS Easy (prefix).

`get_device_info_from_name` returns the descriptor's type and model. `get_formatted_device_name` returns malloc'd "Vendor Product" (caller frees) or NULL.

`getDeviceDisplayName(from:)`: if `fromName` resolves → the matching `supportedModels` name, else the raw BLE name; else C formatted name; else the raw name.

### 4.4 Open sequence
**Swift `openBLEDevice(name:deviceAddress:forcedModel:)`** (holds `connectionLock` for the whole call):
1. On main (async): `isConnecting = true`.
2. Look up `StoredDevice` by address. Configuration priority: **forced > stored > auto-detected from name (`fromName`) > (DC_FAMILY_NULL, 0)**. Auto-detection is only attempted when neither forced nor stored exists.
3. Call C `open_ble_device_with_identification(&data, name, address, family, model)`.
4. Success: persist the configuration — if forced, store (uuid, name, forced family/model); else if no stored device existed and auto-detection succeeded, store it. Then on main: `openedDeviceDataPtr = data`, `isConnecting = false` (debug logs the hand-off delay). Return true.
5. Failure: log status; on main `isConnecting = false`; (if a pointer were returned it is deallocated with Swift's allocator — unreachable since C never returns a pointer on failure). Return false.

**C `open_ble_device_with_identification`**: `calloc` a `device_data_t`. If `stored_family != DC_FAMILY_NULL && stored_model != 0` try `open_ble_device` with it; success → return. Otherwise/then `get_device_info_from_name`; failure → free, return its status. If a stored family was given and the detected family equals it → free and return `DC_STATUS_IO` (retrying the same protocol family with a different model cannot help and creates BLE races — BlueDive changed this from family+model to family-only). Else `open_ble_device` with the detected pair; failure → free, return status.

**C `open_ble_device(data, addr, family, model)`**: zero the struct; `dc_context_new`; `dc_context_set_loglevel(global level)` and `dc_context_set_logfunc` (prints `[libdc LEVEL] basename:line (function): message`, LEVEL ∈ ERROR/WARNING/INFO/DEBUG/TRACE); `find_descriptor_by_model` (iterate descriptors matching `dc_descriptor_get_type == family && dc_descriptor_get_model == model`; UNSUPPORTED if none); `ble_packet_open` (connect; failure → close everything, return); **`dc_device_open` retried up to 5 attempts on the same BLE link with a 3 s sleep before attempts 2–5** (i300C/Pelagic OEMs ignore commands for several seconds after link-up; keeping the link avoids the fragile disconnect/reconnect cycle); failure → free descriptor, close, return; `dc_device_set_events(device, DC_EVENT_DEVINFO | DC_EVENT_PROGRESS | DC_EVENT_CLOCK, handler, data)`; store descriptor; store `model` = malloc'd `"<vendor> <product>"`.

`close_device_data`: free fingerprint, free model, `dc_device_close`, `dc_iostream_close`, `dc_context_free`, `dc_descriptor_free`, nulling each. `free_device_data` = close + `free(struct)`; safe with NULL.

### 4.5 `device_data_t` fields
`device`, `context`, `iostream`, `descriptor` pointers; `have_devinfo` (int) + `devinfo` (`dc_event_devinfo_t`: model, firmware, serial — all unsigned); `have_progress` + `progress` (`dc_event_progress_t`: current, maximum); `have_clock` + `clock` (`dc_event_clock_t`) — **never populated** (handler ignores CLOCK); `fingerprint` (unsigned char*, malloc'd), `fsize`; `fingerprint_context` (void*) and `lookup_fingerprint` function pointer `(context, device_type, serial, size_t *size) -> unsigned char*`; `model` (const char*, "Vendor Product"); `fdeviceid`, `fdiveid` (unused).

### 4.6 Event handling (C)
- `DC_EVENT_DEVINFO`: copy devinfo, `have_devinfo = 1`. If a lookup callback and a model string are set: format serial as **`%08x`** (8 lowercase hex digits of `devinfo.serial`), call `lookup_fingerprint(context, model, serial, &size)`. If a buffer with size > 0 is returned: print it, `dc_device_set_fingerprint(device, buf, size)` (status printed), keep the pointer in `fingerprint`/`fsize` (freed with `free()` on close — hence the buffer **must be malloc'd**; a prior pointer is overwritten without free). Else print "no fingerprint".
- `DC_EVENT_PROGRESS`: copy, `have_progress = 1`.
- Others ignored.

### 4.7 `fetchDeviceInfo` / `updateDeviceConfigurationFromHardware`
- `fetchDeviceInfo`: if `have_devinfo` already → completion(true). Else on a queue `com.libdcswift.deviceinfo` (userInitiated) run `dc_device_foreach` with a callback that returns 0 immediately (stop before any dive); on main: if status is SUCCESS or PROTOCOL and `have_devinfo` → log serial (`%08x`) and model, completion(true); else false.
- `updateDeviceConfigurationFromHardware`: requires `have_devinfo`; `actualModel = devinfo.model`; if a stored device exists with a different model → re-store with the stored family and the hardware model; else if `fromName` resolves with a different model → store (uuid, name, detected family, hardware model). (Note: hardware model numbers are libdivecomputer "model" values from DEVINFO which for some families differ from descriptor IDs — this is upstream behaviour.)

### 4.8 Stored devices persistence (`DeviceStorage`)
UserDefaults key **`com.libdc.storedDevices`**; value = JSON (Foundation `JSONEncoder` defaults: dates as seconds since 2001-01-01, Data as base64) array of `StoredDevice {uuid: String (CBPeripheral identifier uuidString), name: String (BLE name), family: String (DeviceFamily raw value, e.g. "shearwaterPetrel"), model: UInt32, lastConnected: Date (set at creation), serial: String? (optional, backward compatible)}`. Loaded once at init into memory; every mutation re-encodes the whole array and calls `synchronize`. Operations: `storeDevice(uuid:name:family:model:serial:)` (replace by uuid, preserving the existing serial when none supplied; new `lastConnected`), `updateDeviceSerial`, `getStoredDevice(uuid:)`, `removeDevice(uuid:)` (also clears fingerprints: with a known model name and serial → clear that (type, serial); with no serial but known model → clear all fingerprints for that type; then posts `deviceForgotten` with `userInfo["deviceUUID"]`), `getLastConnectedDevice` (max lastConnected), `getAllStoredDevices` (re-reads defaults), `updateStoredDevices(_:)`.

### 4.9 Shared parser context
`DeviceConfiguration.setupContext()` creates one static `dc_context_t` (used only by `createParser`); `cleanupContext()` frees it. `DiveDataViewModel.init` calls setup; its deinit calls cleanup. `createParser` → `create_parser_for_device` (find descriptor by family/model, `dc_parser_new2(parser, context, descriptor, data, size)`, free descriptor).

### 4.10 Log level control
`set_libdc_loglevel`/`get_libdc_loglevel` manage a global (default `DC_LOGLEVEL_WARNING`) applied to each new context at open time (so it must be set **before** opening). Bridge debug prints (`[BLE TIMEOUT]`, `[BLE IOCTL]`, `[BLE READ] Timeout/empty`, `[DC_IO …]` hex dumps) are gated on level ≥ `DC_LOGLEVEL_DEBUG`.

---

## 5. Dive download (`DiveLogRetriever.retrieveDiveLogs`)

Runs on a fresh serial queue `com.libdcswift.retrieval` (userInitiated).

1. On main: `viewModel.resetProgress()` (progress `.notStarted`, status ""), `viewModel.stoppedAtCutoff = false`.
2. Guard `devicePtr.pointee.device != nil`, else `setDetailedError("No device connection found", DC_STATUS_IO)`, completion(false).
3. `deviceName = peripheral.name ?? "Unknown Device"`. Compute `deviceTypeForFingerprint`: if a stored device exists and a `supportedModels` entry matches its (model, family) → that entry's name; else `getDeviceDisplayName(from: deviceName)`.
4. If `useFingerprint` and `have_devinfo` already set (device info from an earlier foreach on this connection): serial = `%08x`; `DeviceStorage.updateDeviceSerial`; `storedFingerprint = viewModel.getFingerprint(forDeviceType: deviceTypeForFingerprint, serial:)`.
5. Build `CallbackContext` (retained via Unmanaged pass-retained; released at completion). `devicePtr` attached.
6. **Progress timer**: `DispatchSourceTimer` on the retrieval queue, fires immediately then every **250 ms**; if `have_progress`, calls `onProgress(current, maximum)` from the device's `DC_EVENT_PROGRESS` data. (A Foundation `Timer` never fires on a GCD thread without a RunLoop — BlueDive fix.) Cancelled after foreach returns.
7. If `useFingerprint`: set `devicePtr.fingerprint_context` = unretained view model pointer and `lookup_fingerprint` = the C-convention lookup closure (Section 5.2). If false, nothing is set, so libdivecomputer gets no fingerprint → full download.
8. Debug: dump peripheral state, dc device pointer, have_devinfo, stored fingerprint hex, isRetrievingLogs, serial/model.
9. `enumStatus = dc_device_foreach(device, diveCallback, contextPtr)`. Non-success logs a warning with status name, dives downloaded so far, fingerprintMatched, hasStoredFingerprint (+ debug context dump).
10. **Clock sync** (Section 5.4) if `syncClock` and (status SUCCESS, or status PROTOCOL with `fingerprintMatched || cutoffReached`).
11. On main — outcome decision (Section 5.3), completion, `context.isCompleted = true`, release context, iOS `endBackgroundTask` (the retriever never *begins* one — only ends an `.invalid` handle; background execution is the host's/`setBackgroundMode`'s job), `currentContext = nil`.
12. `currentContext = context` (static, for `getCurrentContext`).

### 5.1 Dive callback (C convention: data, size, fingerprint, fsize, userdata → Int32; 1 = continue, 0 = stop)
- nil data/userdata/fingerprint → 0.
- **Cancellation**: if `bluetoothManager.isRetrievingLogs == false` → log "Download cancelled", return 0. (The host cancels by clearing `isRetrievingLogs`.)
- **Device info capture (once)**: when `have_devinfo` is set and not yet captured: `deviceSerial = %08x`, `detectedModel = devinfo.model`, `deviceTypeFromLibDC = device_data.model` ("Vendor Product"), `detectedFamily = dc_descriptor_get_type(descriptor)`; `DeviceStorage.updateDeviceSerial`; if `useFingerprint` and no stored fingerprint loaded yet → load with (deviceTypeFromLibDC, serial); `updateDeviceConfigurationFromHardware`; mark captured.
- **Swift-side fingerprint stop**: if `useFingerprint` and a stored fingerprint exists and equals this dive's fingerprint bytes → `fingerprintMatched = true`, return 0. (Belt-and-braces with the C-side `dc_device_set_fingerprint`.)
- **Family/model for parsing**: priority hardware-detected (`detectedModel != 0` → detectedFamily/detectedModel) > stored device > `fromName(deviceName)` > fail (log, return 0). Family must map to `DeviceFamily` else return 0.
- Parse via `GenericParser.parseDiveData(family, model, diveNumber: logCount, data, size)`.
  - **Import cutoff**: if `stopBefore` is set and `dive.datetime < stopBefore` → log, `cutoffReached = true`; if `logCount == 1` (nothing kept yet — this is the newest dive on the device) `lastFingerprint = this fingerprint` (watermark); return 0. Relies on newest-first enumeration.
  - Attach `rawData` (copy of bytes) and `fingerprint` to the dive.
  - **Watermark**: only when `logCount == 1` (first successfully parsed dive = newest) set `lastFingerprint`. Guarded on successful parse so a slot that fails to parse never advances the watermark.
  - On main: `viewModel.appendDives([dive])`, `viewModel.updateProgress(count: logCount)`.
  - `hasNewDives = true`, `logCount += 1`, return 1.
  - Parse error → log, return 1 (skip this dive, continue).

### 5.2 Fingerprint lookup callback (called from C on DEVINFO)
Inputs: context (view model), device type C string, serial C string, out size. Nil context/size → nil. Debug-logs the request. `viewModel.getFingerprint(forDeviceType:serial:)`: if found → `*size = count`, **`malloc`** a buffer (must match the C `free()`; Swift's allocator caused "pointer being freed was not allocated" heap corruption after successful syncs), copy, return. If not found → `*size = 0`, return nil (the C side then skips `dc_device_set_fingerprint`; the previous 4-byte 0xFFFFFFFF sentinel caused `DC_STATUS_INVALIDARGS` on families with other fingerprint sizes, e.g. Oceanic Atom2 needs 8 bytes, and silently disabled fingerprinting).

### 5.3 Outcome decision (on main)
- `DC_STATUS_SUCCESS`: success; save fingerprint if `hasNewDives || (cutoffReached && useFingerprint)`.
- `DC_STATUS_PROTOCOL`:
  - `cutoffReached` → success; save if `hasNewDives || useFingerprint`.
  - `fingerprintMatched` → success; don't save (no new dives).
  - `hasNewDives` → **partial sync**: warn, success, save only if `useFingerprint` (never write a watermark the user opted out of), `viewModel.isPartialSync = true`. (Corrupt/empty slots on old Mares firmware; dives older than the corrupt slot stay unreachable until a forced full re-download.)
  - `storedFingerprint != nil` → success, don't save.
  - else → genuine error (log hint to enable debug mode), failure.
- Any other status → failure.
- Failure: `viewModel.setDetailedError("Download incomplete - DC_STATUS error code: <status>", status)`, completion(false).
- Success: `viewModel.stoppedAtCutoff = cutoffReached`. If saving and `lastFingerprint` and `deviceSerial` exist: device type = stored-device `supportedModels` name if available else `deviceTypeFromLibDC ?? deviceName`; `viewModel.saveFingerprint(lastFP, deviceType, serial)`; `finalizeDiveNumbering()`; progress `.completed`. Else if `fingerprintMatched || (storedFingerprint != nil && !hasNewDives)` → progress `.noNewDives`. Else `finalizeDiveNumbering()`, `.completed`. completion(true).

### 5.4 Clock sync
Build `dc_datetime_t` from the current date in the Gregorian calendar and `TimeZone.current` (year, month, day, hour, minute, second) with `timezone = secondsFromGMT(for: now)` **in seconds** (an earlier bug divided by 60; libdivecomputer's `dc_datetime_t.timezone` is seconds — DiveSystem/Ratio returned INVALIDARGS for non-UTC zones and Shearwater Teric's UTC path was off by 1/60). Call `dc_device_timesync`. SUCCESS → info; `DC_STATUS_UNSUPPORTED` → info (silent normal case); other → warning. Component extraction failure → warning, skipped.

### 5.5 Fingerprint persistence (`DeviceFingerprintStorage`, `DeviceFingerprint`)
UserDefaults key **`"BlueDive"`** (renamed from "DeviceFingerprints" by BlueDive). Value: JSON array of `DeviceFingerprint {id: UUID, deviceType: String, serial: String, fingerprint: Data (base64 in JSON), timestamp: Date}`. Matching: `deviceType` compared lowercased + whitespace-trimmed; serial exact. `getFingerprint` returns the newest (by timestamp) non-empty match. `saveFingerprint` removes all entries for (type, serial) then appends a new one. `clearFingerprint(type, serial)`, `clearFingerprintsForDeviceType(type)`, `clearAllFingerprints()` (removes the key). The view model wraps these (`getFingerprint` → Data?, `saveFingerprint` ignores empty data and sends objectWillChange, `clearFingerprint`, `clearAllFingerprints`, `getFingerprintInfo` → timestamp). Legacy: the view model still has a private key "DeviceFingerprints" used only by `isDownloadOnlyNewDivesEnabled(forDeviceType:serial:)`, which therefore reads a store nothing writes to any more (inconsistency to be aware of). `forgetDevice(deviceType:serial:)` (internal) removes stored devices whose *name* equals the type and clears the fingerprint.

---

## 6. Parsing (`GenericParser.parseDiveData`)

1. `create_parser_for_device(&parser, context (nil from the retriever), family, model, data, size)`; failure → `parserCreationFailed(status)`. Parser destroyed on exit.
2. `dc_parser_get_datetime` → failure throws `datetimeRetrievalFailed`.
3. Setpoint mode: `setpointPerSample = reportsSetpointEverySample(family)` — true for `DC_FAMILY_SHEARWATER_PREDATOR`, `SHEARWATER_PETREL`, `DIVESYSTEM_IDIVE`, `MCLEAN_EXTREME`, `TECDIVING_DIVECOMPUTEREU`; false otherwise (OSTC, EON Steel, D9, Deep Six, Divesoft are change-only). For change-only families, pre-read `DC_FIELD_GASMIX_COUNT` and each `DC_FIELD_GASMIX` (flags = index): collect indices with `usage == DC_USAGE_DILUENT` and `DC_USAGE_OXYGEN`; only if at least one diluent exists are the sets stored (families with no diluent flags cannot signal bailout → setpoint stays held).
4. `dc_parser_samples_foreach` with the sample callback (below); failure → `sampleProcessingFailed`. Then a **post-loop flush** of the last interval (otherwise the final interval's depth/PPO2/pressure was dropped).
5. Fields (each via `dc_parser_get_field`, ignoring non-success):
   - `DC_FIELD_GASMIX_COUNT` (UInt32) and `DC_FIELD_GASMIX` i → `GasMix(helium, oxygen, nitrogen, usage)` (fractions as given by libdivecomputer).
   - `DC_FIELD_TANK_COUNT` and `DC_FIELD_TANK` i → `Tank(volume (L), workingPressure (bar), beginPressure, endPressure, gasMix index, usage ∈ none/oxygen/diluent/sidemount)`. `dc_tankvolume_t`/type is ignored.
   - `DC_FIELD_DECOMODEL` → type BUHLMANN/VPM/RGBM/DCIEM/else none; `conservatism`; GF low/high taken from `params.gf` only for Bühlmann (0 otherwise, stored as UInt32? — non-nil 0 for other models).
   - `DC_FIELD_DIVEMODE` (UInt32) → freedive/gauge/openCircuit/closedCircuit/semiClosedCircuit; unknown or unsupported → openCircuit.
   - `DC_FIELD_SALINITY` → `density > 0 ? density/1000 (kg/m³ → g/cm³, preserving e.g. EN13319 1.020) : (type == DC_WATER_SALT ? 1.025 : 1.000)`.
   - `DC_FIELD_ATMOSPHERIC` (bar) → kept only if finite and within **0.4…1.2**; else nil (Divesoft reports 0 when absent; a zeroed Shearwater opening block reads 0; Cochran derives it from altitude in 250 ft steps). 15 families report it (see RELEASE_NOTES).
   - `DC_FIELD_TEMPERATURE_MINIMUM` / `MAXIMUM` (°C) override the profile-derived min/max. `DC_FIELD_TEMPERATURE_SURFACE` sets both `tempSurface` and `tempSurfaceMeasured`.
   - `DC_FIELD_DIVETIME` (UInt32 seconds) → `reportedDivetime` only if `> 0` and `<= 48*3600` (Mares Icon HD fallback is unsigned and wraps to ~4e9 s).
   - **Shearwater PNF test**: family is shearwaterPetrel and the raw dive does NOT start with bytes 0xFF 0xFF (legacy opening-block marker) and size ≥ 2.
   - `DC_FIELD_AVGDEPTH` (m) → `avgDepth` if finite and > 0; else time-weighted profile average, **cut at `reportedDivetime` only for Shearwater PNF logs** (interpolating the depth at the cut; the cut applies only if the end time is strictly inside the profile's first/last times; otherwise whole profile). Trapezoidal rule; < 2 points → first depth or 0.
   - `DC_FIELD_MAXDEPTH` (m) → `maxDepth` if (family ≠ Shearwater OR PNF) and finite and > 0; else deepest sample. (Legacy Shearwater logs record the maximum in whole m/ft, coarser than 0.1 m samples.) No upper sanity bound (a corrupt all-ones field is not filtered).
6. Date: components year/month/day/hour/minute/second in the Gregorian calendar with the **current (local) time zone**; `dc_datetime_t.timezone` is ignored; nil date → `invalidParameters`.
7. Assemble `DiveData` (Section 7). `divetime` = last `DC_SAMPLE_TIME` seen (`maxTime`), intentionally not `DC_FIELD_DIVETIME`; `temperature` = profile/field minimum (may be +∞ if none); `tankPressure` = flat list of every pressure sample value across tanks; `gasMix` = last real gas index; `gasMixes` nil if empty; `surfaceTemperature`/`measuredSurfaceTemperature`/`minTemperature`/`maxTemperature` nil when not finite; `setpoint` = last reported; `ppo2Readings` cumulative physical sensors only; `cns` last %; `decoStop` from the last deco sample (any type).

### 6.1 Sample callback (libdivecomputer order per record: TIME → DEPTH → TEMPERATURE → PPO2 → SETPOINT → CNS → GASMIX → EVENT …)
Accumulator semantics: values persist (carry forward) across intervals unless stated.
- `DC_SAMPLE_TIME` (ms): **deferred flush** — if a TIME was seen before, emit a profile point for the *previous* interval first (so each point carries its own interval's depth/temp/PPO2, not the next one's), then set `hasSeenTime`, `time = ms/1000`.
- `DC_SAMPLE_DEPTH` (m): `depth`; `maxDepth = max`.
- `DC_SAMPLE_PRESSURE` (tank index, bar): append `(tank, value)` to the cumulative list; `currentPressures[tank] = value` (per-interval; reset on flush).
- `DC_SAMPLE_TEMPERATURE` (°C): `temperature` (carried forward).
- `DC_SAMPLE_EVENT`: map `event.type`: `SAMPLE_EVENT_ASCENT`→ascent, `VIOLATION`→violation, `DECOSTOP`→decoStop, `GASCHANGE`→gasChange, `BOOKMARK`→bookmark, `SAFETYSTOP`→safetyStop(mandatory false), `SAFETYSTOP_MANDATORY`→safetyStop(true), `CEILING`→ceiling, `PO2`→po2, `DEEPSTOP`→deepStop; all others → no event. Then **always** append a synthetic profile point at the current time with the (possibly empty) event list and the current accumulator state (PPO2 accumulators are NOT reset here). Event `flags`/`value`/`time` are ignored. (`SAFETYSTOP_VOLUNTARY`, `GASCHANGE2`, `RBT`, `SURFACE`, `CEILING_SAFETYSTOP`, etc. are not mapped.)
- `DC_SAMPLE_RBT` → `rbt` (UInt32, minutes as libdc). `DC_SAMPLE_HEARTBEAT` → `heartbeat` (bpm). `DC_SAMPLE_BEARING` → `bearing` (degrees).
- `DC_SAMPLE_SETPOINT` (bar): `setpoint` (dive-level last) always; `currentSetpoint` only if not `onOpenCircuit`.
- `DC_SAMPLE_PPO2` (bar): sensor == `DC_SENSOR_NONE` (0xFFFFFFFF, voted/controller) → `currentVotedPPO2`; else `currentPPO2[sensor] = value` and append to cumulative `ppo2`. (No stale fallback from the cumulative list to `po2` — fixed bug where OSTC/Halcyon, which have no voted value, got an arbitrary stale cell value.)
- `DC_SAMPLE_CNS`: `cns = value × 100` (fraction → percent).
- `DC_SAMPLE_DECO`: `deco = {type (dc_deco_type_t), depth (m), time (s), tts (s)}`.
- `DC_SAMPLE_LOCATION` (lat, lon degrees; altitude m): first fix → `location` (entry); every later fix → `exitLocation` (last wins).
- `DC_SAMPLE_GASMIX` (index): if diluent sets are non-empty and index ≠ `DC_GASMIX_UNKNOWN` (0xFFFFFFFF): diluent → `onOpenCircuit = false`, `currentSetpoint = setpoint` (restore); non-oxygen non-diluent → `onOpenCircuit = true`, `currentSetpoint = nil` (bailout); oxygen → unchanged. Then **gas-change synthesis**: if index ≠ UNKNOWN and a previous gas exists and differs → unless the last profile point is at the same time and already carries `.gasChange` (dedup with `SAMPLE_EVENT_GASCHANGE`), append a synthetic point with `[.gasChange]` and `currentGas = new index`. Update the previous-gas tracker only when the index is real (Shearwater sends UNKNOWN for tanks without AI transmitters).
- `DC_SAMPLE_VENDOR` and anything else: ignored.

Flush (`addProfilePoint`): build the point, append, reset `currentPressures`, `currentPPO2`, `currentVotedPPO2`; if `setpointPerSample` reset `currentSetpoint`; `maxTime = max(maxTime, time)`; if a temperature exists: update `tempMinimum/tempMaximum/lastTemperature`, and set `tempSurface` the first time (so "surface temperature" falls back to the first sample's — usually water — temperature). Profile point composition: `pressure` = **last cumulative pressure value of any tank** (carried forward), `pressures` = this interval's per-tank dict, `po2` = voted, `sensorPPO2` = per-cell dict, `ndl` = deco.time if deco.type == `DC_DECO_NDL`, `decoStop`/`decoTime` = deco.depth/time if type == `DC_DECO_DECOSTOP`, `tts` = deco.tts (any type), `currentGas` = gas index, plus cns, rbt, heartbeat, bearing, setpoint = `currentSetpoint`. `pn2`/`phe` are never populated.

Per-family parsing quirks: Shearwater PNF vs legacy (max depth, average cut); per-sample vs change-only setpoint families; Divesoft treated as change-only (reports setpoint only in POINT_1 records and change events); Shearwater gasmix UNKNOWN; `DiveData.temperature` may be infinite for computers without a thermometer (callers must check `isInfinite`); `reportedDivetime` precision: seconds for most, whole minutes ×60 for Shearwater non-PNF, Uwatec Smart, Deepblu, Oceanic i770R; computed by libdivecomputer for Mares Icon HD layouts without the field, Halcyon, Suunto EON Steel. Families reporting `DC_FIELD_AVGDEPTH`: Mares (iconHD/Genius/Horizon), Cressi Goa family, HW OSTC (log version ≥ 0x21), Divesoft (header V2), Deep Six (layout v1), McLean Extreme, Seac Screen, Oceanic i330R/i330R C/DSX. Shearwater PNF dive time starts ~8 s after the profile (observed on a Peregrine).

---

## 7. Data models (types, units, optionality)

**`DiveEvent`** (enum, Hashable): `ascent`, `violation`, `decoStop`, `gasChange`, `bookmark`, `safetyStop(mandatory: Bool)`, `ceiling`, `po2`, `deepStop`. `color`: red/red/orange/blue/yellow/green/red/red/purple. `description`: "Ascent Rate Warning", "Violation", "Deco Stop Required", "Gas Mix Changed", "Bookmark", "Mandatory Safety Stop"/"Safety Stop", "Ceiling Violation", "PPO2 Warning", "Deep Stop". `icon` (SF Symbols): exclamationmark.triangle, exclamationmark.circle, arrow.down.circle, bubble.right, bookmark, checkmark.circle, arrow.up.circle, aqi.high, arrow.down.circle.fill.

**`DiveProfilePoint`** (struct, all `let`, memberwise public init with defaults): `time: TimeInterval` (s), `depth: Double` (m), `temperature: Double?` (°C), `pressure: Double?` (bar, last of any tank), `pressures: [Int: Double]` (tank index → bar, default empty), `po2: Double?` (voted, bar), `sensorPPO2: [Int: Double]` (cell index → bar), `pn2: Double?`, `phe: Double?` (never set), `events: [DiveEvent]`, `ndl: UInt32?` (s), `decoStop: Double?` (m), `decoTime: UInt32?` (s), `tts: UInt32?` (s), `currentGas: Int?`, `cns: Double?` (%), `rbt: UInt32?` (min), `heartbeat: UInt32?` (bpm), `bearing: UInt32?` (°), `setpoint: Double?` (bar, in effect at this sample).

**`GasMix`**: `helium`, `oxygen`, `nitrogen: Double` (fractions), `usage: dc_usage_t`.

**`TankInfo`** (unused): gasMix Int, type dc_tankvolume_t, volume, workPressure, beginPressure, endPressure, usage dc_usage_t.

**Top-level `DecoModel`** (unused duplicate): type (none/buhlmann/vpm/rgbm/dciem), conservatism Int, gfLow/gfHigh UInt32?, `description` ("Bühlmann GF L/H", "Bühlmann", "None", "<Type> (<conservatism>)" or "<Type>"). **Top-level `Location`** (unused): latitude, longitude, altitude Double.

**`DiveData`** (struct, Identifiable, `id = UUID()`): `number: Int` (var; provisional newest=1, renumbered oldest=1 after download), `datetime: Date`, `maxDepth: Double` (m), `avgDepth: Double` (m), `divetime: TimeInterval` (s, last sample), `reportedDivetime: TimeInterval?` (s, computer's own), `temperature: Double` (°C, minimum; may be +∞), `profile: [DiveProfilePoint]`, `tankPressure: [Double]` (bar), `gasMix: Int?`, `gasMixCount: Int?`, `gasMixes: [GasMix]?`, `salinity: Double?` (g/cm³), `atmospheric: Double?` (bar, nil when not reported/invalid), `surfaceTemperature: Double?` (computer value or first-sample fallback), `measuredSurfaceTemperature: Double?` (only computer value), `minTemperature: Double?`, `maxTemperature: Double?`, `tankCount: Int?`, `tanks: [Tank]?`, `diveMode: DiveMode?`, `decoModel: DecoModel?`, `location: Location?` (entry), `exitLocation: Location?`, `rbt: UInt32?`, `heartbeat: UInt32?`, `bearing: UInt32?`, `setpoint: Double?` (last), `ppo2Readings: [(sensor: UInt32, value: Double)]`, `cns: Double?`, `decoStop: DecoStop?`, `rawData: Data?`, `fingerprint: Data?`. Public init takes all of these (defaults: reportedDivetime nil, measuredSurfaceTemperature nil, exitLocation nil, rawData nil; `fingerprint` set after init).
- Nested `Tank { volume, workingPressure, beginPressure, endPressure: Double; gasMix: Int; usage: Usage (none/oxygen/diluent/sidemount) }`.
- `DecoStop { depth: Double; time: TimeInterval; type: Int }` (type = raw `dc_deco_type_t`: 0 NDL, 1 safety stop, 2 deco stop, 3 deep stop).
- `Location { latitude, longitude: Double; altitude: Double? }`.
- `DiveMode` enum: freedive/gauge/openCircuit/closedCircuit/semiClosedCircuit with descriptions "Freedive", "Gauge", "Open Circuit", "Closed Circuit", "Semi-Closed Circuit".
- `DecoModel { type: DecoType; conservatism: Int; gfLow: UInt32?; gfHigh: UInt32? }` with the same `description` logic as above.

**`SampleData`** (internal accumulator): time, depth, temperature?, divetime, maxDepth, avgDepth, lastTemperature, maxTime, `tempSurface = +∞`, `tempSurfaceMeasured = +∞`, `tempMinimum = +∞`, `tempMaximum = −∞` (infinity sentinels — 0 °C is a valid ice-dive temperature, never use 0 as "unset"), pressure list, currentPressures, profile, gasmix?, gasMixes, `atmospheric: Double?` (nil), salinity?, tanks, diveMode (.openCircuit default), decoModel?, location?, exitLocation?, rbt?, heartbeat?, bearing?, setpoint?, currentSetpoint?, ppo2 list, currentPPO2, currentVotedPPO2?, cns?, event? (unused `Event {type, value, flags}`), deco? (`DecoData {type, depth, time, tts}`).

**`StoredDevice`**, **`DeviceFingerprint`**: Section 4.8 / 5.5.

**`DiveDataViewModel`** (ObservableObject): `@Published dives: [DiveData]`, `status: String`, `progress: DownloadProgress` (.notStarted), `hasNewDives: Bool`, `isPartialSync: Bool`, `stoppedAtCutoff: Bool`; `weak persistence: DiveDataPersistence?` (protocol: `saveDives(_:forDevice:)`, `loadDives(forDevice:)`, `clearDives(forDevice:)` — never called by the library); `static getActiveDownloadInstance()` (weak static set in init). `DownloadProgress`: `.notStarted`, `.inProgress(count)`, `.completed`, `.cancelled`, `.failed(message)`, `.noNewDives`; descriptions "Not started", "Downloaded N dives...", "Download completed", "Download cancelled", "Error: <msg>", "No new dives found"; custom Equatable. Methods (all hop to main): `addDive(number:year:…:maxDepth:temperature:)` (placeholder dive with avgDepth = 0.6 × maxDepth), `updateStatus`, `updateProgress(_:)`, `updateProgress(count:)` (status "Downloading dive N...", progress .inProgress(N)), `setError`, `clear()`, `setDetailedError(_:status:)` (maps each `DC_STATUS_*` to a user message: SUCCESS "Operation completed successfully", DONE "Operation completed", UNSUPPORTED "This operation is not supported by your device", INVALIDARGS "Invalid parameters were provided", NOMEMORY "Insufficient memory to complete operation", NODEVICE "Device not found or disconnected", NOACCESS "Access to device was denied", IO multi-line "Connection lost. Please ensure: • Device is within range • Device is turned on • Battery level is sufficient", TIMEOUT "Device took too long to respond. Try again", PROTOCOL "Device communication error. Try turning device off and on", DATAFORMAT "Received invalid data from device", CANCELLED "Download was cancelled", default "Unknown error occurred (Code: …)"; if the message is exactly "Download incomplete" only the status text is shown, else "<message>\n\n<status text>"; sets `.failed`), `appendDives(_:)` (sets hasNewDives, appends, updates count if in progress), `finalizeDiveNumbering()` (sort by datetime ascending, renumber from 1), `resetProgress()`, fingerprint wrappers (5.5), `isDownloadOnlyNewDivesEnabled`.

---

## 8. Diagnostics / logging

- **Swift `Logger`**: singleton; `minimumLogLevel` (default `.debug`); `log` prints `"<prefix> [HH:mm:ss.SSS] [<file name>] <message>"` to stdout and invokes `onLog(LogEvent)` (may be called from background threads; the library never sends telemetry). `enableDebugMode()`: min level debug, `shouldShowRawData = true`, `set_libdc_loglevel(DC_LOGLEVEL_ALL)`, logs an info line — call **before** connecting. `disableDebugMode()`: libdc level WARNING, min level warning, raw data off. `isDebugMode` = libdc level == `DC_LOGLEVEL_ALL` (so Swift debug branches follow the C level). `logPacket` always increments a packet counter and byte total; only when `shouldShowRawData` it calls `onPacket(PacketEvent)` with direction, bytes, characteristic UUID, timestamp (`hexDump`: uppercase hex, space-separated, 16 bytes per line). `resetDataCounters()`.
- **BLE trace points**: outbound in `write`, inbound in `didUpdateValueFor` (both before routing). Debug-gated Swift logs: `[BLE TIMEOUT]`, `[BLE DISCOVER]`, `[BLE NOTIFY]`, `[BLE WRITE]`, `[BLE CLOSE]`, `[BLE CONNECT]`, `[DISCONNECT]` full-state dumps, `[HANDOFF]`, `[FINGERPRINT-LOOKUP]`, `[PRE-FOREACH]`, characteristic property dumps.
- **C/ObjC**: libdivecomputer messages via the context log function to stdout as `[libdc LEVEL] file:line (function): message`; bridge `printf`/`NSLog` lines with prefixes `[BLE]`, `[BLE READ]`, `[BLE WRITE]`, `[BLE IOCTL]`, `[BLE TIMEOUT]`, `[DC_IO READ/WRITE/TIMEOUT/SLEEP/CLOSE]`, `[PROTOCOL RETRY]`, `[C] Setting fingerprint…`. Hex dumps truncated to 64 bytes with "… (N more)". Read errors and close are always printed; hex dumps and timeouts only at level ≥ DEBUG.

---

## 9. Known bugs fixed, per-manufacturer quirks, fragile areas

**Fixed bugs (must stay fixed):**
- Fingerprint buffer allocated with Swift allocator but freed by C `free()` → heap corruption/crash after successful downloads (now `malloc`).
- Custom iostream `close` freed the stream that libdivecomputer immediately frees again (double free).
- `device_data_t` is C-calloc'd; never Swift-`deallocate` it (use `free_device_data`).
- `Timer.scheduledTimer` never fires on a GCD queue (no RunLoop) → progress never updated; use `DispatchSourceTimer`.
- 4-byte sentinel fingerprint broke fingerprinting on 8-byte families (Oceanic Atom2) → return nil/0.
- `dc_datetime_t.timezone` must be seconds, not minutes.
- Profile sample off-by-one-record alignment (flush before advancing time) and the dropped final interval.
- Stale PPO2 fallback into `po2` for physical-only CCR computers.
- Watermark advancing past an unparseable slot (capture only after successful parse).
- Protocol error mid-enumeration discarding all downloaded dives (partial sync).
- Stale `currentContext` retaining the view model after download.
- Auto-reconnect on main queue deadlock; auto-reconnect race on `device_data_t`; re-entrant `close()` resetting `isDisconnecting` early; stale characteristics after reconnect; write-confirm deadline shared across stale callbacks; spurious semaphore credits from ioctl reads; `isPeripheralReady` set asynchronously (bridge polling missed it); `RunLoop.run` in waits blocking main-queue callbacks; `canSendWriteWithoutResponse` hard-fail after 5 s (now 500 ms soft wait).
- 0 °C fabricated as surface/min/max temperature when unset (infinity sentinel).
- Cressi all-models→Cartesio misidentification; Cressi Raffaello fingerprint key mismatch; Peregrine→Peregrine TX; NERD casing; G2 HUD/Aladin A1/A2/Sirius L ordering; Mares Smart Apnea ID 0x010010.
- Shearwater V1 packet size / Perdix 3 V2 framing (in the vendored C library, now upstream).

**Manufacturer quirks:**
- *Shearwater*: SLIP framing requires one BLE notification per read; don't subscribe twice; needs the protocol exit command flushed (0.5 s) before `cancelPeripheralConnection` or stays on "Sending Dive"; Perdix 3 uses service `1aa44039-…` and V2 framing (handled in libdivecomputer); gasmix index UNKNOWN for tanks without AI; PNF vs legacy depth precision; dive time ~1 min shorter than profile (surface logging); reports setpoint per sample (nil on OC bailout); TIMEOUT aborts like IO; "Petrel" name covers gen 1 and 2; Tern/Tern TX share model 12; Shearwater exits BLE mode after close — never auto-reconnect then.
- *Oceanic/Aqualung/Sherwood (Atom2) and Pelagic*: name is `<2 ASCII model chars><digits>`; `DC_IOCTL_BLE_GET_NAME` mandatory (else NAK 0xA5); ignore commands for seconds after link-up → 5 open attempts × 3 s plus 5 s first-read floor; multiple notify chars (auth nonce vs data) → two-pass selection; 8-byte fingerprints; retry on TIMEOUT (3 attempts); i300C turns BT off after a successful sync (no ack to close); needs the peripheral to reach `.disconnected` before reconnecting; i770R dive time in whole minutes; DSX salinity not reported (upstream).
- *Cressi*: advertises Nordic UART and vendor service `…dc10b8` — must pick the vendor one; reads version characteristics via `DC_IOCTL_BLE_CHARACTERISTIC_READ` (5 s default timeout) which must be routed away from the SLIP queue; BLE names `<hex>_<hex>`; aborts on TIMEOUT.
- *Mares*: BlueLink Pro has data + control channels (first-match selection); retries on TIMEOUT (3 attempts); old-firmware corrupt/empty slots → partial sync; Icon HD divetime wrap; several Puck models share 0x35; "Mares bluelink pro" name maps to Smart.
- *Suunto EON Core/Steel*: first-time pairing passkey can take long → 30 s notify-enable wait; aborts on TIMEOUT.
- *DiveSystem/Ratio*: 10 read attempts on TIMEOUT; clock sync requires timezone in seconds; many models/prefixes ("DS", "IX5M", "RATIO-"); iX3M classic-BT variants excluded.
- *Heinrichs Weikamp*: two service UUIDs (Telit/Stollmann, U-Blox); change-only setpoint with diluent flags; name patterns map OSTC variants to a few descriptors (most model ID 0x00).
- *Halcyon Symbios*: physical-sensor PPO2 only (no voted value); HUD model 1, Handset 7.
- *Seac*: advertises as "Tablet".
- *Deep Six platform clones*: Crest CR-4, Genesis Centauri, Scorpena Alpha, all model 0.
- *Divesoft*: atmospheric 0 when absent; change-only setpoint; 4 O2 cells.

**Fragile areas to preserve or improve carefully:** unsynchronised `isPeripheralReady`/`hasReceivedFirstPacket`/`bleTimeoutMs`; `didFailToConnect` does nothing (relies on 30 s timeout); the `fetchDeviceInfo` acceptance of PROTOCOL; `ComputerModel.name` must equal libdivecomputer's "vendor product" for fingerprint keys; hardware DEVINFO model stored into `StoredDevice.model` may differ from descriptor IDs; the view model's legacy "DeviceFingerprints" key; `DiveData.temperature` infinite sentinel; `pressure` in profile points carries forward across tanks; events with unmapped types still produce duplicate profile points; parse-time context is nil (parsers created with a NULL context, so libdivecomputer parser logs are not captured); everything that blocks must stay off the main thread; CoreBluetooth state restoration must not be adopted without the `bluetooth-central` background mode and an audit.

---

## 10. BlueDive team customizations (one line each, newest first)

1. **fd5b0db** — `DiveData.atmospheric` is nil unless the computer reports `DC_FIELD_ATMOSPHERIC` finite within 0.4–1.2 bar (`GenericParser.validAtmosphericRange`); `SampleData.atmospheric` optional; placeholder dive uses nil.
2. **ab4c2e5** — `DiveData.reportedDivetime` from `DC_FIELD_DIVETIME` (nil if 0 or > 48 h); Shearwater PNF detection (first two bytes ≠ 0xFFFF); PNF logs use `DC_FIELD_MAXDEPTH` and cut the profile average at the computer's dive time (interpolated); `calculateAverageDepth(until:)`.
3. **9843523** — Per-sample CCR setpoint (`SampleData.currentSetpoint`, `DiveProfilePoint.setpoint` = setpoint in effect); `reportsSetpointEverySample` family list; bailout handling for change-only backends via diluent/oxygen gas-mix flags.
4. **61481cd** — libdivecomputer → 9e6c3c8; `DC_FIELD_MAXDEPTH`/`DC_FIELD_AVGDEPTH` preferred over profile values (Shearwater excluded for max until the next commit); Cressi Raffaello (model 6); `resolveCressiBLEName` mirroring `dc_match_cressi`; Raffaello fingerprint key fix.
5. **6d36dcb** — `stopBefore: Date?` import cutoff on `retrieveDiveLogs` (stop enumeration at the first older dive; watermark saved when nothing kept and fingerprinting on); `DiveDataViewModel.stoppedAtCutoff`; cutoff stop counts as success and allows clock sync.
6. **1304b05** — `DiveData.measuredSurfaceTemperature` set only from `DC_FIELD_TEMPERATURE_SURFACE` (`SampleData.tempSurfaceMeasured`).
7. **a77d713** — Expanded `supportedModels` (Aladin H Matrix, Pro Plus X, i750TC, i470TC, i200C v2, Wisdom 4, Beacon, Puck Pro +/Lite/Pro EZ/Pro Ultra, Crest CR-4, Genesis Centauri, Scorpena Alpha, full Ratio lines); removed non-BLE models (Predator family, Petrel gen 1, classic-BT iX3M GPS, serial iDive/iDive Color); i200C disambiguated; name cleanup.
8. **faab6f0** — Thread-safety: all background reads of peripheral/characteristics under the serial queue; `didConnect` ignores callbacks during teardown; connect() main-queue dispatch with state re-check; watermark captured only after successful parse; removed dead `systemDisconnect()`.
9. **c0890c7** — Vendored libdivecomputer → official upstream 9b1cd20 (iX3M AI sample/pressure fixes, Frog COMPACT skip, OSTC3 fingerprint precedence, Halcyon/DSX divetime, Seac Tablet 4 MiB ring buffer); clear `currentContext` after download; comment that `divetime` is profile-based.
10. **db3c0f9** — Partial-sync recovery: keep dives downloaded before a `DC_STATUS_PROTOCOL`, advance watermark (only when `useFingerprint`), publish `isPartialSync`.
11. **369656f** — Profile alignment: flush previous interval on `DC_SAMPLE_TIME` with `hasSeenTime` guard; post-loop flush of the final interval; `makeProfilePoint` factory.
12. **a732688** — Per-sensor PPO2 (`DiveProfilePoint.sensorPPO2`, `SampleData.currentPPO2/currentVotedPPO2`); `po2` = voted value only (no stale fallback); `ppo2Readings` physical sensors only; `DC_SENSOR_NONE`/`DC_GASMIX_UNKNOWN` constants.
13. **766ac9b** — C name-pattern fixes (Peregrine, Nerd casing, G2 HUD, Aladin A1/A2, Sirius L, Ratio prefixes, Tern SC, DS/IX5M/RATIO-); clock-sync timezone in seconds; supportedModels additions (Tern TX, Aladin Sport Matrix, Michelangelo/Neon/Nepto, iX3M 2021 GPS Easy); Smart Apnea 0x010010.
14. **c7288c7** — Cherry-picks from upstream: with-response write confirmation, tri-state write result (0/1/2 → SUCCESS/TIMEOUT/IO), `ble_read` TIMEOUT-vs-IO by peripheral readiness, `DC_IOCTL_BLE_CHARACTERISTIC_READ` + `readCharacteristicByUUID:timeout:`, vendor-service preference, ioctl read routing, `connectionLock` around `openBLEDevice`, `useFingerprint` parameter; explicitly declined CoreBluetooth state restoration.
15. **54aa0ee** — `tempSurface` sentinel `Double.infinity` instead of 0; surface/min/max temperatures nil when unset (ice-diving 0 °C fix).
16. **c7bbb38** — Housekeeping: libdivecomputer synced to 8e564eb; removed hw_frog from Makefile.am; UPSTREAM.md markers.
17. **ca792b8** — `Logger.onPacket` / `PacketEvent` / `logPacket` wired into `write` and `didUpdateValueFor` (opt-in via `shouldShowRawData`); removed dead hex-formatting helpers.
18. **6293c2f** — Cressi BLE support (cherry-pick) with BlueDive fixes: per-iteration 5 s write-confirm deadline; no data-semaphore signal for ioctl reads; libdivecomputer Shearwater `maxpacket` fix; UPSTREAM.md, UPSTREAM_ISSUES.md, RELEASE_NOTES.md created; libdivecomputer → 167c065 (Perdix 3 protocol cleanup).
19. **f519ab4** — Shearwater Perdix 3 support (service `1aa44039-…` in both UUID lists, model 14 in supportedModels, "Perdix 3" name pattern; V2 framing in vendored libdivecomputer); salinity density precision (density/1000 fallback 1.025/1.000); auto-reconnect moved off main onto a global queue; `isConnecting` set synchronously before scheduling reconnect; libdivecomputer → 058d06f.
20. **0d8d284** — libdivecomputer → 77759ab (`DC_SAMPLE_LOCATION` replaces `DC_FIELD_LOCATION`); entry/exit GPS (`exitLocation`); gas-change event synthesis on `DC_SAMPLE_GASMIX`; new families `seacScreen`, `halcyonSymbios`; Mares Sirius L, OSTC 5/Nano/cR; OSTC model ID fixes (OSTC 4 0x43; others 0x00); Cressi/Halcyon/Seac service UUIDs; Seac prefix "Tablet"; UPSTREAM.md checklist; log-count fix.
21. **a2deb2f** — Device clock synchronization (`syncClock` → `dc_device_timesync` after download).
22. **1c94568 / 8f00d96 / 7788221** — i300C reliability: `connect(toDevice:)` waits (≤ 5 s) for `.disconnected` before connecting; `dc_device_open` retried 5× with 3 s gaps on the same link; identification fallback skip is family-only; `dc_descriptor_free` on all failure paths.
23. **cac9b50** — Fingerprint lookup returns nil/size 0 instead of a 4-byte 0xFFFFFFFF sentinel; removed Shearwater-only 4-byte sanity check.
24. **64cedc1** — `SAMPLE_EVENT_PO2` mapped to `DiveEvent.po2`.
25. **96bb7a0** — Shearwater "Sending Dive" fix: 0.5 s sleep moved after `free_device_data` (hadDevice captured before); re-entrancy guard in `close()`.
26. **10ceaa5** — Peripheral-ready timeout 10 s → 30 s (pairing dialogs); 500 ms delay before auto-reconnect.
27. **07ff9cc** — `free_device_data()` C teardown API; fingerprint buffer via `malloc`; removed double free in iostream close; two-pass characteristic selection; 5 s first-read floor (`hasReceivedFirstPacket`); `getDeviceName` + `DC_IOCTL_BLE_GET_NAME` handler; debug characteristic dump; let the first i300C attempt fail cleanly and retry.
28. **a41600f** — Notification-enable wait 5 s → 30 s (Suunto EON Core pairing).
29. **b478236** — Comments explaining the shutdown-flush delay.
30. **8a2e377** — `isDisconnecting` set (synchronously) before `cancelPeripheralConnection` to suppress auto-reconnect.
31. **37c799c / 3293a7c / 070ce02** — Per-sample tank pressures: `SampleData.currentPressures`, `DiveProfilePoint.pressures`, populated from `DC_SAMPLE_PRESSURE` and reset per interval.
32. **0253ec3** — Mares model additions (Quad Ci/Quad 2/Sirius/Puck Air 2/Smart Apnea…), `resolveOceanicBLEName`, `bleNamePrefixes` + `resolveByBLENamePrefix`, Swift-first name resolution before the C bridge.
33. **3fed6f5** — `DiveData.fingerprint` attached per dive; fingerprint UserDefaults key renamed "DeviceFingerprints" → "BlueDive".
34. **a92ba0c / d0bdcd6** — `DiveData.rawData` preserving the raw dive bytes; mutable `diveData` in the callback.
35. **df5a812** — Write-without-response: soft 500 ms back-pressure wait then write anyway (was 5 s hard fail).
36. **9c7644f** — Notification packet queue (`receivedPackets` + `partialPacket`) replacing the flat buffer/0x7E frame scanner; one BLE packet per read.
37. **144ecf9** — `DispatchSourceTimer` (250 ms) for progress instead of `Timer`.
38. **50ac09b** — libdivecomputer timeout plumbing: `ble_object_t.timeout_ms`, `ble_set_timeout` → `setTimeout:`, `readDataPartial` honours it (−1 → 3 s, 0 → poll); `writeReadySemaphore`; NSLock on `openedDeviceDataPtr`; discovery/notify timing logs.
39. **e566599** — Structured BLE/DC_IO log prefixes, 64-byte hex-dump truncation, always-log read errors, debug-only timeout logs.
40. **1c35b69** — Runtime libdivecomputer log level (`set_libdc_loglevel`/`get_libdc_loglevel`, default WARNING), context log function to stdout, `ENABLE_LOGGING` define, `Logger.enableDebugMode/disableDebugMode/isDebugMode`, status-name logging for every foreach result.
41. **a9b0272** — Peripheral assignment forced onto the main thread in `connect`.
42. **ede4da1** — `Thread.sleep` polling instead of `RunLoop.run` in discovery/notification waits; `isPeripheralReady`/`connectedDevice` set synchronously in `didConnect`; identification fallback skips a retry when name detection equals the stored config (later relaxed to family-only).

Documentation artefacts BlueDive maintains: `UPSTREAM.md` (what to cherry-pick / never take: keep `getDeviceName`, `setTimeout:` selector, `DC_IOCTL_BLE_GET_NAME`, auto-reconnect, malloc fingerprint, DispatchSourceTimer, nil fingerprint, clock sync, import cutoff; skip state restoration and `SZ_DECOMPRESS_MAX`), `libdivecomputer/UPSTREAM.md` (vendoring procedure and the Swift-side checklist: knownSerialServices, supportedModels, DeviceFamily, knownServiceUUIDs, bleNamePrefixes, device icon assets), `RELEASE_NOTES.md` (v2.0 and Unreleased 2026-10-21 notes quoted throughout above).
