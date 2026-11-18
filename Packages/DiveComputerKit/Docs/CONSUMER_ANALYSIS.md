# BlueDive → LibDCSwift coupling analysis (consumer side only)

> Produced by a Fable agent on 2026-11-02 from BlueDive's own code only (no libdc-swift sources). Line numbers refer to the `working-2.1-BLE` branch at commit `5597382`.

Root: the repository root. Path abbreviations used below (all relative to it):
- **BSV** = `BlueDive/Bluetooth/BluetoothScannerView.swift`
- **BLE** = `BlueDive/Bluetooth/BluetoothScannerView+BLE.swift`
- **IMP** = `BlueDive/Bluetooth/BluetoothScannerView+Import.swift`
- **PP** = `BlueDive/Bluetooth/BluetoothScannerView+ProfileProcessing.swift`
- **VW** = `BlueDive/Bluetooth/BluetoothScannerView+Views.swift`
- **CMP** = `BlueDive/Bluetooth/BluetoothScannerComponents.swift`
- **DIAG** = `BlueDive/Bluetooth/BLEDiagnosticSession.swift`
- **DF** = `BlueDive/Models/DeviceFingerprint.swift`
- **DIVE** = `BlueDive/Models/Dive.swift`
- **TEST** = `BlueDiveTests/DiveDurationTests.swift`

## 0. Where the package is linked

