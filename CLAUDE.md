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

### In-App Language Override

The in-app language (Settings → Appearance & Language → Language, `UserPreferences.languageMode`) changes only the app's own text; the process still runs in the system language. It reaches text through two independent paths, and every new piece of UI must be covered by one of them:

- **`LocalizedStringKey` text and environment-formatted dates** resolve through `\.locale`, which `LanguageOverrideModifier` sets on the main window's content in `BlueDiveApp` (only when a specific language is chosen; "System" leaves `\.locale` untouched).
- **`NSLocalizedString(…, bundle: Bundle.forAppLanguage())`** reads `UserPreferences` directly and does not depend on the environment.

**macOS: every window-hosted presentation must re-apply the locale.** On macOS each sheet is hosted in its own window whose root resets `\.locale` to the system language — even though custom environment values (`DiveStore`, `CloudKitSyncMonitor`) still propagate — so without a fix a sheet, and any sheet presented from it, shows the system language while the main window shows the override. `.standardSheetPresentation()` (see "Sheet sizing") re-applies `LanguageOverrideModifier` inside every sheet on macOS and follows a language change live. A scene-level `WindowGroup { }.transformEnvironment(\.locale)` / `.environment(\.locale, …)` does **not** reach sheet windows (tested) — do not rely on it. Any new window-hosted SwiftUI content on macOS — a `.popover`, `.inspector`, a new `Window`/`WindowGroup` scene, or an `NSHostingView`/`NSHostingController` — must apply `LanguageOverrideModifier(locale: UserPreferences.shared.languageMode.locale)` (observing `UserPreferences`) at its root, and be tested with an in-app language different from the system language. Alerts and swipe actions follow the view that presents them and need nothing (verified on macOS in the main window and inside a sheet); confirmation dialogs and context menus are expected to behave the same but have not been verified. A `.sheet` attached outside `LanguageOverrideModifier` in `BlueDiveApp` (e.g. the menu-bar About sheet) gets the override only through `.standardSheetPresentation()`.

**Text localized once and kept outside the view tree** does not update by itself when the language changes: scheduled notification titles/bodies and notification action titles are generated when scheduled/registered, so `MainTabView` reschedules reminders and re-registers categories on `languageMode` change. Any new content of this kind (notifications, widget timeline text, Spotlight or App Intents strings, cached strings) must be regenerated on a language change as well. Notifications already delivered cannot be changed.

**System-drawn UI follows the process language**, not the in-app override, on both platforms: the macOS menu bar — including our own `.commands` items ("About BlueDive", "Settings…"; verified: they stay in the system language alongside Hide/Quit, which keeps the menu consistent, so leave them as `LocalizedStringKey`) — permission prompts (`InfoPlist.xcstrings`), open/save panels, share sheets and document pickers. This is a platform limitation — do not try to fix it by writing `AppleLanguages` (it needs a relaunch and changes `Locale.current`, breaking the Number Formatting rule below). Users who want those in another language set it per app in System Settings → General → Language & Region → Applications (macOS) or Settings → BlueDive → Language (iOS).

**Test every language-related change on My Mac with the system language set differently from the in-app language** (e.g. system French, app Deutsch): the main window, a sheet, a sheet opened from a sheet, an alert inside a sheet, and a view showing dates.

### Localizable.xcstrings — never edit by hand

`BlueDive/Localizable.xcstrings` is ~1 MB / 38 000 lines. **Never open, read, grep-and-read, or hand-edit it, and never use a file-edit tool on it.** Reading any part of it into context is wasted time. All changes go through `Scripts/xcstrings.py`, which edits the JSON in place, preserves Xcode's exact formatting (byte-identical round-trip, minimal diff), and enforces the review-state rule automatically (`fr-CA` → `translated`; `de` and `nl` → `needs_review`).

The `needs_review` state left on `de`/`nl` is intentional, not a bug: a native reviewer promotes those to `translated` in Xcode's catalog editor (the script never writes `translated` for `de`/`nl`), and a later re-translation via `set` correctly resets them to `needs_review` so the edit is re-reviewed.

Workflow for every new or changed user-facing string:

1. Write the Swift code with the literal key. For `NSLocalizedString`, always pass `value:` with the English text so the string displays before the catalog syncs, e.g. `NSLocalizedString("Service record saved.", bundle: Bundle.forAppLanguage(), value: "Service record saved.", comment: "")`.
2. Build the project (⌘B) so Xcode inserts the key into the catalog. Do not add keys to the catalog yourself. A key that exists only inside `#if os(macOS)` (or only inside `#if os(iOS)`) is extracted only by a build for that platform — build the **My Mac** destination as well as an iOS destination when the change touches platform-specific code.
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

