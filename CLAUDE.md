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

All public-facing text must be defined in code as localizable strings and translated in French (Canada), German, and Dutch in the Localizable file. In SwiftUI views, use `LocalizedStringKey` (e.g. `Text("My Key")`) for direct text display. When building strings programmatically — including inside `Text(verbatim:)` with interpolation, even within SwiftUI views — use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()` instead of `String(localized:)`, because `String(localized:)` follows the OS language and ignores the in-app language override. Outside SwiftUI views (e.g. PDF generation, enum properties, model logic), always use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()`. Never wrap `NSLocalizedString` in a custom helper function (e.g. `L("key")`), because Xcode's string catalog compiler only detects keys from direct `NSLocalizedString` calls with literal strings — a wrapper hides the keys and causes Xcode to mark them as "Stale". When localizing data-model values from a known finite set of options (e.g. weather, current, tank type), use a `switch` with literal `NSLocalizedString` calls for each case so Xcode can detect every key; never pass a runtime variable as the key. Every new localizable key must also have corresponding `fr-CA`, `de`, and `nl` entries added to `Localizable.xcstrings` in the same commit. All German (`de`) and Dutch (`nl`) translations that are added or edited must be marked with `"state" : "needs_review"` in `Localizable.xcstrings`.

When adding a new localizable string, write the Swift code first and build the project so Xcode auto-inserts the key into `Localizable.xcstrings`. For `NSLocalizedString` calls, always include the `value:` parameter with the English text as a fallback so the string displays correctly before Xcode syncs the catalog (e.g. `NSLocalizedString("Service record saved.", bundle: Bundle.forAppLanguage(), value: "Service record saved.", comment: "")`). Only add `fr-CA`, `de`, and `nl` translations after confirming the key exists in the file.

When editing or adding translations in `Localizable.xcstrings`, never read the full file. Always grep for the exact key string first to get its line number, then read only ~25 lines around that position. The file is large (24 000+ lines) and targeted reads are the only efficient approach.

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

- **`ContentView` is the only `@Query Dive` owner.** It owns `@Query dives: [Dive]`, `@Query allInsurances: [DivingInsurance]`, and `@Query allMarineSights: [MarineSight]`.
- When those query results change, `ContentView` passes them to `store.scheduleRebuild(dives:allInsurances:allMarineSights:selectedDiver:force:)`.
- No other view may add a `@Query Dive`. Adding one reintroduces the full-re-delivery cascade freeze this architecture exists to prevent.

### The Three Commit Scopes

On any save, call `store.commit(_ dive: Dive, affects: DiveChangeScope)` with the narrowest scope that covers the change:

- **`.list`** — full rebuild via `scheduleRebuild(force: true)`. Use when a change reorders or renumbers the list: timestamp, depth, duration, dive number, or diver name (EditMenuStatsView).
- **`.rowFields`** — incremental single-dive summary patch. Rebuilds one `DiveSummary` and patches `cachedSummaries[idx]` in place; **`store.dives` is NOT reassigned.** If an active filter (search text, country, gas type, depth range, etc.) is set and the edited field could affect filter membership, `.rowFields` falls back to a full `rebuildFilteredDives` for that dive. Use for edits that change displayed row fields but not list order: site name, country, conditions, gas type (EditSiteDetailsView, EditConditionsView, EditGazView).
- **`.rowBadges`** — badge-only patch via `refreshBadgeSets`. Faults `seenFish`/`photosData` for the one changed dive and patches `hasFish`/`hasPhotos`/`seenFishNames` on its summary. Use for fish and photo add/remove (AddFishView, EditFishView, DiveDetailView+MenuTab).
- **`.nothing`** — no-op. Use for changes that affect neither list order, row fields, nor badges.
- **`store.commitListRebuild()`** — full rebuild for the orphan-fish edge case (a fish with no parent dive), where there is no single `Dive` to pass to `commit`.

### View Update Signals

- `store.cachedSummaries` changes on **all three** commit scopes (`.list`, `.rowFields`, `.rowBadges`). A view that must refresh on any dive-field change observes `onChange(of: store.cachedSummaries)` and bumps a local version counter.
- `store.dives` is reassigned **only** on `.list` commits. Do **not** use `onChange(of: store.dives)` as the change signal in a view that must respond to `.rowFields` edits — it will miss them.
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
