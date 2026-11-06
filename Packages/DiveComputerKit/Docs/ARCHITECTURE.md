# DiveComputerKit — Architecture & Implementation Plan for replacing LibDCSwift

Inputs used (clean-room respected): the behavioural spec (all 484 lines), libdivecomputer headers/sources under `/tmp/libdc-analysis/src/libdivecomputer`, BlueDive's own code, `CLAUDE.md`, `project.pbxproj`. Nothing under `/tmp/libdc-analysis/src/Sources` or any libdc-swift checkout was read.

---

## 1. Executive summary and key decisions

**What changes.** LibDCSwift (remote SPM package `https://github.com/houle988/libdc-swift`, pbxproj:803-811) is replaced by a BlueDive-owned local Swift package **`DiveComputerKit`** containing (a) a C target with the vendored, unmodified libdivecomputer plus a ~60-line shim, and (b) a Swift target with catalog, BLE transport, custom iostream, device session, parser, models and diagnostics. The app's `BluetoothScannerView*` files are re-pointed at the new API; the pure DiveData→Dive mapping is extracted into `DiveImportMapper`; the UserDefaults fingerprint mirror is deleted; the known-device store moves into the app with its on-disk format unchanged. Persisted data formats (family raw values, model IDs, display names, `%08x` serial, fingerprint bytes, raw dive bytes, `com.libdc.storedDevices` JSON) are byte-identical.

**Critique of the preliminary plan — what I changed and why.**

| Preliminary proposal | Verdict | Reason |
|---|---|---|
| Package at `BlueDive/Bluetooth/DiveComputerKit/` | **Rejected — must move to `Packages/DiveComputerKit/` at repo root** | `BlueDive/` is a `PBXFileSystemSynchronizedRootGroup` (pbxproj:96-100). Every `.swift`/`.c` under it is auto-compiled into the app target; a package placed there would be compiled twice (duplicate types, C files built without the module) unless every file is listed as an exception. |
| CoreBluetooth on its own queue + condition-variable queue | Kept, and made the basis for dropping the "never call from main" constraints | Spec §3.11 constraints exist only because the central was created with `queue: nil`. |
| Fingerprint supplied by the app at DEVINFO via a callback into SwiftData | **Changed**: the app passes a `[serial: Data]` table up-front; the session resolves it at DEVINFO on its own thread | A SwiftData lookup from the libdc thread would need `MainActor` blocking; a prebuilt table of all `DeviceFingerprint` records (one row per computer, kilobytes) is trivially Sendable, needs no mirror, and finds the watermark for any known serial — including the "serial unresolvable pre-connect" case the old code could only paper over (IMP:389-435). |
| App-owned KnownDeviceStore with one-time migration of `com.libdc.storedDevices` | Kept the store, **dropped the migration**: keep the key and JSON shape exactly | A key rename buys nothing and adds a failure mode; the format is already app-defined (`StoredDevice` JSON, spec §4.8). |
| `AsyncThrowingStream<DownloadEvent>` download, async connect | Kept, merged into **one** stream per session (`connect → identify → dives → outcome`) with a cancel handle | A single lifecycle object removes the `openedDeviceDataPtr` polling (BLE:272-278) and the "sheet dismiss blocked" rule: close is `await session.cancel()` which joins the libdc thread before freeing anything. |
| Auto-reconnect | **Dropped** (see §4.2) | It is the root of the double-free races and the Shearwater "left BLE mode" 30 s hang (spec §3.10, §9); explicit sessions make it unnecessary. |
| Phases 0→6 | Kept; added a Phase 0b (BLE trace capture) and made golden parity a gate of Phase 3, trace replay a gate of Phase 4 | Both libraries define `dc_*` symbols → single cutover (confirmed), so parity must be proven before cutover, not after. |

**Key decisions (with rationale).**

1. **Local SPM package, not app-target files, not an Xcode framework target.** Reasons: (i) independent Swift language mode and default isolation — the app target has `SWIFT_VERSION = 5.0` with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (pbxproj lines 551, 618); the transport/session/parser code must be *nonisolated* by default, which a package manifest controls (`swiftSettings: [.defaultIsolation(nil)]`, tools-version 6.2); (ii) a hard module boundary kills the `DiveProfilePoint` name collision; (iii) the C target compiles with its own `cSettings` (defines, warning flags) without polluting the app's; (iv) `swift test` runs parser/transport tests in seconds without launching the app; (v) LGPL separation is explicit (the LGPL component is one target with its own `COPYING`). An Xcode framework target would give the same isolation but makes the libdivecomputer sync script fight the project file.
2. **Where libdivecomputer lives:** `Packages/DiveComputerKit/Sources/CLibDiveComputer/{include,src}` as a verbatim copy of upstream `include/` and `src/` (same relative layout as upstream so sync is `rsync --delete` of two directories). Shim in `shim/dc_shim.c` + `include/dc_shim.h`. `version.h` hand-generated (documented in UPSTREAM.md; sync script generates it from `configure.ac`).
3. **Static linking, with an explicit owner sign-off (open question Q1).** Status quo is static. LGPL-2.1 §6 is satisfied by publishing the complete, unmodified libdivecomputer source in the repository (already the case) and by stating in `LICENSE` that the BDSAL does not restrict a user from rebuilding BlueDive with a modified libdivecomputer for their own use (relinkability). If counsel prefers the conservative route, `CLibDiveComputer` becomes `.library(type: .dynamic)` and Xcode embeds it as a framework automatically — a one-line manifest change, no code change, slightly larger app and a dyld load at launch. The LICENSE/README/CONTRIBUTING references to libdc-swift are removed in Phase 6.
4. **Concurrency model (Swift 6 strict in the package):**
   - **One dedicated `Thread` per session** (`LibDCThread`) runs the entire blocking libdivecomputer pipeline (open → foreach → timesync → close). All libdivecomputer callbacks run on it. Not a GCD queue: libdivecomputer blocks for up to 30 s at a time and a thread exposes a `join`.
   - **CoreBluetooth on a private serial `DispatchQueue("app.bluedive.ble")`**; delegate callbacks never touch the main thread. The spec's main-queue assumptions (§3.5 `didConnect` synchronous flag, §3.10 `main.sync` in close, §3.11 "must run off main") are **not retained**: they existed only because the central was on the main queue, and they are the source of the deadlock class the spec documents. Everything the delegate used to set "synchronously on main" is now a field of one lock-protected object, so there is no visibility race to work around.
   - **Locks where a blocking consumer exists, actors everywhere else.** `BLEPeripheralLink` is a `final class: @unchecked Sendable` guarded by one `NSCondition` (its consumer — the libdc thread — cannot `await`). `DiveComputerManager` is `@MainActor @Observable`. Everything crossing between them is a `Sendable` value (`DiscoveredDevice`, `DeviceIdentity`, `DiveData`, `SessionEvent`, `DownloadOutcome`). `CBPeripheral` never leaves the transport layer; the app addresses devices by `UUID`.
   - No Combine anywhere (CLAUDE.md rule); observation via `@Observable` + `AsyncThrowingStream`.
5. **No user-visible strings in the package.** Errors are typed (`SessionError`, `DCStatus`); the app maps them to `NSLocalizedString` literals in a `switch` (CLAUDE.md localisation rule), which also fixes the old English-only `setDetailedError` messages (spec §7).
6. **Data model: no SwiftData change.** `DeviceFingerprint` (`BlueDive/Models/DeviceFingerprint.swift`) keeps its stored attributes; only the type of the *computed* `family` property changes module (same raw values). CloudKit schema unaffected. Flagged explicitly in §5.

---

## 2. Module / file layout

```
Packages/DiveComputerKit/
  Package.swift                      swift-tools-version 6.2; products: DiveComputerKit (static)
  README.md                          architecture summary, threading contract, how to add a device
  Sources/CLibDiveComputer/
    include/libdivecomputer/*.h      upstream verbatim (+ hand-generated version.h)
    include/dc_shim.h                shim API (below)
    src/*.c *.h                      upstream verbatim; excluded in manifest: serial_win32.c, Makefile.am, libdivecomputer.symbols
    shim/dc_shim.c                   ioctl constants as functions, descriptor iterator helper, logfunc trampoline, dc_datetime helpers
    COPYING                          LGPL 2.1 text (upstream)
    UPSTREAM.md                      snapshot SHA/date/version + sync procedure (§10)
  Sources/DiveComputerKit/
    DiveComputerKit.swift            module doc, `public enum DiveComputerKitInfo { libdivecomputerVersion }`
    Catalog/
      DeviceFamily.swift             16 cases, raw values identical to spec §4.1; internal dc_family_t bridge
      ComputerModel.swift            name/family/modelID; Hashable on (family, modelID); Identifiable by "family/modelID"
      DeviceCatalog.swift            supportedModels table (§4.2) + lookups (model(family:modelID:), models(named:))
      BLEServiceCatalog.swift        14 known service UUIDs, 3 excluded UUIDs (§3.6), isVendorSpecific rule
      BLENameResolver.swift          steps 1-4 of §4.3 as data + functions; prefix table; C pattern table as Swift data
      DescriptorLookup.swift         dc_descriptor_iterator_new wrappers: byFamilyModel, byBLEFilter(name), all BLE descriptors
    Transport/
      BLECentral.swift               CBCentralManager owner on bleQueue; scan/retrieve/connect/cancel; state; discovered list publisher
      BLEPeripheralLink.swift        per-connection state machine: GATT selection, packet queue, writes, ioctl read, close
      BLECharacteristicSelector.swift pure two-pass selection + service preference (unit-testable)
      BLEPacketQueue.swift           packets/partial buffer + condition waits (pure, unit-testable)
      BLETiming.swift                every timeout/interval constant from the spec
      BLEError.swift                 transport-level errors
    IOStream/
      DCIOStream.swift               dc_custom_cbs_t table, @convention(c) trampolines, Unmanaged userdata
      DCIOControl.swift              ioctl dispatch: GET_NAME, CHARACTERISTIC_READ, PIN/ACCESSCODE hooks
      BLEAuthorizationProvider.swift protocol for Pelagic PIN / access code (default implementation returns unsupported)
    Session/
      LibDCThread.swift              dedicated Thread + join + cancellable sleep
      DCContext.swift                dc_context_new/free, loglevel, logfunc → DiveComputerLog
      DeviceOpener.swift             descriptor selection, identification fallback, 5×3 s open retries, event registration
      DiveEnumerator.swift           dc_device_foreach callback: cancel, DEVINFO capture, fingerprint stop, cutoff, watermark
      ClockSync.swift                dc_datetime_t from Date/TimeZone (timezone in seconds), dc_device_timesync
      DeviceSession.swift            orchestrates connect → open → enumerate → timesync → teardown; emits SessionEvent
      SessionRequest.swift           inputs (peripheral id, model selection, fingerprints, cutoff, syncClock)
      SessionEvent.swift             event enum
      DownloadOutcome.swift          outcome table (§4.4) result
      SessionError.swift             typed errors + DCStatus
    Parsing/
      DiveParser.swift               parse(family:model:data:context:) → DiveData
      SampleAccumulator.swift        §6.1 state machine (pure Swift, no C in signatures)
      FieldReader.swift              DC_FIELD_* reads + validations (§6 step 5)
      ShearwaterFormat.swift         isPNF(data), reportsSetpointEverySample(family)
      AverageDepth.swift             trapezoidal average, optional cut with interpolation
    Models/
      DiveData.swift                 same field names/units as spec §7 (see §4.6)
      ProfileSample.swift            replaces LibDCSwift.DiveProfilePoint (renamed to kill the collision)
      SampleEvent.swift              9 cases (no SwiftUI Color/icon — app has its own DiveProfileEvent)
      GasMix.swift Tank.swift DecoModel.swift DecoStop.swift Location.swift DiveMode.swift GasUsage.swift PPO2Reading.swift
      DCStatus.swift                 Int32 raw values from common.h:30-41, `name`
      DeviceIdentity.swift           family, modelID (descriptor), hardwareModel, firmware, serial (%08x), libraryName
      DiscoveredDevice.swift         id: UUID, name, lastSeen — Sendable snapshot of a CBPeripheral
    Diagnostics/
      DiveComputerLog.swift          sinks (onLog/onPacket), levels, enable/disableDebugMode, isDebugMode
      LogEvent.swift PacketEvent.swift HexDump.swift
    Manager/
      DiveComputerManager.swift      @MainActor @Observable facade (scan state, discovered list, startSession)
      DeviceSessionHandle.swift      events stream + cancel()
      BluetoothState.swift
  Tests/DiveComputerKitTests/        (Swift Testing; see §7)
    Catalog/   CatalogConsistencyTests.swift NameResolutionTests.swift
    Parsing/   GoldenParityTests.swift SampleAccumulatorTests.swift FieldValidationTests.swift
    Transport/ PacketQueueTests.swift CharacteristicSelectionTests.swift WriteSemanticsTests.swift FakePeripheral.swift
    IOStream/  IOStreamCallbackTests.swift IoctlTests.swift
    Session/   OutcomeDecisionTests.swift CutoffTests.swift TraceReplayTests.swift ScriptedLink.swift
    Fixtures/  golden/ traces/ (see §7 for what is committed)

BlueDive/Bluetooth/ (app)
  KnownDeviceStore.swift             app-owned; UserDefaults "com.libdc.storedDevices", same JSON
  DiveImportMapper.swift             pure DiveData → Dive mapping extracted from +ProfileProcessing / +Import
  BluetoothSyncController.swift      @MainActor @Observable; owns the session task and outcome handling (replaces view-held BLE state)
  (existing files modified per §6)
```

