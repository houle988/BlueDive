# DiveComputerKit — start here

For a session with no prior context. Written 2026-11-19; the code is the truth where this drifts.

## Current state

- **Post-cutover.** DiveComputerKit replaced LibDCSwift in BlueDive on 2026-11-06 (`786a2ce` "feat: replace LibDCSwift with the in-house DiveComputerKit package", `4c04b03` docs/licence), hardened on 2026-11-07 (`48e03d9`). The app links no LibDCSwift code or package.
- **libdivecomputer** is upstream `14f9293` (2026-11-12), version 0.10.0, copied unchanged with no local C patches (synced 2026-11-13, `eff1017`; `../Sources/CLibDiveComputer/UPSTREAM.md`).
- **Latest transport change:** `purge` discards unread input once the device is quiet (`d09f8a3`, 2026-11-14; `DECISIONS.md` L5). Revert rule in `TESTING.md`, "Reading a BLE diagnostic log".
- **Parity:** all eight golden sets pass (re-run 2026-11-19, `GOLDEN_FORMAT.md`); the mapper parity tests were unchanged at the `14f9293` sync (`eff1017`).
- **Not built from the plan:** trace replay, `BluetoothSyncController`, the sync script, the parser log context (`ARCHITECTURE.md`, "As built").

## Reading order

1. `DECISIONS.md` — owner decisions; they override the architecture.
2. `ARCHITECTURE.md` — the "As built" sections first (header table, §2 file tree, §3 public API, §4.4 outcome note, §6 cutoff note, §10). The rest is the 2026-11-02 plan.
3. `../Sources/CLibDiveComputer/UPSTREAM.md` — snapshot and the sync checklist.
4. `MAPPER.md` (DiveData → Dive), `TESTING.md` (tests, logs, device matrix), `GOLDEN_FORMAT.md` (parity data), `ADDING_A_DIVE_COMPUTER.md` (new model or family checklist).
5. `BEHAVIOURAL_SPEC.md` and `CONSUMER_ANALYSIS.md` describe the **old** library and the app **before** the cutover (historical); `LIBDIVECOMPUTER_REFERENCE.md` is a C API reference.

## Rules that bite

- **Clean room:** never read LibDCSwift sources (GitHub, DerivedData, SourcePackages). Work from `BEHAVIOURAL_SPEC.md`, the libdivecomputer headers and sources in `Sources/CLibDiveComputer`, and BlueDive's own code.
- **No C patches:** libdivecomputer is copied, never edited. Updates follow `UPSTREAM.md` and are their own commit.
- **Threading:** CoreBluetooth runs on the package's private queue; each download runs libdivecomputer on its own session thread (every C object created, used and freed there; waits are `NSCondition` waits, plus the bounded close flush, `BLETiming.closeFlush`). The app sees only `DiveComputerManager` (`@MainActor`) and the `SessionEvent` stream. Code the session thread calls (`BLEPairingProvider`, `BLEDiagnosticSession`) is `nonisolated` and touches no `@MainActor` state (`UserPreferences.shared` included).
- **`BLETiming`:** every constant works around a device behaviour; change one only with a device test and a BLE trace.
- **Persisted formats never change:** `DeviceFamily` raw values, catalog names (`Dive.computerName`, icons), `%08x` serials, fingerprint bytes, the `com.libdc.storedDevices` JSON.
- **No data-model change** without the owner's instruction (CLAUDE.md).

## Where things live

