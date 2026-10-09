import SwiftUI

// MARK: - Cross-platform image type

#if os(iOS)
import UIKit
/// Platform-agnostic image type. Maps to `UIImage` on iOS/iPadOS.
typealias PlatformImage = UIImage
/// Platform-agnostic colour type. Maps to `UIColor` on iOS/iPadOS.
typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
/// Platform-agnostic image type. Maps to `NSImage` on macOS.
typealias PlatformImage = NSImage
/// Platform-agnostic colour type. Maps to `NSColor` on macOS.
typealias PlatformColor = NSColor
#endif

// MARK: - SwiftUI Image helpers

extension Image {
    /// Creates a SwiftUI `Image` from a `PlatformImage` on any Apple platform.
    init(platformImage: PlatformImage) {
#if os(iOS)
        self.init(uiImage: platformImage)
#elseif os(macOS)
        self.init(nsImage: platformImage)
#endif
    }
}

// MARK: - Data → PlatformImage helper

extension Data {
    /// Returns a `PlatformImage` initialised from this data, or `nil` if the data is invalid.
    var platformImage: PlatformImage? {
        PlatformImage(data: self)
    }

    /// Content-keyed id for photo data (SwiftUI identity, `.task(id:)`).
    /// Hashes the first and last 256 bytes and the size, so it stays O(1): a deletion that
    /// shifts a different photo into the same index changes the id. The tail is included
    /// because photos from one camera often share their first bytes (the EXIF header).
    var photoTaskID: Int {
        var hasher = Hasher()
        hasher.combine(prefix(256))
        hasher.combine(suffix(256))
        hasher.combine(count)
        return hasher.finalize()
    }
}

// MARK: - Cross-platform semantic colors

extension Color {
    /// Primary system background. Black in dark mode, white in light mode.
    /// Equivalent of `UIColor.systemBackground` / `NSColor.windowBackgroundColor`.
    static var platformBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A darker yellow/amber that remains readable on both light and dark backgrounds.
    /// Used for NDL lines and labels in dive charts.
    static var ndlYellow: Color {
        Color(red: 0.75, green: 0.55, blue: 0.0)
    }

    // MARK: Text readable on a light tint of its own colour
    //
    // Labels drawn in a colour on a light tint of that same colour (the "#123" dive number,
    // dive time and surface interval badges, the dive chart's chips, the map popup's stats).
    // Each keeps the original colour in dark mode; in light mode, where the original on its
    // own tint reads at only about 2 : 1, it uses a deeper shade (about 5–6 : 1 on the tint,
    // and at least 4.5 : 1 on the selected row of the macOS dive list).

    /// Cyan: dive numbers, depth.
    static var readableCyan: Color {
        readableOnTint(darkMode: .cyan, lightMode: (red: 0.0, green: 0.38, blue: 0.50))
    }

    /// Green: dive time, temperature chip.
    static var readableGreen: Color {
        readableOnTint(darkMode: .green, lightMode: (red: 0.0, green: 0.40, blue: 0.12))
    }

    /// Orange: surface interval, dates on the map, deco chip.
    static var readableOrange: Color {
        readableOnTint(darkMode: .orange, lightMode: (red: 0.55, green: 0.27, blue: 0.0))
    }

    /// Amber (`ndlYellow`): NDL chip.
    static var readableAmber: Color {
        readableOnTint(darkMode: .ndlYellow, lightMode: (red: 0.50, green: 0.36, blue: 0.0))
    }

    /// Red: pressure chip.
    static var readableRed: Color {
        readableOnTint(darkMode: .red, lightMode: (red: 0.62, green: 0.10, blue: 0.08))
    }

    /// Indigo: PPO₂ chip.
    static var readableIndigo: Color {
        readableOnTint(darkMode: .indigo, lightMode: (red: 0.27, green: 0.25, blue: 0.65))
    }

    /// Pink: photos chip.
    static var readablePink: Color {
        readableOnTint(darkMode: .pink, lightMode: (red: 0.62, green: 0.10, blue: 0.30))
    }

