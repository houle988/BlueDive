import SwiftUI

// MARK: - Full-width switch toggle

extension View {
    /// iOS-style switch toggle on macOS: label on the leading edge, switch on the trailing
    /// edge, filling the available width. On macOS a Toggle outside a Form is otherwise a
    /// checkbox (or, with `.switch`, a label and switch sized to their content), which
    /// shrinks the card it sits in. On iOS the view is returned unchanged (the iOS default
    /// toggle style is already the switch).
    func fullWidthSwitch() -> some View {
        #if os(macOS)
        self.toggleStyle(FullWidthSwitchToggleStyle())
        #else
        self
        #endif
    }

    /// Same as `fullWidthSwitch()`, for a Toggle that sets an explicit style on iOS:
    /// `style` is applied on iOS only, exactly as before.
    func fullWidthSwitch<S: ToggleStyle>(iOS style: S) -> some View {
        #if os(macOS)
        self.toggleStyle(FullWidthSwitchToggleStyle())
        #else
        self.toggleStyle(style)
        #endif
    }
}

#if os(macOS)
private struct FullWidthSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            // Visual copy of the label; hidden from VoiceOver, which reads the switch's own label.
            configuration.label
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
#endif

// MARK: - Toolbar menus

extension View {
    /// Hides the ⌄ pull-down indicator macOS draws on a toolbar `Menu`, so icon menus look
    /// like their iOS counterparts. On iOS the view is returned unchanged (iOS toolbar menus
    /// have no indicator).
    func toolbarMenuIndicatorHiddenOnMac() -> some View {
        #if os(macOS)
        self.menuIndicator(.hidden)
        #else
        self
        #endif
    }
}

// MARK: - Grouped form style

extension View {
    /// Applies `.formStyle(.grouped)` on macOS, whose default is the two-column style.
    /// On iOS the view is returned unchanged (grouped is already the iOS default).
    func groupedFormStyleOnMac() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
        #else
        self
        #endif
    }
}

// MARK: - Full-width menu picker

/// Menu picker row for custom card layouts (not inside a `Form`): on macOS the label
/// sits on the leading edge and the pop-up button on the trailing edge, filling the
/// width. A plain macOS Picker outside a Form draws its label and pop-up side by side
/// at their natural size, centred in the card. On iOS this returns the plain `Picker`
/// itself (a function, not a wrapper view, so the iOS view tree is unchanged).
@ViewBuilder
func fullWidthPicker<SelectionValue: Hashable, Content: View>(
    _ title: LocalizedStringKey,
    selection: Binding<SelectionValue>,
    @ViewBuilder content: () -> Content
) -> some View {
    #if os(macOS)
    HStack {
        // Visual copy of the label; hidden from VoiceOver, which reads the Picker's own label.
        Text(title)
            .accessibilityHidden(true)
        Spacer(minLength: 8)
        Picker(title, selection: selection, content: content)
            .labelsHidden()
            .fixedSize()
    }
    #else
    Picker(title, selection: selection, content: content)
    #endif
}

// MARK: - List row separator

extension View {
    /// Sets the row background and, on macOS, draws an iOS-style separator line along the
    /// bottom of the row. The macOS `.sidebar` and `.plain` list styles draw no row separators
    /// (and the list style has the final say, so `.listRowSeparator(.visible)` can't force
    /// them); the line is drawn in the row background so it sits on the row's real bottom
    /// edge. Pass `macSeparator: false` for the last row of a section, as iOS does.
    /// On iOS this is exactly `.listRowBackground(background)`.
    func listRowBackground<Background: View>(_ background: Background, macSeparator separator: Bool) -> some View {
        #if os(macOS)
        self.listRowBackground(
            background.overlay(alignment: .bottom) {
                if separator {
                    Divider()
                        .padding(.horizontal, 16)
                }
            }
        )
        #else
        self.listRowBackground(background)
        #endif
    }
}

// MARK: - Grouped list

/// Sectioned list for sheets that looks like the iOS inset-grouped `List` on both
/// platforms. macOS has no inset-grouped list style — a `List` there renders as a
/// sidebar-like list without row cards — so on macOS the same content is shown in a
/// grouped `Form`, matching the other sheets. On iOS this returns the plain `List`
/// itself (a function, not a wrapper view, so the iOS view tree is unchanged).
@ViewBuilder
func groupedList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    #if os(macOS)
    Form(content: content)
        .formStyle(.grouped)
    #else
    List(content: content)
    #endif
}

// MARK: - Form text field
//
// Text field for Form rows that looks like iOS on both platforms: the title is shown as
// grey placeholder text inside the field. In a macOS grouped Form a plain `TextField`'s
// title becomes a separate leading label and the value is pushed to the trailing edge,
// so on macOS the label is hidden and the title is passed as the prompt. On iOS each
// overload returns exactly the original `TextField` call (functions, not a wrapper view,
// so modifiers such as `.focused` still apply to the TextField itself).

@ViewBuilder
func formTextField(_ titleKey: LocalizedStringKey, text: Binding<String>) -> some View {
    #if os(macOS)
    TextField(titleKey, text: text, prompt: Text(titleKey))
        .labelsHidden()
    #else
    TextField(titleKey, text: text)
    #endif
}

@ViewBuilder
func formTextField(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) -> some View {
    #if os(macOS)
    TextField(titleKey, text: text, prompt: Text(titleKey), axis: axis)
        .labelsHidden()
    #else
    TextField(titleKey, text: text, axis: axis)
    #endif
}

@ViewBuilder
func formTextField(verbatim title: String, text: Binding<String>) -> some View {
    #if os(macOS)
    TextField(title, text: text, prompt: Text(verbatim: title))
        .labelsHidden()
    #else
    TextField(title, text: text)
    #endif
}

