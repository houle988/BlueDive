import SwiftUI

// MARK: - Dive Row View

struct DiveRowView: View {
    let summary: DiveSummary
    let diveNumber: Int   // fallback when diveNumber is nil
    private let prefs = UserPreferences.shared
    @Environment(\.locale) private var locale
    #if os(macOS)
    @Environment(DiveListLayout.self) private var diveListLayout: DiveListLayout?
    #endif
    
    var body: some View {
        #if os(macOS)
        // The Mac window is wide: one line with every value in a fixed-width column so the
        // rows line up, falling back to the stacked iOS row when the window is too narrow.
        // Each version tells the main dive list which one is shown, so its column header row is
        // only there with one-line rows (`DiveListLayout`; nil in other lists).
        ViewThatFits(in: .horizontal) {
            wideRow
                .onAppear { reportOneLine(true) }
            stackedRow
                .onAppear { reportOneLine(false) }
        }
        .accessibilityElement(children: .combine)
        #else
        stackedRow
            .accessibilityElement(children: .combine)
        #endif
    }

    #if os(macOS)
    /// Tells the main dive list whether this row shows its one-line version. Only writes (never
    /// read in `body`), so a change does not redraw the rows, only the list's header row.
    private func reportOneLine(_ isOneLine: Bool) {
        guard let diveListLayout, diveListLayout.isOneLine != isOneLine else { return }
        diveListLayout.isOneLine = isOneLine
    }
    #endif

