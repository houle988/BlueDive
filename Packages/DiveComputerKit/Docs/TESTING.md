# DiveComputerKit — tests, BLE logs, device matrix

As of 2026-11-19. Linked from `START_HERE.md`.

## Running the tests

All suites use Swift Testing. Those that need private data are **skipped** (not failed) when their environment variable is unset or empty; the data lives in `~/BlueDive-Fixtures` (`START_HERE.md`), never in the repository.

**Package unit tests** (no private data, seconds):

```
cd Packages/DiveComputerKit && swift test
```

**Golden parser parity**, one run per fixture set (each set has its own `manifest.json`, whose `timeZone` the suite pins with `TZ` and `NSTimeZone.default` before parsing):

```
cd Packages/DiveComputerKit
for d in ~/BlueDive-Fixtures/golden*; do echo "== $d"; DCK_GOLDEN_DIR="$d" swift test --filter GoldenParityTests; done
```

Expected folder layout (`Golden/GoldenParityTests.swift`): `manifest.json` plus one `*.json` per dive (`<serial>_<sha16>.json`), each with `input` (`family`, `modelID`, base64 `rawData`, …) and either `output` or `error`; schema and canonical rendering in `GOLDEN_FORMAT.md`. Every file is a separate test case, compared byte for byte after the accepted deviations. Expected on 2026-11-19, in the order the loop prints the sets (shell glob order of the folder names; labels from `GOLDEN_FORMAT.md`, "Parity results"): main 87, CCR 1, i300C 78, Perdix 3 second set 30, Peregrine (export) 16, Peregrine (Bluetooth) 52, Petrel 1, MacDive logbook 801 cases, all passing.

**Mapper parity and mapper unit tests** (app target, macOS destination):

```
TEST_RUNNER_BLUEDIVE_PARITY_DIR=~/BlueDive-Fixtures/mapper-parity \
xcodebuild test -project BlueDive.xcodeproj -scheme BlueDive -destination 'platform=macOS' \
  -only-testing:BlueDiveTests/DiveImportMapperTests \
  -only-testing:BlueDiveTests/DiveImportMapperParityTests
```

The commands use Xcode's `BlueDive` scheme: no shared scheme is committed, so Xcode creates it automatically when the project is first opened.

xcodebuild passes `TEST_RUNNER_<NAME>` to the test process as `<NAME>`; in Xcode, set `BLUEDIVE_PARITY_DIR` in the scheme's Test environment instead. Expected layout (`BlueDiveTests/DiveImportMapperParityTests.swift`): one subfolder per computer holding `export.bluedive` (BlueDive XML exported by the former LibDCSwift version, raw dive bytes and fingerprints included) and `fingerprints.bluedive` (Fingerprint XML; its first `<device>` gives `familyID`, `modelID`, `serial`). Subfolders without `export.bluedive` are ignored. The suite pins `NSTimeZone.default` to **America/Toronto** (the zone the exports were made in) and runs serialized. Also useful after a mapper change: `-only-testing:BlueDiveTests/ProfileTimeTests -only-testing:BlueDiveTests/DiveDurationTests` (no private data).

Build both an iOS destination and **My Mac** for any change (CLAUDE.md). If xcodebuild seems to run an old build (a changed test does not behave as edited), `touch` the edited file or clean the build folder and run again.

## Test inventory

Package (`Packages/DiveComputerKit/Tests/DiveComputerKitTests/`):

