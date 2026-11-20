# Golden files — format and procedure (Phase 0a)

Golden files record what the **old** LibDCSwift parser produced for real dives, so the new `DiveParser` can be proven byte-identical before the app switches over (`ARCHITECTURE.md` §7, gate of Phase 3). They contain personal dive data and **never enter this repository** (`DECISIONS.md`, Q3).

## Producing them

The generator is a throwaway command-line tool **outside** the repository: `~/Xcode/libdc-golden-harness` (Swift package, macOS). It links libdc-swift at the exact revision BlueDive ships (`fd5b0db0fd8fe19d59a453939465ebf21e0d2aba`) and calls only its public parser, `GenericParser.parseDiveData`, as a black box.

1. With the **current** app (before the cutover), export the dives as BlueDive XML (raw dive computer data and fingerprints are included automatically). Optionally also export the known devices as Fingerprint XML (Settings → Bluetooth Import → Sync Fingerprints), which gives the stored family and model per serial.
2. Run:
   ```
   cd ~/Xcode/libdc-golden-harness
   swift run -c release GoldenHarness \
     --xml ~/BlueDive-Fixtures/exports/diver-a.xml \
     --xml ~/BlueDive-Fixtures/exports/diver-b.xml \
     --fingerprints ~/BlueDive-Fixtures/exports/fingerprints.xml \
     --out ~/BlueDive-Fixtures/golden \
     --tz America/Toronto
   ```
3. Check `manifest.json` and the console summary: dives parsed / failed / without raw data / without model, per computer.

Only dives with `<rawDiveComputerData>` can be used (Bluetooth imports since libdc-swift commit `a92ba0c`). Duplicate raw dives (same SHA-256) are written once.

## Family and model selection

For each dive the harness tries, in order:
1. the stored `familyID` / `modelID` for the dive's serial from the Fingerprint XML (`modelSource = "fingerprintXML"`);
2. the first `supportedModels` entry whose name equals the dive's `<computer>` (`modelSource = "catalogName"`).

The first pair that parses is recorded in `input.family` / `input.modelID`; failed earlier attempts are listed in `failedAttempts`. The new tests must parse with **exactly** `input.family` / `input.modelID`.

## Time zone

The parser builds `datetime` from local-time components, so the harness pins the zone (`--tz`, default `America/Toronto`) and records it in `manifest.json` (`timeZone`). The new tests must run with the same zone (set `TZ` and `NSTimeZone.default` before any date work).

## File layout

`<golden dir>/manifest.json` plus one file per dive, `<normalized serial>_<first 16 hex of SHA-256 of raw data>.json`.

## Canonical rendering

Both sides render with the same rules, and the comparison is **byte-equal, zero tolerance**:

- UTF-8 JSON, 2-space indentation, `": "` after keys, `,\n` between members, one trailing newline.
- Object keys sorted by byte order. Empty arrays `[]`, empty objects `{}`.
- Every `Double` is a JSON **string** with `%.17g` (exact IEEE-754 round-trip); `"inf"`, `"-inf"`, `"nan"`, `"0"`, `"-0"` for special values.
- Integers are JSON numbers. Absent optionals are `null`, and the key is always present.
- Strings escape `"`, `\`, `\n`, `\r`, `\t` and other control characters as `\u00XX`; everything else is literal.
- `[Int: Double]` dictionaries are arrays of `[key, value]` pairs sorted by key.
- Enumerations use the fixed names below, independent of either library's Swift type names.

## Schema (format 1)

```
{
  "format": 1,
  "input": {
    "exportFile", "computerName", "serial", "exportDate", "sourceImport": String,
    "family": DeviceFamily raw value, "modelID": Int, "modelSource": "fingerprintXML" | "catalogName",
    "rawData": base64, "rawDataSHA256": hex, "fingerprint": hex | null
  },
  "failedAttempts": [ { "family", "modelID", "error" } ],
  "output": DiveData | null,
  "error": { "kind", "status": Int | null } | null
}
```

`error.kind`: `parserCreationFailed`, `datetimeRetrievalFailed`, `sampleProcessingFailed`, `fieldRetrievalFailed`, `invalidDate` (the old `invalidParameters`); `status` is the `dc_status_t` value (e.g. -9 = DATAFORMAT).

**DiveData**: `number`, `datetime` (seconds since 1970, Double), `maxDepth`, `avgDepth`, `divetime`, `reportedDivetime?`, `temperature` (may be `"inf"`), `profile` [Point], `tankPressure` [Double], `gasMix?`, `gasMixCount?`, `gasMixes?` [GasMix], `salinity?`, `atmospheric?`, `surfaceTemperature?`, `measuredSurfaceTemperature?`, `minTemperature?`, `maxTemperature?`, `tankCount?`, `tanks?` [Tank], `diveMode?`, `decoModel?`, `location?`, `exitLocation?`, `rbt?`, `heartbeat?`, `bearing?`, `setpoint?`, `ppo2Readings` [{`sensor`, `value`}], `cns?`, `decoStop?` {`depth`, `time`, `type`}. The parser is called with dive number 1. `rawData` / `fingerprint` are inputs, not output.

**Point**: `time`, `depth`, `temperature?`, `pressure?`, `pressures` [[tank, bar]], `po2?`, `sensorPPO2` [[sensor, bar]], `pn2?`, `phe?`, `events` [String], `ndl?`, `decoStop?`, `decoTime?`, `tts?`, `currentGas?`, `cns?`, `rbt?`, `heartbeat?`, `bearing?`, `setpoint?`. `ProfileSample.reportedRBT` (added later, not in the former library's output) is deliberately not encoded.

**GasMix**: `helium`, `oxygen`, `nitrogen`, `usage`. **Tank**: `volume`, `workingPressure`, `beginPressure`, `endPressure`, `gasMix` (Int), `usage`. **DecoModel**: `type`, `conservatism`, `gfLow?`, `gfHigh?`, `description` (the persisted string). **Location**: `latitude`, `longitude`, `altitude?`.

Fixed names:

| Value | Names |
|---|---|
| event | `ascent`, `violation`, `decoStop`, `gasChange`, `bookmark`, `safetyStop`, `safetyStopMandatory`, `ceiling`, `po2`, `deepStop` |
| diveMode | `freedive`, `gauge`, `openCircuit`, `closedCircuit`, `semiClosedCircuit` |
| decoModel.type | `none`, `buhlmann`, `vpm`, `rgbm`, `dciem` |
| usage (gas and tank) | `none`, `oxygen`, `diluent`, `sidemount` |

## Parity results

**Fixture sets (2026-11-19).** Eight golden sets, each its own folder under `~/BlueDive-Fixtures` (outside the repository) with its own `manifest.json`, run one at a time through `DCK_GOLDEN_DIR` (`TESTING.md`). Described generically here; the folder names are the owner's and are not repeated in the repository:

| Set | Content | Cases |
|---|---|---|
| main | Owner's logbook: Shearwater Perdix 2 + Perdix 3 (row 2026-11-02) | 87 |
| CCR | A beta tester's Petrel 3 CCR dive (2026-11-03) | 1 |
| i300C | The owner's Aqualung i300C test unit (2026-11-06) | 78 |
| Perdix 3, second set | A second set of the owner's Perdix 3 dives | 30 |
| Peregrine (export) | The owner's Peregrine: 16 dives from a BlueDive 2.1 (163) XML export (2026-11-06) | 16 |
| Peregrine (Bluetooth) | The same Peregrine: 52 dives downloaded over Bluetooth with the old version (2026-11-06) | 52 |
| Petrel | One CCR decompression dive with a trimix diluent from a beta tester's Petrel 2 (2026-11-03) | 1 |
| MacDive logbook | A beta tester's logbook imported from MacDive (2026-11-03) | 801 |

The Perdix 3 second set has no dated row of its own below; the `eff1017` commit (2026-11-13) reports golden parity unchanged on 8 fixture sets, so it existed and passed by then.

| Date | Golden set | Result |
|---|---|---|
| 2026-11-02 | Owner's logbook: 68 Shearwater Perdix 2 + 19 Perdix 3 dives (43 115 profile points); 60 Peregrine and 8 Oceanic+ dives had no raw data | **87 / 87 byte-identical** after two fixes: a tank's unknown gas index is `4294967295` (`DC_GASMIX_UNKNOWN` unsigned, not -1), and `tanks` is an empty array (not nil) when the computer reports no tanks |
| 2026-11-03 | A beta tester's logbook (BlueDive XML of dives imported from MacDive, 2 134 dives, 1 042 with raw data): 87 Suunto EON Steel, 1 Scubapro G2, and 713 Shearwater blobs in MacDive's own format (not libdivecomputer's) that both parsers reject | **801 / 801 identical** (88 parsed dives byte-identical; 713 rejected with the same error and status), with the accepted deviation below |
| 2026-11-03 | One closed-circuit (CCR) dive from a beta tester's Shearwater Petrel 3, with a setpoint change and diluent + oxygen mixes | **1 / 1 byte-identical**: covers CCR dive mode, per-sample setpoints, voted PPO₂, diluent usage, CNS and the persisted deco-model text |
| 2026-11-03 | One CCR decompression dive with a trimix diluent from a beta tester's Shearwater Petrel 2 (advertised "Petrel", logged as "Shearwater Petrel" by BlueDive 1.10; model 3 given through a Fingerprint XML) | **1 / 1 byte-identical**: adds decompression stops and a trimix diluent |
| 2026-11-06 | Peregrine (export): 16 dives from the owner's Shearwater Peregrine (BlueDive 2.1 (163) XML export) | **16 / 16 byte-identical** |
| 2026-11-06 | The owner's Aqualung i300C test unit: 78 dives covering several years, downloaded over Bluetooth with the old version | **78 / 78 byte-identical**: first non-Shearwater family (Oceanic Atom 2 backend) |
| 2026-11-06 | Peregrine (Bluetooth): 52 dives from the same Peregrine, downloaded over Bluetooth with the old version | **52 / 52 byte-identical** |
| 2026-11-19 | All eight sets, re-run after the libdivecomputer `14f9293` sync (`eff1017`) and the purge change (`d09f8a3`), measured in the owner's session | **All pass**: main 87, CCR 1, i300C 78, Perdix 3 second set 30, Peregrine (export) 16, Peregrine (Bluetooth) 52, Petrel 1, MacDive logbook 801 (1 066 cases). No new accepted deviation. The only parser change in the range is the Apeks DSX helium offset (`2c40452`), and no set contains a DSX dive; the other changes are in the download code (Mares, i330R/DSX), which golden parity does not exercise |

## Accepted deviations

The comparison is byte-identical except for these documented, owner-approved differences (`GoldenDiff.applyAcceptedDeviations`):

| Field | Old library | DiveComputerKit | Why accepted |
|---|---|---|---|
| `gasMixCount`, `tankCount` | `0` when the computer does not report the count (e.g. EON Steel dives without gas data) | `nil` ("not reported") | Neither value is read by the app (the mapper counts the `gasMixes` / `tanks` arrays) nor stored; the Gas tab is unchanged. Owner decision 2026-11-03 |

## After a libdivecomputer sync

The goldens record the **old** library's output and are produced only by the external harness above. They are never regenerated with DiveComputerKit — that would compare the new code with itself. When an upstream parser change makes a golden differ, explain the difference from the upstream commit, then either fix the code or, with the owner's approval, add a row to "Accepted deviations" (and its rule to the golden comparison); the golden files themselves are never edited. Sync checklist: `Sources/CLibDiveComputer/UPSTREAM.md`.

Not yet covered by a golden (no dive in the sets exercises it): other families (Mares, OSTC, Suunto beyond the EON Steel, …), `tanks` when `DC_FIELD_TANK_COUNT` is unsupported (currently an empty array), Bühlmann with GF 0/0, VPM conservatism text, `gasMixes` when the count is 0, CCR bailout to open circuit, per-sensor PPO₂ readings, change-only setpoint computers (OSTC, Divesoft), GPS entry/exit, and sub-second sample times. Add users' exports from other families to close these.
