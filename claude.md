# BlueDive — Project Instructions

BlueDive is a dive log application for macOS and iOS. It is designed as a feature-rich alternative to MacDive, a previously popular dive logging app that is no longer actively maintained by its developer.

## General Rules

When importing, exporting, processing, and storing data, never convert, normalize, or alter dive data. Preserve original values unless the user explicitly modifies them through the app.

Do not change the data model (structs, properties, enums, relationships) unless explicitly instructed to do so.

Do not estimate any data displayed or stored. All fields must be calculated or extracted from the data model unless explicitly instructed to do so.

## Language & Localisation

Always use English (Canada) for labels, text, and comments in user-facing content.

All public-facing text must be defined in code as localizable strings and translated in French (Canada) in the Localizable file. In SwiftUI views, use `LocalizedStringKey` (e.g. `Text("My Key")`) for direct text display. When building strings programmatically — including inside `Text(verbatim:)` with interpolation, even within SwiftUI views — use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()` instead of `String(localized:)`, because `String(localized:)` follows the OS language and ignores the in-app language override. Outside SwiftUI views (e.g. PDF generation, enum properties, model logic), always use `NSLocalizedString(_:bundle:comment:)` with `Bundle.forAppLanguage()`. Never wrap `NSLocalizedString` in a custom helper function (e.g. `L("key")`), because Xcode's string catalog compiler only detects keys from direct `NSLocalizedString` calls with literal strings — a wrapper hides the keys and causes Xcode to mark them as "Stale". When localizing data-model values from a known finite set of options (e.g. weather, current, tank type), use a `switch` with literal `NSLocalizedString` calls for each case so Xcode can detect every key; never pass a runtime variable as the key. Every new localizable key must also have a corresponding `fr-CA` entry added to `Localizable.xcstrings` in the same commit.

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

## Date and Time Formatting

All date and time values displayed in SwiftUI views must respect both the system language and the in-app language override. Always obtain the locale from SwiftUI's environment and apply it to every date format:

- In any `View` struct that displays dates, declare `@Environment(\.locale) private var locale`.
- When using SwiftUI's `Text(_:format:)` with a `Date.FormatStyle`, always append `.locale(locale)` to the format style, e.g. `Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))`.
- When using `DateFormatter` directly, set `formatter.locale = locale` (from `@Environment(\.locale)`) rather than `.current` or `.autoupdatingCurrent`.
- Never hardcode a locale or use `Locale.current` directly in a view — it does not reflect the in-app language override.