    /// Number, flag and badges (centred), then site / duration + surface interval / location /
    /// date / gas stacked, depth trailing.
    private var stackedRow: some View {
        HStack(alignment: .top, spacing: 15) {
            // Centred like the depth, so it stays balanced whatever the number of text lines.
            diveIcon
                .frame(maxHeight: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                diveTitle(lineLimit: 2)
                diveDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            depthInfo
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    #if os(macOS)
    /// One line (macOS): number, flag, site + location, date, duration, surface interval,
    /// gas, depth and badges, each in its own fixed-width column (`DiveListColumns`, shared
    /// with `DiveListColumnHeader` so the labels stay over their values).
    private var wideRow: some View {
        HStack(spacing: DiveListColumns.spacing) {
            numberBadge
                .frame(width: DiveListColumns.number, alignment: .leading)

            flagCircle(diameter: DiveListColumns.flag, fontSize: 18)

            VStack(alignment: .leading, spacing: 2) {
                diveTitle(lineLimit: 1)
                locationLine
                    .lineLimit(1)
            }
            .frame(minWidth: DiveListColumns.site, idealWidth: DiveListColumns.site,
                   maxWidth: .infinity, alignment: .leading)

            dateText
                .lineLimit(1)
                .frame(width: DiveListColumns.date, alignment: .leading)

            durationBadge
                .frame(width: DiveListColumns.duration, alignment: .leading)

            // ZStack, not Group: a Group's frame applies to its children, so with no surface
            // interval the column would vanish and shift the columns before it.
            ZStack {
                if hasSurfaceInterval {
                    surfaceIntervalBadge
                }
            }
            .frame(width: DiveListColumns.surfaceInterval, alignment: .leading)

            gasText
                .frame(width: DiveListColumns.gas, alignment: .leading)

            depthInfo
                .monospacedDigit()
                .frame(width: DiveListColumns.depth, alignment: .trailing)

            mediaBadges
                .fixedSize()
                .frame(width: DiveListColumns.media, alignment: .leading)
        }
        // Breathing room between the dense one-line rows.
        .padding(.vertical, 8)
    }
    #endif

    private var diveIcon: some View {
        VStack(spacing: 4) {
            numberBadge
            flagCircle(diameter: 44, fontSize: 24)
            mediaBadges
        }
    }

    private var numberBadge: some View {
        Text(verbatim: "#\(summary.diveNumber ?? diveNumber)")
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.cyan.opacity(0.2))
            .foregroundStyle(.cyan)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func flagCircle(diameter: CGFloat, fontSize: CGFloat) -> some View {
        let resolved = resolvedFlag
        return ZStack {
            Circle()
                .fill(resolved.color.opacity(0.15))
                .frame(width: diameter, height: diameter)

            Text(resolved.flag)
                .font(.system(size: fontSize))
                .accessibilityHidden(true)
        }
    }

    private var mediaBadges: some View {
        HStack(spacing: 4) {
            if summary.hasFish {
                Image(systemName: "fish.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.teal)
                    .accessibilityLabel(Text("Has fish sightings"))
            }
            if summary.hasPhotos {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("Has photos"))
            }
        }
    }
    
    /// Returns the emoji flag and accent colour for the dive's country
    private var resolvedFlag: (flag: String, color: Color) {
        CountryLookup.resolve(summary.siteCountry)
    }

    private func diveTitle(lineLimit: Int) -> some View {
        Text(summary.siteName)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(lineLimit)
    }

    private var diveDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Duration + surface interval badges
            HStack(spacing: 6) {
                durationBadge

                if hasSurfaceInterval {
                    surfaceIntervalBadge
                }
            }
            
            // Location and Country
            locationLine
            
            dateText

            // Gases used, under the date
            if !summary.gasNames.isEmpty {
                gasText
            }
        }
    }

    /// Gases used on the dive, e.g. "Trimix + Nitrox" (empty when the dive has no tanks).
    private var gasText: some View {
        Text(verbatim: summary.displayGasNames)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var hasSurfaceInterval: Bool {
        !summary.surfaceInterval.isEmpty && summary.surfaceInterval != "0h 00m"
    }

    private var durationBadge: some View {
        Text(summary.shortFormattedDuration)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.2))
            .foregroundStyle(.green)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var surfaceIntervalBadge: some View {
        Text(summary.displaySurfaceInterval)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .foregroundStyle(.orange)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var locationLine: some View {
        HStack(spacing: 4) {
            if summary.hasGPSCoordinates {
                Image(systemName: "location.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Has GPS coordinates"))
            }

            locationText
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dateText: some View {
        Text(summary.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
            .font(.caption)
            .foregroundStyle(.gray)
    }
    
    private var locationText: Text {
        if let country = summary.siteCountry, !country.isEmpty {
            // If both location and country exist, combine them
            if !summary.location.isEmpty && summary.location != "Inconnu" && summary.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
                return Text(verbatim: "\(summary.location), \(country)")
            }
            // If only country exists
            return Text(verbatim: country)
        }
        // If only location exists
        if !summary.location.isEmpty && summary.location != "Inconnu" && summary.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
            return Text(verbatim: summary.location)
        }
        // Fallback
        return Text("Unknown location")
    }
    
    private var depthInfo: some View {
        let depthValue = summary.displayMaxDepth
        let depthSymbol = prefs.depthUnit.symbol
        return Text(verbatim: depthValue.localizedString(decimals: 1) + depthSymbol)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
    }
}

#if os(macOS)
// MARK: - Dive List Columns (macOS)

/// Column widths of the one-line dive row on macOS, shared by `DiveRowView` and
/// `DiveListColumnHeader` so the header labels stay aligned with the values.
enum DiveListColumns {
    static let spacing: CGFloat = 12
    static let number: CGFloat = 76
    static let media: CGFloat = 48
    static let flag: CGFloat = 32
    /// Minimum (and ideal) width of the flexible site column.
    static let site: CGFloat = 180
    static let date: CGFloat = 170
    static let duration: CGFloat = 70
    static let surfaceInterval: CGFloat = 120
    static let gas: CGFloat = 120
    static let depth: CGFloat = 100
}

/// Whether the main dive list's rows show their one-line version (macOS). Owned by
/// `ContentView` and put in the environment of its Lists; each `DiveRowView` writes it, so the
/// list shows its column header row only with one-line rows. Absent (nil) in other lists.
/// A stable reference rather than a Binding, which would change on every `ContentView` redraw
/// and redraw every visible row with it.
@Observable final class DiveListLayout {
    var isOneLine = true
}

/// Column labels over the one-line dive rows (macOS). Only added to the list while its rows
/// are one-line (`DiveListLayout`), so it leaves no empty row in the stacked layout.
struct DiveListColumnHeader: View {
    var body: some View {
        // The empty fallback keeps the labels from overflowing during the moment between the
        // rows switching to stacked and this row being removed.
        ViewThatFits(in: .horizontal) {
            labels
                // One header element: "Dive #, Country, Site, …".
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        }
    }

    private var labels: some View {
        HStack(spacing: DiveListColumns.spacing) {
            label(Text("Dive #"), alignment: .leading)
                .frame(width: DiveListColumns.number, alignment: .leading)
            // Wider than the flag; centred, it extends into the spacing on either side.
            label(Text("Country"), alignment: .center)
                .fixedSize()
                .frame(width: DiveListColumns.flag, alignment: .center)

            label(Text("Site"), alignment: .leading)
                .frame(minWidth: DiveListColumns.site, idealWidth: DiveListColumns.site,
                       maxWidth: .infinity, alignment: .leading)
            label(Text("Date"), alignment: .leading)
                .frame(width: DiveListColumns.date, alignment: .leading)
            label(Text("Duration"), alignment: .leading)
                .frame(width: DiveListColumns.duration, alignment: .leading)
            label(Text("Surface Interval"), alignment: .leading)
                .frame(width: DiveListColumns.surfaceInterval, alignment: .leading)
            label(Text("Gas"), alignment: .leading)
                .frame(width: DiveListColumns.gas, alignment: .leading)
            label(Text("Max Depth"), alignment: .trailing)
                .frame(width: DiveListColumns.depth, alignment: .trailing)
            Color.clear.frame(width: DiveListColumns.media, height: 0)
        }
    }

    private func label(_ text: Text, alignment: TextAlignment) -> some View {
        text
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .lineLimit(1)
            .multilineTextAlignment(alignment)
    }
}

extension View {
    /// Shows `DiveListColumnHeader` as a plain List row (macOS): no row background or
    /// separator. A row, not a section header, so it has exactly the dive rows' width and
    /// insets (a sidebar section header is wider and shrinks on hover for its disclosure
    /// chevron, which shifted the labels).
    func diveListHeaderRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
#endif

// MARK: - Stat Mini Box

struct StatMiniBox: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 8))
                .fontWeight(.bold)
                .foregroundStyle(color)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

