# Adding a New App Language

A complete checklist for adding an in-app language to BlueDive, built from the Dutch (`b4e03c5`), Norwegian Bokmål (`71ff056`) and Spanish additions. Follow it in order; every step names the file and symbol to change. The general localization rules (`NSLocalizedString` with `Bundle.forAppLanguage()`, never editing `Localizable.xcstrings` by hand, `needs_review` for non-French languages) are in `CLAUDE.md` → "Language & Localisation" and apply throughout.

Throughout this guide, `xx` stands for the new language code (e.g. `it`, `pt`, `sv`) and "Endonym" for the language's own name (e.g. "Italiano").

> One commit per language: translations for a language ship in the same commit as the code that adds it. Never commit, push or branch without the maintainer's explicit approval (see `CLAUDE.md` → General Rules).

---

## 0. Decide before starting (ask the maintainer)

| Question | Why it matters | What we chose before |
|---|---|---|
| Language code: plain (`es`) or regional (`pt-BR`)? | One localization serves every regional variant that falls back to it (es-MX and es-419 devices resolve to `es`); a regional one leaves the others in English. `AppLanguage.effective` matches languages by language code only, so a second variant of a language already shipped (e.g. `pt-PT` beside `pt-BR`) also needs `effective` changed to compare full identifiers (see its doc comment). | `nl`, `nb`, `es` (neutral Spanish for Spain and Latin America). Prefer one neutral code. |
| Review state | `Scripts/xcstrings.py` writes `needs_review` for every language in `REVIEW`. | Every language except `fr-CA` is `needs_review` until a native speaker signs off. |
| Hour / day abbreviations in compact durations ("1h 05m", "2d 3h") | Some languages do not use "h" for hours. | Dutch "u", Norwegian "t", French "j" for days; Spanish keeps "h". |
| Register and quotes | Consistency across ~1 750 strings. | "du"/"tú" informal forms; `«»` for French, Norwegian, Spanish; `„“` for German. |
| Script and direction | This guide assumes a left-to-right language written with spaces between words. A right-to-left language (Arabic, Hebrew) needs a separate review of every layout, and a language without spaces (Japanese, Chinese) breaks the word-based photo-caption name hint (`commonNameHint`). | Only left-to-right, space-separated languages so far. |
| Commits | One commit per language. | Commit the previous language before starting the next — shared files (catalogs, `SettingsView`, the caption, docs) cannot be split afterwards. |

---

## 1. Project and translation script

1. **Known regions** — `BlueDive.xcodeproj/project.pbxproj`, `knownRegions` list: add `xx` (done in Xcode: Project → Info → Localizations → +). Until the catalogs have `xx` values no `xx.lproj` is built, so adding it early is harmless.
2. **`Scripts/xcstrings.py`**:
   - `LANGS` — append `"xx"` (this makes `missing`/`check` require it and adds a `--xx` option to `set`).
   - `REVIEW` — add `"xx"` (always `needs_review`).
   - Update the docstring (usage lines and "Rules baked in").
3. Run `python3 Scripts/xcstrings.py missing` — every key should now be listed as missing `xx` only.

## 2. Code changes