A string-backed field pre-filled from a stored value shows it rounded (e.g. `editableString(decimals: 2)`, `"%.6f"` coordinates). Never parse that text back unconditionally on save — it would silently round data the user did not touch. Keep the stored value with its pre-fill text in a `PrefilledDouble` (`CrossPlatformImage.swift`: `.decimals(_:_:minDecimals:)`, `.coordinate(_:)`) and save through `resolve(_:)` (or `preservedDouble(_:original:originalText:)`): an untouched field keeps the stored value at full precision; an edited one is parsed; an emptied one becomes nil. Code that rewrites the text with an exact value (copying a site, resetting GPS, "Same as Entry") replaces the whole `PrefilledDouble`. When a field's `onChange` parses its text into a working Double, skip re-parsing text the code wrote from that exact value (a unit switch or template apply), or the value is rounded to its text — mark that text and skip only it (see `setProgrammaticText` / `skipsProgrammaticText` in the tank editor); never compare against the value's formatting, which would also skip a user edit that happens to match it and leave the field showing one value while saving another. Keep the stored value in `@State`, not a `let`: a `let` is recomputed on every parent re-render (e.g. an iCloud sync) while the text keeps its first value. `parseFlexibleDouble` rejects non-finite input ("inf", "nan", "1e400"). Never convert parsed or stored Doubles with `Int(_:)` (it traps beyond `Int`'s range, e.g. a typed "99999999999999999999"): use `Int(exactly: value.rounded())` for input (nil instead of a trap; the duration field rounds to the nearest minute), and `editableString` rather than `String(Int(...))` for pre-fill text.

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

## macOS Support (Native Universal App)

BlueDive is a universal app: the same SwiftUI code builds for iOS/iPadOS and as a **native macOS** app (the "My Mac" destination). "Designed for iPad" is disabled (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`), so the iOS build never runs on a Mac and `ProcessInfo.processInfo.isiOSAppOnMac` is always `false` — do not use it.

### One Shared UI

The Mac app must offer the same user experience as iOS/iPadOS, built from the same code. Do not write a separate macOS layout (`macOSBody`, `macOSLayout`, a macOS-only toolbar or sheet) for a screen that already exists on iOS.

- **Prefer shims over `#if`.** When a SwiftUI API is iOS-only, add a macOS equivalent to `PlatformCompat.swift` so call sites stay identical (existing shims: `navigationBarTitleDisplayMode(_:)`, `.bottomBar`, `.topBarLeading` → `.navigation`, `.topBarTrailing` → `.automatic`, `NSColor.systemGroupedBackground`). Use `.fullWidthSegmentedPicker()` instead of `.pickerStyle(.segmented)` for any segmented picker that should span its container, as it does on iOS — on macOS a segmented control otherwise sizes to its segments and shows its label. Keep plain `.pickerStyle(.segmented)` only for deliberately compact pickers (inline toggles with a fixed `.frame(maxWidth:)`, toolbar items). Every `Button` needs an explicit look on macOS, because an unstyled macOS Button is a bordered push button (grey capsule sized to its label) everywhere, while on iOS it is borderless: use `.listRowButton()` for a Button that acts as a whole `List`/`Form` row (navigation-style rows, picker choices, text action rows — accent-coloured by default, red for `role: .destructive`, whole row clickable), `.borderlessButton()` for a Button in an ordinary layout (cards, headers, bottom bars, icon buttons, inline links), or an explicit `.buttonStyle(...)`. Buttons inside toolbars, menus, alerts, confirmation dialogs, context menus, swipe actions and menu-bar commands are styled by the system and need none of these.
- **Toolbars in sheets**: in a sheet, macOS renders `.primaryAction` and `.confirmationAction` items as the sheet's accent-filled default button at the bottom (triggered by Return). In any view presented as a sheet, place utility items (filter, add, refresh, "…" menus) with `.sheetPrimaryAction` (iOS `.primaryAction`, macOS `.automatic`) — a cyan icon in a `.primaryAction` item is invisible on the cyan fill. Reserve `.confirmationAction` for the real confirm button (Save/Done/Add), and colour its label with `.confirmationActionForeground(_:)` (applied on iOS only) instead of `.foregroundStyle(_:)`. Root tab views and views pushed in the main window keep `.primaryAction` — they use the window toolbar.
- **Principal items in the main window**: on macOS the tab bar (Dives / Map / Equipment / Documents) occupies the centre of the window toolbar, so a `.principal` item in a tab root or a view pushed from it sits beside the tabs and shifts them. Use `.principalOutsideTabBar` there (iOS `.principal`, macOS `.primaryAction`). Plain `.principal` is fine in sheets, which have no tab bar. Cross-platform helpers that wrap both implementations (`PlatformImage`, `PlatformColor`, `Color.platformBackground`, `platformKeyboardType(_:)`, `platformTextInputAutocapitalization(_:)`, `adaptiveDatePickerStyle()`, `closeToolbarButton(action:)`) live in `CrossPlatformImage.swift`.
- **Use `#if os(macOS)` only for genuine platform differences**: AppKit/UIKit-only APIs (`NSSavePanel` vs `.fileExporter`, `NSPasteboard` vs `UIPasteboard`, `NSWorkspace`, fonts/images in PDF generation), APIs unavailable on macOS (`fullScreenCover` → `.sheet`, paging `TabView` → one page at a time, `BGTaskScheduler`), Mac-only features (menu bar commands, "Show database in Finder"), and input-method adaptations (previous/next dive buttons instead of swipe). Keep such a branch as small as possible — wrap the single differing modifier or call, not the whole view.
- Before removing or editing a platform branch, verify its boundaries with `grep -n "#if os\|#else\|#endif"` — do not assume a diff hunk stayed within its intended platform.
- Every change must build for **both** an iOS destination and **My Mac** before it is considered done.
- **Keep iOS untouched**: a macOS-only fix must not change what the iOS compiler sees. Put the macOS behaviour inside a helper whose iOS branch returns the view (or the original call) unchanged — prefer a function returning the original control over a wrapper `View` struct, so the iOS view tree stays identical, or inside `#if os(macOS)`; do not add "harmless on iOS" modifiers unguarded.

### Presentation & Controls

- **Sheet sizing**: Every `.sheet()` presentation must end with `.standardSheetPresentation()` (`PlatformCompat.swift`), never the individual presentation modifiers. On iOS it is exactly `.presentationSizing(.page)`, `.presentationDetents([.large])` and `.presentationDragIndicator(.visible)`; pass `dragIndicator: .hidden` for a sheet that deliberately hides the indicator (the calculator safety warnings). On macOS it also re-applies the in-app language: each sheet is hosted in its own window whose root resets `\.locale` to the system language, so without it a sheet — including one presented from another sheet — shows the system language instead of the in-app override. On macOS, `.presentationSizing(.page)` alone sizes the sheet (detents and the drag indicator have no effect there); do not add a macOS-only `.frame(width:height:)` or `.frame(minWidth:…maxWidth:…)` to sheet content — it overrides `.page` and makes the sheet smaller or narrower than on iPad.
- **Date pickers**: Use `.adaptiveDatePickerStyle()` (defined in `CrossPlatformImage.swift`) instead of `.datePickerStyle(.compact)`. It applies the compact style on every platform (a date field that opens a calendar popover); do not use `.graphical` in form rows on macOS, where it renders a fixed, small inline calendar. macOS has no seconds component (`.hourMinuteAndSecond` is unavailable) — use `.hourAndMinute` and preserve the stored seconds on save.
- **Forms**: every `Form` must carry `.groupedFormStyleOnMac()` (or an explicit `.formStyle(.grouped)`) directly. macOS otherwise uses its two-column style (labels in a separate leading column); a form style set higher up, e.g. at the app root, does not reach Forms inside sheets. The helper returns the view unchanged on iOS, where grouped is already the default.
- **List-based sheets**: a `List` that forms a sheet's main content (a picker or settings-style list of sections) uses `groupedList { … }` (`PlatformCompat.swift`) instead of `List { … }`. macOS has no inset-grouped list style — a plain `List` there renders sidebar-like, without row cards — so on macOS the helper shows the same content in a grouped `Form`, matching the other sheets; on iOS it returns exactly `List { … }`. Main-window lists (dive list, Equipment, Documents) and lists with their own explicit `.listStyle(...)` keep `List`.
- **Toggles**: every `Toggle` uses `.fullWidthSwitch()` (`PlatformCompat.swift`). On macOS a Toggle outside a Form is otherwise a checkbox, and a `.switch` toggle sizes to its label, shrinking the card it sits in; the helper gives the iOS layout (label leading, switch trailing, full width). On iOS it returns the view unchanged; if the Toggle needs an explicit style on iOS, use `.fullWidthSwitch(iOS: .switch)` instead of a separate `.toggleStyle(...)`. When adding it to an existing chain, place it before any modifier that takes a trailing closure (e.g. `.onChange(of:) { }`).
- **Menu pickers in cards**: a menu-style `Picker` in a custom card layout (not inside a `Form`) uses `fullWidthPicker(title, selection:) { … }` (`PlatformCompat.swift`) — on macOS it lays out label leading / pop-up trailing at full width instead of a label+pop-up pair centred at natural size; on iOS it returns exactly the plain `Picker`. Pickers inside a `Form` need nothing (the grouped style already lays them out as rows).
- **Text fields in Forms**: use `formTextField("Title", text:)` (`PlatformCompat.swift`) instead of `TextField` for any text field inside a `Form` (directly or via a row component such as `MenuTextField`). In a macOS grouped Form a plain `TextField`'s title becomes a separate leading label and the value is pushed to the trailing edge (duplicating icon rows' own labels); `formTextField` hides that label on macOS and shows the title as the grey placeholder, as on iOS. On iOS it returns exactly `TextField(title, text:)`; use `formTextField(verbatim:text:)` for a computed `String` title and the `axis:` overload for multi-line fields.
- **Swipe to delete**: on iOS a `List` turns `.onDelete` into a trailing swipe-to-delete automatically; macOS does not. Every list that deletes with `.onDelete` also needs a `#if os(macOS)` trailing `.swipeActions(edge: .trailing)` with a `role: .destructive` button that calls the same handler (see `ContentView`, `GearListView`, `TankTemplateListView`, `GearGroupListView`). Give that button `.tint(.red)`: macOS colours swipe buttons with the ambient tint, so without it the root `.tint(.cyan)` turns the Delete button cyan instead of the destructive red iOS applies automatically (this is a swipe action, not a toolbar button, so the no-local-tint rule does not apply). Leave `.onDelete` in place for iOS.
- **Row separators in main-window lists**: macOS draws no row separators in `.sidebar` or `.plain` lists, and `.listRowSeparator(.visible)` cannot force them (the list style has the final say). A list that shows separators on iOS and needs them on macOS sets its row background with `.listRowBackground(_:macSeparator:)` (`PlatformCompat.swift`) instead of `.listRowBackground(_:)`, passing `false` for the last row of each section as iOS does (see the dive list in `ContentView`). On iOS it is exactly `.listRowBackground(_:)`.
- **Settings**: Settings is the same sheet on both platforms (presented by `ContentView`); on macOS the app menu's **Settings…** command (⌘,) posts `.openSettings` to present it. Do not add a separate SwiftUI `Settings` scene.
- **Pages pushed inside a sheet**: on iOS a sheet can be swiped down from any page of its `NavigationStack`; macOS has no swipe-to-dismiss, and the root page's close button and Escape shortcut disappear once a page is pushed, so the user would have to go Back before closing. Give every page pushed inside a sheet `.closeSheetButtonOnMac { dismiss() }` (`PlatformCompat.swift`) at its `NavigationLink` destination, passing the dismiss action of the view that owns the `NavigationStack` — inside a pushed page `@Environment(\.dismiss)` only pops the page (see the topic pages in `SettingsView`). On macOS it adds `closeToolbarButton` in `.cancellationAction` with the Escape shortcut and sets `\.isPushedInSheet`; on iOS it returns the view unchanged. A page shown both in the main window and inside a sheet (e.g. `DiveDetailView`, pushed from Statistics, Trips, Marine Life and the Calendar) reads `@Environment(\.isPushedInSheet)` and places its utility items with `.sheetPrimaryAction` when it is true — otherwise macOS draws its `.primaryAction` items as the sheet's accent-filled default button (see "Toolbars in sheets").
- **Window scenes need a stable id**: every macOS `WindowGroup`/`Window` scene must have an explicit `id:` (the main window uses `WindowGroup(id: "main")` through `mainWindowGroup` in `BlueDiveApp`). SwiftUI derives the window's frame autosave name from it (`<id>-AppWindow-<n>`, observed, not documented), which is what lets AppKit save and restore the window's size and position across launches while "Close windows when quitting an application" is on. Without an id the name contains a memory address that changes every launch, so the frame is never restored. The main window opens maximized on the focused display on first launch (`.defaultWindowPlacement`) and AppKit's autosave restores it afterwards — do not add a custom frame save/restore or a macOS-only `.frame(width:height:)` for window sizing. Keep the id macOS-only (as `mainWindowGroup` does) so the iOS scene stays unchanged.

## Liquid Glass & HIG Toolbar Compliance

Under iOS/macOS 26+ "Liquid Glass," toolbar buttons render inside a translucent glass capsule. Follow these rules for any toolbar, sheet, or button work.

### Root-Cause Rule: No Local Tint on Bare Toolbar Buttons

A local `.tint(...)` placed directly on a bare toolbar `Button` (one **not** using `.buttonStyle(.borderedProminent)` or another explicit button style) fills the Liquid Glass capsule **background**, not just the label — this is what caused toolbar buttons to render white/wrong instead of the app's cyan brand color, especially on Mac. This is the single most important rule in this section; when in doubt, grep the whole tree for `.tint(` and check each hit against the categories below.

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

### Icon Simplification

- The Liquid Glass capsule already provides a visual container — do not additionally wrap toolbar icons in `.circle`/`.circle.fill` SF Symbol variants (use `plus`, `ellipsis`, `info`, not `plus.circle.fill`, `ellipsis.circle.fill`, `info.circle`). This applies to both platforms; toolbar icons are shared code.
- Icon+text (`HStack { Image; Text }`) toolbar labels collapse to icon-only on regular-width idiom (iPad/Mac) by Apple's documented default; no modifier prevents this. If the text must always stay visible, drop the icon entirely rather than fighting the collapse.

### Toolbar Layout & Accessibility

- Never group multiple interactive controls inside one `HStack` that itself sits inside a single `ToolbarItem`. Under SDK 26/27 toolbar-overflow layout this silently clips every control but the first when space is constrained (e.g. a narrow Mac window). Give each control its own `ToolbarItem`/`ToolbarItemGroup` entry.
- **Grouping on macOS**: the iOS navigation bar merges neighbouring items into one glass capsule, but macOS only shares a capsule between items in the same `ToolbarItemGroup`, and gives every toolbar `Menu` its own capsule with a ⌄ pull-down indicator. For a tab root or main-window view, keep the iOS toolbar as separate `ToolbarItem`s and add a `#if os(macOS)` branch that places the same controls in one `ToolbarItemGroup` per side (see `ContentView`, `DiveMapView`, `GearListView`, `DocumentsView`, `DiveDetailView`). Write each control once as a `private var … : some View` property used by both branches, and put `.toolbarMenuIndicatorHiddenOnMac()` on menus (`DiverFilterToolbar` already does). A lone toolbar `Menu` in a sheet needs only `.toolbarMenuIndicatorHiddenOnMac()`. Two groups placed on the same side are merged into one capsule on macOS; keep them distinct with `ToolbarSpacer(.fixed, placement:)` between them, inside `if #available(iOS 26.0, macOS 26.0, *)` (see the previous/next vs Export/Edit groups in `DiveDetailView`).
- `.topBarLeading`/`.topBarTrailing` may be used unguarded: `PlatformCompat.swift` maps them to `.navigation` / `.automatic` on macOS. Cross-platform placements (`.cancellationAction`, `.confirmationAction`, `.destructiveAction`, `.primaryAction`, `.automatic`) remain preferred where they express the intent.
- Every icon-only toolbar control (a `Button`/`Menu` whose label is only an `Image`, no text) must carry `.accessibilityLabel(Text("..."))`, translated per the Localization workflow. When the label depends on state (e.g. a show/hide toggle), write two literal `Text("Key A")`/`Text("Key B")` branches — never a ternary or variable passed as the key (`Text(condition ? LocalizedStringKey("A") : LocalizedStringKey("B"))` bypasses Xcode's literal-string extraction).

### What NOT To Do

- Never add a local `.tint()` to a bare (non-`.buttonStyle`) toolbar `Button` — color the `Image` inside the label with `.foregroundStyle()` instead, or rely on the ambient `AccentColor`.
- Never remove a `.tint()` from a `.buttonStyle(.borderedProminent)` button without checking whether it encodes intentional per-section/per-tab color-coding.
- Never place multiple controls in one `HStack` inside a single `ToolbarItem`.
- Never add a macOS-only layout, toolbar, or sheet for a screen that already exists on iOS — share the iOS code and add a shim to `PlatformCompat.swift` if an API is missing on macOS.
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

**Commit trailer** — when the output is an actual git commit message (not just a GitHub release body), end with the standard co-author trailer naming the Claude model that is actually doing the work in the current session (do not copy a model name from an older commit), e.g.:
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
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

- **`ContentView` is the only `@Query Dive` owner.** It owns `@Query dives: [Dive]` and `@Query allMarineSights: [MarineSight]`, and when they change passes them to `store.scheduleRebuild(dives:allMarineSights:selectedDiver:)`.
- **`DiverSourcesFeeder` (`DiverFilter.swift`) feeds the rest of the diver-name list.** It owns `@Query` for `Gear`, `Certification` and `DivingInsurance`, and when any of their diver names change calls `store.updateDiverSources(gear:certifications:insurances:)` — a narrow path that only refreshes the diver-name list, not the full dive pipeline. It is attached once with `.background(DiverSourcesFeeder())` to the `TabView` in `MainTabView`, so it stays mounted whatever tab is selected (`ContentView` is not guaranteed to be mounted or updating while another tab is shown). Keep it a background view — putting the queries on `MainTabView` itself would re-evaluate all four tabs on every gear or document change.
- **Diver-name lists read `store.cachedUniqueDivers`** — diver filter menus (`DiverFilterToolbar`, `.diverFilterReset`) and Diver field suggestions alike. Never call `DiverFilter.uniqueDivers(...)` outside `DiveStore`, and never add a `Gear`/`Certification`/`DivingInsurance` `@Query` just to build a diver list. `cachedUniqueDivers` is published only after both feeders have delivered at least once, so a persisted diver selection is never cleared by a half-built list at launch.
- No other view may add a `@Query Dive`. Adding one reintroduces the full-re-delivery cascade freeze this architecture exists to prevent.

### The Three Commit Scopes

On any save, call `store.commit(_ dive: Dive, affects: DiveChangeScope)` with the narrowest scope that covers the change:

- **`.list`** — full rebuild via `rebuildDerivedDiveState(...)` (called directly, bypassing the debounce). Use when a change reorders or renumbers the list: timestamp, depth, duration, dive number, or diver name (EditMenuStatsView).
- **`.rowFields`** — incremental single-dive summary patch. Rebuilds one `DiveSummary` and patches `cachedSummaries[idx]` in place; **`store.dives` is NOT reassigned.** If an active filter (search text, country, gas type, depth range, etc.) is set and the edited field could affect filter membership, `.rowFields` falls back to a full `rebuildFilteredDives` for that dive. Use for edits that change displayed row fields but not list order: site name, country, conditions, gas type (EditSiteDetailsView, EditConditionsView, EditGazView).
- **`.rowBadges`** — badge-only patch via `refreshBadgeSets`. Faults `seenFish`/`photosData` for the one changed dive and patches `hasFish`/`hasPhotos`/`seenFishNames` on its summary. Use for fish and photo add/remove (AddFishView, EditFishView, DiveDetailView+MenuTab).
- **`.nothing`** — no-op. Use for changes that affect neither list order, row fields, nor badges.
- **`store.commitListRebuild()`** — full rebuild for the orphan-fish edge case (a fish with no parent dive), where there is no single `Dive` to pass to `commit`.
- Both `.list` and `commitListRebuild()` cancel any debounced `@Query` rebuild, so they rebuild from the **latest `@Query` delivery** (dives and marine sights, recorded by `scheduleRebuild` and `rebuildDerivedDiveState`), not from `store.dives`: a delivery still in the 50 ms debounce (e.g. a dive added by the same iCloud import) would otherwise be dropped until the next membership change, since saving never re-delivers the `@Query`.

### View Update Signals

- `store.cachedSummaries` changes on **all three** commit scopes (`.list`, `.rowFields`, `.rowBadges`). A view that must refresh on any dive-field change observes `onChange(of: store.cachedSummaries)` and bumps a local version counter.
- `store.dives` is reassigned **only** on `.list` commits. Do **not** use `onChange(of: store.dives)` as the change signal in a view that must respond to `.rowFields` edits — it will miss them.
- `store.searchText` updates synchronously as the user types, but `store.cachedFilteredSummaries` lags it by up to 150ms via `scheduleSearchRebuild`'s debounce. A view deciding what empty-state to show (e.g. "no results for this search" vs. "no results for this diver") based on whether search is active must check `store.appliedSearchText` — the debounce-synced value, updated inside `rebuildFilteredDives` — not the live `store.searchText`, or it can briefly render a state describing search results that haven't been computed yet.
- `DiveMapView` already uses `onChange(of: store.cachedSummaries, initial: true)`. Do not change it.
- `MarineLifeView` uses a fish-specific hash in its `.task(id:)` fingerprint and needs no summary observer.
- Widget (App Group) data is rewritten by `DiveStore` itself whenever the aggregation's widget fingerprint changes (`scheduleAggregation`), so it stays current whatever tab is shown. Do not re-add an `onChange(of: store.cachedWidgetFingerprint)` writer in a view — it would write twice.

### Remote Changes (iCloud)

Edits another device makes to an **existing** dive change no dive membership, so the `@Query` path never rebuilds for them (models compare by identity; `scheduleRebuild` skips unchanged IDs). They reach the caches through persistent history instead:

- **`RemoteChangeFeeder`** (`RemoteChangeFeeder.swift`) is attached with `.background(RemoteChangeFeeder())` to the `TabView` in `MainTabView`, next to `DiverSourcesFeeder`, so it runs whatever tab is shown. It observes the system's `.NSPersistentStoreRemoteChange` (posted for iCloud imports, this app's own saves and CloudKit bookkeeping) and, 1.5 s after the last notification of a burst, calls `store.applyRemoteHistory(container:)`. It also catches up once when it starts. It does nothing when iCloud sync is off. Observing this system notification is not the "posting `NotificationCenter` notifications" the rule below forbids.
- **`DiveStore.applyRemoteHistory(container:)`** reads the new history transactions (off the MainActor), skips this app's own saves by author, and classifies each updated dive by `updatedAttributes`:

| Changed attributes | Action |
|---|---|
| `timestamp`, `diverName`, or the current sort field (`maxDepth` + `importDistanceUnit` for depth, `duration`, `diveNumber`) | one `commitListRebuild()` for the batch |
| `seenFish`, `photosData` | badge refresh for those dives only |
| other stored attributes `DiveSummary(from:)` reads (site, location, country, coordinates, surface interval, rating, buddies, dive types, tags, dive number, depth, duration, `tanksData` → gas) | summary patch for those dives, one assignment of `cachedSummaries` |
| anything else (notes, `averageDepth`, profile, …) | nothing |

  Dive inserts and deletes are left to the `@Query` membership path; updates to a dive added in the same batch are patched once it is in the list. A fish added or removed on another device always comes with a `seenFish` update on its dive; a fish **renamed** there changes only its `MarineSight` row, so the store resolves the parent dive (fresh context) and refreshes its badges. Because a change is committed ~1 s before the main context merges it, the store reads the committed values through a fresh `ModelContext(container)` and waits (up to 3 s) until the main context shows them before patching. Intermediate wait attempts check only the suspected dives (this batch's deletions, the checked dives, the current pending ones); before returning, every listed dive is compared with the store's dive identifiers (one identifier-only query), and the caches are then touched with no `await` in between. While any listed dive is gone from the store (deleted in this batch or not, including deletions merged during the wait), no batch touches the caches — reading a deleted SwiftData object crashes. Such a batch is **deferred**: its position and noted pages are kept, and the next full rebuild (normally the `@Query` delivering the deletion) re-runs it; a re-run whose deferred dives are all still listed ends right after classification, before any fetch. Remaining window (accepted, same size as the `@Query` debounce): a dive in the latest `@Query` delivery but not yet in the identifier map, deleted remotely before the next synchronous rebuild, is not covered by the sweep. Temporary identifiers (no `storeIdentifier`) are never treated as deletions. Because saving does not re-deliver the `@Query` (models compare by identity), a dive recorded under its temporary identifier is remapped from the local save's history (`insert Dive` in this app's own transactions). Known limit: a deferral while the Dives tab (`ContentView`) is not updating lasts until it re-delivers. A fetch that hits the 500-transaction limit is only noted (`NotedRemotePages`: whether a listed dive changed, a merge sample, badge/photo dives, renamed fish, deletions, local inserts — not the pages' list/row sets) and the next fetch continues right after it; the last page applies the whole backlog, with one full rebuild if any listed dive changed. An empty history read still applies noted pages or a deferral. A batch with more than 100 changed dives this device lists is also applied with one full rebuild, after checking a 20-dive sample (from every page) plus every dive whose badges are refreshed; smaller batches check, and patch, every changed dive. A changed dive that joins the list during the wait (added and edited on the other device) is patched on one extra run, unless a full rebuild re-reads everything anyway. Fresh-context reads use grouped `contains(persistentModelID)` queries (200 per query, one-by-one fallback); photo counts, which load every photo blob, are compared only for dives whose `photosData` changed, and only on the final check. Local inserts are remapped only while the identifier map holds a temporary identifier, so ordinary local saves skip the remote path. Renamed fish are resolved up to 300 per batch (with yields); fish/photo badge refreshes are capped at 100 (they run synchronously after the final check); above either cap, fish names refresh at the next membership change. After a merge-wait timeout the batch (with its noted pages) is re-read once before the position moves on. The widget data written after an aggregation is built from the summary snapshot, never from `dives`, and a fish-cache publish is skipped (and the aggregation re-run) if a badge refresh happened during the compute. The history position lives in `DiveStore` (in memory), not in the feeder view; only a history read error restarts it from the current time. The feeder's 1.5 s wait is cancellable, but an apply in progress never is (its merge wait would end at once).
- **Every `ModelContext` the app creates must set `author` with the `"BlueDive."` prefix** (the main context is `"BlueDive.main"`, `recalcSequencesInBackground`'s is `"BlueDive.background"`, the read-only remote-history contexts' is `"BlueDive.remoteHistory"`, `GearSnapshotReader`'s is `"BlueDive.gearSnapshot"`). Without it, that context's saves are treated as another device's edits and patched a second time.
- **Remote changes never trigger `recalcSequencesInBackground`.** Surface intervals and dive numbers arrive already calculated by the other device; recalculating them here would bounce writes between devices.
- When a new `DiveSummary` field is added, add its stored attribute to the classification sets in `classifyRemoteHistory` (and to the list set if it affects sorting or grouping), or remote edits to it will not refresh the row.

### Background Safety

- `Task.detached` and `nonisolated` functions must never read `UserPreferences.shared` or any other `@MainActor`-isolated property.
- For depth display inside a background task, capture `displayInFeet: Bool` and `depthFactor: Double` on the MainActor first and pass them in as parameters.
- Never read `DiveSummary.displayMaxDepth` from a background task — it reads `UserPreferences.shared` (MainActor-isolated). Use the raw value plus a captured `depthFactor` instead.
- `DiveSummary` conformance to `Sendable` is what makes it safe to hand across these boundaries.

### What NOT To Do

- Never add `@Query var dives: [Dive]` to any view other than `ContentView`.
- Never compute a diver-name list locally (`DiverFilter.uniqueDivers(...)`) or add a `Gear`/`Certification`/`DivingInsurance` `@Query` only for one; read `store.cachedUniqueDivers`.
- Never post `NotificationCenter` notifications to signal dive changes — call `store.commit(_:affects:)` directly.
- Never call `store.scheduleRebuild(...)` from a child view. Only `ContentView` owns the query inputs; child views call `commit()`.
- Never use `onChange(of: store.dives)` to re-trigger a view that displays `.rowFields`-affected data (site, country, gas stats); use `onChange(of: store.cachedSummaries)`.
- Never read `DiveSummary.displayMaxDepth` from a background task; use the raw value with a captured `depthFactor`.
- Never create a `ModelContext` without setting `author = "BlueDive.<role>"`, and never recalculate surface intervals or dive numbers in response to remote changes.

### Adding a New Edit Sheet

1. Determine the applicable `DiveChangeScope` from the list above.
2. Add `@Environment(DiveStore.self) private var store` to the edit view.
3. On save, call `store.commit(dive, affects: <scope>)`, replacing any `NotificationCenter.default.post(...)` call.
4. If the view must recompute its stats when any dive field changes, add `@State private var contentVersion: Int = 0`, add `.onChange(of: store.cachedSummaries) { _, _ in contentVersion += 1 }`, and include `contentVersion` in the view's `.task(id:)` fingerprint.

## MapKit Annotation Z-Order Has No SwiftUI-Level Control

SwiftUI's `Annotation` conforms to `MapContent`, not `View` — `.zIndex()` does not compile on it, and the complete public `MapContent` modifier surface (`tint`, `tag`, `foregroundStyle`, `stroke`, `strokeStyle`, `annotationTitles`, `annotationSubtitles`, `mapOverlayLevel`, `mapItemDetailSelectionAccessory` — confirmed by dumping the SDK's `_MapKit_SwiftUI.swiftinterface`) exposes no equivalent of `MKAnnotationView.zPriority`/`displayPriority`. **The order two `Annotation`s are declared in a `Map`'s content builder has no effect on which one renders in front when they visually overlap** — MapKit decides that itself, using its own geography-based heuristic (observed: the annotation with the lower latitude renders on top, regardless of declaration order — verified by swapping declaration order and confirming zero visual change, then reverting one annotation's content back to the old code as a control and re-measuring the same pin to confirm the shift was real).

If a specific annotation must always render in front of another when they overlap (e.g. a dive's entry pin must win over its exit pin), the only way to get real control is to **merge the two into a single `Annotation`** and stack them yourself with a plain SwiftUI `ZStack` inside its `content:` closure — ordinary `ZStack` layering *is* respected (later view = on top), because at that point it's no longer two independent MapKit-managed annotations, it's one annotation containing ordinary SwiftUI content. The "back" pin needs to be manually offset to its true screen position relative to the "front" pin's anchor, using `MKMapPoint` to project both coordinates and taking the difference (scaled by points-per-map-point derived from the visible `MKMapRect`) as a SwiftUI `.offset()`. Fall back to two independent annotations once they're far enough apart to read as separate pins, so each keeps its own accurate anchor and label. See `SiteEntryExitMap` in `DiveDetailView+SiteDetails.swift` for the full implementation (overlap-distance threshold, live-vs-initial `MKMapRect` handling, and the identical/overlapping/separate three-way branch).