    /// Text colour for a label drawn on a light tint of its own colour (badges, chart chips):
    /// keeps `darkMode` unchanged in dark mode and uses the deeper sRGB `lightMode` colour in
    /// light mode, where the original colour on its own light tint is hard to read.
    static func readableOnTint(darkMode: Color,
                               lightMode: (red: Double, green: Double, blue: Double)) -> Color {
        #if os(iOS)
        let dark = UIColor(darkMode)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? dark
                : UIColor(red: lightMode.red, green: lightMode.green, blue: lightMode.blue, alpha: 1)
        })
        #else
        let dark = NSColor(darkMode)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : NSColor(srgbRed: lightMode.red, green: lightMode.green, blue: lightMode.blue, alpha: 1)
        })
        #endif
    }

    /// Equivalent of `UIColor.secondarySystemBackground` / `NSColor.windowBackgroundColor`.
    static var platformSecondaryBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Equivalent of `UIColor.tertiarySystemBackground` / `NSColor.underPageBackgroundColor`.
    static var platformTertiaryBackground: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

// MARK: - App screen background

/// Shared screen background for the dive list and dive detail: a subtle blue tint
/// fading in from the top. The dive list draws the translucent gradient over the
/// window background; dive detail uses the opaque variant (gradient over the platform
/// background) so stacked pages in the swipe-between-dives transition never show
/// through each other.
struct AppBackground: View {
    var opaque = true

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.platformBackground.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        if opaque {
            Color.platformBackground.overlay(gradient)
        } else {
            gradient
        }
    }
}

// MARK: - Adaptive DatePicker style

extension DatePicker {
    /// Uses `.compact` on every platform: a small date field that opens a calendar
    /// popover when tapped/clicked. On macOS this matches the iOS experience — the
    /// `.graphical` style renders a fixed, small calendar inline in the form row.
    func adaptiveDatePickerStyle() -> some View {
        self.datePickerStyle(.compact)
    }
}

// MARK: - Toolbar Close Button

/// A toolbar dismiss button that never loses progress (per HIG, distinct from `.cancel`).
/// Uses the standard system close affordance on iOS 26+, falling back to a plain
/// "Close" label pre-26. Place at `.cancellationAction` to match HIG's leading-edge
/// convention for dismiss buttons.
@ViewBuilder
func closeToolbarButton(action: @escaping () -> Void) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
        Button(role: .close, action: action)
    } else {
        Button("Close", action: action)
    }
}

// MARK: - Text field clear-button tap target

extension View {
    /// Enlarges a text field's clear button (`xmark.circle.fill`) tap area on iOS so the
    /// ~20 pt glyph reaches an accessible size, without moving the glyph, changing its
    /// appearance, or altering the surrounding layout.
    ///
    /// Apply to the `Image` inside the button's label, after its `.foregroundStyle`.
    ///
    /// Geometry — the hit rectangle grows **downward, upward and trailing only**, never
    /// back toward the typed text:
    /// - The clear button sits at the trailing edge of its field (as an `.overlay(alignment: .trailing)`
    ///   or as the last sibling in the field's `HStack`). Growing the hit box leading-ward
    ///   would park an invisible 44 pt "Clear" target on top of the end of the user's own
    ///   text, so a tap meant to reposition the caret would wipe the field instead. This is
    ///   why UIKit's own `clearButtonMode` button is also deliberately sub-44 pt.
    /// - Trailing/vertical growth only ever extends into the row's own padding or the field's
    ///   inset, where nothing interactive lives.
    /// - The trailing `.padding(-12)` cancels the layout effect of the expanded frame, so the
    ///   glyph renders in exactly its original position and rows keep their original height;
    ///   `.contentShape` keeps the enlarged rectangle hit-testable. Verified layout-neutral:
    ///   an unmodified and a modified field row both measure 320 × 22.
    ///
    /// Result: a ~44 × 32 pt target (up from ~20 × 20) for a body-sized glyph.
    ///
    /// No-op on macOS: pointer input does not need finger-sized targets, and the existing
    /// sizing inside `#if os(macOS)` branches is intentional.
    func clearButtonTapTarget() -> some View {
        #if os(iOS)
        self
            .padding(.vertical, 12)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
            .padding(.vertical, -12)
            .padding(.trailing, -12)
        #else
        self
        #endif
    }

