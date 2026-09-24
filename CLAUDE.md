# BlueDive — Project Instructions

BlueDive is a dive log application for macOS and iOS. It is designed as a feature-rich alternative to MacDive, a previously popular dive logging app that is no longer actively maintained by its developer.

## General Rules

Before making any code changes, confirm the approach with the user and wait for explicit approval. Do not modify files until the user has authorized the change.

Never commit, push, or perform any git or GitHub operations (including creating branches, pull requests, or tags) without explicit user authorization first.

When importing, exporting, processing, and storing data, never convert, normalize, or alter dive data. Preserve original values unless the user explicitly modifies them through the app.

Do not change the data model (structs, properties, enums, relationships) unless explicitly instructed to do so.

Do not estimate any data displayed or stored. All fields must be calculated or extracted from the data model unless explicitly instructed to do so.

## Language & Localisation

Always use English (Canada) for labels, text, and comments in user-facing content.

All public-facing text must be defined in code as localizable strings and translated in French (Canada), German, and Dutch in the Localizable file. In SwiftUI views, use `LocalizedStringKey` (e.g. `Text("My Key")`) for direct text display. When building strings programmatically — including inside `Text(verbatim:)` with interpolation, even within SwiftUI views — use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()` instead of `String(localized:)`, because `String(localized:)` follows the OS language and ignores the in-app language override. Outside SwiftUI views (e.g. PDF generation, enum properties, model logic), always use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()`. Never wrap `NSLocalizedString` in a custom helper function (e.g. `L("key")`), because Xcode's string catalog compiler only detects keys from direct `NSLocalizedString` calls with literal strings — a wrapper hides the keys and causes Xcode to mark them as "Stale". When localizing data-model values from a known finite set of options (e.g. weather, current, tank type), use a `switch` with literal `NSLocalizedString` calls for each case so Xcode can detect every key; never pass a runtime variable as the key.

### Localizable.xcstrings — never edit by hand

`BlueDive/Localizable.xcstrings` is ~1 MB / 38 000 lines. **Never open, read, grep-and-read, or hand-edit it, and never use a file-edit tool on it.** Reading any part of it into context is wasted time. All changes go through `Scripts/xcstrings.py`, which edits the JSON in place, preserves Xcode's exact formatting (byte-identical round-trip, minimal diff), and enforces the review-state rule automatically (`fr-CA` → `translated`; `de` and `nl` → `needs_review`).

The `needs_review` state left on `de`/`nl` is intentional, not a bug: a native reviewer promotes those to `translated` in Xcode's catalog editor (the script never writes `translated` for `de`/`nl`), and a later re-translation via `set` correctly resets them to `needs_review` so the edit is re-reviewed.

Workflow for every new or changed user-facing string:

1. Write the Swift code with the literal key. For `NSLocalizedString`, always pass `value:` with the English text so the string displays before the catalog syncs, e.g. `NSLocalizedString("Service record saved.", bundle: Bundle.forAppLanguage(), value: "Service record saved.", comment: "")`.
2. Build the project (⌘B) so Xcode inserts the key into the catalog. Do not add keys to the catalog yourself.
3. Run `python3 Scripts/xcstrings.py missing` — it lists every key still lacking `fr-CA`, `de` or `nl`. These are the only keys you translate.
4. Write the translations to a temp JSON file and apply them in one call:
   ```
   cat > /tmp/i18n.json <<'JSON'
   {
     "Service record saved.": { "fr-CA": "Fiche d'entretien enregistrée.", "de": "Wartungseintrag gespeichert.", "nl": "Onderhoudsrecord opgeslagen." }
   }
   JSON
   python3 Scripts/xcstrings.py set-json /tmp/i18n.json
   ```
   For a single key: `python3 Scripts/xcstrings.py set "Key" --fr-CA "…" --de "…" --nl "…"`.
   Plural keys take a dict per language: `"fr-CA": { "one": "%lld plongée", "other": "%lld plongées" }`. The script refuses to overwrite a plural with a plain string.
5. Run `python3 Scripts/xcstrings.py check` before committing; it exits non-zero if any translatable key is missing a language. Translations for a key ship in the same commit as the code that introduces it.