- `BlueDive.xcodeproj/project.pbxproj`: remote package `https://github.com/houle988/libdc-swift`, branch `working` (lines 803-810); product **`LibDCSwift` only** (XCSwiftPackageProductDependency line 819-823), linked into the **BlueDive app target only** (Frameworks phase line 126; `packageProductDependencies` line 243). Not linked to `BlueDiveTests` (which uses `TEST_HOST`/`BUNDLE_LOADER` into BlueDive.app, lines 371-414, and `import LibDCSwift` at TEST:2 works via the host app) nor to `BlueDiveWidgetExtensionExtension` (imports only WidgetKit/SwiftUI/AppIntents/os). No bridging header, no `OTHER_LDFLAGS`/`HEADER_SEARCH_PATHS` referencing it, no embed step (static SPM product).
- `BlueDive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: pin `libdc-swift` branch `working`, rev `fd5b0db0fd8fe19d59a453939465ebf21e0d2aba`; also `fit-swift-sdk` 21.214.0 and `swift-collections` 1.2.1 (the latter is likely a transitive dep of libdc-swift — verify before removing it from Package.resolved).
- Docs mentioning it: `CONTRIBUTING.md:64,99-105`, `README.md:16,57-58`, `CLAUDE.md:115,131` (data rules referencing `reportedDivetime`/`DC_FIELD_DIVETIME`, `DiveData.atmospheric`/`DC_FIELD_ATMOSPHERIC`).

### Files importing the library (11)
`import LibDCSwift` in: BSV:4, BLE:4, IMP:4, PP:3, VW:4, CMP:3, DIAG:2, DF:3, `BlueDive/App/BlueDiveApp.swift:7`, `BlueDive/Dive List/ContentView.swift:6`, TEST:2. **No file imports `LibDCBridge` or `Clibdivecomputer` and no C symbol (`dc_*`, `device_data_t`, `free_device_data`, `DC_FIELD_*`) is called directly** — those appear only in comments (BSV:146-148, PP:62-63, DIVE:242). Two imports are dead: `BlueDiveApp.swift:7` (only a commented-out `LibDCSwift.Logger.shared.enableDebugMode()` at line 151) and `ContentView.swift:6` (no library symbol used; it only presents `BluetoothScannerView(isTeardownUnsafe:)` at line 439 and `import CoreBluetooth` at line 3).

Files in `BlueDive/Bluetooth/` that do **not** import it: `BluetoothSyncState.swift`, `FingerprintDebugView.swift`, `ShearwaterPNFGPS.swift`.

## 1. Complete symbol inventory (the minimum API surface the replacement must provide, or the call sites to adapt)

### 1a. `CoreBluetoothManager` (ObservableObject singleton)
| Symbol | Where | Use |
|---|---|---|
| `CoreBluetoothManager.sharedManager` | BSV:45 (`@ObservedObject var bleManager`) | view observes it |
| `$discoveredPeripherals` (Published `[CBPeripheral]`) | BSV:264 `.onReceive`; VW:272,284,302 | re-run `checkForTargetDevice`; list rows |
| `startScanning(omitUnsupportedPeripherals: Bool)` | BLE:14 (`false`) | scan |
| `stopScanning()` | BLE:19 | |
| `clearDiscoveredPeripherals()` | BLE:85; VW:697 | rescan |
| `centralManager: CBCentralManager` | BLE:73 `retrievePeripherals(withIdentifiers:)` | direct connect to known UUID |
| `isConnecting: Bool` (settable) | BLE:230 | set synchronously before `openBLEDevice` to suppress library auto-reconnect race |
| `isRetrievingLogs: Bool`, `currentRetrievalDevice: CBPeripheral?` | BLE:265-266, 387-388 | set early to block auto-reconnect |
| `openedDeviceDataPtr` (optional opaque pointer) | BLE:276 (poll loop), 281, 312 | waited for ≤5 s with `Thread.sleep`; passed to `DiveLogRetriever` |
| `close(clearDevicePtr: Bool)` | BSV:271; BLE:286,316,454,495,521; VW:662 | teardown (frees C `device_data_t`) |
| `clearRetrievalState()` | BLE:287,455,496,522 | must run after `close()` (comment BLE:419-424) |

### 1b. `DeviceConfiguration`
| Symbol | Where | Use |
|---|---|---|
| `openBLEDevice(name:deviceAddress:forcedModel:(family:model:)?) -> Bool` | BLE:240-244 | **blocking** connect, called on `DispatchQueue.global(qos:.userInitiated)`; side effect: writes a nil-serial `StoredDevice` (BLE:289-297 cleanup) |
| `getDeviceDisplayName(from: String) -> String` | BLE:134,192,348,379,386,630; IMP:632; CMP:180,184,196; VW:398 | BLE adv name → model display name |
| `supportedModels: [ComputerModel]` | BLE:143,156,189,345,638,738; IMP:376,383,629,810,919; CMP:44,174,192,334 | lookups by `name` or `(family, modelID)` |
| `ComputerModel` (`.name: String`, `.family: DeviceFamily`, `.modelID: UInt32`; `Identifiable`; `==` is (family,modelID) only, names unique — CMP:398-400) | BSV:97 `modelOverrides: [String: ComputerModel]`; CMP:102,327-333 | model picker / override |
| `DeviceFamily` (String-RawRepresentable, Hashable) | DF:35-37 (`rawValue` persisted as `familyID`), BSV:14,24,87; BLE:231; IMP:666; PP:59-68,90,213-216 | identity + behaviour switches |
| `DeviceFamily` cases referenced by name | PP:60-67 `.oceanicAtom2 .pelagicI330R .hwOstc3 .cressiGoa .deepsixExcursion .deepbluCosmiq .oceansS1 .mcleanExtreme`; PP:226,570 `.shearwaterPetrel`; PP:231,238 `.halcyonSymbios` | tank filter / gas inference |

### 1c. `DeviceStorage.shared` (UserDefaults, BLE-UUID → device)
| Symbol | Where |
|---|---|
| `getAllStoredDevices() -> [StoredDevice]?` | BLE:70,291,513,554,588,713; IMP:422,726,735 |
| `getStoredDevice(uuid:) -> StoredDevice?` | BLE:111,128,188,340,545,617; IMP:83,138,309,373,609,616,799,810,918; PP:92; CMP:107 |
| `storeDevice(uuid:name:family:model:serial:)` | BLE:162,552; IMP:311,322 |
| `updateStoredDevices(_ [StoredDevice])` | BLE:294,516,557,597,724; IMP:731 |
| `removeDevice(uuid:)` | IMP:753 |
| `StoredDevice` fields: `.uuid: String`, `.serial: String?`, `.family: DeviceFamily`, `.model: UInt32` (`.name` written, not read) | BSV:94 `[StoredDevice]?` state; CMP:169,189 |

### 1d. `DeviceFingerprintStorage.shared` (UserDefaults watermark cache, keyed `(deviceType: String, serial: String)`)
| Symbol | Where |
|---|---|
| `clearFingerprint(forDeviceType:serial:)` | BLE:359; IMP:487,714 |
| `loadFingerprints() -> [entry]` (entry has `.serial`, `.deviceType`) | IMP:427,452,478,715 |
| `saveFingerprints(_:)` | IMP:431,458,482,719 |
| `saveFingerprint(_ Data, deviceType:, serial:)` | IMP:464,469 |
| `getFingerprint(forDeviceType:serial:)?.fingerprint: Data` | IMP:635 |

### 1e. `DiveDataViewModel` (ObservableObject) and `DiveLogRetriever`
| Symbol | Where |
|---|---|
| `DiveDataViewModel()` | BLE:324 |
| `$progress` publisher; cases `.inProgress(Int)` (dive count), `.failed(String)` | BLE:328-334, 503 |
| `.dives: [DiveData]`, `.stoppedAtCutoff: Bool`, `.isPartialSync: Bool` | BLE:428,434,436,463,493 |
| `DiveLogRetriever.retrieveDiveLogs(from: devicePtr, device: CBPeripheral, viewModel:, bluetoothManager:, syncClock: Bool, useFingerprint: Bool, stopBefore: Date?, onProgress: (Int,Int)->Void, completion: (Bool)->Void)` | BLE:393-527 |

Behavioural contracts the app relies on: `onProgress` reports **transfer bytes** (BLE:405); `completion` is called on main but `viewModel.dives` is populated by a double `main.async` so the app re-dispatches (BLE:413-417, 427); library itself writes `DeviceStorage.updateDeviceSerial` with the hardware serial mid-download (BLE:536-544) and saves the UserDefaults watermark (`shouldSaveFingerprint`) only when `useFingerprint == true` (BLE:464-483); it stops at the first dive before `stopBefore` (BLE:400-402); `syncClock` sets the DC clock after download (BLE:398; VW:207-210, 715-721).

### 1f. `DiveData` (per-dive result) — every member read
`datetime` (BLE:439; IMP:80,183,196; PP:776,806), `divetime: TimeInterval` seconds (IMP:196; PP:878), `reportedDivetime: TimeInterval?` (IMP:196; PP:874), `maxDepth` (IMP:798; PP:818), `avgDepth` (IMP:799; PP:664), `temperature: Double` (may be non-finite — IMP:804-805; PP:668,820), `minTemperature`/`maxTemperature: Double?` (IMP:805-806; PP:668-669), `measuredSurfaceTemperature: Double?` (IMP:811; PP:826), `profile: [LibDCSwift.DiveProfilePoint]` (everywhere), `tankPressure: [Double]` (IMP:850-854; PP:686-689), `gasMix: Int?` (IMP:852,883; PP:118,610,687,705), `gasMixes: [GasMix]?` (IMP:820; PP:558,674), `tanks: [DiveData.Tank]?` (IMP:825; PP:679), `decoModel?.description` (IMP:893-894; PP:735-736), `cns: Double?` (IMP:896; PP:770), `decoStop?` with `.type: Int`, `.depth`, `.time` (IMP:898; PP:745,918-919), `salinity: Double?` (IMP:930; PP:750), `atmospheric: Double?` (IMP:936; PP:842), `location?` `.latitude .longitude .altitude` (IMP:943; PP:756-762), `exitLocation?` `.latitude .longitude` (IMP:950; PP:858), `diveMode?` cases `.freedive .gauge .openCircuit .closedCircuit .semiClosedCircuit` (PP:716-728), `rawData: Data?` (IMP:926; PP:853), `fingerprint: Data?` (IMP:172,927; PP:854). Full memberwise init signature is in TEST:273-280: `number, datetime, maxDepth, avgDepth, divetime, reportedDivetime, temperature, profile, tankPressure, gasMix, gasMixCount, gasMixes, salinity, atmospheric, surfaceTemperature, minTemperature, maxTemperature, tankCount, tanks, diveMode, decoModel, location, rbt, heartbeat, bearing, setpoint, ppo2Readings, cns, decoStop` (rbt/heartbeat/bearing/setpoint/ppo2Readings/gasMixCount/tankCount/surfaceTemperature/number are never read by the app).
- `DiveData.Tank`: `.gasMix: Int` (index or DC_GASMIX_UNKNOWN <0), `.usage: DiveData.Tank.Usage` (`.oxygen` case used PP:231), `.beginPressure`, `.endPressure`, `.volume`, `.workingPressure` (Doubles, 0 = unreported) — PP:213,596-633.
- `GasMix`: `.oxygen`, `.helium` fractions 0–1 (PP:214,223-260,647,879).

### 1g. `LibDCSwift.DiveProfilePoint` (name-collides with BlueDive's own `DiveProfilePoint`, hence the explicit qualification at PP:127,150,272,322,325)
Fields read: `time` (seconds), `depth` (m), `temperature?`, `pressure?` (legacy single), `pressures: [Int: Double]` (non-optional dict), `ndl?` (integer seconds), `decoStop?` (ceiling m), `decoTime?` (integer seconds), `cns?`, `po2?`, `sensorPPO2: [Int: Double]`, `events: [LibDCSwift.DiveEvent]`, `currentGas: Int?` (gas-mix index; only set on samples where DC_SAMPLE_GASMIX fired — PP:158-160), `setpoint?` — PP:105,116,131,168-184,329-409.
- `LibDCSwift.DiveEvent` cases (exhaustively switched, PP:272-293): `.ascent .violation .decoStop .gasChange .bookmark .safetyStop(Bool) .ceiling .po2 .deepStop`.

### 1h. `Logger.shared` (LibDCSwift's, not os.Logger)
`enableDebugMode()` DIAG:186, `disableDebugMode()` DIAG:206, `minimumLogLevel = .debug` DIAG:207, `onLog: ((event)->Void)?` with `event.timestamp`, `event.level.prefix`, `event.category`, `event.message` DIAG:164-167,208; `onPacket` with `event.timestamp`, `event.direction.rawValue`, `event.characteristicUUID`, `event.data`, `event.hexDump` DIAG:168-177,209; `log(_:level:)` with `.warning`/`.info` PP:247,254,259,264.

## 2. End-to-end data flow

1. **Entry**: ContentView.swift:439 presents `BluetoothScannerView(isTeardownUnsafe:)` as a sheet, `.interactiveDismissDisabled(isBluetoothSyncTeardownUnsafe)` (ContentView:441; binding kept in sync by BSV:313-318 via `isTeardownUnsafe(_:)` BSV:155-162 — `.connecting/.downloading/.importing` are unsafe because `close(clearDevicePtr:)` frees the C pointer while `dc_device_foreach` may still run, BSV:144-148). Deep link `.addDiveBluetooth` (ContentView:447).
2. **Known devices screen** (VW:132-258): `@Query DeviceFingerprint` sorted by `updatedAt` desc (BSV:42), de-duplicated by `normalizedComputerSerial()` (BSV:175-183; sentinel serials `"0","00000000","unknown","n/a"` exempt, BLE:532). Diver name per serial from `Gear` category "Computer" (BSV:186-203). Toggles: Download All Dives, Limit Import by Date (only with Download All), Sync device clock (`@AppStorage("syncDeviceClock")`, default true, BSV:74).
3. **Scanning**: `startScanning()` BLE:12 → `bleManager.startScanning(omitUnsupportedPeripherals:false)`; `checkForTargetDevice()` (BLE:105-174) on each `$discoveredPeripherals` emission matches by `DeviceStorage` serial, or (post-reinstall) by name/family+model against `cachedTargetFingerprint`, deferring `DeviceStorage` writes via `pendingDeviceStorageSeed` + `modelOverrides` (BLE:149-164).
4. **Device selection**: `handleDeviceTap` (BLE:607-679) → reassociation matching of peripheral name/model to `dedupedKnownDevices`; alert (1 match) or picker sheet (`DeviceReassociationPickerSheet` CMP:250); `confirmReassociation` (BLE:684-749) prunes stale `DeviceStorage` entries for the serial, sets seed + override; model picker `ModelPickerSheet` (CMP:325) writes `modelOverrides[uuid]`.
5. **Connect** `connectToDevice` (BLE:176-308): resolve display name (override > DeviceStorage model > `getDeviceDisplayName`); start `BLEDiagnosticSession` if enabled; `bleManager.isConnecting = true`; background `openBLEDevice(name:deviceAddress:forcedModel:)`; on success set `isRetrievingLogs/currentRetrievalDevice`, poll `openedDeviceDataPtr` ≤5 s; failure branches clean up nil-serial orphan `StoredDevice`, discard seed, restore pruned entries.
6. **Download** `retrieveDiveLogs` (BLE:311-528): `DiveDataViewModel`; Combine sink on `$progress` → `diveCountDuringDownload`; **Download All** clears single `(deviceType, serial)` UserDefaults key (BLE:357-359) and passes `useFingerprint:false`; else `syncFingerprintFromDatabase` (IMP:365-496) copies SwiftData `DeviceFingerprint.fingerprintData` into the library cache under every deviceType key for that serial (mirror), or sweeps stale entries; `effectiveCutoff` only for full-history downloads (BLE:382-385). Progress: bytes → `.downloading(current:total:)` with guard against late events (BLE:403-411). Completion: filter `datetime >= cutoff`, `cutoffStopDate = viewModel.stoppedAtCutoff ? cutoff : nil`, `isPartialSync`, `commitPendingSeed()` (BLE:534-563 verifies the library-reported serial matches the seed), `close` → `clearRetrievalState`, then `showingImportConfirmation` or `.completed(0,0,0)` with `persistFingerprintRecord` when dives were downloaded but all filtered (BLE:449-488). **There is no user cancel during download** — Close is disabled and swipe-dismiss blocked; only `onDisappear` tears down (BSV:267-291).
7. **Import** `importDownloadedDives` (IMP:62-238, `Task { @MainActor }`): sort by `datetime`; `resolveGearDiverName(forSerial:)` (`BlueDive/Data & Sync/DiverFilter.swift:170`); next dive number per diver; previous dive end for surface interval (uses `consistentDurationSeconds ?? duration*60`, IMP:125-126); duplicate index `[fingerprint: Dive]` for dives with same normalized `computerSerialNumber` within ±`deduplicationHighConfidenceWindow` (86 400 s, `BlueDive/Shared/CrossPlatformImage.swift:558`) (IMP:137-169). Match by `diveData.fingerprint` → skip (normal) or `mergeComputerData` (Download All). Else `convertToBlueDiveDive`. `previousDiveEndTime = datetime + (reportedDivetime ?? divetime)` (IMP:196). Save → `persistFingerprintRecord(for: selectedDevice)` (IMP:607-685: reads library cache `getFingerprint(forDeviceType: libraryDeviceType, serial:)`, upserts `DeviceFingerprint` keyed by serial with identity rules override > existing > auto-detected). Rollback on save failure keeps `downloadedDives` for retry (IMP:211-221). `store.commitListRebuild()` when merged (IMP:227-229). Weather offer (IMP:252-297).

### 2a. Field mapping `DiveData` → `Dive` (`convertToBlueDiveDive` PP:656-867; merge variant IMP:796-962)
| Dive field | Source | Notes |
|---|---|---|
| `timestamp` | `datetime` | |
| `diveNumber` | per-diver sequence | not from DC `number` |
| `diveTypes` | `diveMode` → "Freediving"/"Gauge"/"Open Circuit"/"Rebreather"/"Semi-Rebreather", nil → "Reef" (PP:715-731) | merge does not touch it |
| `computerName` | `supportedModels` name for DeviceStorage (family,model) ?? `connectedDeviceName` ?? localized `dive.computer.default_ble_name` (PP:810; IMP:916-923) | **persisted model display string** |
| `computerSerialNumber` | `DeviceStorage.getStoredDevice(uuid:).serial` trimmed, nil if empty (PP:798-801) | **persisted; dedup key** |
| `surfaceInterval` / `isRepetitiveDive` | computed from previous end (PP:773-796; <24 h repetitive) | |
| `maxDepth`, `averageDepth` | `maxDepth`, `avgDepth` metres | `importDistanceUnit = "meters"` hardcoded PP:832 |
| `duration`/`durationSeconds` | `applyDuration` PP:873-880: `reportedDivetime` finite → `setDuration(seconds:)` (DIVE:1526); else `setDuration(minutes: Dive.roundedMinutes(fromSeconds: divetime))` (DIVE:1538,1622) | tested TEST:271-301 |
| `waterTemperature` | `temperature` if finite | °C hardcoded PP:833 |
| `minTemperature` | `minTemperature` finite ?? profile min ?? `temperature` | |
| `maxTemperature` | `maxTemperature` finite ?? profile max | |
| `airTemperature` | `measuredSurfaceTemperature` (not the library's first-sample fallback `surfaceTemperature`) PP:822-826; merge only fills empty IMP:811-813 | |
| `decompressionAlgorithm` | `decoModel.description` | string persisted |
| `cnsPercentage` | `cns` ?? last profile `cns` | |
| `isDecompressionDive` | `decoStop?.type == 2` ∨ any profile `decoStop != nil` ∨ any `.decoStop` event (PP:745-747) | note: merge/convert check `decoStop != nil` (not `> 0`) |
| `siteWaterType` | `waterType(forSalinity:)` (`BlueDive/Shared/WaterTypeHelpers.swift:6`) from g/cm³ | |
| `siteLatitude/Longitude/Altitude` | `location` validated range, (0,0) rejected (PP:756-767) | |
| `exitLatitude/Longitude` | `exitLocation` validated (PP:858-864) | |
| `surfacePressure` | `atmospheric` → `Dive.init` applies `validatedSurfacePressure` (DIVE:1474,1507-1510; range 0.4…1.2 bar DIVE:1503 "same as LibDCSwift's GenericParser.validAtmosphericRange"); merge only if valid (IMP:936-938) | bar |
| `importPressureUnit "bar"`, `importVolumeUnit "liters"`, `importWeightUnit` from UserDefaults `weightUnit`, `sourceImport "Bluetooth"` | PP:834-837 | |
| `profileSamples` | `consolidateProfilePoints` (PP:321-414) then `remapProfileCurrentGas` (PP:298-313) | see below |
| `tanks` | `buildTanksFromComputerTanks` (PP:552-651) / fallbacks PP:686-708, then `applyGasSwitchUsageTimes` (PP:433-541) | see below |
| `rawDiveComputerData` | `rawData` | **persisted raw bytes**; consumed by `ShearwaterPNFGPS` |
| `fingerprintData` | `fingerprint` | **persisted; dedup key** |
| `decoStops` | `extractDecoStops` (PP:891-921): per-depth peak `decoTime`, `DecoStop(type: 2)`; fallback header `decoStop` only if `type == 2` | `DecoStop.type` ints = libdivecomputer `DC_DECO_*` (DIVE:242) |
| merge-only preserved | notes, rating, buddies, dive type, site, number, surface interval, tank volume/workingPressure/material/type (IMP:837-849) | |

**Profile consolidation** (PP:321-414): groups by identical `time` (seconds); base = first point; events union de-duplicated; synthesizes `.decoStop` when `base.decoStop > 0`; `tankPressure` = `pressures[0]` ?? lowest-index ?? `pressure`; `tankPressures` = `pressures` or nil if empty; `sensorPPO2` merged across the group; `currentGas` = last non-nil in group; `setpoint` = last point's; **time ÷ 60 → minutes**, `ndl` seconds→minutes, `ceilingDepth = decoStop if > 0`, `ceilingTime = decoTime/60 if decoStop > 0`, `cns`, `ppo2 = po2`. BlueDive `DiveProfilePoint` is DIVE:43-83 (minutes, metres, bar; `setpoint` validated by `validSetpoint` DIVE:111-114).

**Tanks/gas**: tier logic in `resolveGasMix` (PP:209-269): index valid → that mix; Shearwater → tank N = mix N; Halcyon O2 usage → ≥99% O2 mix; else profile-appearance order (`orderedGasMixIndices` PP:101-111); else positional; else first mix; else `headerGasMix ?? 21` percent. Shearwater pressure-drop inference `inferShearwaterGasMixToTank` (PP:149-205). Pressure fallback from profile when header `beginPressure/endPressure <= 0` (PP:126-140, 620-633). Unused-tank filter only when `@AppStorage("filterUnusedTanks")` and family ∈ `familiesNeedingSwiftTankFilter` (PP:59-68, 640-648, 693). Gas-only tanks appended for unclaimed mixes. `TankData` DIVE:121-170; usage times stored in **seconds** (PP:466-467, 537-538).

### 2b. Known-device persistence
`DeviceFingerprint` (@Model, DF:12-49): `serial`, `computerName`, `fingerprintData`, `familyID` (= `DeviceFamily.rawValue`, e.g. "shearwaterPetrel"), `modelID: UInt32` (libdivecomputer model number, e.g. 4 = Perdix 2), `updatedAt`. Three stores must be kept coherent: SwiftData (`DeviceFingerprint`), `DeviceStorage` (UserDefaults, BLE UUID → serial/family/model), `DeviceFingerprintStorage` (UserDefaults `(deviceType, serial)` → watermark). `seedDeviceStorageFromDatabase` (IMP:305-330), `syncFingerprintFromDatabase` (IMP:365-496), `persistFingerprintRecord` (IMP:607-685), `deleteKnownDevice` (IMP:690-760: sweeps all three stores by normalized serial; sentinel → single-entry only), `clearAllDeviceFingerprintRecords` (IMP:772-789).

## 3. Threading / concurrency
- View is SwiftUI main-actor; `bleManager` is `@ObservedObject` (BSV:45); `$discoveredPeripherals` observed via `.onReceive` (BSV:264) and read directly in body (VW:272-302).
- `openBLEDevice` runs on `DispatchQueue.global(qos: .userInitiated)` (BLE:239) because it blocks waiting on CoreBluetooth callbacks delivered on main (BLE:220-224); `isConnecting` set synchronously before dispatch (BLE:226-230); busy-wait poll `Thread.sleep(0.05)` on `openedDeviceDataPtr` (BLE:272-278) reading an `@Published`-style property from a background thread; results hopped back with `DispatchQueue.main.async`.
- Download progress: Combine `viewModel.$progress.receive(on: DispatchQueue.main).sink` stored in `@State var downloadProgressCancellable: AnyCancellable?` (BSV:84; BLE:328-334); `onProgress` closure wraps in `main.async` (BLE:404); `completion` re-dispatches to main to let the library's double-async `appendDives` land (BLE:413-417, 427, 501).
- Import: `Task { @MainActor in … }` (IMP:72); weather fetch `Task { @MainActor }` + `await WeatherBatchFetcher.run` (IMP:291-296).
- `BLEDiagnosticSession`: own serial `DispatchQueue(label:"com.bluedive.BLEDiagnosticSession", qos:.utility)` (DIAG:57) guarding file handle; `Logger.shared.onLog/onPacket` callbacks may arrive on any thread and are enqueued (DIAG:221-232).
- No async/await is used against the library; all library APIs are callback/Combine-based.

## 4. Library-dependent features
- **BLE diagnostic trace** (DIAG; UI in `BlueDive/SettingsView/BluetoothSettingsView.swift:67,71,93,266,287,328` and VW:608-653): depends entirely on `Logger.shared` hooks (`onLog`, `onPacket`, `enableDebugMode/disableDebugMode`, `minimumLogLevel`). File format `BlueDive_BLE_<ts>.log` in Documents, prune to 5, 24 h auto-off via UserDefaults `bleDiagnosticLoggingEnabled`/`bleDiagnosticLoggingExpiry`.
- **FingerprintDebugView** (`BlueDive/Bluetooth/FingerprintDebugView.swift`): pure SwiftData editor of `DeviceFingerprint` (hex override at :340-346, shows `familyID` :234 and `modelID` as `0x%02X` :275). No library import, but depends on the cache being re-seeded from SwiftData before each sync.
- **Fingerprint XML import/export** (`BlueDive/Import & Export/Fingerprint XML/`): Exporter writes `serial, computerName, familyID, modelID (decimal), fingerprint (lowercase hex), updatedAt` (FingerprintXMLExporter.swift:49-55); Parser/ImportFlow writes `DeviceFingerprint` with raw `familyID`/`modelID` strings/ints (FingerprintImportFlow.swift:204-207), identity via `isSameComputer` (:159-168). No library import; **the XML format fixes `familyID` rawValues and `modelID` numbers as an external contract.**
- **Clock sync**: `syncClock: syncDeviceClock` arg (BLE:398); UI text VW:207-210, 715-721.
- **Shearwater PNF GPS** (`BlueDive/Bluetooth/ShearwaterPNFGPS.swift`): **parses raw bytes itself** from `Dive.rawDiveComputerData` (record type 0x19/0x29, 32-byte records, lat/lon int32 BE ÷100000 at +21/+25). Callers `BlueDive/DiveDetailView/DiveDetailView+EditSheets.swift:1323-1329, 1897-1908`. Requires the new parser to store the **same raw dive bytes** in `rawData` for Shearwater.
- **Known devices list / forget device / reassociation / model override / Download All / import cutoff / unused-tank filter / partial-sync warning** — all in BSV/BLE/IMP/VW as described above; `BlueDive/SettingsView/SettingsView.swift:659` resets `filterUnusedTanks`.
- Dedup on file import also uses `fingerprintData` + normalized serial (`BlueDive/Dive List/ContentView+Import.swift:681-690, 788-799`) and `BlueDiveXMLExporter/Parser` round-trip `rawDiveComputerData`/`fingerprintData` as Base64 (BlueDiveXMLExporter.swift:431-437; BlueDiveXMLParser.swift:247-249, 683-685, 744-745). `DiveDetailView+Samples.swift:80-86` shows fingerprint hex.

## 5. Library-specific behaviours / DATA-COMPATIBILITY constraints
1. **`DeviceFingerprint.familyID` strings** = `DeviceConfiguration.DeviceFamily.rawValue` (DF:23-26). At least these rawValues exist in stored data/XML: `shearwaterPetrel, halcyonSymbios, oceanicAtom2, pelagicI330R, hwOstc3, cressiGoa, deepsixExcursion, deepbluCosmiq, oceansS1, mcleanExtreme` (plus every other family the library's `supportedModels` emits). The new family enum must keep identical rawValues or provide a migration; `DeviceFamily(rawValue:)` returning nil degrades records to "legacy" (BLE:703, 729-733).
2. **`DeviceFingerprint.modelID`** = libdivecomputer model number per family (DF:28-29; e.g. 4 = Perdix 2); exported as decimal in XML. Must match exactly.
3. **`computerName` / `Dive.computerName`** = `supportedModels[...].name` display strings (e.g. "Shearwater Perdix 2", "Aqualung i300C") — used as the `deviceType` key in the fingerprint cache (IMP:627-633), for reassociation name matching (BLE:640), asset icon lookup by exact name (CMP:44-49, 80-87; see `DIVE_COMPUTER_ICONS.md`), and persisted in every imported `Dive`. Names must remain identical.
4. **`Dive.computerSerialNumber`** = library-reported serial string (trimmed; case preserved; may be sentinel "0"/"00000000"). Dedup compares `normalizedComputerSerial()` (lowercase/trim). Serial formatting (hex vs decimal, zero-padding) must match what libdivecomputer/LibDCSwift produced per family, or existing dives won't dedup against re-downloads.
5. **`Dive.fingerprintData` / `DeviceFingerprint.fingerprintData`** = libdivecomputer's per-family fingerprint bytes. Incremental sync and duplicate detection depend on byte-identical fingerprints for the same dive; the watermark comparison ("stop at first dive whose fingerprint equals the stored one") must be preserved, as must "stop at first dive before `stopBefore`" and `stoppedAtCutoff`/`isPartialSync` signals.
6. **Units**: depth m, temp °C, pressure bar, volume L, profile `time` and `divetime`/`reportedDivetime` in **seconds** (converted ÷60), `ndl`/`decoTime` integer seconds, `decoStop` metres, `salinity` g/cm³ (≈1.0 fresh / 1.025 salt), `atmospheric` bar, GasMix fractions 0–1, `gasMix` header is an **index** in `usedGasMixIndices` (PP:118) but treated as a **percentage** in the fallbacks (`Double(gasMix ?? 21)/100`, PP:687,705; IMP:852,883) — an existing inconsistency to be aware of.
7. **nil-vs-0 conventions**: `temperature` non-optional but may be NaN/inf (guards at IMP:804; PP:668,820); `Tank.beginPressure/endPressure/volume/workingPressure` use 0 = unreported (PP:622-632); `measuredSurfaceTemperature` nil unless finite; `currentGas` nil except on gas-switch samples, negative = DC_GASMIX_UNKNOWN (PP:105,116,168); `decoStop` on header non-nil even for NDL dives → must check `type == 2` (PP:742-745); `pressures`/`sensorPPO2` non-optional dicts (empty = none); `DecoStop.type` ints 0..3 = `DC_DECO_*`.
8. **Event-point duplication**: library emits separate profile points at the same timestamp for events (consolidation PP:328-335 relies on identical `time`).
9. `reportedDivetime` = `DC_FIELD_DIVETIME` → `durationSeconds`; `divetime` = last-sample time (CLAUDE.md:115).
10. `avgDepth` is already resolved by the library's GenericParser (time-weighted fallback) PP:662-664.
11. `DeviceStorage` is written by **the library** (nil-serial entry on `openBLEDevice`, serial via `updateDeviceSerial` mid-download) — app code depends on this (BLE:289-297, 536-551; IMP:609-610). The library's lazy mid-download fingerprint lookup under the resolved serial is why the app mirrors/sweeps by serial (IMP:16-50, 347-364).
12. `surfacePressure` validity range mirrors `GenericParser.validAtmosphericRange` (DIVE:1500-1503).
13. Tank filtering assumptions per family (PP:20-36): which C parsers already filter unused tanks.

## 6. Tests
- `BlueDiveTests/DiveDurationTests.swift:2` imports LibDCSwift; `:269-301` constructs `DiveData(...)` memberwise and tests `BluetoothScannerView.applyDuration` (3 tests). This is the **only** test touching the BLE/parsing path; it will break when the type is removed.
- `BlueDiveTests/BuhlmannZHL16CTests.swift:17,244-288` and `DiveDurationTests.swift:26-27,162` use **BlueDive's** `DiveProfilePoint` (qualified `BlueDive.DiveProfilePoint` because of the name collision). `SurfacePressureTests.swift` tests `validatedSurfacePressure` (not library-bound). No tests for `consolidateProfilePoints`, `buildTanksFromComputerTanks`, `resolveGasMix`, `extractDecoStops`, `applyGasSwitchUsageTimes`, reassociation, or fingerprint persistence.

## 7. Coupling assessment and seam suggestions
**Cleanly separable already:** `BluetoothSyncState.swift`, `ShearwaterPNFGPS.swift`, `FingerprintDebugView.swift`, Fingerprint XML import/export, `Dive` model helpers (`applyDuration` target APIs, `validatedSurfacePressure`, `roundedMinutes`), and the pure static functions in PP (`consolidateProfilePoints`, `remapProfileCurrentGas`, `applyGasSwitchUsageTimes`, `buildTanksFromComputerTanks`, `resolveGasMix`, `extractDecoStops`, `orderedGasMixIndices`, `usedGasMixIndices`, `pressureRangeFromProfile`) — these only need the input types (`DiveData`, `LibDCSwift.DiveProfilePoint`, `GasMix`, `DiveData.Tank`, `DeviceFamily`, `LibDCSwift.DiveEvent`) renamed.

**Entangled in the view:** `BluetoothScannerView` (a SwiftUI `View`) directly owns the BLE session: `@ObservedObject CoreBluetoothManager`, background `DispatchQueue` + `Thread.sleep` polling of a C pointer, `DiveLogRetriever` callbacks, three persistence stores (SwiftData / `DeviceStorage` / `DeviceFingerprintStorage`) reconciled inline (IMP:365-496, 607-685, 690-760), and `Logger.shared.log` calls from pure mapping code (PP:247-264). `DeviceStorage`/`DeviceFingerprintStorage` are library-owned UserDefaults caches that the app treats as a second source of truth, with the library writing to them mid-download — this is the deepest entanglement.

**Suggested adapter boundary (app-owned protocol/types, no library imports outside one module):**
1. `DiveComputerFamily: String` enum + `DiveComputerModel { name, family, modelID }` + `supportedModels` catalog with **identical rawValues/names/modelIDs** (§5.1-3); `DeviceFingerprint.family` and XML keep working unchanged.
2. `DownloadedDive` (replacement for `DiveData`) and `DownloadedSample`/`DownloadedEvent`/`DownloadedTank`/`DownloadedGasMix` value types with the exact members in §1f-g and the same unit conventions (§5.6-8); rename BlueDive's `DiveProfilePoint` collision away by naming the new sample type differently.
3. `DiveComputerSession` protocol: `scan()`/`stop()` publishing `[CBPeripheral]`, `connect(peripheral, forcedModel:) async throws -> ConnectedDevice` (exposing `serial`, resolved model, family), `download(options: {useFingerprint, storedFingerprint: Data?, stopBefore: Date?, syncClock}) -> AsyncThrowingStream<DownloadEvent>` with events `.progress(bytes,total)`, `.diveParsed(count)`, `.dive(DownloadedDive)`, `.finished(stoppedAtCutoff:, partial:, newFingerprint: Data?)`, and `close()`. Passing the stored fingerprint **in** and getting the new watermark **out** removes the `DeviceFingerprintStorage` mirror/sweep logic entirely (IMP:365-496, BLE:336-375, IMP:627-641) and makes SwiftData the single source of truth as the comments already intend.
4. App-owned `KnownDeviceStore` replacing `DeviceStorage` (BLE UUID ↔ serial/family/model), written only by the app after a confirmed download — eliminates the nil-serial orphan and `commitPendingSeed` serial-mismatch handling (BLE:289-297, 534-563).
5. `DiagnosticsSink` protocol (`onLog`, `onPacket`, `enable/disable`) implemented by the new BLE layer so `BLEDiagnosticSession` keeps its file format.
6. Move PP's pure functions and `mergeComputerData`/`convertToBlueDiveDive` into a non-View `DiveImportMapper` taking `(DownloadedDive, deviceFamily, computerName, serial, filterUnusedTanks)` so they become unit-testable without a `BluetoothScannerView`; replace `Logger.shared.log` with `os.Logger`.
7. Delete the dead imports at `BlueDiveApp.swift:7` and `ContentView.swift:6`, and rewrite TEST:269-301 against the new `DownloadedDive` type.
