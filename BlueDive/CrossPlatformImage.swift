import SwiftUI

// MARK: - Cross-platform image type

#if os(iOS)
import UIKit
/// Platform-agnostic image type. Maps to `UIImage` on iOS/iPadOS.
typealias PlatformImage = UIImage
/// Platform-agnostic color type. Maps to `UIColor` on iOS/iPadOS.
typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
/// Platform-agnostic image type. Maps to `NSImage` on macOS.
typealias PlatformImage = NSImage
/// Platform-agnostic color type. Maps to `NSColor` on macOS.
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

// MARK: - Cross-platform DatePicker components

#if os(macOS)
extension DatePickerComponents {
    /// `.hourAndMinute` — macOS does not expose seconds in a DatePicker. Call site is macOS-only.
    static var platformHourMinute: DatePickerComponents { .hourAndMinute }
}
#endif

// MARK: - iOS-only toolbar placements

#if os(macOS)
extension ToolbarItemPlacement {
    /// `.bottomBar` is iOS-only. On macOS this maps to `.automatic`, which places toolbar items
    /// in the window title bar area rather than a bottom bar. Photo viewer prev/next controls
    /// use this placement and will appear at the top on macOS.
    static var bottomBar: ToolbarItemPlacement { .automatic }
}
#endif

// MARK: - Adaptive DatePicker style

extension DatePicker {
    /// Uses `.graphical` (full-size calendar) on macOS, `.compact` on iOS/iPadOS.
    @ViewBuilder
    func adaptiveDatePickerStyle() -> some View {
        #if os(macOS)
        self.datePickerStyle(.graphical)
        #else
        self.datePickerStyle(.compact)
        #endif
    }
}

#if os(macOS)
// .navigationBarTitleDisplayMode(_:) and NavigationBarItem are iOS-only.
// Provide stubs so call sites compile on macOS without modification.
// Note: if Apple ever vends NavigationBarItem on macOS, rename this stub to
// avoid a redeclaration conflict and update navigationBarTitleDisplayMode accordingly.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}
extension View {
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View { self }
}
#endif

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