// MARK: - Principal items in the main window

extension ToolbarItemPlacement {
    /// Use instead of `.principal` for toolbar items in views shown in the main window
    /// (tab roots and views pushed from them). iOS: `.principal` (centre of the
    /// navigation bar). macOS: the tab bar already occupies the centre of the window
    /// toolbar, and a `.principal` item would sit beside it and push the tabs aside,
    /// so the item goes to the trailing action area instead.
    static var principalOutsideTabBar: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .principal
        #endif
    }
}

// MARK: - Toolbar items in sheets
//
// In a sheet, macOS renders `.primaryAction` and `.confirmationAction` items as the
// sheet's default button: accent-filled, at the bottom, triggered by Return.

extension ToolbarItemPlacement {
    /// Use instead of `.primaryAction` for utility items (filter, add, refresh, menus)
    /// in a view presented as a sheet. iOS: `.primaryAction` (trailing edge of the
    /// navigation bar). macOS: `.automatic`, so the item is an ordinary toolbar button
    /// rather than the sheet's accent-filled default button.
    static var sheetPrimaryAction: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// Label colour for a `.confirmationAction` button. iOS draws the button as
    /// coloured text; macOS draws it accent-filled, where a coloured label would be
    /// unreadable, so the colour is applied on iOS only.
    func confirmationActionForeground<S: ShapeStyle>(_ style: S) -> some View {
        #if os(macOS)
        self
        #else
        self.foregroundStyle(style)
        #endif
    }
}

// MARK: - Button styles matching iOS defaults
//
// On iOS an unstyled Button is borderless (tinted label, no background) and, inside a
// List/Form, becomes a full-width tappable row. On macOS an unstyled Button is a bordered
// push button (grey capsule sized to its label) everywhere, including inside Lists.
// These helpers give macOS the iOS look; on iOS they return the view unchanged.

extension View {
    /// Use on a `Button` that acts as a whole `List`/`Form` row (a navigation-style row,
    /// a picker choice, or a text action row such as "Connect as New Device").
    /// Colours set by the call site (on the label or on the Button) take precedence.
    func listRowButton() -> some View {
        #if os(macOS)
        self.buttonStyle(ListRowButtonStyle())
            .foregroundStyle(.tint)
        #else
        self
        #endif
    }

    /// Use on a `Button` placed in an ordinary layout (cards, headers, bottom bars,
    /// icon buttons, inline links) that relies on the iOS default borderless look.
    func borderlessButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.borderless)
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Full-width, chrome-free row button: accent-coloured by default, red for
/// destructive buttons, dimmed while pressed or disabled — as on iOS.
private struct ListRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.6 : 1))
    }
}
#endif

// MARK: - Full-width segmented picker

extension View {
    /// Segmented picker that fills the available width, as on iOS.
    /// On macOS a segmented control sizes to its segments and shows its label,
    /// so the label is hidden and the picker is given the full width.
    /// Do not use for deliberately compact pickers (inline toggles, toolbar items).
    func fullWidthSegmentedPicker() -> some View {
        #if os(macOS)
        self.pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        #else
        self.pickerStyle(.segmented)
        #endif
    }
}

// MARK: - macOS shims for iOS-only SwiftUI APIs
//
// BlueDive shares one SwiftUI codebase between iOS/iPadOS and native macOS.
// The shims below give iOS-only modifiers and toolbar placements a macOS
// equivalent so call sites stay identical on both platforms, instead of
// wrapping every use in `#if os(iOS)`.

#if os(macOS)
/// Stand-in for `NavigationBarItem`, which is unavailable on macOS.
/// Only used as the parameter type of the `navigationBarTitleDisplayMode(_:)` shim below.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

extension View {
    /// No-op on macOS: windows and sheets have no navigation bar title display mode.
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }
}

extension ToolbarItemPlacement {
    /// macOS has no bottom bar; items placed there appear in the window toolbar instead.
    static var bottomBar: ToolbarItemPlacement { .automatic }

    /// Leading edge of the macOS window toolbar.
    static var topBarLeading: ToolbarItemPlacement { .navigation }

    /// Trailing edge of the macOS window toolbar.
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
}

/// UIKit semantic colours referenced by shared views as `Color(.name)`,
/// mapped to their closest AppKit equivalents.
extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
}
#endif

// MARK: - Standard sheet presentation

extension View {
    /// The presentation every `.sheet` uses: page sizing, the large detent and a drag
    /// indicator. On macOS it also applies the in-app language: there each sheet is hosted in
    /// its own window whose root resets `\.locale` to the system language, so the override set
    /// on the main window (`LanguageOverrideModifier` in `BlueDiveApp`) doesn't reach sheets,
    /// including sheets presented from another sheet. On iOS sheets inherit the override and
    /// this is exactly the three presentation modifiers.
    func standardSheetPresentation(dragIndicator: Visibility = .visible) -> some View {
        #if os(macOS)
        self.modifier(AppLanguageSheetLocale())
            .presentationSizing(.page)
            .presentationDetents([.large])
            .presentationDragIndicator(dragIndicator)
        #else
        self.presentationSizing(.page)
            .presentationDetents([.large])
            .presentationDragIndicator(dragIndicator)
        #endif
    }
}

#if os(macOS)
private struct AppLanguageSheetLocale: ViewModifier {
    // Observed, so an open sheet follows a language change made in Settings.
    @State private var prefs = UserPreferences.shared

    func body(content: Content) -> some View {
        content.modifier(LanguageOverrideModifier(locale: prefs.languageMode.locale))
    }
}
#endif
