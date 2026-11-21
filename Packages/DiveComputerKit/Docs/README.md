# DiveComputerKit — Design documents

DiveComputerKit is the BlueDive-owned replacement for the LibDCSwift package (fork of deepsealabs/libdc-swift). It talks to dive computers over Bluetooth LE and parses their dives with the vendored libdivecomputer C library. It replaced LibDCSwift in the app on 2026-11-06 (commit `786a2ce`); libdivecomputer is upstream `14f9293`.

**New here? Read [`START_HERE.md`](START_HERE.md) first.**

## Reading order

1. [`START_HERE.md`](START_HERE.md) — current state, where things live, private data, links.
2. [`DECISIONS.md`](DECISIONS.md) — owner decisions; **take precedence over the architecture where they differ**.
3. [`ARCHITECTURE.md`](ARCHITECTURE.md) — the "As built" sections first (`START_HERE.md` lists them); the rest is the 2026-11-02 plan.
4. [`../Sources/CLibDiveComputer/UPSTREAM.md`](../Sources/CLibDiveComputer/UPSTREAM.md) — the vendored snapshot and the sync checklist.
5. [`MAPPER.md`](MAPPER.md), [`TESTING.md`](TESTING.md) and [`GOLDEN_FORMAT.md`](GOLDEN_FORMAT.md) — the app-side mapping; tests, BLE logs, device matrix; parity data. [`ADDING_A_DIVE_COMPUTER.md`](ADDING_A_DIVE_COMPUTER.md) when adding a model or family.
6. [`BEHAVIOURAL_SPEC.md`](BEHAVIOURAL_SPEC.md) and [`CONSUMER_ANALYSIS.md`](CONSUMER_ANALYSIS.md) — the **old** library and the app **before** the cutover (historical); [`LIBDIVECOMPUTER_REFERENCE.md`](LIBDIVECOMPUTER_REFERENCE.md) — C API reference.

## Documents

| File | Content | Status |
|---|---|---|
| [`START_HERE.md`](START_HERE.md) | Orientation for a new session: state, layout, private data, rules | Current (2026-11-19) |
| [`DECISIONS.md`](DECISIONS.md) | Owner decisions (Q1–Q6, O1–O7) and later decisions (L0–L5), Phase 4 implementation notes | Current; project owner |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The 2026-11-02 plan (layout, API, per-layer design, persistence, app integration, testing, phases, risks, parity checklist) with "As built" notes and sections | Plan + as-built notes |
| [`MAPPER.md`](MAPPER.md) | `DiveImportMapper` as built: `makeDive`, `merge`, tanks, gases, duration, TTS/RBT | Current (2026-11-19) |
| [`TESTING.md`](TESTING.md) | Running the tests, test inventory, reading a BLE diagnostic log, device test matrix | Current (2026-11-19) |
| [`ADDING_A_DIVE_COMPUTER.md`](ADDING_A_DIVE_COMPUTER.md) | Checklist for adding a dive computer: new model in a supported family, model from a libdivecomputer sync, new family; validating without the unit; definition of done | Current (2026-11-20) |
| [`GOLDEN_FORMAT.md`](GOLDEN_FORMAT.md) | Golden-file procedure, canonical rendering and schema, parity results, accepted deviations | Current |
| [`../Sources/CLibDiveComputer/UPSTREAM.md`](../Sources/CLibDiveComputer/UPSTREAM.md) | Vendored libdivecomputer snapshot, verification against upstream, build settings, **sync checklist** | Current |
| [`LIBDIVECOMPUTER_REFERENCE.md`](LIBDIVECOMPUTER_REFERENCE.md) | Developer reference for the libdivecomputer C API: build integration, custom iostream, BLE ioctls, fields and samples, events, status codes, fingerprints, sync risks | Reference (2026-11-02, corrections marked) |
| [`BEHAVIOURAL_SPEC.md`](BEHAVIOURAL_SPEC.md) | Plain-English functional specification of the **old** LibDCSwift (`working` @ `fd5b0db`): behaviours, constants, device quirks, BlueDive customizations. Contains no code | **Historical snapshot** of the old library at migration time; still the clean-room source for "what the old code did" |
| [`CONSUMER_ANALYSIS.md`](CONSUMER_ANALYSIS.md) | How BlueDive used LibDCSwift before the cutover (branch `working-2.1-BLE` @ `5597382`): symbol inventory, data flow, field mapping, data-compatibility constraints | **Historical snapshot** of the app before the cutover; line numbers no longer match |

## Clean-room provenance

LibDCSwift is licensed under the LGPL 2.1 and was mostly written by a third party. To keep DiveComputerKit an independent work:

- The old wrapper's source was read **only** to write `BEHAVIOURAL_SPEC.md`, which describes behaviour in plain language and contains no code.
- `ARCHITECTURE.md` and the implementation are based only on that specification, the libdivecomputer headers and sources, and BlueDive's own code.
- No code is copied from LibDCSwift. Facts (UUIDs, timeouts, model IDs, name patterns) are reused as data.
- This still applies: never read LibDCSwift sources (GitHub, DerivedData, SourcePackages) for new work; the libdivecomputer sources under `Sources/CLibDiveComputer` are fine (CLAUDE.md).

This is a good-faith process record, not legal advice.

## Licensing

- DiveComputerKit's own code is covered by the BlueDive Source Available License (repository `LICENSE`).
- libdivecomputer (`Sources/CLibDiveComputer`) is LGPL 2.1, vendored unchanged from https://github.com/libdivecomputer/libdivecomputer, statically linked (see `DECISIONS.md`, Q1).
