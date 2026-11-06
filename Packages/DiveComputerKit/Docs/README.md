# DiveComputerKit — Design documents

DiveComputerKit is the BlueDive-owned replacement for the LibDCSwift package (fork of deepsealabs/libdc-swift). It talks to dive computers over Bluetooth LE and parses their dives with the vendored libdivecomputer C library.

## Documents

| File | Content | Author |
|---|---|---|
| [`DECISIONS.md`](DECISIONS.md) | Owner decisions on the open questions and remaining open items. **Takes precedence over the architecture where they differ.** | Project owner |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Architecture and implementation plan: layout, public API, per-layer design, persistence, app integration, testing, phases, risks, sync procedure, parity checklist. | Fable agent, 2026-11-02 |
| [`BEHAVIOURAL_SPEC.md`](BEHAVIOURAL_SPEC.md) | Plain-English functional specification of the old LibDCSwift (`working` @ `fd5b0db`): behaviours, constants, device quirks, BlueDive customizations. Contains no code. | Fable agent, 2026-11-02 |
| [`CONSUMER_ANALYSIS.md`](CONSUMER_ANALYSIS.md) | How BlueDive uses LibDCSwift today: symbol inventory, data flow, field mapping, data-compatibility constraints. | Fable agent, 2026-11-02 |
| [`GOLDEN_FORMAT.md`](GOLDEN_FORMAT.md) | Golden-file procedure, canonical rendering and schema used to prove parser parity (Phase 0a / Phase 3 gate). | Project |
| [`LIBDIVECOMPUTER_REFERENCE.md`](LIBDIVECOMPUTER_REFERENCE.md) | Developer reference for the libdivecomputer C API: build integration, custom iostream, BLE ioctls, fields and samples, events, status codes, fingerprints, sync risks. | Fable agent, 2026-11-02 |

## Clean-room provenance

LibDCSwift is licensed under the LGPL 2.1 and was mostly written by a third party. To keep DiveComputerKit an independent work:

- The old wrapper's source was read **only** to write `BEHAVIOURAL_SPEC.md`, which describes behaviour in plain language and contains no code.
- `ARCHITECTURE.md` and the implementation are based only on that specification, the libdivecomputer headers and sources, and BlueDive's own code.
- No code is copied from LibDCSwift. Facts (UUIDs, timeouts, model IDs, name patterns) are reused as data.

This is a good-faith process record, not legal advice.

## Licensing

- DiveComputerKit's own code is covered by the BlueDive Source Available License (repository `LICENSE`).
- libdivecomputer (`Sources/CLibDiveComputer`) is LGPL 2.1, vendored unchanged from https://github.com/libdivecomputer/libdivecomputer, statically linked (see `DECISIONS.md`, Q1).