| What | Where |
|---|---|
| Package | `Packages/DiveComputerKit/` (file tree: `ARCHITECTURE.md` §2, as built) |
| Catalog, name resolution | `Sources/DiveComputerKit/Catalog/` (`DeviceCatalog.supportedModels`, `BLENameResolver`, `BLEServiceCatalog`) |
| BLE link, timings | `Sources/DiveComputerKit/Transport/` (`BLEPeripheralLink`, `BLETiming`) |
| libdivecomputer callbacks, ioctls | `Sources/DiveComputerKit/IOStream/` |
| Session (open, DEVINFO, fingerprint, foreach, outcome) | `Sources/DiveComputerKit/Session/` |
| Parser | `Sources/DiveComputerKit/Parsing/DiveParser.swift`, `SampleAccumulator.swift`, `FieldReader.swift` |
| App: scanner, download flow | `BlueDive/Bluetooth/BluetoothScannerView*.swift` (`+BLE`: request and event loop; `+Import`: fingerprint table, import, persist/delete) |
| App: DiveData → Dive | `BlueDive/Bluetooth/DiveImportMapper.swift` (`MAPPER.md`) |
| Known devices | `BlueDive/Bluetooth/KnownDeviceStore.swift`: `DeviceStorage` / `StoredDevice`, UserDefaults key `com.libdc.storedDevices` (LibDCSwift's format, kept so existing devices keep working); one identifier per real serial, written only from what the device reports |
| Watermarks (fingerprints) | SwiftData `DeviceFingerprint` only (`BlueDive/Models/DeviceFingerprint.swift`) |
| Pelagic PIN / access codes | `BlueDive/Bluetooth/BLEPairingProvider.swift`: `BLEPairingProvider`, Keychain `BLEAccessCodeKeychain` (service `app.bluedive.divecomputer.accesscode`, account = advertised name) |
| BLE diagnostic log | `BlueDive/Bluetooth/BLEDiagnosticSession.swift` (`TESTING.md`) |
| Device icons | `BlueDive/Assets.xcassets/DeviceIcons/`, procedure in `DIVE_COMPUTER_ICONS.md` (repository root) |
| Adding a model or family (every file and test it touches) | `ADDING_A_DIVE_COMPUTER.md` |
| Tests | `Packages/DiveComputerKit/Tests/DiveComputerKitTests/`; app: `BlueDiveTests/DiveImportMapper*Tests.swift` (`TESTING.md`) |

## Private data (outside the repository)

Golden files, mapper fixtures, BLE traces and dive exports are the owner's and beta testers' dive data (`DECISIONS.md` Q3). They are **never** committed, never copied into the package (`Tests/DiveComputerKitTests/Fixtures/` is bundled into the test target and holds only synthetic data), and are passed to tests by environment variable. Neither folder below is in git: **both must be backed up by the owner.**

- `~/BlueDive-Fixtures/` — test data:
  - `golden*/` — one folder per golden set (eight in 2026-11; `GOLDEN_FORMAT.md`), each a `manifest.json` (with `timeZone`) plus one `<serial>_<sha16>.json` per dive. Used through `DCK_GOLDEN_DIR`.
  - `mapper-parity/` — one subfolder per computer with `export.bluedive` (BlueDive XML from the old version, raw data included) and `fingerprints.bluedive` (Fingerprint XML with the stored family and model). Used through `BLUEDIVE_PARITY_DIR`.
  - `exports/` — BlueDive XML exports the golden harness reads; `traces/` — `BlueDive_BLE_*.log` files.
- `~/Xcode/libdc-golden-harness/` — the external golden harness: a throwaway macOS Swift package that links the **old** LibDCSwift (`fd5b0db`) and calls its public parser as a black box to produce the goldens (`GOLDEN_FORMAT.md`). It cannot be rebuilt from this repository; goldens are never regenerated with DiveComputerKit.

When investigating a user's file: work on a copy in `/tmp`, never commit it, delete it when done (CLAUDE.md).

## Common tasks

- Run the tests → `TESTING.md`, "Running the tests".
- Update libdivecomputer → `UPSTREAM.md`, "Sync procedure".
- Read a tester's BLE log → `TESTING.md`, "Reading a BLE diagnostic log".
- Change how a downloaded dive becomes a `Dive` → `MAPPER.md`, then the mapper parity tests.
- Add a dive computer (new model, model from a sync, or new family) → `ADDING_A_DIVE_COMPUTER.md`.
