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