**Run the script only after the build has finished and the catalog is not dirty in Xcode's editor.** The script does an unguarded read-modify-write; if Xcode has unsaved changes to the catalog (or a build is re-extracting strings) when the script writes, one side silently clobbers the other. After running the script, re-run `show`/`check` (or reopen the catalog) to confirm the edit survived.

Other commands: `show "Key"` prints one entry. The `check` and `missing` commands are **per-file** — when you touch a widget string, run them against the widget catalog too. Put `--file` **after** the subcommand (it is a per-command option), e.g. `python3 Scripts/xcstrings.py check --file BlueDiveWidgetExtension/Localizable.xcstrings` or `python3 Scripts/xcstrings.py set "Key" --de "…" --file BlueDiveWidgetExtension/Localizable.xcstrings`. If `set` reports the key is not found, the build has not run yet — build, do not use `--create` (Xcode collates keys in localized order; a key appended by `--create` gets relocated on Xcode's next write, causing a large move-diff).

Translation quality rules: keep `%lld`, `%@`, `%.1f` and other format specifiers unchanged and in the same order; French uses fr-CA conventions (espace insécable before `:`, `?`, `!`; `«»` quotes); German uses `„“` quotes; keep the same terminal punctuation as the English source.

Fallback only if no shell is available in the current agent session: locate the key with a search for the exact text `"<key>" : {` (use the JSON-escaped form of the key — e.g. a key containing a newline is stored as `\n`, quotes as `\"`), read at most 15 lines around that line, and perform a single targeted replacement of the empty or comment-only entry with the full `localizations` block. Never read more than that, never reformat, never rewrite the file.

## Number Formatting

Number formatting (thousands separators and decimal separators) must always follow the OS region settings, not the in-app language override. This is because iOS/macOS separates language (text/translations) from region (number and date formats) — a user may choose English as the app language but have a French or German region configured, and their number format preference must be respected.

- Always format user-facing numbers using `Double.localizedString(decimals:minDecimals:)` (defined in `CrossPlatformImage.swift`), which uses `NumberFormatter` with `numberStyle = .decimal` and `locale = Locale.current`. This produces locale-correct thousands separators (`,` in en-CA, ` ` in fr-CA, `.` in de) and decimal separators automatically.
- **`localizedString` is for display labels only — never use it to pre-fill a TextField.** Its grouping separators (e.g. "3,000" in en-CA, "3.000" in de) are misinterpreted by `parseFlexibleDouble` as decimal separators, silently corrupting values ≥ 1000 on save. Use `Double.editableString(decimals:minDecimals:)` instead for any TextField `initialValue` or assignment — it produces the same locale decimal separator but omits the thousands grouping separator (e.g. "3000" in any locale).
- Never use `String(format: "%.Xf", value)` or `"\(someInt)"` string interpolation for displayed numbers — these bypass locale formatting and produce no thousands separator and a hardcoded `.` decimal.
- Use `minDecimals:` to preserve trailing zeros (e.g. `localizedString(decimals: 2, minDecimals: 2)` so "1.40" does not render as "1,4").
- For integers that can reach 1000+ (dive counts, pressures in psi, gear use counts, species counts, etc.), always convert via `Double(intValue).localizedString(decimals: 0)`.
- **Exceptions** (use hardcoded format, not locale-aware): GPS coordinates (`"%.6f, %.6f"` — dot and comma are coordinate notation, not locale separators), time duration padding (`%02d`), and data exported to XML/CSV where a fixed format is required for interoperability.
- Note: this rule is the opposite of date/locale handling — for **text/translations** use the in-app language override (`Bundle.forAppLanguage()`), but for **number formatting** always use `Locale.current` (OS region).

## Text Fields

All TextFields in edit and add views must include a clear button rendered as an overlay on the right side of the field, allowing the user to clear the field's content. All TextField input in edit and add views must be trimmed to remove leading and trailing whitespace before storing or processing the value.

All TextFields bound to Double values must use a string-backed TextField (not `format: .number`) and accept both '.' and ',' as decimal separators. Normalize commas to dots before parsing to Double. This ensures correct input regardless of the user's locale.

## Appearance

The interface must support both light mode and dark mode, adapting correctly to the user's system appearance setting, with the ability to override it based on user preference.

## Per-Dive Unit Display

Every dive in the database stores its raw values in the unit they were imported in, recorded in per-dive metadata fields (`importDistanceUnit`, `importTemperatureUnit`, `importPressureUnit`, `importVolumeUnit`, `importWeightUnit`). Never display raw stored values directly. Always use the unit-aware display helpers defined on `Dive` so that each value is correctly converted from its stored unit to the user's preferred display unit:

- **Depth / altitude**: use `dive.displayMaxDepth`, `dive.displayAverageDepth`, `dive.displaySiteAltitude`, or `dive.displayProfileDepth(_:)` for profile samples (the lower-level `dive.displayDepth(_ rawValue:)` is also available). Then append `prefs.depthUnit.symbol` — do **not** pass these already-converted values to `DepthUnit.formatted()` or `DepthUnit.convert()`, which assume metre input and would double-convert imperial dives.
- **Temperature**: use `dive.displayWaterTemperature`, `dive.displayMinTemperature`, `dive.displayAirTemperature`, `dive.displayMaxTemperature`, or `dive.displayProfileTemperature(_:)` for samples. For formatting with a symbol use `prefs.temperatureUnit.formatted(_ value:, from: dive.storedTemperatureUnit)`.
- **Pressure**: use `dive.displayPressure(_ rawValue:)` or `dive.formattedPressure(_ rawValue:, decimals:)` for tank pressures and profile sample pressures.
- **Volume**: use `dive.formattedVolume(_ rawValue:, workingPressureRaw:, decimals:)` for tank sizes.
- **Weight**: format weights using `prefs.weightUnit.formatted(_ value:, from: dive.storedWeightUnit)`.

Never call `DepthUnit.formatted(_ meters:)` or `DepthUnit.convert(_ meters:)` with a raw stored value — these methods assume metres input. Always go through the `Dive` display helpers first.

## Mac (Designed for iPad) Support

BlueDive supports running as an iPad app on Apple Silicon Macs via "Designed for iPad" mode. The following patterns ensure a good experience on Mac:

- **Sheet sizing**: All `.sheet()` presentations must include `.presentationSizing(.page)`, `.presentationDetents([.large])`, and `.presentationDragIndicator(.visible)` so sheets appear at page size instead of the small default form sheet on iPad/Mac.
- **Date pickers**: Use `.adaptiveDatePickerStyle()` (defined in `CrossPlatformImage.swift`) instead of `.datePickerStyle(.compact)`. This shows a full graphical calendar on Mac and compact style on iPhone/iPad.
- **Platform detection**: Use `ProcessInfo.processInfo.isiOSAppOnMac` to detect "Designed for iPad" mode at runtime. Note that `#if os(iOS)` is `true` in this mode.

## Liquid Glass & HIG Toolbar Compliance

Under iOS/macOS 26+ "Liquid Glass," toolbar buttons render inside a translucent glass capsule. Follow these rules for any toolbar, sheet, or button work.

### Root-Cause Rule: No Local Tint on Bare Toolbar Buttons

A local `.tint(...)` placed directly on a bare toolbar `Button` (one **not** using `.buttonStyle(.borderedProminent)` or another explicit button style) fills the Liquid Glass capsule **background**, not just the label — this is what caused toolbar buttons to render white/wrong instead of the app's cyan brand color, especially on macOS "Designed for iPad." This is the single most important rule in this section; when in doubt, grep the whole tree for `.tint(` and check each hit against the categories below.

- The app's brand color (cyan) is supplied ambiently by two mechanisms kept deliberately together: the `AccentColor` asset catalog (`Assets.xcassets/AccentColor.colorset` and `BlueDiveWidgetExtension/Assets.xcassets/AccentColor.colorset`, both populated with explicit light/dark sRGB cyan values) and a root `.tint(.cyan)` on `BlueDiveApp`'s `WindowGroup` content. `.tint()` is always respected in-process; `AccentColor` is what reaches out-of-process system UI (share sheets, pickers) that `.tint()` can't. Do not remove either as "redundant" — they cover different surfaces.
- On a bare toolbar button, color only the `Image` inside the label via `.foregroundStyle(...)` (glyph color) — never the button itself via `.tint()`.
- `.buttonStyle(.borderedProminent)` buttons may legitimately carry a local `.tint()` to explicitly set their fill color — a different, correct mechanism from the bare-button case. Example: `DiveDetailView+EditSheets.swift` gives each edit tab's Save/Add buttons a `.tint()` matching that tab's brand color (`.blue` for Site Details, `.green` for Gas, etc. — see the tab color mapping in `DiveDetailView.swift`). Never strip these as "redundant cyan cleanup" — verify against the tab color mapping before touching any tint in that file.
- Documented exception: `MapUserLocationButton` (a native MapKit control, used in `DiveMapView.swift`) requires an explicit `.tint()` to pick up the brand color — this is not the anti-pattern.

### Toolbar Button Placement

- Close/Cancel (dismiss without saving) → `.cancellationAction` (leading edge). Use the `closeToolbarButton(action:)` helper (`CrossPlatformImage.swift`) for standard dismiss buttons — it uses `Button(role: .close, action:)` on iOS 26+/macOS 26+ (the system's "doesn't lose progress" affordance, distinct from `.cancel`), falling back to a plain "Close" button pre-26.
- Done/Save (confirm) → `.confirmationAction` (trailing edge).
- Exception: when a sheet's *sole* toolbar action is a non-destructive "Done" with no separate save step (e.g. a simple list-picker sheet), `.confirmationAction` (trailing) is still HIG-correct — matches Apple's own simple-list-picker convention even though it's the only button.
- Destructive actions (delete) → `.destructiveAction`. This placement is platform-divergent by Apple's own design: iOS/tvOS/watchOS render it on the **trailing** edge; macOS/Mac Catalyst render it on the **leading** edge (next to Cancel/Close) with a cautionary appearance. Do not "fix" this by moving it elsewhere on macOS — it's documented, intentional behavior.
- Only one prominent/primary action per sheet.
- Any `@available` gate added around `role: .close` or another 26+ API must list every platform the code actually ships on (`iOS 26.0, macOS 26.0, *`) — omitting one is a compile error waiting for the first build on that platform.

### Icon Simplification (iOS / shared code only)

- The Liquid Glass capsule already provides a visual container — do not additionally wrap toolbar icons in `.circle`/`.circle.fill` SF Symbol variants (use `plus`, `ellipsis`, `info`, not `plus.circle.fill`, `ellipsis.circle.fill`, `info.circle`) inside `#if os(iOS)` or unguarded/shared code.
- Never apply this simplification inside a `#if os(macOS)` branch — see "macOS Branch Preservation" below.
- Icon+text (`HStack { Image; Text }`) toolbar labels collapse to icon-only on regular-width idiom (iPad/Mac) by Apple's documented default; no modifier prevents this. If the text must always stay visible, drop the icon entirely rather than fighting the collapse.

### Toolbar Layout & Accessibility

- Never group multiple interactive controls inside one `HStack` that itself sits inside a single `ToolbarItem`. Under SDK 26/27 toolbar-overflow layout this silently clips every control but the first when space is constrained (e.g. Mac "Designed for iPad" at narrower widths). Give each control its own `ToolbarItem`/`ToolbarItemGroup` entry.
- `.topBarLeading`/`.topBarTrailing` are iOS-only placements — never use them unguarded on code that also compiles for macOS; gate with `#if os(iOS) ... #else .automatic ... #endif` or use a cross-platform placement (`.cancellationAction`, `.confirmationAction`, `.destructiveAction`, `.primaryAction`, `.automatic`).
- Every icon-only toolbar control (a `Button`/`Menu` whose label is only an `Image`, no text) must carry `.accessibilityLabel(Text("..."))`, translated per the Localization workflow. When the label depends on state (e.g. a show/hide toggle), write two literal `Text("Key A")`/`Text("Key B")` branches — never a ternary or variable passed as the key (`Text(condition ? LocalizedStringKey("A") : LocalizedStringKey("B"))` bypasses Xcode's literal-string extraction).

### macOS Branch Preservation

BlueDive plans a native macOS release. Every `#if os(macOS)` / `#else` branch is intentional and must be preserved exactly, even when it looks like unfinished HIG cleanup (older icon style, different button placement, different string casing) — do not simplify, re-tint, reword, or restructure code inside a macOS branch as a side effect of an iOS-focused fix, and do not delete a macOS branch's content when applying a fix meant only for iOS/shared code. Verify the true boundaries with `grep -n "#if os\|#else\|#endif"` before editing near one — do not assume a diff hunk stayed within its intended platform.

There is currently no real macOS build target: "My Mac (Designed for iPad)" still compiles as `#if os(iOS)`, and a native "My Mac" destination is reported incompatible with the current scheme. Consequently, Xcode's string catalog extractor can never pick up a *brand-new* string that exists only inside a `#if os(macOS)` block through the normal build-and-extract workflow (see Localization above). Such a key requires `Scripts/xcstrings.py set --create` as a deliberate, narrow exception to the "don't use `--create`" rule — accept the one-time move-diff risk this defers until a real macOS target is eventually built.

### What NOT To Do

- Never add a local `.tint()` to a bare (non-`.buttonStyle`) toolbar `Button` — color the `Image` inside the label with `.foregroundStyle()` instead, or rely on the ambient `AccentColor`.
- Never remove a `.tint()` from a `.buttonStyle(.borderedProminent)` button without checking whether it encodes intentional per-section/per-tab color-coding.
- Never place multiple controls in one `HStack` inside a single `ToolbarItem`.
- Never use `.topBarLeading`/`.topBarTrailing` without a macOS-compatible fallback.
- Never simplify a circle-bordered icon, reword a string, or otherwise edit content inside a `#if os(macOS)` branch as an incidental side effect of an iOS fix.
- Never add a new `@available` gate for a 26+ API without including every platform the code target actually ships on.

## App Group & Widget Data Sharing

BlueDive shares data with the widget extension via an App Group. When a change affects data that the widget reads, update the App Group store as well — do not only update the main app's local storage. Only touch App Group storage when the change is directly relevant to widget-displayed data; do not write to the App Group for data the widget does not consume.

## XML Import / Export Date Formatting

All `DateFormatter` instances in XML parsers and exporters must use `TimeZone.current` (device local time) so that exported files round-trip correctly on re-import regardless of the user's timezone. Never use `TimeZone(identifier: "UTC")` or any fixed timezone in parser or exporter date formatters — doing so shifts timestamps for users not in UTC and breaks backward compatibility with previously exported files. Set `formatter.timeZone = TimeZone.current` explicitly on every parser formatter, even though it is the default, so the intent is visible.

## Date and Time Formatting

All date and time values displayed in SwiftUI views must respect both the system language and the in-app language override. Always obtain the locale from SwiftUI's environment and apply it to every date format:

- In any `View` struct that displays dates, declare `@Environment(\.locale) private var locale`.
- When using SwiftUI's `Text(_:format:)` with a `Date.FormatStyle`, always append `.locale(locale)` to the format style, e.g. `Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))`.
- When using `DateFormatter` directly, set `formatter.locale = locale` (from `@Environment(\.locale)`) rather than `.current` or `.autoupdatingCurrent`.
- Never hardcode a locale or use `Locale.current` directly in a view — it does not reflect the in-app language override.

## Release Notes & Commit Messages (GitHub)

When asked for a GitHub release note, PR description, or commit message, use the Conventional Commits style below.

**Title** — a single Conventional Commits line: `<type>: <imperative summary>` (e.g. `feat: BLE Diagnostic Logging with saveable trace files`). Common types: `feat`, `fix`, `refactor`, `perf`, `docs`, `chore`, `test`. Keep it under ~72 characters, lowercase after the colon, no trailing period.

**Body** — a blank line after the title, then a one-paragraph summary of what the change does and why, followed by grouped sections with these exact headings (include only the ones that apply, in this order):

- `Added:` — new user-facing features or capabilities.
- `Changed:` — modifications to existing behaviour.
- `Fixed:` — bug fixes.
- `Notes:` — caveats, defaults, safety/behaviour details worth calling out.

Each section is a bullet list (`- `). Write from the user/reviewer's perspective; name the concrete UI location (e.g. "Settings → Bluetooth Import"), file/type where useful, and any default state.

**Commit trailer** — when the output is an actual git commit message (not just a GitHub release body), end with the standard co-author trailer:
`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
Omit the trailer when the text is only a GitHub release/PR body.

When a plain, non-technical version is also requested, provide a separate "user-facing" note in simple language (no type prefix, no file/type references), describing what the user can now do and how.

## DiveStore Architecture

All dive-list data flows through a single `DiveStore`. Follow these rules for any change that reads or mutates dive data displayed in lists, on the map, or in trips.

### Purpose and Motivation

SwiftData `@Query` has no delta mechanism — every observer receives a full re-delivery on any activation, so with multiple active `@Query Dive` observers (there were ~10), every sheet open/close cascaded through all of them. At 10 000+ dives the `gasType` JSON decode and `seenFish` relationship faults triggered by those cascades caused hard freezes. `DiveStore` collapses ownership to a single query and delivers targeted, scoped updates so the app scales from 10 to 10 000+ dives.

### Core Types

- **`@MainActor @Observable final class DiveStore`** — the single source of truth for the dive list, filters, sort, and all derived caches. It is injected via the SwiftUI environment from `BlueDiveApp.swift` and is **never** instantiated inside a child view.
- **`struct DiveSummary: Identifiable, Hashable, Sendable`** — a value-type snapshot of one dive used by list rows, the map, and trips. All fields are scalar (no SwiftData faults). It carries mutable badge fields (`hasFish`, `hasPhotos`, `seenFishNames`) that the store patches in place. It is `Sendable` specifically so it can cross concurrency boundaries safely.
- **`enum DiveChangeScope`** — the change classification passed to `commit(_:affects:)`: `.list`, `.rowBadges`, `.rowFields`, `.nothing`.

### Environment Injection

- `BlueDiveApp` owns `@State private var diveStore = DiveStore()` and passes it down with `.environment(diveStore)` on the root container wrapping `MainTabView` (`RootLaunchContainer`).
- Every child view that needs the store declares `@Environment(DiveStore.self) private var store`. Never declare `@State private var store = DiveStore()` in a child view — that creates a second, disconnected instance.

### @Query Ownership

- **`ContentView` is the only `@Query Dive` owner.** It owns `@Query dives: [Dive]`, `@Query allInsurances: [DivingInsurance]`, `@Query allGear: [Gear]`, `@Query allCertifications: [Certification]`, and `@Query allMarineSights: [MarineSight]`.
- When `dives`/`allMarineSights` change, `ContentView` passes them to `store.scheduleRebuild(dives:allMarineSights:selectedDiver:)`. When `allGear`/`allCertifications`/`allInsurances` change, it calls `store.updateDiverSources(gear:certifications:insurances:)` instead — a narrow path that only refreshes the diver-name list, not the full dive pipeline.
- No other view may add a `@Query Dive`. Adding one reintroduces the full-re-delivery cascade freeze this architecture exists to prevent.

### The Three Commit Scopes

On any save, call `store.commit(_ dive: Dive, affects: DiveChangeScope)` with the narrowest scope that covers the change:

- **`.list`** — full rebuild via `rebuildDerivedDiveState(...)` (called directly, bypassing the debounce). Use when a change reorders or renumbers the list: timestamp, depth, duration, dive number, or diver name (EditMenuStatsView).
- **`.rowFields`** — incremental single-dive summary patch. Rebuilds one `DiveSummary` and patches `cachedSummaries[idx]` in place; **`store.dives` is NOT reassigned.** If an active filter (search text, country, gas type, depth range, etc.) is set and the edited field could affect filter membership, `.rowFields` falls back to a full `rebuildFilteredDives` for that dive. Use for edits that change displayed row fields but not list order: site name, country, conditions, gas type (EditSiteDetailsView, EditConditionsView, EditGazView).
- **`.rowBadges`** — badge-only patch via `refreshBadgeSets`. Faults `seenFish`/`photosData` for the one changed dive and patches `hasFish`/`hasPhotos`/`seenFishNames` on its summary. Use for fish and photo add/remove (AddFishView, EditFishView, DiveDetailView+MenuTab).
- **`.nothing`** — no-op. Use for changes that affect neither list order, row fields, nor badges.
- **`store.commitListRebuild()`** — full rebuild for the orphan-fish edge case (a fish with no parent dive), where there is no single `Dive` to pass to `commit`.

### View Update Signals

- `store.cachedSummaries` changes on **all three** commit scopes (`.list`, `.rowFields`, `.rowBadges`). A view that must refresh on any dive-field change observes `onChange(of: store.cachedSummaries)` and bumps a local version counter.
- `store.dives` is reassigned **only** on `.list` commits. Do **not** use `onChange(of: store.dives)` as the change signal in a view that must respond to `.rowFields` edits — it will miss them.
- `store.searchText` updates synchronously as the user types, but `store.cachedFilteredSummaries` lags it by up to 150ms via `scheduleSearchRebuild`'s debounce. A view deciding what empty-state to show (e.g. "no results for this search" vs. "no results for this diver") based on whether search is active must check `store.appliedSearchText` — the debounce-synced value, updated inside `rebuildFilteredDives` — not the live `store.searchText`, or it can briefly render a state describing search results that haven't been computed yet.
- `DiveMapView` already uses `onChange(of: store.cachedSummaries, initial: true)`. Do not change it.
- `MarineLifeView` uses a fish-specific hash in its `.task(id:)` fingerprint and needs no summary observer.

### Background Safety

- `Task.detached` and `nonisolated` functions must never read `UserPreferences.shared` or any other `@MainActor`-isolated property.
- For depth display inside a background task, capture `displayInFeet: Bool` and `depthFactor: Double` on the MainActor first and pass them in as parameters.
- Never read `DiveSummary.displayMaxDepth` from a background task — it reads `UserPreferences.shared` (MainActor-isolated). Use the raw value plus a captured `depthFactor` instead.
- `DiveSummary` conformance to `Sendable` is what makes it safe to hand across these boundaries.

### What NOT To Do

- Never add `@Query var dives: [Dive]` to any view other than `ContentView`.
- Never post `NotificationCenter` notifications to signal dive changes — call `store.commit(_:affects:)` directly.
- Never call `store.scheduleRebuild(...)` from a child view. Only `ContentView` owns the query inputs; child views call `commit()`.
- Never use `onChange(of: store.dives)` to re-trigger a view that displays `.rowFields`-affected data (site, country, gas stats); use `onChange(of: store.cachedSummaries)`.
- Never read `DiveSummary.displayMaxDepth` from a background task; use the raw value with a captured `depthFactor`.

### Adding a New Edit Sheet

1. Determine the applicable `DiveChangeScope` from the list above.
2. Add `@Environment(DiveStore.self) private var store` to the edit view.
3. On save, call `store.commit(dive, affects: <scope>)`, replacing any `NotificationCenter.default.post(...)` call.
4. If the view must recompute its stats when any dive field changes, add `@State private var contentVersion: Int = 0`, add `.onChange(of: store.cachedSummaries) { _, _ in contentVersion += 1 }`, and include `contentVersion` in the view's `.task(id:)` fingerprint.

## MapKit Annotation Z-Order Has No SwiftUI-Level Control

SwiftUI's `Annotation` conforms to `MapContent`, not `View` — `.zIndex()` does not compile on it, and the complete public `MapContent` modifier surface (`tint`, `tag`, `foregroundStyle`, `stroke`, `strokeStyle`, `annotationTitles`, `annotationSubtitles`, `mapOverlayLevel`, `mapItemDetailSelectionAccessory` — confirmed by dumping the SDK's `_MapKit_SwiftUI.swiftinterface`) exposes no equivalent of `MKAnnotationView.zPriority`/`displayPriority`. **The order two `Annotation`s are declared in a `Map`'s content builder has no effect on which one renders in front when they visually overlap** — MapKit decides that itself, using its own geography-based heuristic (observed: the annotation with the lower latitude renders on top, regardless of declaration order — verified by swapping declaration order and confirming zero visual change, then reverting one annotation's content back to the old code as a control and re-measuring the same pin to confirm the shift was real).

If a specific annotation must always render in front of another when they overlap (e.g. a dive's entry pin must win over its exit pin), the only way to get real control is to **merge the two into a single `Annotation`** and stack them yourself with a plain SwiftUI `ZStack` inside its `content:` closure — ordinary `ZStack` layering *is* respected (later view = on top), because at that point it's no longer two independent MapKit-managed annotations, it's one annotation containing ordinary SwiftUI content. The "back" pin needs to be manually offset to its true screen position relative to the "front" pin's anchor, using `MKMapPoint` to project both coordinates and taking the difference (scaled by points-per-map-point derived from the visible `MKMapRect`) as a SwiftUI `.offset()`. Fall back to two independent annotations once they're far enough apart to read as separate pins, so each keeps its own accurate anchor and label. See `SiteEntryExitMap` in `DiveDetailView+SiteDetails.swift` for the full implementation (overlap-distance threshold, live-vs-initial `MKMapRect` handling, and the identical/overlapping/separate three-way branch).