    /// Grows a small control's tappable rectangle by the given per-edge insets **without
    /// changing layout**: the glyph keeps its exact position and the row keeps its exact
    /// size, because the expanding `.padding` is cancelled by an equal negative `.padding`
    /// applied after `.contentShape`.
    ///
    /// Apply to the `Image` inside a `Button`/`Menu` label, after its `.foregroundStyle`.
    /// This is the same technique as `clearButtonTapTarget()`, generalised so each edge can
    /// be sized independently — necessary wherever a control sits close to another control
    /// (chip grids, "add/remove" icon pairs in a section header) and a symmetric 44 × 44
    /// frame would either bloat the surrounding container or overlap the neighbour's target.
    ///
    /// Sizing rule used at the call sites: grow generously into padding/whitespace, and no
    /// more than **half the measured gap** toward an adjacent interactive control, so two
    /// enlarged targets can touch but never overlap.
    ///
    /// Insets are layout-direction aware (`leading`/`trailing`, not left/right).
    ///
    /// No-op on macOS: pointer input does not need finger-sized targets, and the existing
    /// sizing inside `#if os(macOS)` branches is intentional.
    func tapTargetInsets(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        bottom: CGFloat = 0,
        trailing: CGFloat = 0
    ) -> some View {
        #if os(iOS)
        self
            .padding(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -top, leading: -leading, bottom: -bottom, trailing: -trailing))
        #else
        self
        #endif
    }
}

// MARK: - Tap target enlargement as a nominal view

/// Grows a small control's tappable rectangle by the given per-edge insets **without
/// changing layout** — same geometry as `View.tapTargetInsets(...)`, but packaged as a
/// nominal `View` struct instead of a modifier chain.
///
/// **Use this, not `tapTargetInsets(...)`, inside any view property that is combined with
/// several sibling sections into one `some View`.**
///
/// Why: `tapTargetInsets(...)` adds three nested anonymous `ModifiedContent<...>` layers to
/// the *call site's* type. `some View` hides that type from the type-checker, but the Swift
/// ABI must still copy the full concrete nested generic at runtime, and each layer adds a
/// level of recursion to the generated value-witness `initializeWithCopy`. Stacking ten of
/// these across three sibling sections that all funnel into `DiveDetailView.menuTabContent`
/// pushed that recursive copy past the stack limit and crashed with `EXC_BAD_ACCESS`
/// (`swift_retain` inside a 13-deep `ExclusiveGesture`/`HStack` witness chain) on every
/// attempt to open a dive. A build succeeds either way — only a live tap-test catches it.
///
/// A struct's `body` is its own self-contained opaque type, so the padding/`contentShape`
/// complexity stops at this boundary and never propagates into the parent's compound type.
/// This is Apple's standard guidance for bounding generated-type complexity.
///
/// Wrap the `Image` inside a `Button`/`Menu` label, after its `.foregroundStyle`. Insets are
/// layout-direction aware (`leading`/`trailing`, not left/right).
///
/// Sizing rule used at the call sites: grow generously into padding/whitespace, and no more
/// than **half the measured gap** toward an adjacent interactive control, so two enlarged
/// targets can touch but never overlap. Never grow back toward adjacent text.
///
/// No-op on macOS: pointer input does not need finger-sized targets, and the existing sizing
/// inside `#if os(macOS)` branches is intentional.
struct TapTargetInset<Content: View>: View {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(iOS)
        content()
            .padding(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -top, leading: -leading, bottom: -bottom, trailing: -trailing))
        #else
        content()
        #endif
    }
}

/// The standard text-field clear glyph (`xmark.circle.fill`, secondary style) with its
/// enlarged tap target already applied — the exact chain that every clear button in the app
/// spells out by hand.
///
/// Use this instead of `Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
/// .clearButtonTapTarget()` inside any view property that is combined with several sibling
/// sections into one `some View`. See `TapTargetInset` for the full explanation: this packages
/// five `ModifiedContent` layers behind one nominal type's `body`, so the call site's concrete
/// type stays flat and the runtime value-witness copy cannot recurse deep enough to overflow
/// the stack.
///
/// The geometry itself still lives in `clearButtonTapTarget()`, so there is one source of truth.
struct ClearButtonGlyph: View {
    var body: some View {
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .clearButtonTapTarget()
            .accessibilityLabel(Text("Clear"))
    }
}