**Shim (`dc_shim.h`)** — only what Swift cannot import: `unsigned int dc_shim_ioctl_ble_get_name(void)` etc. (function-like macros `DC_IOCTL_BLE_*` from `ble.h`/`ioctl.h`; values: GET_NAME 0x40006200, GET_PINCODE 0x40006201, GET_ACCESSCODE 0x40006202, SET_ACCESSCODE 0x80006202, CHARACTERISTIC_READ 0x40006203, CHARACTERISTIC_WRITE 0x80006203 — the shim returns the macro so the values track upstream), `dc_status_t dc_shim_descriptor_iterator(dc_iterator_t **)` (the `dc_descriptor_iterator` macro, descriptor.h:50), and `size_t dc_shim_sizeof_ble_uuid(void)` (16). No private headers (`iostream-private.h`) are included anywhere — `dc_custom_open` (custom.h:63) replaces the hand-built vtable.

**Package.swift essentials.** `CLibDiveComputer`: `path: "Sources/CLibDiveComputer"`, `exclude: ["src/serial_win32.c","src/Makefile.am","src/libdivecomputer.symbols","include/libdivecomputer/Makefile.am","include/libdivecomputer/version.h.in","UPSTREAM.md","COPYING"]`, `publicHeadersPath: "include"`, `cSettings: [.headerSearchPath("src"), .define("ENABLE_LOGGING"), .define("HAVE_PTHREAD_H"), .define("HAVE_CLOCK_GETTIME"), .define("HAVE_LOCALTIME_R"), .define("HAVE_GMTIME_R"), .define("HAVE_TIMEGM"), .define("HAVE_STRUCT_TM_TM_GMTOFF"), .define("HAVE_STRERROR_R"), .define("HAVE_IOKIT_SERIAL_IOSS_H", .when(platforms: [.macOS])), .unsafeFlags(["-Wno-shorten-64-to-32"])]` (unsafeFlags are permitted for local packages; drop it if the package is ever published). `DiveComputerKit`: `swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]`, `linkerSettings: [.linkedFramework("CoreBluetooth")]`. Platforms: `.iOS(.v18), .macOS(.v15)` to match pbxproj deployment targets 18.6/15.6 (raise when the app does).

---

## 3. Public API and consumer mapping

```swift
// Catalog
public enum DeviceFamily: String, Codable, CaseIterable, Sendable { case suuntoEonSteel, shearwaterPetrel, hwOstc3, uwatecSmart, oceanicAtom2, pelagicI330R, maresIconHD, deepsixExcursion, deepbluCosmiq, oceansS1, mcleanExtreme, divesoftFreedom, cressiGoa, diveSystem, seacScreen, halcyonSymbios }
public struct ComputerModel: Hashable, Identifiable, Sendable { public let name: String; public let family: DeviceFamily; public let modelID: UInt32; public var id: String }
public enum DeviceCatalog {
  public static let supportedModels: [ComputerModel]
  public static func model(family: DeviceFamily, modelID: UInt32) -> ComputerModel?        // first match (sibling names share IDs)
  public static func resolve(advertisedName: String) -> (family: DeviceFamily, modelID: UInt32)?
  public static func displayName(forAdvertisedName name: String) -> String
  public static let knownServiceUUIDs: [CBUUID]
}

// Discovery / manager
public struct DiscoveredDevice: Identifiable, Hashable, Sendable { public let id: UUID; public let name: String?; public let lastSeen: Date }
public enum BluetoothState: Sendable { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }

@MainActor @Observable public final class DiveComputerManager {
  public static let shared: DiveComputerManager
  public private(set) var bluetoothState: BluetoothState
  public private(set) var isScanning: Bool
  public private(set) var discoveredDevices: [DiscoveredDevice]          // only named peripherals that pass the filter (§3.6)
  public var discoveryFilter: @Sendable (_ id: UUID, _ name: String) -> Bool   // app injects "known device OR catalog resolves"
  public func startScanning(onlyKnownServices: Bool)
  public func stopScanning()
  public func clearDiscoveredDevices()
  public func knownPeripheral(id: UUID) -> DiscoveredDevice?             // retrievePeripherals(withIdentifiers:)
  public private(set) var activeSession: DeviceSessionHandle?
  public func startSession(_ request: SessionRequest) -> DeviceSessionHandle  // one at a time; precondition(activeSession == nil)
}

// Session
public struct SessionRequest: Sendable {
  public var peripheralID: UUID
  public var advertisedName: String?
  public var modelSelection: ModelSelection          // .forced(DeviceFamily, UInt32) | .stored(DeviceFamily, UInt32) | .autoDetect
  public var fingerprintsBySerial: [String: Data]    // key: lowercased %08x serial; empty when "Download all dives"
  public var cutoff: Cutoff?                         // .stopBefore(Date, onlyWhenNoWatermark: Bool)
  public var syncClock: Bool
  public var authorization: (any BLEAuthorizationProvider)?   // Pelagic PIN/access code; nil = unsupported (parity)
}
public enum ConnectStep: Sendable { case retrievingPeripheral, waitingForDisconnectedState, connecting, discoveringServices, enablingNotifications, openingDevice(attempt: Int) }
public enum SessionEvent: Sendable {
  case connecting(ConnectStep)
  case connected
  case deviceIdentified(DeviceIdentity, watermarkApplied: Bool)
  case progress(current: UInt32, maximum: UInt32)
  case dive(DiveData)                                  // newest first; number = provisional count
  case diveSkipped(index: Int, error: ParseError)
  case clockSync(ClockSyncResult)                       // .synced, .unsupported, .failed(DCStatus), .skipped
  case finished(DownloadOutcome)
}
public struct DownloadOutcome: Sendable {
  public enum Kind: Sendable { case completed, noNewDives, partial, stoppedAtCutoff }
  public let kind: Kind; public let status: DCStatus; public let diveCount: Int
  public let identity: DeviceIdentity?; public let newestFingerprint: Data?; public let shouldAdvanceWatermark: Bool
  public let fingerprintMatched: Bool; public let cutoffReached: Bool
}
public enum SessionError: Error, Sendable { case bluetoothUnavailable(BluetoothState), peripheralNotFound, connectionFailed(underlying: String?), connectionTimeout, serviceDiscoveryFailed, notificationEnableFailed, unsupportedDevice(name: String?), deviceOpenFailed(DCStatus, attempts: Int), disconnected, downloadFailed(DCStatus), cancelled }
public enum DCStatus: Int32, Sendable { case success = 0, done = 1, unsupported = -1, invalidArgs = -2, noMemory = -3, noDevice = -4, noAccess = -5, io = -6, timeout = -7, protocolError = -8, dataFormat = -9, cancelled = -10; public var name: String }
public final class DeviceSessionHandle: Sendable { public let events: AsyncThrowingStream<SessionEvent, any Error>; public func cancel() async }   // cancel waits for teardown (thread join)

// Parsing (also usable standalone — golden tests, re-parse of stored rawDiveComputerData)
public enum DiveParser { public static func parse(family: DeviceFamily, modelID: UInt32, data: Data, diveNumber: Int) throws(ParseError) -> DiveData }
public enum ParseError: Error, Sendable { case parserCreationFailed(DCStatus), datetimeRetrievalFailed(DCStatus), sampleProcessingFailed(DCStatus), invalidDate }

// Diagnostics
public final class DiveComputerLog: @unchecked Sendable { public static let shared; public var onLog: (@Sendable (LogEvent) -> Void)?; public var onPacket: (@Sendable (PacketEvent) -> Void)?; public var minimumLevel: LogLevel; public func enableDebugMode(); public func disableDebugMode(); public var isDebugMode: Bool }
public enum LogLevel: Int, Sendable { case debug, info, warning, error; public var prefix: String }   // "🔍 DEBUG", "ℹ️ INFO", "⚠️ WARN", "❌ ERROR"
public struct LogEvent: Sendable { level, message, category, function, timestamp }
public enum PacketDirection: String, Sendable { case inbound, outbound }
public struct PacketEvent: Sendable { direction, data, characteristicUUID: String, timestamp; public var hexDump: String }
```