| Suite (file) | Covers |
|---|---|
| `LibraryBuildTests` (`LibraryBuildTests.swift`) | The vendored C library builds and links: `dc_version` is 0.10.0, the shim's `DC_IOCTL_BLE_*` values, BLE descriptors exist, `dc_custom_open` links |
| `CatalogConsistencyTests` (`CatalogTests.swift`) | `legacyFamiliesAreKept`: the old library's 16 families are a prefix of `DeviceFamily.allCases` (unchanged, in order, new ones appended), raw values and `dcFamily` values unique; `legacyModelsAreKept`: every old-catalog model (minus the non-BLE models, Q4) still listed with the same name, family and model number, in the same relative order, each (family, model) still resolving to the same first name, new models allowed; unique names; every model has a BLE descriptor; every BLE descriptor is in the catalog (upstream-sync tripwire); `legacyServiceUUIDsAreKept`: the old 14 service UUIDs kept (case-insensitive), new ones allowed, all lowercased, no duplicate (`ADDING_A_DIVE_COMPUTER.md`) |
| `LegacyCatalogCheckTests` (`CatalogTests.swift`) | The prefix, subsequence and superset checks behind those tests, on made-up catalogs: additions (models anywhere, families appended) pass; a removed, renamed, changed or moved model, a new sibling listed before a shared model number, a removed UUID, and a removed, renamed, reordered, inserted or duplicated family fail |
| `NameResolutionTests` (`CatalogTests.swift`) | `resolve` and `displayName` give the old library's result for every name in `Fixtures/ble-name-samples.json` (recorded in `legacy-catalog.json`; L1) |
| `ServiceCatalogTests` (`CatalogTests.swift`) | Short-form service UUIDs ("FEFB", "FCEF") match; GATT 0x1801 loses to a dive-computer service |
| `SampleAccumulatorTests` (`ParserTests.swift`) | The profile state machine with scripted sample streams: intervals, events, pressures, `reportedRBT` vs `rbt`, Uwatec default RBT, voted/sensor PPO₂, gas-change synthesis, setpoints (per-sample and change-only), locations, deco and CNS |
| `FieldRuleTests` (`ParserTests.swift`) | Average-depth trapezoid, Shearwater PNF detection, setpoint families, deco-model descriptions, event mapping, garbage data fails |
| `PacketQueueTests` (`TransportSessionTests.swift`) | Notification boundaries, partial reads, purge of the partial rest |
| `CharacteristicSelectionTests` (`TransportSessionTests.swift`) | Vendor service over Nordic UART, ignored firmware/unknown services, two-pass write/notify selection |
| `DiscoveryTableTests` | The scan list's rule (`DiscoveryTable`, advertised and already-connected peripherals, `DECISIONS.md` L9): a name is required, the filter is asked only for a new identifier, a refresh is not published, sorted by name, cleared |
| `IOStreamTests` (`TransportSessionTests.swift`) | The `@convention(c)` callbacks through real `dc_iostream_*` calls over `FakeLink`: read/write status mapping, timeout and purge forwarding, `GET_NAME`, `CHARACTERISTIC_READ`, the Pelagic PIN / access-code ioctls with a fake provider |
| `DownloadDecisionTests` (`TransportSessionTests.swift`) | The outcome table (SUCCESS and PROTOCOL rows, failures), the clock-sync rule, timezone in seconds |
| `SessionTests` (`TransportSessionTests.swift`) | Whole `DeviceSession`s over `FakeLink` with real backends: connection failure closes the link, unsupported name, silent device times out, the Oceanic retry purges before resending (L5), cancel during a download |
| `GoldenParityTests` (`Golden/`) | Parser output byte-identical to the old library (private, `DCK_GOLDEN_DIR`); `GoldenEncoding.swift` / `Canonical.swift` are the canonical encoder, `GoldenDiff.applyAcceptedDeviations` the accepted deviations |

App (`BlueDiveTests/`):

