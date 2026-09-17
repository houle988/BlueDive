import SwiftUI

// MARK: - Cross-platform image type

#if os(iOS)
import UIKit
/// Platform-agnostic image type. Maps to `UIImage` on iOS/iPadOS.
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
/// Platform-agnostic image type. Maps to `NSImage` on macOS.
typealias PlatformImage = NSImage
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

    /// Content-keyed id for SwiftUI `.task(id:)` on photo data.
    /// XOR of a prefix hash and count is O(1), collision-resistant for same-size
    /// photos, and stronger than count alone: a deletion that shifts a different
    /// photo into the same ForEach/index slot changes the id and triggers a re-run.
    var photoTaskID: Int { prefix(64).hashValue ^ count }
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

// MARK: - Conditional view modifier helper

extension View {
    /// Applies a view-builder transform only when `condition` is true.
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Adaptive DatePicker style

extension DatePicker {
    /// Uses `.graphical` (full-size calendar) when running as an iPad app on Mac,
    /// and `.compact` (small inline button) on actual iOS devices.
    @ViewBuilder
    func adaptiveDatePickerStyle() -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            self.datePickerStyle(.graphical)
        } else {
            self.datePickerStyle(.compact)
        }
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
    return Double(normalized)
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
