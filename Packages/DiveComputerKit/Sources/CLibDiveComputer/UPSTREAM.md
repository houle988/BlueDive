# Vendored libdivecomputer

This target is [libdivecomputer](https://github.com/libdivecomputer/libdivecomputer) (LGPL 2.1, see `COPYING`), compiled directly as a SwiftPM C target and linked statically into BlueDive (`Docs/DECISIONS.md`, Q1). Only `shim/`, `include/dc_shim.h`, `include/CLibDiveComputer.h`, `include/module.modulemap` and this file are BlueDive's; everything else is upstream.

## Current snapshot

| Field | Value |
|---|---|
| Upstream commit | `14f92934c0aedbba7a5aafe8915e8a96d944335c` (2026-11-12, "Retry a corrupt flash read on the Aqualung i330R and Apeks DSX") |
| Version (`version.h`) | 0.10.0 (upstream `0.10.0-devel`; the suffix is not used, see below) |
| Previous snapshot | `9e6c3c8` (2026-09-11), taken from libdc-swift `working` @ `fd5b0db` (`Docs/DECISIONS.md`, O5) |
| Synced on | 2026-11-13 |

### Changes since the previous snapshot

| Upstream commit | File | Change |
|---|---|---|
| `885c1cf` | `src/mares_iconhd.c` | Detects a NAK packet and reads its error code |
| `b33112b` | `src/mares_iconhd.c` | A dive whose data is unavailable (`0x08000020`) is returned with its header only instead of ending the download |
| `2c40452` | `src/oceanic_atom2_parser.c` | Apeks DSX: corrected helium offset (changes parsed gas mixes of DSX dives) |
| `14f9293` | `src/pelagic_i330r.c` | i330R / DSX: a failed flash read (protocol error or timeout) is retried up to 3 times, with a 1 s sleep and an input purge, which BlueDive implements (`DCIOStream` forwards it to `BLEPeripheralLink.purge`, which discards the queued notifications once the device is quiet; `Docs/DECISIONS.md`, L5) |

No new backends, `DC_FAMILY_*`, descriptor rows, BLE filters, `DC_IOCTL_*`, `dc_sample_type_t` or `dc_field_type_t` members.

### Verification against upstream (2026-11-13)

`diff -r` of this tree against a clone of upstream at `14f9293`:

| Path | Result |
|---|---|
| `src/` | **Identical**, except `src/libdivecomputer.rc` (Windows resource, not copied) |
| `include/libdivecomputer/` | **Identical**, except `version.h` (hand-generated, see below) |
| `COPYING`, `README`, `NEWS`, `configure.ac`, `Makefile.am`, `libdivecomputer.pc.in` | Identical |

No local C patches are applied.

## Files not copied / excluded

| File | Reason |
|---|---|
| `src/libdivecomputer.rc` | Windows resource script |
| `.github/`, `.travis.yml`, `.gitignore` | Upstream CI and autotools ignore rules |
| `src/serial_win32.c` | Present, excluded in `Package.swift` (Windows only) |
| `src/Makefile.am`, `src/libdivecomputer.symbols`, `include/libdivecomputer/Makefile.am`, `include/libdivecomputer/version.h.in`, root `Makefile.am`, `configure.ac`, `NEWS`, `README`, `COPYING`, `libdivecomputer.pc.in` | Present, excluded in `Package.swift` (autotools / documentation) |

**Upstream paths intentionally not vendored** (a `diff -r` of the whole tree lists them as "Only in" the clone): `examples/`, `doc/`, `contrib/`, `m4/`, `include/Makefile.am`, and the VCS and CI metadata (`.git/`, `.github/`, `.travis.yml`, `.gitignore`).

**BlueDive-only files in the vendored tree** (listed as "Only in" this folder): `shim/` (`dc_shim.c`), `include/dc_shim.h`, `include/CLibDiveComputer.h`, `include/module.modulemap` and this file (`UPSTREAM.md`).

`hw_frog.c/.h` no longer exist upstream (merged into `hw_ostc3.c`).

## version.h

Autotools is not run, so `include/libdivecomputer/version.h` is derived by hand from `version.h.in` using `m4_define([dc_version_major|minor|micro], …)` in upstream's `configure.ac`. `DC_VERSION` omits `dc_version_suffix` (e.g. `devel`). Regenerate it at every sync.

## Build settings (`Package.swift`)

Defines: `ENABLE_LOGGING`, `HAVE_PTHREAD_H`, `HAVE_CLOCK_GETTIME`, `HAVE_LOCALTIME_R`, `HAVE_GMTIME_R`, `HAVE_TIMEGM`, `HAVE_STRUCT_TM_TM_GMTOFF`, `HAVE_STRERROR_R`; `HAVE_IOKIT_SERIAL_IOSS_H` on macOS only. Never define `HAVE_VERSION_SUFFIX` or `ENABLE_PTY`. Warnings silenced for this target only: `-Wno-shorten-64-to-32`, `-Wno-macro-redefined` (upstream's `DEBUG` log macro). Links `libm`.

## Sync procedure

This is the **single authoritative checklist** (`Docs/ARCHITECTURE.md` §10 points here). The sync is manual: there is no script. An update is its own commit (`chore: sync libdivecomputer to <short sha>`), made only when the owner asks.

1. **Clone upstream** at the chosen commit, outside the repository: `git clone https://github.com/libdivecomputer/libdivecomputer /tmp/ldc && git -C /tmp/ldc checkout <sha>`.
2. **Copy, never patch.** Replace the upstream files of this folder with upstream's: `src/` (whole folder, so removed upstream files disappear), `include/libdivecomputer/` (whole folder, but put the hand-generated `version.h` back, step 3), and the root files `COPYING`, `NEWS`, `README`, `configure.ac`, `Makefile.am`, `libdivecomputer.pc.in`. **Keep BlueDive's files**: `shim/`, `include/dc_shim.h`, `include/CLibDiveComputer.h`, `include/module.modulemap` and this file — do not `rsync --delete` the `include/` folder itself, which would remove them. Do not copy `src/libdivecomputer.rc` or the hidden files (`.github/`, `.travis.yml`, `.gitignore`). No local C patches (`Docs/DECISIONS.md`, Q1/O5): a fix BlueDive needs goes upstream or into Swift.
3. **Regenerate `version.h`** from `include/libdivecomputer/version.h.in` with the numbers of `configure.ac`'s `m4_define([dc_version_major], …)`, `dc_version_minor`, `dc_version_micro` (not `AC_INIT`, which only receives the `dc_version` macro). `DC_VERSION` omits `dc_version_suffix`. Update `LibraryBuildTests.versionMatchesVendoredSnapshot` if the number changes.
4. **Check the tree**: run `diff -r` only on the vendored paths of the verification table: `src/`, `include/libdivecomputer/` and the root files `COPYING`, `README`, `NEWS`, `configure.ac`, `Makefile.am`, `libdivecomputer.pc.in` (e.g. `diff -r /tmp/ldc/src src`, `diff -r /tmp/ldc/include/libdivecomputer include/libdivecomputer`, then `diff` per root file). The expected output is only the `version.h` difference and `src/libdivecomputer.rc` ("Only in" the clone), the entries of "Files not copied"; anything else is a copy mistake. A diff of the whole tree also lists the paths under "Upstream paths intentionally not vendored" and "BlueDive-only files", which is expected. If a new upstream file is Windows-only or autotools-only, add it to `exclude:` in `Package.swift`.
5. **Review the C diff and add the catalog rows** (`git diff --stat` and the diff itself): new backends (new `.c` files are compiled automatically, `sources: ["src", "shim"]`), `DC_FAMILY_*`, descriptor rows and BLE filters in `descriptor.c`, `DC_IOCTL_*` in `ble.h` / `ioctl.h`, new `dc_sample_type_t` / `dc_field_type_t` / event members (parser work in `SampleAccumulator` / `FieldReader`), changed iostream calls (`purge`, `poll`, `sleep`, timeouts) and retry logic, which the BLE layer must honour (see `Docs/DECISIONS.md` L5 for how `14f9293`'s purge was handled). Record each relevant commit in "Changes since the previous snapshot". `CatalogConsistencyTests.everyBLEDescriptorIsInCatalog` (the tripwire this step refers to) fails on a new BLE descriptor of a supported family and names it. Add each one by following `Docs/ADDING_A_DIVE_COMPUTER.md` (case B, then case A; case C for a new `DC_FAMILY_*`): catalog row, name resolution, service UUID, icon. The catalog name is persisted (`"<vendor> <product>"`, trimmed) and never renamed afterwards. `legacyModelsAreKept` and `legacyServiceUUIDsAreKept` accept additions but fail if an old-library model is removed, renamed or reordered, or an old service UUID removed; do not edit `Tests/DiveComputerKitTests/Fixtures/legacy-catalog.json`: it is the old library's record.
6. **Build** the package and the app for an iOS destination and **My Mac**, and run `swift test` in `Packages/DiveComputerKit` (`Docs/TESTING.md`).
7. **Golden parity**: run `GoldenParityTests` once per fixture set (`DCK_GOLDEN_DIR`, `Docs/TESTING.md`). The goldens **cannot be re-blessed with DiveComputerKit**: they were produced by the external golden harness running the **old** LibDCSwift (`Docs/GOLDEN_FORMAT.md`), and regenerating them with the new code would make the test compare the code with itself. When an upstream parser change alters output (e.g. `2c40452`, DSX helium), explain each difference from the upstream commit and record it as an owner-approved deviation in `GOLDEN_FORMAT.md` ("Accepted deviations", implemented in the golden comparison), or confirm that no fixture exercises it — never overwrite the golden files.
8. **Mapper parity**: run `BlueDiveTests/DiveImportMapperParityTests` and `DiveImportMapperTests` (`BLUEDIVE_PARITY_DIR`, `Docs/TESTING.md`), as CLAUDE.md requires for any change reaching the mapping.
9. **Update this file**: upstream commit, date, version, previous snapshot, the changes table and the verification table.
10. **Device smoke test** on at least one owner's unit (Shearwater and the i300C when a shared file such as `iostream.c` or `packet.c`, or their backends, changed), with BLE Diagnostic Logging on; keep the trace outside the repository (`~/BlueDive-Fixtures/traces`).