#if os(iOS)
extension View {
    /// Applies a keyboard type on iOS/iPadOS.
    func platformKeyboardType(_ type: UIKeyboardType) -> some View {
        self.keyboardType(type)
    }

    /// Applies text input autocapitalization on iOS/iPadOS.
    func platformTextInputAutocapitalization(_ behavior: TextInputAutocapitalization) -> some View {
        self.textInputAutocapitalization(behavior)
    }
}
#else
/// Dummy type so `.platformKeyboardType(...)` call sites compile on macOS without UIKeyboardType.
enum PlatformKeyboardType {
    case numberPad, decimalPad, asciiCapable, phonePad, emailAddress
}

/// Dummy type so `.platformTextInputAutocapitalization(...)` call sites compile on macOS.
enum PlatformAutocapitalization {
    case words, sentences, characters, never
}

extension View {
    /// No-op on macOS — keyboard types are not applicable on desktop.
    func platformKeyboardType(_ type: PlatformKeyboardType) -> some View {
        self
    }

    /// No-op on macOS — text input autocapitalization is not applicable on desktop.
    func platformTextInputAutocapitalization(_ behavior: PlatformAutocapitalization) -> some View {
        self
    }
}
#endif

// MARK: - App links

let wikiDocumentationURL = URL(string: "https://github.com/houle988/BlueDive/wiki")!

// MARK: - Shared card backgrounds

