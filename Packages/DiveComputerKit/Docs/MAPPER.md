# DiveImportMapper — as built (2026-11-19)

`BlueDive/Bluetooth/DiveImportMapper.swift` turns a downloaded `DiveData` (DiveComputerKit, units: s, m, °C, bar) into the logbook's `Dive`. It is the only path from a Bluetooth download to a `Dive` (CLAUDE.md). This file describes the committed code; the 2026-11-02 plan is `ARCHITECTURE.md` §6. Tests: `TESTING.md` (`DiveImportMapperParityTests`, `DiveImportMapperTests`, `ProfileTimeTests`, `DiveDurationTests`).

## Shape

- `enum DiveImportMapper`, main-actor isolated (the app target's default, like `Dive`). It reads no view state, no `DeviceStorage` and no `UserPreferences`; it does log through `DiveComputerLog.shared`.
- `struct DiveImportContext` — captured once per import by `BluetoothScannerView.makeImportContext()` (`+Import.swift`): `deviceFamily` (stored device's family; nil = unknown), `catalogComputerName` (catalog name of the stored family + model), `connectedDeviceName`, `computerSerial` (stored serial, trimmed, nil when empty), `filterUnusedTanks` (Settings → Bluetooth Import, `@AppStorage("filterUnusedTanks")`, off by default), `importWeightUnit` (symbol of the user's weight unit).
- **Who calls what** (`+Import.swift`, the import loop): the downloaded dives are matched against the logbook by fingerprint + normalized serial (dives within the dedup window of the batch). A match is **merged** (`merge`) only in "Download all dives" mode, otherwise skipped; an unmatched dive becomes a new dive (`makeDive`) with the next dive number, the batch's diver name and the previous dive's end time (`datetime + (reportedDivetime ?? divetime)`, chained through the batch).
- Both entry points first call **`gasMixReferencesByPosition`** (below), then share the same helpers, so a re-download assigns gases and tanks exactly as the first download did.

## `makeDive(from:diveNumber:previousDiveEndTime:diverName:context:)`

| Dive field | From |
|---|---|
| `timestamp` | `datetime` |
| `maxDepth`, `averageDepth` | `maxDepth`, `avgDepth` (the parser already fell back to the profile's time-weighted average) |
| `duration` / `durationSeconds` | `applyDuration` (below) |
| `waterTemperature` | `temperature` when finite |
| `minTemperature` / `maxTemperature` | `minTemperature` / `maxTemperature` when finite, else the profile's min / max (min also falls back to `temperature`) |
| `airTemperature` | `measuredSurfaceTemperature` only — never `surfaceTemperature`, which falls back to the first sample's water temperature |
| `diveTypes` | `diveMode`: Freediving, Gauge, Open Circuit, Rebreather (CCR), Semi-Rebreather; none when not reported (no default) |
| `decompressionAlgorithm` | `decoModel.description` ("Bühlmann GF 40/85", …) |
| `cnsPercentage` | `cns`, else the last sample with CNS |
| `isDecompressionDive` | `decoStop.type == 2`, or any sample with a deco-stop depth or a `.decoStop` event |
| `decoStops` | `extractDecoStops`: one stop per depth (rounded to the metre) with the peak remaining time, deepest first; else the header's last deco sample if it is a deco stop (type 2) |
| `siteWaterType` | `waterType(forSalinity:)` when `salinity` is reported |
| `siteLatitude/Longitude/Altitude` | `location` when in range and not (0, 0) |
| `exitLatitude/Longitude` | `exitLocation`, same rule |
| `surfacePressure` | `atmospheric` (already in 0.4–1.2 bar, and validated again by `Dive.init`) |
| `surfaceInterval`, `isRepetitiveDive` | from `previousDiveEndTime`: "Xd Yh MMm" / "Yh MMm", repetitive under 24 h; "0h 00m" without a previous dive |
| `computerName` | catalog name, else connected name, else the localized "Dive Computer" |
| `computerSerialNumber` | `context.computerSerial` |
| units | `importDistanceUnit` "meters", temperature "°c", pressure "bar", volume "liters" (the library's units, stored as is); weight = `context.importWeightUnit` |
| `sourceImport` | "Bluetooth" |
| `rawDiveComputerData`, `fingerprintData` | `rawData`, `fingerprint` (attached by the session) |
| `profileSamples` | `consolidateProfilePoints`, then `remapProfileCurrentGas` |
| `tanks` | one of the four tank paths, then `applyGasSwitchUsageTimes` |

Site name, location, buddies, notes, rating stay empty for the user.

## `merge(_:into:context:)` — a re-download into an existing dive

**Replaced** from the computer: `maxDepth`, `averageDepth`, the duration (`applyDuration`), `waterTemperature`, `min/maxTemperature` (same rules as `makeDive`, written even when nil), `tanks` (below), `cnsPercentage`, `isDecompressionDive`, `profileSamples`, `decoStops`, `rawDiveComputerData`, `fingerprintData`, and `sourceImport` = "Bluetooth".

**Replaced only when the computer reports a value:** `decompressionAlgorithm`, `siteWaterType` (salinity), `surfacePressure` (`Dive.validatedSurfacePressure`; an earlier value is kept otherwise), entry and exit coordinates (valid, not (0, 0)), `computerName` (catalog name, else connected name, else kept).

**Only into an empty field:** `airTemperature` (from `measuredSurfaceTemperature`), so a value from Open-Meteo or the user is never overwritten.

**Kept:** everything else — timestamp, dive number, diver, site and location names, buddies, rating, notes, dive types, site altitude, serial, surface interval, the import units.

**Tank identity (since `75e502d`):** in every tank path the tank at the same **position** keeps its `id` and the user-set fields the computer does not provide (`volume` and `workingPressure` when the computer reports none, `tankMaterial`, `tankType`); usage times are recomputed from the fresh profile. A tank's format (`tankType`) is the user's when set, else the computer's diluent/oxygen flag (`tankType(forUsage:)`: the tank's own `usage`, else the `usage` of the gas mix the computer reports it is on — never of a mix matched by pressure inference or position; a gas-only tank takes its mix's; "Diluent" / "O2", nothing for none or sidemount), on a first download and a re-download alike. Exception, computer-tank and gas-mixes-only paths (`storedTanks`): when the tank count differs from the stored dive's ("Filter unused tanks" toggled between two downloads, or a CCR bailout an earlier version had put on the O₂ transmitter now getting its own tank), only the transmitter slots pair by position; a gas-only tank pairs with the stored gas-only tank of the same gas (O₂/He percentages, each used once, in order), then with the next leftover stored one, so a gas added or dropped by the rebuild does not move another tank's id and details; the transmitter count is the new download's (0 in the gas-mixes-only path). With an unchanged count every tank pairs by position, so a re-download of the same dive behaves as before and a gas the user edited never swaps two tanks' details. Repeated gases (an i300C reports an unset slot as 21 %) pair in order, which cannot tell two tanks of the same gas apart (neither could position). Known limit: a gas the user edited, when the count also changes, takes the next leftover stored tank, which may be another gas's. When none of the four tank paths applies (no tanks, no tank pressure, no gas mixes, and `gasMix` nil or 21), the existing tanks are left untouched.

## Duration — `applyDuration`

`reportedDivetime` (the computer's `DC_FIELD_DIVETIME`) when finite → `dive.setDuration(seconds:)` (seconds and rounded minutes); otherwise `dive.setDuration(minutes: Dive.roundedMinutes(fromSeconds: divetime))` — whole minutes from the last profile sample, with **no** seconds (that is the profile's length, not the computer's dive time). Never assigns the fields directly (CLAUDE.md "Dive Duration").

## Profile — `consolidateProfilePoints` and `remapProfileCurrentGas`

- Samples are grouped by time: the parser emits a point per interval plus separate points at the same time for events and synthesized gas changes. Per group: the first point is the base; events from all points are merged without duplicates (`SampleEvent` → `DiveProfileEvent`); a `.decoStop` event is added when the base has a deco-stop depth > 0; per-sensor PPO₂ is merged; `currentGas` is the group's last non-nil one; `setpoint`, `tts` and `rbt` come from the group's **last** point (the interval's end state).
- Units: `time` s → min; `ndl` s → min; `ceilingDepth` = `decoStop` (m) only when > 0, `ceilingTime` = `decoTime` s → min only then; `tankPressure` = tank 0, else the lowest tank, else the carried `pressure`; `tankPressures` = this interval's per-tank values.
- **TTS / RBT:** `tts` (seconds in `ProfileSample`) → minutes; `rbt` = `ProfileSample.reportedRBT` (minutes, this interval only — not the carried `rbt`). `DiveProfilePoint` applies `validTTS` (0 or less is no TTS: backends write 0 when the computer computes none) and `validRBT` (0 is a real reading; negatives dropped) (`BlueDive/Models/Dive.swift`).
- `remapProfileCurrentGas` then turns each point's gas-mix position into a **tank index** (`gasMixToTankIndex`); a mix without a tank (filtered out) gives `currentGas = nil`.

## Gas mixes and tanks

- **`gasMixReferencesByPosition`** (`DECISIONS.md` L4): when `DiveData.gasMixFieldIndices` is set (a `DC_FIELD_GASMIX` could not be read), every reference — sample `currentGas`, `Tank.gasMix`, header `gasMix` — is turned from a field index into a position in `gasMixes`; a reference to the unreadable mix becomes unknown, and a tank on it gets `unreadableGasMix` (-2), which `resolveGasMix` gives the no-data default (21 % O₂) instead of another mix's gas. A gas switch with no gas then ends the open tank's usage window (`switchesToUnknownGasEndUsage`). Without `gasMixFieldIndices` the data is unchanged.
- **Tank paths**, in order: (1) the computer reports tanks → `buildTanksFromComputerTanks`; (2) only `tankPressure` → one tank (first/last pressure > 0); (3) only gas mixes → one gas-only tank per mix (filtered, below); (4) nothing → one tank from `gasMix` (merge: only when `gasMix` is set and not 21). Paths 2 and 4 read `gasMix` as an O₂ percentage (`Double(gasMix ?? 21) / 100`) although `DiveData.gasMix` is a gas-mix index — behaviour inherited from the former mapper and kept for parity.
- **`buildTanksFromComputerTanks`** (shared by `makeDive` and `merge`): for each computer tank, the gas comes from `resolveGasMix` — the tank's own mix index; for Shearwater with `DC_GASMIX_UNKNOWN`, tank N = mix N; for Halcyon Symbios's O₂ tank, the ≥ 99 % O₂ mix; otherwise the order mixes first appear in the profile (`orderedGasMixIndices`; not Halcyon); then positional; then the first mix; then the header gas or 21 %. Begin/end pressures fall back to the first/last non-zero profile pressure of that tank (`pressureRangeFromProfile`). Then a gas-only tank is added for every mix no tank claimed (non-AI stage bottles), subject to the unused-tank filter.
- **Shearwater gas-to-tank inference** (`inferShearwaterGasMixToTank`, family `shearwaterPetrel` with more than one mix): Shearwater reports `DC_GASMIX_UNKNOWN` for tanks, so each mix's active period is credited to the tank whose pressure falls most. Constants: `dropoutFilterBar = 10` (a drop above 10 bar between two samples is a transmitter dropout, ignored), `pressureNoiseCeilingBar = 10` (the winner must lead the runner-up by 10 bar …), `pressureDropRatioThreshold = 3` (… or by 3×; an unopposed winner is always trusted). Mappings must point at distinct tanks; with `minMappings: 1`, a single remaining mix/tank pair is assigned by elimination. Inferred pairs take precedence over `resolveGasMix`.
- **Shearwater CCR with flagged transmitters** (`isFlaggedShearwaterCCR`: family `shearwaterPetrel` and a tank `usage` `.oxygen`/`.diluent`, which libdivecomputer sets on CC/CC2/SC dives from the transmitter name "O…"/"D…" or the HP-CCR slots): `shearwaterCCRMixForTank` replaces the inference above and `resolveGasMix`. Shearwater lists open-circuit mixes (bailouts) and diluents, never the oxygen supply. A diluent transmitter is matched only to a diluent mix, any other transmitter only to an open-circuit mix: pressure inference restricted to that group (`tankIndices`/`mixIndices`), then the group's remaining mixes in profile order, then list order (one transmitter and one mix are matched at once). The oxygen transmitter gets **pure oxygen** (o2 1.0, he 0; owner decision `DECISIONS.md` L10) and no mix, so no profile sample or usage window points at it; a transmitter left without a mix of its group gets the no-data 21 %. An unclaimed mix (a bailout with no transmitter) becomes a gas-only tank. On `merge`, the oxygen tank keeps a stored gas of 99 % O₂ or more (set by the user); any other stored gas becomes pure oxygen. Dives without flagged tanks (open circuit, logs without transmitter names) are unchanged. Two consequences of libdivecomputer's flags, kept as they are: the name test is the first letter only, so on a CC/CC2/SC dive a transmitter named e.g. "Deco" is flagged diluent; and the HP-CCR slots are flagged in every dive mode while an open-circuit log lists no diluent, so an HP-CCR unit logged in OC mode gets an "O2" tank of pure oxygen, a "Diluent" tank with the no-data 21 % and its open-circuit gases as gas-only tanks (never an OC gas on a CCR cylinder by position). `buildTanksFromComputerTanks` returns the oxygen tanks it set (`oxygenSupplyTanks`), which `merge` uses for the 99 % rule.
- **Unused-tank filter** (`familiesNeedingSwiftTankFilter`: `oceanicAtom2`, `pelagicI330R`, `hwOstc3`, `cressiGoa`, `deepsixExcursion`, `deepbluCosmiq`, `oceansS1`, `mcleanExtreme` — parsers that report every configured mix): only when `filterUnusedTanks` is on and the family is in the set **or unknown**, gas-only tanks are kept only for mixes in `usedGasMixIndices` (mixes seen in the profile, plus the header `gasMix`, else mix 0). Families whose parsers already drop unused tanks (Shearwater, Suunto, Scubapro/Uwatec, Mares, Divesoft, Ratio) are never filtered.
- **Usage times** (`applyGasSwitchUsageTimes`, seconds): from the profile's `.gasChange` points; the first gas seen opens a segment at t = 0; a dive with no switch gives the tank of its first gas the whole profile (0 to the last sample); contiguous segments of one tank are merged, empty ones dropped, and a tank used in two separate segments (switch back) gets none, so its RMV is not diluted. A tank that already has usage times keeps them.
