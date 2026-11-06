# Vendored libdivecomputer

This target is [libdivecomputer](https://github.com/libdivecomputer/libdivecomputer) (LGPL 2.1, see `COPYING`), compiled directly as a SwiftPM C target and linked statically into BlueDive (`Docs/DECISIONS.md`, Q1). Only `shim/`, `include/dc_shim.h`, `include/CLibDiveComputer.h`, `include/module.modulemap` and this file are BlueDive's; everything else is upstream.

## Current snapshot

| Field | Value |
|---|---|
| Upstream commit | `9e6c3c8328562b9b82abce7b476d86e79046d446` (2026-09-11, "Add missing fields to the i770R parser") |
| Version (`version.h`) | 0.10.0 |
| Taken from | libdc-swift `working` @ `fd5b0db` (the copy BlueDive shipped), unchanged (`Docs/DECISIONS.md`, O5) |
| Vendored on | 2026-11-02 |

### Verification against upstream (2026-11-02)

`diff -r` of this tree against a clone of upstream at `9e6c3c8`:

| Path | Result |
|---|---|
| `src/` | **Identical**, except `src/libdivecomputer.rc` (Windows resource, not copied) |
| `include/libdivecomputer/` | **Identical**, except `version.h` (hand-generated, see below) and `Makefile.am` (not copied) |
| `COPYING`, `README`, `Makefile.am` | Identical |
| `configure.ac`, `NEWS` | **Older than upstream** (left as shipped): `configure.ac` still says minor version 9 and uses `AC_PROG_CC_C99` unconditionally; `NEWS` lacks the 0.9.0 entry. Neither file is compiled. Take upstream's copies at the next sync. |

No local C patches are applied.

## Files not copied / excluded

| File | Reason |
|---|---|
| `src/libdivecomputer.rc` | Windows resource script |
| `.github/`, `.travis.yml`, `.gitignore` | Upstream CI and autotools ignore rules |
| `src/serial_win32.c` | Present, excluded in `Package.swift` (Windows only) |
| `src/Makefile.am`, `src/libdivecomputer.symbols`, `include/libdivecomputer/Makefile.am`, `include/libdivecomputer/version.h.in`, root `Makefile.am`, `configure.ac`, `NEWS`, `README`, `COPYING`, `libdivecomputer.pc.in` | Present, excluded in `Package.swift` (autotools / documentation) |

`hw_frog.c/.h` no longer exist upstream (merged into `hw_ostc3.c`).

## version.h

Autotools is not run, so `include/libdivecomputer/version.h` is derived by hand from `version.h.in` using `m4_define([dc_version_major|minor|micro], …)` in upstream's `configure.ac`. Regenerate it at every sync.

## Build settings (`Package.swift`)

Defines: `ENABLE_LOGGING`, `HAVE_PTHREAD_H`, `HAVE_CLOCK_GETTIME`, `HAVE_LOCALTIME_R`, `HAVE_GMTIME_R`, `HAVE_TIMEGM`, `HAVE_STRUCT_TM_TM_GMTOFF`, `HAVE_STRERROR_R`; `HAVE_IOKIT_SERIAL_IOSS_H` on macOS only. Never define `HAVE_VERSION_SUFFIX` or `ENABLE_PTY`. Warnings silenced for this target only: `-Wno-shorten-64-to-32`, `-Wno-macro-redefined` (upstream's `DEBUG` log macro). Links `libm`.

## Sync procedure

Follow `Docs/ARCHITECTURE.md` §10:

1. Clone upstream at the chosen commit.
2. Replace `src/` and `include/libdivecomputer/` (and the root files) with upstream's, keeping BlueDive's files listed above and dropping `src/libdivecomputer.rc` and the hidden files (`.github/`, `.travis.yml`, `.gitignore`).
3. Regenerate `version.h`, then update this file (commit, date, version, verification table).
4. Review the C diff: new backends, `DC_FAMILY_*`, descriptor rows and BLE filters, `DC_IOCTL_*`, `dc_sample_type_t` / `dc_field_type_t` members.
5. Build for iOS and My Mac and run `swift test`. `CatalogConsistencyTests` list catalog rows to add. Re-run golden parity: expected changes are reviewed and re-blessed deliberately.
6. Run a device smoke test.