| Suite | Covers |
|---|---|
| `DiveImportMapperParityTests` | Every fixture dive's raw bytes → `DiveParser` → `DiveImportMapper.makeDive` → BlueDive XML equals the old version's export in every computer-provided value (IDs, dive number, diver, the first dive's surface interval and the new TTS/RBT attributes excepted); merging the same download back changes nothing, tank IDs included (private, `BLUEDIVE_PARITY_DIR`) |
| `DiveImportMapperTests` | What the fixtures do not reach: computer-name fallbacks, serial and weight unit from the context, "Filter unused tanks" on/off and per family, merge keeps user fields and tank IDs (every tank path, count changes), gas references when a mix could not be read (L4) |
| `KnownDeviceStoreTests` | The known-device list (`DeviceStorage`, `com.libdc.storedDevices`) keeps entries it cannot decode (a newer build's family): read skips them in order, `storeDevice` / `updateDeviceSerial` / `removeDevice` keep them, a write for the same `uuid` replaces one, `removeDevice` of its `uuid` removes it; a fully readable list is written with the same encoder as before, so it is the same JSON value as the former format (key order may vary between writes, as it always did); an unknown entry is written after the readable ones, wherever it was read; malformed elements (not an object with a string `uuid`) are dropped on the next write; a corrupt blob reads as nil (own `UserDefaults` suite, made-up devices) |
| `ProfileTimeTests` | TTS/RBT storage rules, the Bluetooth mapping (seconds → minutes, RBT only where reported), re-download, BlueDive XML / Subsurface / UDDF |
| `DiveDurationTests` | Duration rules, including `DiveImportMapper.applyDuration` (computer time vs last sample) |

Not implemented: trace replay (`DCK_TRACE_DIR`) and an authentication replay for the i330R/DSX (`DECISIONS.md` Q3, O2).

## Reading a BLE diagnostic log

**Producing one.** Settings → Bluetooth Import → **BLE Diagnostic Logging** (`BluetoothSettingsView`, `BLEDiagnosticSession`). It turns itself off 24 hours after it is enabled (`BLEDiagnosticSession.autoOffInterval`). Each connection while it is on writes `Documents/BlueDive_BLE_yyyy-MM-dd_HHmmss.log` (`BLEDiagnosticSession.start()` prunes the older files to the five newest just before creating the new one, so up to six exist: five previous logs plus the current one). The user shares it with **Save Diagnostic Log** (Settings → Bluetooth Import, or the scanner's error screen). Logs contain serial numbers, device names and complete dive data: they are private, kept in `~/BlueDive-Fixtures/traces` at most, and never committed or quoted in the repository.

**Line format.** A header (`BlueDive BLE Diagnostic Log`, `Started: …`), then:

- log lines: `[<Unix time, 3 decimals>] [<level>] [<category>] <message>` — level `🔍 DEBUG`, `ℹ️ INFO`, `⚠️ WARN`, `❌ ERROR`; category = the Swift file that logged (`BLEPeripheralLink`, `BLECentral`, `DeviceSession`, `DCIOStream`, `DCIOControl`, the app's `BluetoothScannerView+BLE` …) or `libdivecomputer`;
- packets: `[<time>] [INBOUND]` or `[OUTBOUND]` `<characteristic UUID> (<n> bytes)` followed by a hex dump (16 bytes per line).

**Message prefixes** (in the message, after the category): `[BLE SCAN]` (a dive computer already connected to the system, listed without advertising, `DECISIONS.md` L9), `[BLE CONNECT]` (retrieve, open, connect, chosen service, notifications, ready, close), `[BLE DISCOVER]` (services, then each characteristic with its properties), `[BLE READ]` (read timeouts, late values, purge), `[BLE WRITE]` (not ready, not confirmed, errors), `[BLE NOTIFY]`, `[BLE IOCTL]` (PIN, access code, characteristic read, unsupported request), `[BLE TIMEOUT]` (libdivecomputer changing the read timeout), `[DISCONNECT]`; from the app `[Serial check]`, `[DeviceStorage]`, `[Reassociation]`, `[Known device]` (connecting to a stored device by its identifier, or finding it under a new one); from libdivecomputer `[libdc ERROR|WARNING|INFO|DEBUG|TRACE] <file>:<line> (<function>): <message>`. The session's own lines have no bracket prefix ("dc_device_open attempt N failed", "Fingerprint <hex> for <serial>: DC_STATUS_SUCCESS", "No fingerprint for …", "Dive skipped", "Download ended with …", "Clock synchronized", "Session ended: …"). Only lines logged through `DiveComputerLog` reach the file: what the app logs with its own `Self.logger` (`os.Logger`, e.g. the `[BLE] …` lines in `BluetoothScannerView+BLE.swift`) goes to the system log only and never appears in the diagnostic file.

**A healthy session**, in order: `Session for <name> <uuid>: model …` → `[BLE CONNECT] Opening …` / `… found in this scan` or `retrieved from the system` → `Connect requested` → `Connected` → `[BLE DISCOVER] Services: …` and the characteristics → `[BLE CONNECT] Service <uuid>, write <uuid>, notify <uuid>` (the chosen service and characteristics) → `[BLE CONNECT] Notifications enabled after …` → `Ready` → libdivecomputer's open (`[libdc INFO] … Purge: direction=3`, the first `[OUTBOUND]` / `[INBOUND]` packets) → `Fingerprint <hex> for <serial>: DC_STATUS_SUCCESS` or `No fingerprint for …` (DEVINFO) → the download (packets, progress) → `Download ended with DC_STATUS_SUCCESS after N dives …` → the close (the protocol's exit command, the `closeFlush`) → `[BLE CONNECT] Closing …` → `[DISCONNECT] …`.

**Known benign noise:** `Purge: direction=3` (libdivecomputer logs every purge; 13 families purge at every open attempt); OSTC (`hw_ostc3.c`) `Unexpected empty header found.` once per empty logbook slot; `[BLE TIMEOUT]` changes; on the i300C, a first read that waits the 5 s first-read floor.

**Purge revert rule (`DECISIONS.md` L5).** A `[BLE READ] Purge: N unread bytes discarded after …` line followed by a read timeout, near a failure that did not happen in a 2.2 build made before `d09f8a3` (2026-11-14, the purge change; the device answered late and ignored the resend), points at `d09f8a3`: revert that commit alone (with a device test), not the libdivecomputer sync. The first 2.2 beta builds (165) predate the purge change, so a regression seen in every 2.2 build points to the engine cutover (`786a2ce`), not to the purge.

## Device test matrix

"Device" = a real download with the current DiveComputerKit; "golden" = the parser only, against files the old library produced (no transport). Beta results are from build 2.2 (165 and later).

| Model | Family | How verified | Date | Result | Notes |
|---|---|---|---|---|---|
| Shearwater Perdix 2 | shearwaterPetrel | Owner's unit, device; golden | 2026-11-06 cutover; 2026-11-13/14; 2026-11-20 | OK | Downloads after the purge change, protocol V1; nothing dropped by purges. libdivecomputer `0194f09` (2026-11-20): incremental sync identical to the 2.2 build (same command sequence, no new dives); Download All Dives read 3 manifest pages and 105 dives, all merged, no deleted record in the manifest (the fixed case is not exercised by this unit). 2026-11-22, macOS, held by LightBlue (`DECISIONS.md` L9): listed through `[BLE SCAN]` (not listed before the change), opened and downloading over the shared link until cancelled; the cancel's exit command also disconnected LightBlue |
| Shearwater Perdix 3 | shearwaterPetrel | Owner's unit, device; golden | 2026-11-06; 2026-11-13/14 | OK | Downloads after the purge change, protocol V2; cancel tested at cutover |
| Shearwater Peregrine | shearwaterPetrel | Owner's unit, device at cutover; golden (two sets from that unit: one from an export, one downloaded over Bluetooth) | 2026-11-06 | OK | |
| Aqualung i300C | oceanicAtom2 | Owner's test unit, device; golden | 2026-11-06; 2026-11-13/14; 2026-11-22 | OK | Open, first-read floor and retry purges; cancel mid-answer led to the close quiet wait. 2026-11-22, macOS, bonded at the OS level (`DECISIONS.md` L9): while held by LightBlue, listed through `[BLE SCAN]` (GAP name resolves to the i300C) and downloading until cancelled; once LightBlue disconnected, found again through its advertisement and downloading until cancelled; a complete download while LightBlue held it (idle): 7 dives imported, no read or write error, watermark saved |
| Aqualung i300C (×2, one set to imperial units) | oceanicAtom2 | A beta tester, device | 2026-11-11 | OK | Pairing with access code, cutoff, new dives only, Download All merge |
| Mares Puck Pro via Bluelink Pro | maresIconHD | A beta tester, device | 2026-11-11 | OK | Before the purge change; a Mares trace with it is still wanted (retry-purge family) |
| Shearwater Petrel 3 (CCR) | shearwaterPetrel | A beta tester, device; golden (1 CCR dive) | 2026-11-11 | OK | |
| Shearwater Petrel 2 | shearwaterPetrel | Golden only (1 CCR deco dive) | 2026-11-03 | Pass | |
| Heinrichs Weikamp OSTC Plus ("OSTC+ BLE") | hwOstc3 | A beta tester, device | 2.1: failed; 2.2: OK; trace 2026-11-18 | OK on 2.2 | 2.1 (old library) failed with an IO error at open. The trace shows the u-blox service `2456E1B9-…D701` with one characteristic `…D703` for both write and notify, firmware 3.38, the open-time purge OK. OSTCs on the Telit/Stollmann service (`FEFB`) are untested: UART credit flow control is not implemented and might be needed for Telit-chip units (unverified) |
| Suunto EON Steel | suuntoEonSteel | Golden only (a beta tester's MacDive logbook) | 2026-11-03 | Pass | No device test (EON Core, D5 not covered at all) |
| Scubapro G2 | uwatecSmart | Golden only (1 dive) | 2026-11-03 | Pass | No device test |

**No device test and no golden:** Oceanic big-page models (i770R, A300CS, ProPlus X, F11, ProPlus 3 — the purge quiet wait on a real late reply is untested), Aqualung i330R / Apeks DSX (pelagicI330R: PIN / access-code flow tested only with a fake provider), the other Mares models, Cressi (cressiGoa), Divesoft, Ratio (diveSystem), Halcyon Symbios, Seac, Deep Six, Deepblu, Oceans S1, McLean. These rely on libdivecomputer itself.

**Open asks:** a BLE trace from a Mares user (retry-purge family), from a big-page Oceanic user, and from an i330R / DSX user (`DECISIONS.md` O2, L5).