| # | File → symbol | Change |
|---|---|---|
| 1 | `BlueDive/SettingsView/SettingsView.swift` → `enum AppLanguage` | Add `case xxName = "xx"`; in `displayName` return the endonym (plain string, not localized — language names are shown in their own language); in `locale` return `Locale(identifier: "xx")`. `effective` and the picker need nothing (`allCases`). |
| 2 | `BlueDive/SettingsView/AppearanceSettingsView.swift` → the two "Choose System to use your device's language … or override with English, Français, …" captions (macOS and iOS) | Append the endonym to the list in **both** strings. This creates two new keys: translate them into **every** language (derive from the old translations by inserting the endonym) and remove the two old keys, which Xcode marks stale, with `python3 Scripts/xcstrings.py remove "<old key>"`. |
| 3 | `BlueDiveWidgetExtension/BlueDiveWidgetExtension.swift` → `AddDiveProvider.currentLocale()` | Add `case "xx": return Locale(identifier: "xx")`. Without it the widget follows the system language. |
| 4 | Compact hour/day letters (only if the language does not use "h"/"d") | `Dive.displaySurfaceInterval` (`Models/Dive.swift`) and `DiveSummary.displaySurfaceInterval` (`Data & Sync/DiveSummary.swift`): add a `case "xx":` rewriting `(\d+)h\b` (and/or the day) for display only — stored values never change. `StatisticsView` → the `hourSuffix` switch (and `daySuffix`, today a French-only ternary on `isFrench` — turn it into a switch if the day letter changes). The `"%dh %02dm"` and `"%dh %02dm %02ds"` keys of the main catalog and the widget's `"%@ h"` and `"%@ h %@ min"` keys get the letter in the translation. Update the doc comment on `Dive.displaySurfaceInterval`. |
| 5 | `BlueDive/Marine Life/SpeciesPhotoMatching.swift` → `commonNameHint(before:)` | Add the language's indefinite/definite articles in the `switch UserPreferences.shared.languageMode.effective` (they apply **only** when the app is in that language). Never add them to the shared `articles` set: an article of one language is often an ordinary word in another (Norwegian "en"/"et" are French "in"/"and") and would let a photo join the wrong existing species. Skip articles already in the shared set. |
| 6 | `BlueDive/Shared/CountryLookup.swift` → `nameToCode` | Append a `// <Language> (xx) country names` block (see §4) and update the doc comment listing supported languages. |
| 7 | `BlueDive/Marine Life/INaturalistService.swift` → `nameLanguageCodes` | Check the code is listed (iNaturalist common-name languages); add it if iNaturalist supports it. |