**Consumer symbol → new API**

| Old symbol (file) | New |
|---|---|
| `CoreBluetoothManager.sharedManager` / `@ObservedObject bleManager` (BSV:45) | `DiveComputerManager.shared` via `@Environment` or `@State`; `@Observable` |
| `bleManager.$discoveredPeripherals` + `onReceive` (BSV:264) | `.onChange(of: manager.discoveredDevices)` |
| `startScanning(omitUnsupportedPeripherals:)` (BLE:14) | `startScanning(onlyKnownServices:)` (inverted name, same semantics) |
| `stopScanning`, `clearDiscoveredPeripherals` | same names |
| `centralManager.retrievePeripherals(withIdentifiers:)` (BLE:73) | `manager.knownPeripheral(id:)` |
| `isConnecting`, `isRetrievingLogs`, `currentRetrievalDevice`, `clearRetrievalState` | gone; `manager.activeSession != nil`; the view's `syncState` is the only UI state |
| `openedDeviceDataPtr` polling (BLE:272-278) | gone; `.connected` event |
| `close(clearDevicePtr:)` (BSV:271, BLE:286/454/495/521, Views:662) | `await handle.cancel()` (idempotent; safe at any time) |
| `DeviceConfiguration.openBLEDevice(name:deviceAddress:forcedModel:)` (BLE:240) | `manager.startSession(SessionRequest(...modelSelection: .forced/.stored/.autoDetect))` |
| `DeviceConfiguration.getDeviceDisplayName(from:)` | `DeviceCatalog.displayName(forAdvertisedName:)` |
| `DeviceConfiguration.supportedModels`, `ComputerModel`, `DeviceFamily` | `DeviceCatalog.supportedModels`, `ComputerModel`, `DeviceFamily` (top-level) |
| `DeviceStorage.shared.*` (BLE:70-162, 291-296, 513-517, 545-558, 588-598, 617, 713-726; IMP:83,138,305-330,373-422,609-616,726-753; PP:92,799,810; Components:107) | `KnownDeviceStore.shared.*` (same method names: `device(id:)`, `allDevices`, `store(...)`, `updateSerial`, `remove(id:)`, `replaceAll`) |
| `DeviceFingerprintStorage.shared.*` (BLE:359; IMP:427-487, 635, 714-719) | **deleted** — fingerprints come from SwiftData directly (`SessionRequest.fingerprintsBySerial`, `DownloadOutcome.newestFingerprint`) |
| `DiveDataViewModel` (`$progress` sink BLE:328, `dives`, `stoppedAtCutoff`, `isPartialSync`, `progress .failed(msg)`) | `SessionEvent.dive` count, `DownloadOutcome.kind/.cutoffReached`, `SessionError` |
| `DiveLogRetriever.retrieveDiveLogs(from:device:viewModel:bluetoothManager:syncClock:useFingerprint:stopBefore:onProgress:completion:)` (BLE:393-527) | `for try await event in handle.events { ... }` |
| `DiveData` fields (PP:656-867, IMP:796-955, Tests:272-279) | `DiveData` — same field names; `GasMix.usage`/`Tank.usage` → `GasUsage`; `ppo2Readings: [PPO2Reading]` |
| `LibDCSwift.DiveProfilePoint` (PP:127, 322, 325) | `ProfileSample` |
| `LibDCSwift.DiveEvent` (PP:272) | `SampleEvent` (same 9 cases) |
| `Logger.shared.onLog/onPacket/enableDebugMode/disableDebugMode/minimumLogLevel` (BLEDiagnosticSession:164-209) | `DiveComputerLog.shared.*` — identical event shapes |
| `DeviceConfiguration.DeviceFamily` in `DeviceFingerprint.family` (Models/DeviceFingerprint.swift:35-38) | `DeviceFamily` |

---

## 4. Detailed design per layer

### 4.1 Catalog & name resolution

All tables are **Swift data** (static arrays), unit-tested against libdivecomputer at test time, never derived at runtime:

- `DeviceFamily` ↔ `dc_family_t` (spec §4.1): the 16 cases; `init?(dcFamily:)` returns nil for Predator, D9, Tecdiving, etc.
- `DeviceCatalog.supportedModels` — port spec §4.2 verbatim (names are persisted in `Dive.computerName`, `DeviceFingerprint.computerName`, Fingerprint XML `<computerName>`, and icon asset names via `modelLevelAssetName` in `BluetoothScannerComponents.swift:80`). Includes the non-BLE legacy entries (Atom 3.1 0x4456, Wisdom 3 0x4458, Icon HD 0x14) for display-name compatibility; mark them `transports: []` so the picker can grey them out later.
- `BLEServiceCatalog`: the 14 service UUIDs and 3 excluded UUIDs of §3.6, lowercased comparison; `isNordicUART(uuid)` for the vendor-preference rule.
- `BLENameResolver.resolve(name)` — exactly steps 1–4 of §4.3: (1) Oceanic/Pelagic `<2 printable ASCII><digits>` → `(c0<<8)|c1` in `oceanicAtom2 ∪ pelagicI330R`; (2) Cressi `<hex>_<hex>` canonical-hex check → `cressiGoa`; (3) prefix table (18 entries, order preserved); (4) descriptor fallback. Step 4 is implemented as: the C pattern table of §4.3 ported as Swift data `[(pattern, vendor, product, mode)]` with `.prefix` and `.substring` (the spec notes EXACT and CONTAINS were both `strstr`), matched against `DescriptorLookup.all` by vendor/product; then `dc_descriptor_filter(descriptor, DC_TRANSPORT_BLE, name)` over descriptors whose `dc_descriptor_get_transports` contains BLE (descriptor.h:107, 125). **Why not `dc_descriptor_filter` alone:** the filter is *per family* for Shearwater, Suunto, Uwatec, Mares, HW, Divesoft, Deep Six, Ratio, Seac (descriptor.c `dc_filter_shearwater` uses `dc_match_name` against a family-wide list; `dc_filter_mares` likewise) — it returns true for every descriptor of the family, so it cannot pick Perdix vs Teric or Puck Pro vs Sirius. It is model-precise only for Oceanic/Pelagic (`dc_match_oceanic`), Cressi (`dc_match_cressi`) and Halcyon (`dc_match_halcyon`). Hence Swift steps 1–3 stay authoritative and step 4 is the fallback, exactly as today. Edge: "NERD"/"Predator" patterns resolve to Predator-family descriptors → `DeviceFamily(dcFamily:)` nil → unresolved (same as today).
- `displayName(forAdvertisedName:)`: resolve → first `supportedModels` entry with that (family, modelID) → `name`; else libdivecomputer "Vendor Product"; else the raw name (spec §4.3 end).
- `DescriptorLookup` wraps `dc_shim_descriptor_iterator` + `dc_iterator_next` + `dc_descriptor_free` with a Swift `struct Descriptor { vendor, product, family, model, transports }` snapshot; `byFamilyModel` returns the `OpaquePointer` (owned, freed by `DeviceOpener`/`DiveParser`).
- Tests: every `supportedModels` entry with BLE in its `transports` exists in libdivecomputer with BLE (fail); every BLE descriptor exists in `supportedModels` (fail — this is the "new device upstream" tripwire for §10); each `supportedModels.name == "\(vendor) \(product)"` for the descriptor it opens (fingerprint-key contract, spec §4.2 "Important contract") — note the Ratio product `"iX3M 2021 GPS Pro "` has a trailing space in descriptor.c:428; the test must trim and the catalog keeps BlueDive's trimmed name.

### 4.2 BLE transport