extension View {
    func sectionCardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }

    func detailCardBackground() -> some View {
        self.background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Locale-aware number formatting

private enum NumberFormatterCache {
    private static let lock = NSLock()
    private static var cache = [String: NumberFormatter]()

    // Performs both the cache lookup and the format call while holding the lock,
    // since NumberFormatter is not thread-safe for concurrent use (e.g. PDF export
    // or notification scheduling on a background thread).
    static func format(_ value: Double, decimals: Int, minDecimals: Int, grouping: Bool, locale: Locale) -> String {
        let key = "\(decimals),\(minDecimals),\(grouping ? 1 : 0),\(locale.identifier)"
        lock.lock()
        defer { lock.unlock() }
        let formatter: NumberFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            let f = NumberFormatter()
            f.locale = locale
            f.minimumFractionDigits = minDecimals
            f.maximumFractionDigits = decimals
            f.numberStyle = .decimal
            f.usesGroupingSeparator = grouping
            cache[key] = f
            formatter = f
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension Double {
    /// Locale-aware decimal string with grouping separators (e.g. "3,000" en-CA, "3.000" de).
    /// Use for display labels ONLY — never for TextField pre-fill (grouping separators corrupt values ≥ 1000 on parse).
    func localizedString(decimals: Int = 1, minDecimals: Int = 0, locale: Locale = .current) -> String {
        NumberFormatterCache.format(self, decimals: decimals, minDecimals: minDecimals, grouping: true, locale: locale)
    }

    /// Locale-aware decimal string without grouping separators — safe for TextField pre-fill.
    /// Preserves the locale decimal separator (e.g. "12,5" in fr-CA) but omits thousands separators.
    /// Pairs with parseFlexibleDouble. Never use localizedString(decimals:) for TextField pre-fill.
    func editableString(decimals: Int = 1, minDecimals: Int = 0, locale: Locale = .current) -> String {
        NumberFormatterCache.format(self, decimals: decimals, minDecimals: minDecimals, grouping: false, locale: locale)
    }
}

// MARK: - Duration Formatting

/// A duration in minutes as hours and minutes, abbreviated in the app language
/// (e.g. "42min" / "1h 36min" in English and German, "1h 36m" in French, "1 u, 36 m" in Dutch);
/// minutes only below one hour. `locale` defaults to the in-app language override
/// (or the system language when "System" is chosen), like the dates on screen.
func formattedMinutes(_ totalMinutes: Int, locale: Locale? = nil) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = totalMinutes >= 60 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .abbreviated
    let languageLocale = locale ?? UserPreferences.shared.languageMode.locale ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = languageLocale
    formatter.calendar = calendar
    guard let text = formatter.string(from: TimeInterval(totalMinutes) * 60) else {
        return Double(totalMinutes).localizedString(decimals: 0) + " min"
    }
    // The formatter groups the hour count by the app language ("1,234h" in English), but
    // numbers follow the OS region (Number Formatting): swap in the region's grouping.
    let hours = totalMinutes / 60
    guard hours >= 1000 else { return text }
    let languageNumber = NumberFormatter()
    languageNumber.numberStyle = .decimal
    languageNumber.locale = languageLocale
    guard let languageHours = languageNumber.string(from: NSNumber(value: hours)),
          let range = text.range(of: languageHours) else { return text }
    return text.replacingCharacters(in: range, with: Double(hours).localizedString(decimals: 0))
}

// MARK: - Flexible Double Parsing

/// Parses a string to Double, accepting '.' or ',' as decimal separator.
/// Strips thin-space (U+202F) and non-breaking-space (U+00A0) grouping separators before parsing.
/// Canonical counterpart to editableString(decimals:) for TextField round-trips.
func parseFlexibleDouble(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed
        .replacingOccurrences(of: "\u{202F}", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: "")
        .replacingOccurrences(of: ",", with: ".")
    // Double(String) also accepts "inf", "nan" and overflowing input such as "1e400". No field
    // takes those, and a non-finite value cannot be JSON-encoded (tanks would be lost) or shown.
    guard let value = Double(normalized), value.isFinite else { return nil }
    return value
}

/// The value to save from a string-backed Double field that was pre-filled from a stored value.
/// Pre-fill text is rounded for display (e.g. 2 decimals, or "%.6f" for coordinates), so parsing
/// it back would silently alter the stored value on every save. When the (trimmed) text still
/// equals the text the field was pre-filled with, the stored `original` is returned unchanged,
/// at full precision; otherwise the edited text is parsed (empty text → nil).
func preservedDouble(_ text: String, original: Double?, originalText: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed == originalText.trimmingCharacters(in: .whitespaces) { return original }
    return parseFlexibleDouble(trimmed)
}

/// A stored Double and the rounded text its string-backed field was pre-filled with.
/// `resolve` returns the stored value unchanged while the text is untouched, so saving a form
/// never rounds data the user did not edit (see preservedDouble). Code that rewrites the text
/// with an exact value (e.g. copying another dive's site) replaces the whole PrefilledDouble.
struct PrefilledDouble {
    var value: Double?
    var text: String

    func resolve(_ current: String) -> Double? {
        preservedDouble(current, original: value, originalText: text)
    }

    /// Pre-filled with `editableString(decimals:)` (no grouping separator).
    static func decimals(_ value: Double?, _ decimals: Int, minDecimals: Int = 0) -> PrefilledDouble {
        PrefilledDouble(value: value,
                        text: value.map { $0.editableString(decimals: decimals, minDecimals: minDecimals) } ?? "")
    }

    /// GPS coordinates: "%.6f" is coordinate notation, not locale number formatting.
    static func coordinate(_ value: Double?) -> PrefilledDouble {
        PrefilledDouble(value: value, text: value.map { String(format: "%.6f", $0) } ?? "")
    }
}

// MARK: - NDL Sentinel

/// Dive computers emit values at or above this threshold to signal "no decompression limit required".
/// Profile samples with NDL ≥ ndlSentinel must be excluded from display and charting.
let ndlSentinel: Double = 999

// MARK: - Deduplication Windows

/// 24 h: both serials confirmed equal (or serial + fingerprint match); tolerates clock drift
/// and timezone corrections on the same device.
let deduplicationHighConfidenceWindow: TimeInterval = 86_400

/// 2 h: serial compatible but not both confirmed (e.g. MacDive sequential identifiers like "42");
/// narrower window reduces cross-diver false positives.
let deduplicationLowConfidenceWindow: TimeInterval = 7_200

// MARK: - Computer Serial Normalization

extension String {
    /// Trims whitespace, lowercases, and returns nil for empty or sentinel computer serial values.
    /// Used by both the BLE and file-import duplicate-detection paths so normalisation stays consistent.
    func normalizedComputerSerial() -> String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, !BluetoothScannerView.knownSentinelSerials.contains(s) else { return nil }
        return s
    }
}