No other code branches on the language: `Bundle.forAppLanguage()`, `LanguageOverrideModifier`, date formatting, the PDF logbook, notifications and the iPad tab pinning all work from `AppLanguage.locale` and the translated text. Verify that the only hits are the places above (the two `languageCode` reads in `Bundle.forAppLanguage()`, `INaturalistService.appLanguageCode` and the widget's bundle lookup need nothing):

```
grep -rnE 'languageCode\?*\.identifier|case \.(german|dutch|norwegianBokmal|spanish)\b|case "(fr-CA|de|nl|nb|es)"' BlueDive BlueDiveWidgetExtension --include='*.swift'
```

Do **not** add the language to `OrdinaryWords` (`SpeciesPhotoMatching.swift`): it is English-only on purpose, because the French, German and Dutch spelling dictionaries contain Latin words and would reject real scientific names. Rank detection (`isRankName`) uses Latin suffixes and needs nothing either.

## 3. Build, then translate

1. Build **My Mac** and an **iOS** destination (macOS-only and iOS-only keys are extracted only by their platform's build), so Xcode inserts the new caption keys.
2. `python3 Scripts/xcstrings.py missing` → only `xx` should be missing, plus the two new caption keys (all languages).
3. **Export** the keys to translate, with context, in batches (≈ 200 keys):

```python
# /tmp/xx/export.py — run from the repo root
import json, os
os.makedirs("/tmp/xx", exist_ok=True)
for f, tag in [("BlueDive/Localizable.xcstrings", "main"), ("BlueDive/InfoPlist.xcstrings", "plist"),
               ("BlueDiveWidgetExtension/Localizable.xcstrings", "widget")]:
    items = []
    for k, v in json.load(open(f))["strings"].items():
        loc = v.get("localizations", {})
        if not k.strip() or v.get("shouldTranslate", True) is False or "xx" in loc:
            continue
        def val(l):
            u = loc.get(l)
            if not u: return None
            if "variations" in u:
                return {c: x["stringUnit"]["value"] for c, x in u["variations"]["plural"].items()}
            return u["stringUnit"]["value"]
        e = {"key": k, "fr-CA": val("fr-CA"), "de": val("de")}
        if val("en") not in (None, k): e["en"] = val("en")      # display text differs from the key
        if v.get("comment"): e["comment"] = v["comment"]
        if any(isinstance(x, dict) for x in (val("en"), e["fr-CA"], e["de"])): e["PLURAL"] = True
        items.append(e)
    n = 200 if tag == "main" else 1000
    for i in range(0, len(items), n):
        json.dump(items[i:i + n], open(f"/tmp/xx/{tag}_{i // n:02d}.json", "w"), ensure_ascii=False, indent=1)
```

4. **Write one shared brief** (`/tmp/xx/PROMPT.md`) before translating, and give every translator (or agent) the same one. Lesson learnt: Norwegian batches translated without a shared glossary rendered the Samples tab as «Målinger» in some strings and «Målepunkter» in others (including where the tab is named inside a sentence), and gave "Many" and "Abundant" the same word; both had to be fixed by hand. The Spanish batches, with the brief below, were consistent and needed only two hand fixes: "WEIGHT" (the ballast card) → «LASTRE», and the Spain-only «coste» → «costo». The brief must contain:
   - Output format: `/tmp/xx/out_<batch>.json` = `{ "<key>": { "xx": "…" } }`; translate `"en"` when present instead of the key; plural entries as a dict with **exactly the CLDR categories of the language**: `one`/`other` for most Germanic languages (de, nl, nb, sv, da); `one`/`many`/`other` for Spanish, Italian and Portuguese, with `many` identical to `other` (as `es` does here — the older `fr-CA` entries have only `one`/`other`); Slavic languages also need `few` (Polish, Czech, Russian: check the CLDR plural rules). Set the same categories in `CATS` in the validator (§4).
   - Register, quotes, Apple UI terms for the platform in that language (Settings, Cancel, Done, Add, Delete…).
   - A **diving glossary**: dive, diver, dive site, logbook, depth, max/average depth, bottom time, surface interval, safety stop, deco stop, ceiling, NDL, tank, twinset, pony, gas/mix, weights (ballast) vs gear weight, wetsuit/drysuit, dive computer, regulator, BCD, gear/equipment, gear service, buddy, trip, marine life, species, sighting, encounters, **Samples** (the raw dive-computer data tab), profile, chart, certification, insurance, weather ("Fetch Weather"), conditions, visibility, current; the marine-life quantity labels **Single / Few / Many / Abundant** (all four must differ); taxonomic ranks.
   - Rules: keep every format specifier (`%@`, `%lld`, `%1$@`…) in count and order, `\n`, leading/trailing spaces, units, symbols, arrows; keep brand names (BlueDive, MacDive, iCloud, iNaturalist, UDDF, Subsurface, Garmin, Shearwater, Bluetooth, PDF, XML, CSV, FIT); keep language endonyms; decimals inside text follow the language (German uses `5,2`); keys with nothing to translate are copied unchanged.
   - Length limits: chart chip short labels `"Prof."`, `"Temp."`, `"Press."` ≤ 6 characters; tab keys `"Equipment (tab)"` and `"Marine Life (tab)"` one short word if possible; `"Dives"` is also a tab label.
   - Known traps: `"Diver for %lld year%@"` — the code appends an English `"s"` as `%2$@` for more than one year; keep `%2$@` only if "noun + s" is the plural in the language, otherwise drop it (Norwegian: `"Dykker i %1$lld år"`). `"WEIGHT"` (dive detail card) is the dive's ballast; `"Weight"` is shared with gear weight.
   - Translators must not touch any file outside `/tmp/xx`.
5. Translate the batches (up to ~5 parallel agents of 2 batches each worked well; the last one also takes `plist_00` and `widget_00`).

## 4. Validate, then apply

Run this **before** applying anything:

```python
# /tmp/xx/validate.py — exits with the number of problems
import json, re, glob, sys
LANG, CATS = "xx", {"one", "other"}          # set CATS to the language's CLDR plural categories
spec = re.compile(r'%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfFeEgGcCsSp%]')
def specs(s):
    out, n = [], 0
    for m in spec.finditer(s):
        if m.group(0) == "%%": continue
        n += 1; out.append((int(m.group(1)) if m.group(1) else n, re.sub(r'^%(\d+\$)?', '%', m.group(0))))
    return sorted(out)
bad = 0
for inp in sorted(glob.glob("/tmp/xx/[mpw]*_[0-9][0-9].json")):
    items = json.load(open(inp)); out = json.load(open(inp.replace("/tmp/xx/", "/tmp/xx/out_")))
    if set(out) != {e["key"] for e in items}: print("KEY SET MISMATCH", inp); bad += 1
    for e in items:
        src, t = e.get("en", e["key"]), out[e["key"]][LANG]
        if e.get("PLURAL") or isinstance(t, dict):
            ref = src["other"] if isinstance(src, dict) else src
            if not isinstance(t, dict) or set(t) != CATS: print("PLURAL", e["key"], t); bad += 1; continue
            bad += sum(specs(v) != specs(ref) and not (c == "one" and len(specs(v)) < len(specs(ref))) for c, v in t.items())
        elif specs(t) != specs(src) or src.endswith("\n") != t.endswith("\n") \
                or src.startswith(" ") != t.startswith(" ") or src.endswith(" ") != t.endswith(" "):
            print("SPEC/WS", repr(src), "->", repr(t)); bad += 1
print("problems:", bad); sys.exit(bad)
```

Then check consistency by hand (the validator cannot): look up the translations of the glossary keys (`"Samples"`, `"Single"`, `"Few"`, `"Many"`, `"Abundant"`, `"Weight"`, `"Weights"`, `"Fetch Weather"`, `"Edit Conditions"`, `"Other Names"`, `"Update Samples"`) and confirm every UI name quoted inside a sentence (`«…»`, `„…“`) is exactly the translation of that button's own key. Also list values identical to English and confirm each one is legitimate (units, brand names, words spelled the same).

Apply, once the build has finished and the catalog is not open with unsaved changes in Xcode:

```
python3 - <<'EOF'
import json, glob
m = {}
for f in sorted(glob.glob("/tmp/xx/out_main_*.json")): m.update(json.load(open(f)))
json.dump(m, open("/tmp/xx/apply_main.json", "w"), ensure_ascii=False)
EOF
python3 Scripts/xcstrings.py set-json /tmp/xx/apply_main.json
python3 Scripts/xcstrings.py set-json /tmp/xx/out_plist_00.json  --file BlueDive/InfoPlist.xcstrings
python3 Scripts/xcstrings.py set-json /tmp/xx/out_widget_00.json --file BlueDiveWidgetExtension/Localizable.xcstrings
for f in BlueDive/Localizable.xcstrings BlueDive/InfoPlist.xcstrings BlueDiveWidgetExtension/Localizable.xcstrings; do
  python3 Scripts/xcstrings.py check --file "$f"; done
```

Finally compare each catalog with `HEAD` (`git show HEAD:<file>`): no key's existing translations, comments or states may change except the two caption keys swapped in §2 #2, and every `xx` entry must be `needs_review`.

## 5. Country names (`CountryLookup.nameToCode`)

`nameToCode` is a dictionary **literal**: a duplicated key traps at runtime, the first time a country flag is resolved (the static table is built lazily), so the build does not catch it. Lookups are accent- and case-insensitive (`normalizedKey`), and the first entry wins for keys that normalize alike.

1. Write the language's country names (≈ 200, lower case, including dive territories: Bonaire, Curaçao, Cayman Islands, Turks and Caicos, French Polynesia, Galápagos…) as a Python dict `{name: iso_code}`.
2. Filter them against the existing table — skip any name already present (same normalized form), report any that would map to a **different** code, and drop duplicates within the new list:

```python
import re, unicodedata
src = open("BlueDive/Shared/CountryLookup.swift").read()
table = src[src.index("private static let nameToCode"):src.index("// MARK: - ISO code → accent colour")]
norm = lambda s: ''.join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn").lower()
existing = {}
for k, v in re.findall(r'"([^"]+)"\s*:\s*"([a-z]{2})"', table): existing.setdefault(norm(k), v)
new = {}
for k, v in NEW_NAMES.items():
    if norm(k) in existing:
        if existing[norm(k)] != v: print("CONFLICT", k, v, "existing", existing[norm(k)])
    elif norm(k) not in {norm(x) for x in new}: new[k] = v
```

3. Insert the block just before the closing `]` of `nameToCode`, grouped by initial letter (`// A` …), three entries per line, and re-run a literal-duplicate check over the whole table (`collections.Counter` of the keys must have no count above 1).
4. Codes without an entry in `accentColor` fall back to cyan — acceptable.

## 6. Layout checks (by calculation, then on screen)

The layouts adapt to text width at runtime, so no per-language code is needed, but check that the new language does not lose information:

- **iPad tab bar** (`TabBarFit` / `MainTabTitle`, `App/MainTabView.swift`): run `TabBarFit.pinnedTabCount(geometry:hasTopTabBar:titleWidths:showsCalculatorsMenu:)` with the translated titles of `"Dives"`, `"Map"`, `"Equipment (tab)"`, `"Marine Life (tab)"`, `"Documents"` measured as in `namedTabWidths` (UIFont 17 pt medium, + 32.4 pt) for widths 834 (11-inch portrait), 744 (mini), 1032 (13-inch), 1194 (landscape), with and without the calculators menu and Bold Text. Reference: 11-inch portrait pins en 2, fr-CA 2, nl 2, de 3, nb 1, es 2. Dives always keeps its name.
- **Dive chart chips** (`ToggleButton` in `DiveDetailView/UnifiedDiveChartFixed.swift`): compare the caption2 widths of Depth/Temperature/Pressure/NDL/PPO₂/Deco/Photos with English. Longer labels switch to the short label (`"Prof."` etc.) or, for Photos, to icon-only on narrow iPhones — expected, as in French; check the short labels are short.
- **macOS dive list column headers** (`DiveListColumnHeader` / `DiveListColumns`, `Dive List/DiveListComponents.swift`): fixed widths with `lineLimit(1)` — Dive # 76, Duration 70, Surface Interval 120, Gas 120, Max Depth 100, Date 170 pt at caption semibold (10 pt on macOS). The translations of `"Dive #"`, `"Duration"`, `"Surface Interval"`, `"Max Depth"` must fit (Spanish "Intervalo en superficie" is 113 of 120 pt).
- **Legend** (macOS one line → two lines → stacked; iOS stacked): nothing to measure, it always falls back.

`RunCodeSnippet` in a non-UI file (e.g. `Shared/CountryLookup.swift`) runs these calculations; it uses UIKit with an iOS destination and AppKit with My Mac. It sometimes crashes in SwiftUI's window setup (`RootWindowLayoutComputer`) before the snippet runs — retry; never set `UserPreferences` from a snippet (it writes the real defaults).

## 7. Documentation

- `CLAUDE.md` → "Language & Localisation": the language list in the first paragraph; the review-state sentence (`fr-CA` → `translated`; … → `needs_review`) and the `needs_review` paragraph; workflow step 3 (`missing`), the `set-json` example (add the language to the "Service record saved." example) and the single-key `set` example; plural categories if the language has more than `one`/`other`; **Translation quality rules** (quotes, hour letter, register, any language-specific convention such as neutral Spanish).
- `README.md` → "Localized" bullet.
- `CONTRIBUTING.md` → the "Localization" contribution bullet and the PR rule listing required languages.
- `Scripts/xcstrings.py` → docstring.
- This file → add the language to the references (§0 table, §6 tab pinning).

## 8. Verify

1. Build **My Mac** and an **iOS** destination; `GetBuildLog` with severity warning must show nothing new (string catalog warnings appear there).
2. Confirm `xx.lproj` exists in `BlueDive.app/Contents/Resources/` and in the widget extension (`BlueDive.app/Contents/PlugIns/BlueDiveWidgetExtensionExtension.appex/Contents/Resources/` in the My Mac build).
3. Runtime spot checks: `NSLocalizedString("Settings", bundle: <xx bundle>)`, a plural key (`"%lld dives"` for 1, 2 and 1 000 000), `"%dh %02dm"`, a few `CountryLookup.resolve(_:)` names in the new language, `Bundle.preferredLocalizations(from:forPreferences:)` for the regional variants (e.g. `["es-MX"]` → `["es"]`).
4. **Manual test on My Mac with the system language different from the app language** (`CLAUDE.md`): the main window, a sheet, a sheet opened from a sheet, an alert inside a sheet, a view showing dates, the Home Screen widget; on iPad (11-inch portrait) the tab bar and the leading toolbar buttons; on a narrow iPhone the chart chips.
5. Review the diff for regressions and `CLAUDE.md` compliance before asking for the commit.

## 9. Commit

Conventional Commits format (`CLAUDE.md` → Release Notes & Commit Messages): `feat: add <Language> (<Endonym>) in-app language support`, with Added (catalog entry counts, `AppLanguage` case, country block, widget locale), Changed (caption, hour letter, photo-caption articles, script and docs), Notes (`needs_review`, layout results, what was verified and what still needs the manual test). See commits `b4e03c5` (Dutch) and `71ff056` (Norwegian Bokmål), and the Spanish commit that follows them, for examples.

---

## Known pre-existing issues (do not "fix" them while adding a language)

- **Plural rules follow the system language.** Plural keys are formatted with `String(format:)` without a locale (e.g. `MarineLifeView`), so the plural category is chosen with the system language's rules (French system: "0 inmersión"). Passing the app-language locale would also change thousands separators, which the Number Formatting rule forbids — a separate decision.
- **The shared article `"de"`** (Dutch) also matches French/Spanish "de" ("of"): "Étoile de mer (…)" gives the name hint "mer". Moving the Dutch articles to the Dutch-only branch of `commonNameHint` is a separate fix.
- **`"Diver for %lld year%@"`** appends an English "s": German shows "Jahrs". A proper plural key in `DiverProfileView` is a separate fix.