**`BLECentral`** (owns `CBCentralManager(delegate:self, queue: bleQueue)`): state (`BluetoothState`), `scan(onlyKnownServices:)` → `scanForPeripherals(withServices: knownServiceUUIDs or nil, options: nil)`; `didDiscover`: ignore nameless peripherals; dedupe by identifier; apply the injected `discoveryFilter(id, name)`; publish to `DiveComputerManager` via `Task { @MainActor in }`. `retrieve(id:) -> CBPeripheral?`. `connect(peripheral, link:)`: routes `didConnect`/`didFailToConnect`/`didDisconnect` to the link registered for that identifier. `didDisconnectPeripheral`: link.markDisconnected(error) → wakes every waiter with `.disconnected`. **No auto-reconnect** (justification: §1; the spec's own §9 list of fixed bugs is dominated by its side effects; an unexpected disconnect now fails the session deterministically and the UI offers Retry).

**`BLEPeripheralLink`** — one per session, `NSCondition`-guarded state:
- *Connect sequence* (spec §3.5): if `peripheral.state != .disconnected`, poll every **100 ms** up to **5 s** for `.disconnected` (CoreBluetooth has no state-change callback; keep the poll, on the libdc thread with cancellable sleeps), warn and proceed if still not. `central.connect(peripheral, options: nil)`; wait on the condition up to **30 s** for `didConnect` (pairing dialog); `didFailToConnect` fails immediately (change: spec §3.5 says it only logged and relied on the 30 s timeout — deterministic failure is strictly better; the 30 s remains the backstop).
- *Service discovery* (§3.7): `discoverServices(nil)`; in `didDiscoverServices` reset `preferredService/write/notify/characteristicsByUUID`; for each non-excluded service: if known → choose it, **vendor-specific beats Nordic UART** (`6e400001-…ca9e`); call `discoverCharacteristics(nil)` for every non-excluded service. `didDiscoverCharacteristicsFor`: ignore services other than the preferred one (blocks GATT 0x1801 hijack); index all by lowercased UUID; **two-pass selection** (pass 1: first `.writeWithoutResponse` → write, first `.notify` → notify; pass 2 fills empty slots with first `.write` / first `.indicate`). Signal the condition. The waiter times out after **5 s**. Debug-dump every characteristic's UUID and property bits. Do **not** call `setNotifyValue` here.
- *Enable notifications*: `setNotifyValue(true, for: notify)`; wait on `didUpdateNotificationStateFor` up to **30 s**; fast-fail when the link leaves `.connected` (the disconnect handler broadcasts).
- *Packet queue* (`BLEPacketQueue`, §3.9): `didUpdateValueFor`: error → log and drop; `DiveComputerLog.logPacket(.inbound, data, uuid)` **before routing**; if an ioctl read route matches this characteristic → store in `ioctlValue` and signal **only the ioctl waiter** (no `firstPacketReceived`, no data signal — spec rationale: spurious credits / Cressi first-read floor); else append the notification **as one element** (boundaries preserved — Shearwater SLIP reads `BLE_MTU_MAX` and expects one frame per read, shearwater_common.c `slip_read`), set `firstPacketReceived = true`, broadcast.
  `read(requested, timeoutMs)`: effective timeout: `< 0` → **3.0 s**; `== 0` → poll mode (one check, return immediately); `> 0` → ms/1000; **first-read floor**: until `firstPacketReceived`, a timeout below 5 s is raised to **5.0 s** (not in poll mode). Dequeue: drain `partial` first (up to `requested`), else pop head: if `count <= requested` return whole, else return prefix and stash remainder. Nothing available → `condition.wait(until: deadline)` (replaces the 50 ms/1 ms polling: identical semantics, lower latency, no busy-wait). Returns `nil` on deadline (debug log: timeout, requested, configured ms, peripheral state).
- *Writes* (§3.8): snapshot (peripheral, writeChar); none → `.failure`. `logPacket(.outbound)`. `.writeWithoutResponse`: if `!canSendWriteWithoutResponse` wait on the condition (signalled by `peripheralIsReady(toSendWriteWithoutResponse:)`) up to **500 ms total**, then **write anyway** with a warning; `writeValue(type: .withoutResponse)`; `.success`. `.withResponse`: `lastWriteError = nil; pendingWriteCallbacks += 1; writeValue(.withResponse)`; loop while `pendingWriteCallbacks > 0`: wait with a **fresh 5 s deadline per iteration**; timeout → `.timeout`; after the loop: link not connected → `.failure`; `lastWriteError != nil` → `.failure`; else `.success`. `didWriteValueFor`: store error, decrement (floor 0), broadcast.
- *Characteristic read for ioctl* (§3.9): requires an indexed characteristic with `.read`; set route (lowercased UUID), clear value, `readValue(for:)`, wait on the condition until deadline for `ioctlValue` (replaces the 20 ms poll), clear route in `defer`. Timeout = `timeoutMs > 0 ? timeoutMs/1000 : 5.0`.
- *Device name*: `peripheral.name ?? ""` (for `GET_NAME`).
- *Close / disconnect* (§3.10, re-sequenced for the new ownership — see §4.4 teardown): `markClosing()` (fails all future waits), clear queues, null characteristics, `cancelPeripheralConnection`, wait up to **2 s** for `didDisconnect` (so a subsequent connect does not hit the 5 s "not disconnected" wait), release. The `isDisconnecting` 0.5 s reset and the re-entrancy guard disappear with auto-reconnect; `firstPacketReceived` is simply never reset before the device close (spec §3.10 step 8 rationale preserved: the exit-command read uses the backend's short timeout).
- *Cancellation*: `link.cancel()` sets a flag and broadcasts; every wait returns `.cancelled`/IO at once (including the 3 s open-retry sleeps, implemented as condition waits).

**`BLETiming`** (single source of constants): `disconnectedStatePoll = 0.1`, `disconnectedStateWait = 5`, `connectWait = 30`, `discoveryWait = 5`, `notifyEnableWait = 30`, `defaultReadTimeout = 3`, `firstReadFloor = 5`, `writeWithoutResponseBackpressure = 0.5`, `writeConfirmPerCallback = 5`, `ioctlReadDefault = 5`, `openRetries = 5`, `openRetryDelay = 3`, `closeFlush = 0.5`, `disconnectWait = 2`, `progressCoalesce = 0.1`.

### 4.3 Custom iostream (`DCIOStream`)

Created with `dc_custom_open(&iostream, ctx, DC_TRANSPORT_BLE, &cbs, userdata)` (custom.h:63); `userdata = Unmanaged.passUnretained(link).toOpaque()` (the session owns the link for the whole stream lifetime; released after `dc_iostream_close`). libdivecomputer treats NULL callbacks as success (custom.c), so only these are set:

| Callback | Implementation | Return |
|---|---|---|
| `set_timeout(ms)` | store on link (debug log old→new) | SUCCESS |
| `read(data,size,actual)` | `link.read(size, timeout)`; nil/empty → `*actual=0`, link connected ? **TIMEOUT** : **IO** (retrying backends: oceanic_atom2 3×, divesystem 10×, mares; non-retrying abort either way) ; else copy, `*actual=n`, SUCCESS. Never SUCCESS with 0 bytes. | as described |
| `write(data,size,actual)` | `.success` → `*actual=size`, SUCCESS; `.timeout` → 0, TIMEOUT; `.failure` → 0, IO | |
| `ioctl(req,data,size)` | `DCIOControl.dispatch` (below); unknown → UNSUPPORTED | |
| `sleep(ms)` | cancellable condition wait (not `Thread.sleep`, so cancel wakes it) | SUCCESS |
| `poll(timeout)` | wait until a packet is queued or timeout (hw_ostc3.c:420 uses it as a delay; NULL would return at once — both work; implementing it is closer to the serial semantics) | SUCCESS / TIMEOUT |
| `purge(direction)` | input: clear `packets`/`partial` (oceanic_atom2, mares_iconhd, cressi_goa, seac, divesystem purge before retries); output: no-op | SUCCESS |
| `close` | `link.markIOStreamClosed()` only — **never free**: `dc_iostream_close` (iostream.c) calls the vtable close and then `dc_iostream_deallocate`s its own struct | SUCCESS |
| `set_break/dtr/rts/get_lines/get_available/configure/flush` | NULL | (libdc returns SUCCESS) |

Logging parity: read non-success always logs an error line; hex dumps (≤64 bytes + "… (N more)") at debug; write errors always logged (spec §3.2). Note libdivecomputer itself also HEXDUMPs reads at INFO level through the context (iostream.c `dc_iostream_read`), which `DCContext` routes to `onLog`.

**`DCIOControl`**: `CHARACTERISTIC_READ`: `size >= 16` and data non-NULL else INVALIDARGS; UUID via `dc_ble_uuid2str` (ble.h:84) else INVALIDARGS; `want = size-16`; `link.readCharacteristic(uuid, timeout: timeoutMs>0 ? ms/1000 : 5.0)`; nil or shorter than `want` → IO; copy exactly `want`; SUCCESS (cressi_goa.c:499). `GET_NAME`: data/size>0 required; empty name → UNSUPPORTED (oceanic_atom2.c:816-823 tolerates and warns); needs `strlen+1 <= size` else NOMEMORY; copy NUL-terminated. `GET_PINCODE` / `GET_ACCESSCODE` / `SET_ACCESSCODE`: forwarded to `SessionRequest.authorization` if present — `pinCode(for identity) -> String?` (blocking on the libdc thread; the app implementation hops to MainActor to present a prompt and returns via a continuation; nil → UNSUPPORTED), `accessCode(for:) -> Data?` (16 bytes; nil → UNSUPPORTED), `store(accessCode:for:)`. With `authorization == nil` all three return UNSUPPORTED, which pelagic_i330r.c:389-441 tolerates for GET/SET_ACCESSCODE and fails on GET_PINCODE exactly as today (parity). This is the hook for i330R/DSX support later (Phase 6 optional; needs new UI strings).

### 4.4 Device session (`DeviceSession`, on `LibDCThread`)

Phases, in order, each emitting events; any failure → `SessionError` thrown on the stream after teardown:

1. **Request validation** on the caller: Bluetooth `.poweredOn` else `bluetoothUnavailable`; `retrieve(id)` else `peripheralNotFound`.
2. **Connect** (§4.2) → `.connected`.
3. **Context**: `dc_context_new`, `dc_context_set_loglevel(DiveComputerLog.libdcLevel)`, `dc_context_set_logfunc(trampoline)` → `onLog` as `"[libdc LEVEL] basename:line (function): message"` mapped to `LogLevel` (ERROR→error, WARNING→warning, INFO→info, DEBUG/ALL→debug).
4. **Descriptor & open** (`DeviceOpener`, spec §4.4): resolve configuration priority **forced > stored > autoDetect(name) > unsupported**. `dc_custom_open`. `dc_device_open(&device, ctx, descriptor, iostream)` retried **5×, 3 s cancellable wait before attempts 2–5**, same link. On failure with a `.stored` selection: run name detection; if detected family == stored family → fail with the open status (retrying the same protocol with a different model cannot help); else retry open with the detected pair (identification fallback, family-only). `dc_device_set_events(DEVINFO|PROGRESS|CLOCK)`, `dc_device_set_cancel(isCancelled)`. Record `libraryName = "\(vendor) \(product)"`.
5. **Events** (callbacks on this thread): `DEVINFO` → `DeviceIdentity(serial: String(format: "%08x", devinfo.serial), hardwareModel: devinfo.model, firmware, family/modelID of the descriptor, libraryName)`; look up `fingerprintsBySerial[serial]` (only when `!fingerprintsBySerial.isEmpty`, i.e. `useFingerprint`); if found and non-empty → `dc_device_set_fingerprint(device, bytes, count)` (device.h:86; wrong size → INVALIDARGS is logged and treated as "no fingerprint", keeping the download full rather than failing — same net behaviour as today's size-mismatch outcome) → emit `.deviceIdentified(identity, watermarkApplied:)`. The bytes live in a Swift `[UInt8]` owned by the session — libdivecomputer copies them (`shearwater_petrel_device_set_fingerprint` memcpy), so no malloc/free pairing exists any more (spec §9 heap-corruption bug class eliminated). `PROGRESS` → `.progress` coalesced to ≥100 ms apart (plus always the last). `CLOCK` ignored.
6. **Enumerate** (`DiveEnumerator`, `dc_device_foreach`; data/fingerprint buffers are backend-owned → copy immediately): callback returns 0 on cancel; DEVINFO-derived family/model used for parsing (priority hardware-detected descriptor > stored > name); Swift-side fingerprint equality stop (`fingerprintMatched = true`, return 0); parse via `DiveParser`; **cutoff**: if `cutoff.stopBefore` applies (always, or only when `watermarkApplied == false` when `onlyWhenNoWatermark`) and `dive.datetime < stopBefore` → `cutoffReached = true`; if `logCount == 1` (newest dive) → `newestFingerprint = this fingerprint`; return 0. Attach `rawData`, `fingerprint`; **watermark** only when `logCount == 1` after a successful parse; emit `.dive`; `logCount += 1`; return 1. Parse error → `.diveSkipped`, return 1.
7. **Outcome** (port of spec §5.3, pure function `DownloadOutcome.decide(status:hasNewDives:fingerprintMatched:cutoffReached:useFingerprint:hadStoredFingerprint:)`, unit-tested):

| status | condition | kind | shouldAdvanceWatermark |
|---|---|---|---|
| SUCCESS | — | `cutoffReached ? .stoppedAtCutoff : (hasNewDives ? .completed : (fingerprintMatched || hadStoredFingerprint ? .noNewDives : .completed))` | `hasNewDives || (cutoffReached && useFingerprint)` |
| PROTOCOL | cutoffReached | `.stoppedAtCutoff` | `hasNewDives || useFingerprint` |
| PROTOCOL | fingerprintMatched | `.noNewDives` | false |
| PROTOCOL | hasNewDives | `.partial` | `useFingerprint` |
| PROTOCOL | hadStoredFingerprint | `.noNewDives` | false |
| PROTOCOL | else | **throw** `.downloadFailed(.protocolError)` | — |
| CANCELLED (or callback stopped by cancel) | — | **throw** `.cancelled` | — |
| other | — | **throw** `.downloadFailed(status)` | — |

   `newestFingerprint` is returned only when `shouldAdvanceWatermark`.
8. **Clock sync** (`ClockSync`) when `syncClock` and (SUCCESS, or PROTOCOL with `fingerprintMatched || cutoffReached`): `dc_datetime_t` from `Calendar(identifier: .gregorian)` + `TimeZone.current` components, `timezone = secondsFromGMT(for: now)` **in seconds**; `dc_device_timesync`; SUCCESS → `.synced`, UNSUPPORTED → `.unsupported` (silent), else `.failed(status)`.
9. **Teardown** (always, also on error/cancel; this ordering is the Shearwater "Sending Dive" fix): (a) `dc_device_close` (sends the protocol exit, e.g. Shearwater `2E 90 20 00`, shearwater_petrel.c:116-129; its read uses the backend's timeout because `firstPacketReceived` is still true); (b) **flush ≤0.5 s**: if a `.withoutResponse` write is outstanding, wait for `peripheralIsReady` or 0.5 s; for `.withResponse` wait for the pending callback or 0.5 s (bounded identically to the spec's blind sleep, but returns early when the radio confirms); (c) `dc_iostream_close`; release the `Unmanaged` link reference; (d) `dc_descriptor_free`, `dc_context_free`; (e) `link.close()` → `cancelPeripheralConnection`, wait ≤2 s for `didDisconnect`; (f) finish the stream (`.finished(outcome)` then `finish()`, or `finish(throwing:)`). The thread exits; `cancel()` awaits the join, so by the time the app sees the stream end **no C pointer is alive** — the sheet-dismiss blocking during `.connecting/.downloading` (BSV:155-162) becomes unnecessary.
10. **Cancellation**: `handle.cancel()` sets the flag, `link.cancel()` wakes every wait; `dc_device_set_cancel` makes retrying backends abort between transactions (device.c `device_is_cancelled` is polled by oceanic_atom2, mares_iconhd, suunto_eonsteel, hw_ostc3; Shearwater/Pelagic/Cressi are stopped by the dive callback returning 0 and by the link failing their next read). Outcome `.cancelled`.

Threading guarantee (documented in README): libdivecomputer objects are touched only on `LibDCThread`; `BLEPeripheralLink` methods may be called from the libdc thread and `bleQueue` only; `DiveComputerManager` only on `MainActor`.

### 4.5 Parser (`DiveParser` + `SampleAccumulator`)

`parse(family:modelID:data:diveNumber:)`: descriptor by (family, modelID); `dc_parser_new2(&parser, ctx, descriptor, bytes, count)` (parser.h:297 — copies data) with a parser-only `dc_context` whose log function routes to `DiveComputerLog` (improvement over the old NULL context; no output change); failure → `parserCreationFailed`. `dc_parser_get_datetime` failure → `datetimeRetrievalFailed`. Setpoint mode `ShearwaterFormat.reportsSetpointEverySample(family)` true for SHEARWATER_PREDATOR/PETREL, DIVESYSTEM_IDIVE, MCLEAN_EXTREME, TECDIVING; for change-only families pre-read `GASMIX_COUNT`/`GASMIX[i]` and collect `diluent`/`oxygen` index sets, stored only if ≥1 diluent. `dc_parser_samples_foreach` with the accumulator; failure → `sampleProcessingFailed`; **post-loop flush**. Fields exactly as spec §6 step 5 (GASMIX, TANK, DECOMODEL with GF only for Bühlmann else non-nil 0, DIVEMODE default `.openCircuit`, SALINITY `density>0 ? density/1000 : (salt ? 1.025 : 1.000)`, ATMOSPHERIC finite and in `0.4...1.2` else nil, TEMPERATURE_MIN/MAX override, TEMPERATURE_SURFACE sets both surface values, DIVETIME `>0 && <= 48*3600`, PNF test `family == shearwaterPetrel && size >= 2 && !(b0 == 0xFF && b1 == 0xFF)`, AVGDEPTH finite>0 else trapezoidal average cut at `reportedDivetime` only for PNF with interpolation and only if strictly inside the profile, MAXDEPTH accepted when `(family != shearwater || isPNF) && finite && > 0` else deepest sample). Date: Gregorian components in `TimeZone.current`, `dc_datetime_t.timezone` ignored; nil → `invalidDate`.

**`SampleAccumulator`** — pure Swift state machine (testable without C via a `SampleInput` enum mirrored from `dc_sample_type_t`/`dc_sample_value_t`, parser.h:35-51, 251-287):

| Input | Effect (carry-forward unless stated) |
|---|---|
| `time(ms)` | if `hasSeenTime` → flush previous interval first; `hasSeenTime = true`; `time = ms/1000` |
| `depth(m)` | `depth`; `maxDepth = max` |
| `pressure(tank, bar)` | append to cumulative `pressures`; `currentPressures[tank] = bar` (reset on flush) |
| `temperature(°C)` | `temperature` |
| `event(type)` | map ASCENT/VIOLATION/DECOSTOP/GASCHANGE/BOOKMARK/SAFETYSTOP(false)/SAFETYSTOP_MANDATORY(true)/CEILING/PO2/DEEPSTOP; others → none; **always** append a synthetic point at `time` with the (possibly empty) events and current state; PPO2 accumulators untouched; flags/value ignored |
| `rbt`, `heartbeat`, `bearing` | set |
| `setpoint(bar)` | `setpoint` (dive-level) always; `currentSetpoint` only if `!onOpenCircuit` |
| `ppo2(sensor, bar)` | `sensor == 0xFFFFFFFF` → `currentVotedPPO2`; else `currentPPO2[sensor]`, append to cumulative `ppo2Readings` |
| `cns(fraction)` | `cns = value × 100` |
| `deco(type, depth, time, tts)` | `deco` |
| `location(lat, lon, alt)` | first → `location`; later → `exitLocation` (last wins) |
| `gasmix(index)` | if diluent sets non-empty and `index != 0xFFFFFFFF`: diluent → `onOpenCircuit=false; currentSetpoint=setpoint`; non-oxygen non-diluent → `onOpenCircuit=true; currentSetpoint=nil`; oxygen → unchanged. Then if `index != UNKNOWN`, previous gas exists and differs → unless last point is at the same time and already carries `.gasChange`, append synthetic `[.gasChange]` point with `currentGas = index`. Update previous-gas tracker only for real indices |
| `vendor`, unknown | ignored |

Flush: build `ProfileSample(time, depth, temperature, pressure = last cumulative pressure of any tank, pressures = currentPressures, po2 = voted, sensorPPO2 = currentPPO2, pn2/phe = nil, events, ndl = deco.time if type == NDL, decoStop/decoTime = deco.depth/time if DECOSTOP, tts = deco.tts, currentGas, cns, rbt, heartbeat, bearing, setpoint = currentSetpoint)`; append; reset `currentPressures`, `currentPPO2`, `currentVotedPPO2`, and `currentSetpoint` if `setpointPerSample`; `maxTime = max`; temperature → `tempMin/tempMax/lastTemperature`, `tempSurface` set on first. Sentinels: `+∞/−∞` (0 °C is valid). Assembly: `divetime = maxTime`, `temperature = min(profile/field)` (may be `+∞`), `tankPressure` flat list, `gasMix` last real index, `gasMixes` nil if empty, surface/min/max nil when not finite, `setpoint` last, `ppo2Readings` physical only, `cns` last, `decoStop` last deco sample (any type).

### 4.6 Models

Kept identical in names, units and optionality to spec §7 so the mapper's logic (PP:656-921, IMP:796-955) ports by find/replace: `DiveData { number: Int (var), datetime: Date, maxDepth, avgDepth: Double (m), divetime: TimeInterval (s, last sample), reportedDivetime: TimeInterval? (s), temperature: Double (°C, min, may be +∞ — kept in V1 for byte-identical goldens; see §11), profile: [ProfileSample], tankPressure: [Double] (bar), gasMix: Int?, gasMixCount: Int?, gasMixes: [GasMix]?, salinity: Double? (g/cm³), atmospheric: Double? (bar), surfaceTemperature: Double?, measuredSurfaceTemperature: Double?, minTemperature, maxTemperature: Double?, tankCount: Int?, tanks: [Tank]?, diveMode: DiveMode?, decoModel: DecoModel?, location, exitLocation: Location?, rbt, heartbeat, bearing: UInt32?, setpoint: Double?, ppo2Readings: [PPO2Reading] (sensor: UInt32, value: Double), cns: Double?, decoStop: DecoStop?, rawData: Data?, fingerprint: Data? }` — `Sendable`, `Codable` (for goldens), memberwise `public init` with defaults for every optional (so `DiveDurationTests.swift:272-279` shrinks to the five fields it cares about). `ProfileSample` = spec's `DiveProfilePoint` fields. `SampleEvent` = the 9 cases (no `color/icon/description`: the app has `DiveProfileEvent` at Dive.swift:7-37). `GasMix { helium, oxygen, nitrogen: Double; usage: GasUsage }`, `Tank { volume, workingPressure, beginPressure, endPressure: Double; gasMix: Int; usage: GasUsage }`, `GasUsage { none, oxygen, diluent, sidemount }`, `DecoStop { depth: Double; time: TimeInterval; type: Int (raw dc_deco_type_t: 0 NDL, 1 safety, 2 deco, 3 deep) }` (the mapper tests `type == 2`, PP:745, 913-919), `Location { latitude, longitude: Double; altitude: Double? }`, `DiveMode` 5 cases, `DecoModel { type: DecoType; conservatism: Int; gfLow, gfHigh: UInt32?; description }` with the same description strings ("Bühlmann GF L/H", "Bühlmann", "None", "<Type> (<conservatism>)"/"<Type>") — persisted in `Dive.decompressionAlgorithm` (PP:736, IMP:894), so byte-identical. Dropped as unused by the app: `TankInfo`, top-level `DecoModel`/`Location` duplicates, `SampleData` public type, `DiveDataViewModel`, `DownloadProgress`, `StoredDevice` (moves to the app), `DeviceFingerprint` struct, `Notification.Name.deviceForgotten`.

### 4.7 Diagnostics

`DiveComputerLog` (lock-protected; called from bleQueue and the libdc thread): `log(_:level:file:function:)` prints `"<prefix> [HH:mm:ss.SSS] [<file>] <message>"` to `os.Logger(subsystem: "app.bluedive.DiveComputerKit", category:)` and invokes `onLog(LogEvent)`; `logPacket(direction:data:uuid:)` counts always, calls `onPacket` only when `showRawData`; `enableDebugMode()`: `minimumLevel = .debug`, `showRawData = true`, libdc level `DC_LOGLEVEL_ALL` (applied to contexts created afterwards — call before connecting, as today), logs the info line; `disableDebugMode()`: WARNING / `.warning` / raw off; `isDebugMode` = libdc level == ALL. `PacketEvent.hexDump`: uppercase hex, space-separated, 16 bytes per line — `BLEDiagnosticSession.swift:164-177` writes `event.level.prefix`, `event.category`, `event.direction.rawValue.uppercased()`, `event.characteristicUUID`, `event.data.count`, `event.hexDump`; all preserved so existing trace files remain comparable. libdivecomputer context messages arrive as `[libdc LEVEL] file:line (function): message` lines with category `"libdivecomputer"`.

---

## 5. Persistence & migration

- **`KnownDeviceStore`** (app, `BlueDive/Bluetooth/KnownDeviceStore.swift`): `struct KnownDevice: Codable { uuid: String; name: String; family: DeviceFamily (String raw); model: UInt32; lastConnected: Date; serial: String? }` — same keys, same `JSONEncoder()` defaults, same UserDefaults key `"com.libdc.storedDevices"`. Methods mirror the ones the app calls today (IMP:305-330 seed, BLE:545-558 commit, BLE:713-726 prune, IMP:726-753 delete, BLE:588-598 restore). `removeDevice` no longer clears fingerprints or posts `deviceForgotten` (the app already does its own SwiftData deletion in `deleteKnownDevice`, IMP:690-770). **No migration.** The store is written only by the app, never mid-download by the library: the hardware serial is written by the app when `.deviceIdentified` arrives (replacing the library's `updateDeviceSerial`, spec §5.1), and the hardware-model correction (spec §4.7) is applied **only when `DeviceCatalog.model(family, hardwareModel)` exists** (keeps the useful Oceanic/Pelagic case, drops the namespace-mismatch garbage the spec flags as fragile).
- **Fingerprint source of truth = SwiftData `DeviceFingerprint`**, read before the session (`fingerprintsBySerial = Dictionary(records.map { ($0.serial.normalizedComputerSerial() ?? $0.serial.lowercased(), $0.fingerprintData) }.filter { !$0.1.isEmpty })`, empty when "Download all dives") and written after (`DownloadOutcome.newestFingerprint` when `shouldAdvanceWatermark`, via the existing `persistFingerprintRecord` rules IMP:607-685 minus the UserDefaults read at IMP:635). The whole mirror (IMP:332-496) and the sweeps are deleted. UserDefaults key `"BlueDive"` (and the legacy `"DeviceFingerprints"`) are no longer read; Phase 6 adds a one-time `removeObject(forKey:)` for both at launch (harmless if absent).
- **SwiftData/CloudKit: no model change.** `DeviceFingerprint` keeps `serial`, `computerName`, `fingerprintData`, `familyID`, `modelID`, `updatedAt`; `Dive.computerName/computerSerialNumber/fingerprintData/rawDiveComputerData` unchanged (Dive.swift:341-342, 483, 489). The only edit in `Models/DeviceFingerprint.swift` is the type of the computed `family` (line 35) and the import on line 3 — a computed property is not a stored attribute, so no CloudKit schema step. **Flag:** if during implementation anyone proposes storing `hardwareModel` or `peripheralID` on `DeviceFingerprint`, that is a model change requiring explicit owner instruction (CLAUDE.md) and the CloudKit schema procedure.
- Fingerprint XML (`FingerprintXMLExporter.swift:49-52`, `FingerprintXMLParser.swift:125-148`) writes/reads `familyID`/`modelID`/`computerName` strings — unaffected because raw values and names are identical.

---

## 6. App integration

Per file:

| File | Change |
|---|---|
| `BlueDive.xcodeproj/project.pbxproj` | Remove `XCRemoteSwiftPackageReference "libdc-swift"` (803-811) and product ref (15, 126, 243, 819-823); add `XCLocalSwiftPackageReference "Packages/DiveComputerKit"` and link product `DiveComputerKit` to the app target. Tests keep `@testable import BlueDive` + `import DiveComputerKit` (transitively available as today). |
| `BluetoothScannerView.swift` | `import DiveComputerKit`; drop `Combine`; `@ObservedObject bleManager` → `@State private var sync = BluetoothSyncController()` (or `DiveComputerManager.shared`); `selectedDevice: CBPeripheral?` → `selectedDeviceID: UUID?` + `selectedDeviceName`; `downloadProgressCancellable` removed; `onReceive(bleManager.$discoveredPeripherals)` → `.onChange(of: manager.discoveredDevices)`; `onDisappear` → `Task { await sync.cancel() }`; `isTeardownUnsafe` reduced to `.importing` only (new behaviour: a download can be cancelled — see localisation); `CachedDeviceFingerprint.family` / `ReassociationCandidate.family` type → `DeviceFamily`. |
| `BluetoothScannerView+BLE.swift` | `connectToDevice` becomes `sync.start(request)` + an event loop (`for try await event`) mapping `.connecting` → `.connecting(deviceName:)`, `.progress` → `.downloading(current:total:)`, `.dive` → `diveCountDuringDownload += 1`, `.deviceIdentified` → `KnownDeviceStore` serial/model update + `pendingDeviceStorageSeed` commit check, `.finished` → the two existing success branches (BLE:426-499, using `outcome.kind`, `outcome.cutoffReached`, `outcome.newestFingerprint`), thrown `SessionError` → the failure branch (BLE:500-525) with localised messages. Delete the `openedDeviceDataPtr` poll (272-306), `isRetrievingLogs/currentRetrievalDevice/clearRetrievalState` lines, `DeviceFingerprintStorage.clearFingerprint` (359). Everything about seeds/reassociation/prune stays, re-pointed at `KnownDeviceStore`. |
| `BluetoothScannerView+Import.swift` | `DeviceStorage` → `KnownDeviceStore`. Delete `syncFingerprintFromDatabase` (365-496) and replace with `fingerprintTable(excluding downloadAll:)` returning `[String: Data]` plus `isIncremental` decided from `.deviceIdentified(watermarkApplied:)`; the cutoff becomes `Cutoff.stopBefore(date, onlyWhenNoWatermark: true)` so the library applies it exactly when the download is full-history (the BLE:382-385 pre-connect guess disappears). `persistFingerprintRecord` takes `(identity, fingerprint: Data)` instead of reading UserDefaults (635). `deleteKnownDevice`: drop the `DeviceFingerprintStorage` calls (713-719). `mergeComputerData` moves to `DiveImportMapper`. |
| `BluetoothScannerView+ProfileProcessing.swift` | Becomes `DiveImportMapper.swift`: an `enum DiveImportMapper` (nonisolated, pure) holding `consolidateProfilePoints`, `remapProfileCurrentGas`, `applyGasSwitchUsageTimes`, `buildTanksFromComputerTanks`, `resolveGasMix`, `inferShearwaterGasMixToTank`, `orderedGasMixIndices`, `usedGasMixIndices`, `pressureRangeFromProfile`, `resolvedPressure`, `extractDecoStops`, `applyDuration`, `convertDiveEvent`, plus `makeDive(from: DiveData, context: ImportContext) -> Dive` and `merge(_:into:context:)` where `ImportContext { computerName, serial, family, diveNumber, previousDiveEndTime, diverName, filterUnusedTanks, weightUnitSymbol }` replaces the view-state reads (`selectedDevice`, `connectedDeviceName`, `connectedDeviceFamily`, `filterUnusedTanks`, PP:683-693, 798-812, 836). Type renames: `LibDCSwift.DiveProfilePoint` → `ProfileSample`; `LibDCSwift.DiveEvent` → `SampleEvent`; `.usage` comparisons → `GasUsage`. Logic unchanged (golden Dive-level tests, §7). |
| `BluetoothScannerView+Views.swift` | `bleManager.discoveredPeripherals` (272-309) → `manager.discoveredDevices` (`DiscoveredDevice`, `id: \.id`); row init takes `DiscoveredDevice`; `DeviceConfiguration.getDeviceDisplayName` (398) → `DeviceCatalog.displayName`; toolbar close (662) → `Task { await sync.cancel(); dismiss() }`; `isConnecting(to:)` (914) compares `UUID`s; add a **Cancel** button in the downloading state. |
| `BluetoothScannerComponents.swift` | `DeviceConfiguration.supportedModels/ComputerModel/getDeviceDisplayName` → `DeviceCatalog`; `DeviceStorage`/`StoredDevice` → `KnownDeviceStore`/`KnownDevice`; rows take `DiscoveredDevice` instead of `CBPeripheral`. |
| `BLEDiagnosticSession.swift` | `import DiveComputerKit`; `Logger.shared` → `DiveComputerLog.shared` (lines 164-209); file format unchanged. |
| `Models/DeviceFingerprint.swift` | `import DiveComputerKit`; `DeviceConfiguration.DeviceFamily` → `DeviceFamily` (lines 3, 24, 35-41). Not a stored-attribute change. |
| `App/BlueDiveApp.swift` | Remove dead `import LibDCSwift` (7) and the commented `LibDCSwift.Logger` line (151). |
| `Dive List/ContentView.swift` | Remove dead `import LibDCSwift` (6). |
| `BlueDiveTests/DiveDurationTests.swift` | `import DiveComputerKit`; `DiveData(...)` memberwise call (272-279) → `DiveData(number: 1, datetime:, maxDepth: 11.4, avgDepth: 7.7, divetime:, reportedDivetime:, temperature: 19)`; `BluetoothScannerView.applyDuration` → `DiveImportMapper.applyDuration`. |
| `BluetoothSettingsView.swift`, `FingerprintDebugView.swift`, Fingerprint XML | No change (they do not import LibDCSwift). |
| `LICENSE`, `README.md:57-58`, `CONTRIBUTING.md:64,99-105` | Replace libdc-swift references with DiveComputerKit (BDSAL) + libdivecomputer (LGPL, vendored at `Packages/DiveComputerKit/Sources/CLibDiveComputer`). |

**Combine removal:** the two Combine uses (`onReceive(bleManager.$discoveredPeripherals)`, `viewModel.$progress.sink`) are replaced by `@Observable` + the event stream; `import Combine` is removed from `BluetoothScannerView.swift` and `+BLE.swift`.

**Localisation impact** (all via the xcstrings workflow — build, `Scripts/xcstrings.py missing`, `set-json`, `check`; never edit the catalog by hand): new user-facing strings: `"Cancel download"` (button), `"Download cancelled"` (state), and a `switch SessionError` with one `NSLocalizedString(..., value:)` per case replacing the library's hard-coded English (`"Device took too long to respond. Try again"`, `"Connection lost. Please ensure: …"`, `"Device communication error. Try turning device off and on"`, `"This operation is not supported by your device"`, `"Received invalid data from device"`, `"Access to device was denied"`, `"Device not found or disconnected"`, `"Unknown error occurred (Code: %lld)"`), plus `"Pairing code"` prompt strings only if the Pelagic authorization UI ships. Existing keys (`"Unable to connect to %@"`, `"Download failed: %@"`, `"Failed to download dives"`, `"Connection established but device not ready"`) are kept or retired as the flow dictates. Translations in fr-CA, de, nl, nb, es in the same commit.

**macOS:** same code; `CBCentralManager` on a private queue works identically; `HAVE_IOKIT_SERIAL_IOSS_H` only for macOS; build **My Mac** and an iOS destination for every phase (CLAUDE.md); the Cancel button needs `.borderlessButton()`/explicit style; the diagnostics file export path (`NSSavePanel`, Views:640-654) is untouched.

---

## 7. Testing strategy

**Golden-file parity harness (Phase 0, before any new code):**
1. Export raw dives from the owner's logbook: a throwaway `Scripts/golden_export.py` (read-only, run with `python3 -I` against a *copy* of `default.store` taken from a Format-2 backup zip, CLAUDE.md "Database Backup Format") selects `ZDIVE` rows with non-null `ZRAWDIVECOMPUTERDATA`, resolves external-storage references under `.default_SUPPORT/_EXTERNAL_DATA/`, and writes `golden-input.json`: `[{computerName, computerSerialNumber, timestamp, rawData(b64), fingerprint(b64)}]`. `computerName` → `(family, modelID)` through the catalog (names sharing a model ID share a parser, so the ambiguity is harmless).
2. Throwaway package **outside the repo** (`~/Xcode/libdc-golden-harness`, macOS executable) depending on the OLD remote `libdc-swift` (branch `working`); for each input calls the old `GenericParser.parseDiveData` and writes `golden/<serial>-<unix ts>.json` in canonical form: keys sorted, `Double` as `%.17g`, non-finite as `"inf"/"-inf"/"nan"`, `Date` as `timeIntervalSince1970` string, `Data` base64, `[Int: Double]` as sorted `[[k, v]]`, tuples as objects. The harness is a black-box consumer of the old library (permitted under the clean-room rule). Run with `TZ` pinned (e.g. `TZ=America/Toronto`) because datetime conversion uses the local zone; the new tests set the same `TZ`.
3. `GoldenParityTests` (new package): parse each input with `DiveParser`, encode `DiveData` with the same canonical encoder, compare **byte-equal, zero tolerance**. Goldens are the owner's personal data: store under `Tests/Fixtures/golden/` only with owner approval (Q3), otherwise read from `DCK_GOLDEN_DIR`.
4. Also a Dive-level golden: a DEBUG-only app test maps each `DiveData` golden through `DiveImportMapper.makeDive` and compares a canonical dump of the resulting `Dive` fields before and after the extraction (guards the mapper refactor).

**Unit tests (Swift Testing, package):** `SampleAccumulatorTests` (scripted `SampleInput` sequences: deferred flush, post-loop flush, event synthetic points, gas-change dedup, bailout/diluent restore, voted vs sensor PPO2, first/last location, infinity sentinels, pressure carry-forward); `FieldValidationTests` (atmospheric range, divetime bounds, PNF detection, avg-depth cut interpolation, salinity density); `CatalogConsistencyTests` (§4.1); `NameResolutionTests` (table of names → expected (family, modelID) including "FH12345"→i300C, "6_1A2B"→Raffaello, "Mares bluelink pro"→Smart, "Tablet123"→Seac, "Perdix 2"→Perdix 2, "Peregrine"→Peregrine not TX, "G2 HUD"→0x42, "DS123"→Ratio); `OutcomeDecisionTests` (every row of §4.4 table); `CutoffTests`; `ClockSyncTests` (timezone in seconds, DST).

**Transport tests with a fake peripheral:** `FakePeripheral` implements a small protocol the link uses (`PeripheralProtocol`: services/characteristics/write/read/setNotify/state) so `BLEPeripheralLink` can be driven without CoreBluetooth: `CharacteristicSelectionTests` (Cressi dual service → vendor; Pelagic nonce+data notify → two-pass picks the right one; GATT 0x1801 ignored; Mares data/control); `PacketQueueTests` (boundaries, partial stash, first-read floor, poll mode, timeout vs IO on disconnect, ioctl route isolation); `WriteSemanticsTests` (back-pressure 500 ms then write anyway; per-callback 5 s deadline; stale callbacks). `IOStreamCallbackTests` call the `@convention(c)` trampolines directly through `dc_custom_open` + `dc_iostream_read/write/ioctl` with a `ScriptedLink`. `TraceReplayTests`: parse existing `BlueDive_BLE_*.log` files (inbound/outbound blocks with hex dumps) into a script; the `ScriptedLink` replays inbound packets when the matching outbound is written and runs a full `DeviceSession` (open → foreach → close) against real libdivecomputer backends with no radio — this validates read/write/ioctl semantics for every family the owner has a trace for (i300C handshake incl. GET_NAME, Shearwater SLIP, Cressi CHARACTERISTIC_READ). Traces committed only with approval (Q3).

**Device matrix (manual, Phase 5 exit):** per family one unit, each checked for: connect time, full download, incremental (fingerprint) download → "No new dives", cutoff download, cancel mid-download then reconnect, clock sync result, Shearwater returns to its menu (no "Sending Dive"), i300C BT auto-off handled, diagnostics trace produced: Shearwater (Peregrine, Perdix/Petrel 2, Perdix 3 if available), Aqualung i300C (Oceanic Atom2), Cressi (Raffaello/Goa), Mares (Puck Pro/Sirius), Suunto EON Core/D5, Scubapro G2, OSTC, Ratio, Divesoft, Seac Tablet, Halcyon Symbios — the last six as available. Compare the new trace against the old library's trace for the same device: identical outbound packet sequence after the handshake (ordering/timing may differ).

---

## 8. Phased plan

| Phase | Work | Exit criteria | Effort |
|---|---|---|---|
| 0a Golden capture | `golden_export.py`; harness package linking the old library; produce goldens for every raw dive in the logbook; Dive-level dump of the current mapper | Goldens committed/stored; harness archived | 1–2 d |
| 0b Trace capture | Enable BLE Diagnostic Logging; one full + one incremental sync per available device with the OLD app; archive traces | ≥1 trace per family owned | 0.5 d + device time |
| 1 Package & C build | `Packages/DiveComputerKit`, vendored libdivecomputer (SHA 9e6c3c8), shim, manifest, `version.h`; app project switched to the local package (nothing imports it yet, old package still linked? **No** — duplicate `dc_*` symbols; keep the old package until Phase 5, build the new package standalone with `swift build`/`xcodebuild` on both platforms) | Package builds for iOS + My Mac with zero errors; warning count recorded | 1–2 d |
| 2 Catalog | DeviceFamily, ComputerModel, DeviceCatalog, BLEServiceCatalog, BLENameResolver, DescriptorLookup + tests | `CatalogConsistencyTests`, `NameResolutionTests` green | 1 d |
| 3 Parser & models | Models, SampleAccumulator, FieldReader, DiveParser + golden parity | **100 % byte-identical goldens**; accumulator/field tests green | 3–4 d |
| 4 Transport, iostream, session | BLECentral, BLEPeripheralLink, DCIOStream/DCIOControl, DeviceSession and friends, DiveComputerLog, DiveComputerManager + fake-peripheral tests + trace replay | Transport tests green; `TraceReplayTests` complete a session for every captured trace; first real-device smoke test from a scratch app or the package's example | 5–7 d |
| 5 App cutover | Remove libdc-swift, link DiveComputerKit, per-file changes (§6), `KnownDeviceStore`, `DiveImportMapper`, `BluetoothSyncController`, localisation, Dive-level golden check | Both platforms build; `DiveDurationTests` + Dive-level goldens green; device matrix passed; a sync with the old app's known device list and fingerprints is incremental on first run (no re-download) | 4–6 d |
| 6 Cleanup & docs | Delete `"BlueDive"`/`"DeviceFingerprints"` UserDefaults keys; update LICENSE/README/CONTRIBUTING/`DIVE_COMPUTER_ICONS.md`; CLAUDE.md note on the threading contract and the sync procedure; optional: `temperature` → Optional, Pelagic PIN UI | Docs merged; `xcstrings.py check` clean | 2–3 d |

Rollback: until Phase 5 merges, the old remote package is untouched; Phase 5 is one commit/branch — rollback is `git revert` of that merge (no persisted format changes, so data written by the new code is readable by the old code and vice versa; the only one-way step is the Phase 6 key deletion, which only forces one full re-download per device on rollback).

---

## 9. Risk register & open questions

| Risk | Impact | Mitigation |
|---|---|---|
| A device-timing behaviour not captured by the spec (e.g. a backend sensitive to read latency) | Field failures on one family | Trace replay + device matrix before cutover; `BLETiming` constants identical; keep diagnostics on during beta |
| Swift 6 strict concurrency friction with CoreBluetooth (non-Sendable `CBPeripheral`) | Build churn | `CBPeripheral` confined to `BLECentral`/`BLEPeripheralLink` (`@unchecked Sendable` with a documented lock discipline); all public types Sendable |
| `@convention(c)` callbacks capturing context | Crashes | Only `Unmanaged.passUnretained(link)`; lifetime strictly bracketed by `dc_custom_open … dc_iostream_close`; asserts in DEBUG |
| Fingerprint size mismatch (`dc_device_set_fingerprint` INVALIDARGS) | Silent full download | Log at warning + emit `watermarkApplied: false`; the app shows "Downloading all dives" |
| Data-compat regression (names, raw values, serial format, deco description) | Dedup/reassociation/icon breakage | Catalog tests, golden byte-equality, Dive-level golden, `DeviceFamily` raw-value test pinned to the 16 strings |
| Dropping auto-reconnect changes UX for flaky links | More "Retry" taps | Explicit error + Retry; collect feedback; can add *app-level* retry later without library changes |
| LGPL static linking | Legal exposure | Q1; dynamic fallback is a one-line change; publish unmodified sources + notice |
| Upstream sync adds a descriptor/filter the catalog lacks | Device invisible in scan | `CatalogConsistencyTests` fail on sync → §10 checklist |
| `-Wno-shorten-64-to-32` via `unsafeFlags` | Breaks if the package is ever consumed remotely | Local package only; documented |
| Pelagic i330R/DSX still unsupported (parity) | Same as today | Hook designed; UI later |

Open questions for the owner: **Q1** static vs dynamic linking of the LGPL target (recommendation: static + LICENSE clarification). **Q2** Allow cancelling a download (new UX + strings)? Recommended yes. **Q3** May goldens/traces (personal dive data) be committed to the repo, or kept in a private fixture directory? **Q4** Keep the non-BLE legacy catalog entries (Atom 3.1, Wisdom 3, Icon HD) visible in the model picker? **Q5** Ship the Pelagic PIN prompt in this cycle? **Q6** Branch/PR structure: one long-lived `feature/divecomputerkit` branch with the phases as PRs, or phases 1–4 in a separate repo? (Recommend in-repo branch; nothing links until Phase 5.)

---

## 10. libdivecomputer manual-sync procedure

`Scripts/sync_libdivecomputer.sh <upstream-sha>` (to be written; steps are also the manual checklist):
1. `git clone --depth 50 https://github.com/libdivecomputer/libdivecomputer /tmp/ldc && git -C /tmp/ldc checkout <sha>`.
2. `rsync -a --delete --exclude 'Makefile.am' --exclude 'serial_win32.c' --exclude 'libdivecomputer.symbols' --exclude 'libdivecomputer.rc' /tmp/ldc/src/ Packages/DiveComputerKit/Sources/CLibDiveComputer/src/` and likewise `include/libdivecomputer/` (keeping our `version.h`, excluding `version.h.in`, `Makefile.am`).
3. Regenerate `version.h`: read `AC_INIT([libdivecomputer],[X.Y.Z…])` from `configure.ac`, fill the `version.h.in` template (`@DC_VERSION@`, `@DC_VERSION_MAJOR@`…).
4. Update `UPSTREAM.md` (SHA, date, version) and `COPYING` if changed.
5. `git diff --stat` the C tree; grep new `dc_filter_*` / descriptor rows / `DC_IOCTL_*` / `dc_sample_type_t` / `dc_field_type_t` members (new enum members = parser work).
6. `swift build` (iOS + macOS via xcodebuild) and `swift test`: `CatalogConsistencyTests` lists missing catalog rows → add to `DeviceCatalog`, `BLEServiceCatalog` (new service UUID from the vendor filter), `BLENameResolver` prefix table, and a device icon per `DIVE_COMPUTER_ICONS.md`; re-run golden parity (parser changes upstream are expected to change goldens — review and re-bless deliberately).
7. Device smoke test on at least one unit; commit with `chore: sync libdivecomputer to <sha>`.

---

## 11. Parity checklist (spec §3–6, §10) and recommended changes

| Spec behaviour / constant | New location | Keep / Change |
|---|---|---|
| §3.1 ObjC protocol, `NSClassFromString`, `+shared` | — | **Drop** (no ObjC bridge; Swift calls C directly) |
| §3.2 custom vtable, close must not free | `DCIOStream` via `dc_custom_open`; `close` callback no-op | Keep semantics |
| §3.3 read nil/empty → TIMEOUT if connected else IO; write 0/1/2 mapping; set_timeout; sleep; close | `DCIOStream` | Keep |
| §3.4 CHARACTERISTIC_READ (16-byte UUID, want, 5 s default, IO on short), GET_NAME (UNSUPPORTED/NOMEMORY) | `DCIOControl` | Keep; **add** PIN/ACCESSCODE hook (default UNSUPPORTED = parity) |
| §3.5 connect: 100 ms/5 s wait for `.disconnected`; 30 s ready wait; discover; notify | `BLEPeripheralLink.connect`, `BLETiming` | Keep; **change**: `didFailToConnect` fails fast |
| §3.5 `didConnect` ignored while disconnecting; flags set synchronously on main | — | **Drop** (no auto-reconnect; single lock-protected state) |
| §3.6 scan with known UUIDs or nil; named peripherals only; filter known-or-resolvable; 14 service UUIDs; 3 excluded | `BLECentral`, `BLEServiceCatalog`, `discoveryFilter` injected by the app | Keep |
| §3.7 reset on `didDiscoverServices`; vendor over Nordic; discover chars for all non-excluded; ignore non-preferred; two-pass selection; no `setNotifyValue` there; 50 ms/5 s discovery wait; 30 s notify wait; fast-fail on disconnect | `BLECharacteristicSelector`, `BLEPeripheralLink` | Keep (condition waits instead of polling) |
| §3.8 writeWithoutResponse 500 ms soft wait then write; withResponse fresh 5 s per callback; results 0/1/2 | `BLEPeripheralLink.write` | Keep |
| §3.9 one notification = one packet; partial stash; ioctl routing without signalling; −1→3 s, 0→poll, first-read 5 s floor; 20 ms char-read poll | `BLEPacketQueue`, `BLEPeripheralLink` | Keep semantics; polling → condition waits |
| §3.10 close ordering; 0.5 s flush after device close; re-entrancy guard; `isDisconnecting` 0.5 s; auto-reconnect 500 ms on global queue | `DeviceSession.teardown`, `BLEPeripheralLink.close` | Keep ordering + bounded 0.5 s flush; **drop** auto-reconnect and its guards |
| §3.11 main-queue delegates; serial queue; NSLock on pointer; `Thread.sleep` polling; `setBackgroundMode`/`queueOperation` | private bleQueue; `NSCondition`; thread join | **Change** (private queue); `setBackgroundMode` dropped (app never called it); `queueOperation` replaced by `bluetoothState` |
| §4.1 DeviceFamily raw values & dc_family mapping | `DeviceFamily` | Keep byte-identical |
| §4.2 supportedModels (names, IDs) incl. shared IDs | `DeviceCatalog` | Keep byte-identical |
| §4.3 resolution order 1–4; prefix table; C pattern table (substring for EXACT/CONTAINS); `dc_descriptor_filter` fallback; display name rule | `BLENameResolver`, `DescriptorLookup` | Keep |
| §4.4 forced > stored > auto; `connectionLock`; 5×3 s open retries; family-only fallback skip; events DEVINFO/PROGRESS/CLOCK; `"<vendor> <product>"`; free on all failure paths | `DeviceOpener`; one session at a time enforced by `DiveComputerManager` | Keep |
| §4.4 persist configuration to StoredDevice on open success | app (`KnownDeviceStore`) on `.connected`/`.deviceIdentified` | Keep (moved to app) |
| §4.6 DEVINFO `%08x` serial, fingerprint lookup, malloc'd buffer | `DeviceSession` DEVINFO handler, `fingerprintsBySerial` | Keep serial format; **change** lookup source (SwiftData table) and remove malloc contract |
| §4.7 `fetchDeviceInfo` (foreach returning 0) | — | **Drop** (unused by app) |
| §4.7 hardware model written to StoredDevice | app, only when the hardware model is a valid descriptor ID for the family | **Change** (guarded) |
| §4.8 `com.libdc.storedDevices` JSON, operations, `deviceForgotten` | `KnownDeviceStore` | Keep format; drop notification (unused) |
| §4.9 shared parser context | per-parse context with log routing | Change (no output difference) |
| §4.10 global libdc log level applied at context creation; debug-gated bridge prints | `DiveComputerLog`, `DCContext` | Keep |
| §5 retrieval queue; reset progress; device type for fingerprint key; 250 ms progress timer; `useFingerprint` toggles lookup; status-name logging | `DeviceSession` (events replace the timer; coalesced ≥100 ms) | Keep effect |
| §5.1 callback: cancel via flag; DEVINFO capture once; `updateDeviceSerial`; Swift-side fingerprint stop; family/model priority; parse; cutoff (`logCount == 1` watermark); rawData/fingerprint attached; watermark after successful parse; parse error → continue | `DiveEnumerator` | Keep; serial update moves to the app on `.deviceIdentified` |
| §5.2 lookup returns nil/size 0 when absent | `fingerprintsBySerial` miss → no `set_fingerprint` | Keep |
| §5.3 outcome table | `DownloadOutcome.decide` | Keep exactly |
| §5.4 clock sync (timezone seconds; UNSUPPORTED silent) | `ClockSync` | Keep |
| §5.5 `"BlueDive"` UserDefaults fingerprint store; (type, serial) matching; legacy `"DeviceFingerprints"` | — | **Drop** (SwiftData is the source of truth; keys removed in Phase 6) |
| §6 parser steps 1–7, §6.1 accumulator, flush, point composition, per-family quirks | `DiveParser`, `SampleAccumulator`, `FieldReader`, `ShearwaterFormat`, `AverageDepth` | Keep exactly (golden-verified) |
| §7 models (names, units, nil/0/∞ conventions, `DecoModel.description`) | `Models/` | Keep; `DiveProfilePoint`→`ProfileSample`, `DiveEvent`→`SampleEvent`, `dc_usage_t`→`GasUsage`, tuple→`PPO2Reading`; unused types dropped; Color/icon dropped |
| §8 Logger prefixes, `onLog/onPacket`, hexDump format, `[libdc LEVEL] file:line (function): message` | `DiveComputerLog` | Keep (renamed type) |
| §10 items 1–42 (BlueDive customizations) | each maps to the rows above: 1,2,4,6,11,12,15,24,31 → parser/models; 3 → accumulator setpoint; 5,10,33 → enumerator/outcome; 7,13,19,20,32 → catalog; 8,14,18,22,25-30,35,36,38,41,42 → transport/session; 9,16 → C vendoring; 17,39,40 → diagnostics; 21 → ClockSync; 23 → fingerprint table; 34 → `rawData`; 37 → progress events | Kept unless listed as changed above |

**Behaviours recommended to change (summary with justification):** (1) auto-reconnect dropped — eliminates the double-free/stale-connection class and the Shearwater BLE-mode hang; explicit sessions + Retry; (2) CoreBluetooth off the main queue — removes every "must not run on main" constraint and the deadlock class; (3) `didFailToConnect` fails fast — deterministic errors instead of a 30 s wait; (4) fingerprint source = SwiftData table passed to the session — removes the fragile UserDefaults mirror and the `"Unknown"` key problem, and makes the cutoff decision correct by construction (`onlyWhenNoWatermark`); (5) hardware-model overwrite guarded by catalog membership; (6) polling loops → condition waits (same timeouts, lower latency, no 1 ms busy-sleeps); (7) library emits no user-facing text — the app localises; (8) cancel during download becomes possible (Q2); (9) parser context non-NULL so libdivecomputer parser logs reach the diagnostic file. Everything else, including every timeout constant, selection rule, status mapping, table, validation range and model field, is kept.

### Critical Files for Implementation
- BlueDive/Bluetooth/BluetoothScannerView+BLE.swift (session lifecycle, seeds, reassociation — the main cutover surface)
- BlueDive/Bluetooth/BluetoothScannerView+Import.swift (fingerprint source-of-truth change, KnownDeviceStore, persist/delete flows)
- BlueDive/Bluetooth/BluetoothScannerView+ProfileProcessing.swift (becomes DiveImportMapper; must stay logic-identical)
- BlueDive.xcodeproj/project.pbxproj (remove remote libdc-swift, add local package; synchronized-root-group constraint)
- /tmp/libdc-analysis/src/libdivecomputer/include/libdivecomputer/custom.h (dc_custom_cbs_t — the iostream contract), with ble.h/ioctl.h for the ioctl constants the shim must expose
