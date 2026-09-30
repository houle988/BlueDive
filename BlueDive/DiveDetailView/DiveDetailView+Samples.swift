import SwiftUI

// MARK: - Fingerprint Copy Button

private struct FingerprintCopyButton: View {
    let data: Data
    @State private var copied = false

    private var hexString: String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = hexString
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hexString, forType: .string)
            #endif
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                .foregroundStyle(copied ? .green : .teal)
                .animation(.easeInOut(duration: 0.2), value: copied)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Copy Fingerprint"))
    }
}

// MARK: - Samples Tab

extension DiveDetailView {

    var samplesTabContent: some View {
        VStack(spacing: 20) {
            if dive.profileSamples.isEmpty {
                emptySamplesView
            } else {
                samplesFormatInfoSection
                fingerprintSection
                samplesTableSection
            }
        }
    }

    var emptySamplesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("No samples available")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Import a dive from your dive computer to see detailed data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Fingerprint

    var fingerprintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "barcode.viewfinder")
                    .foregroundStyle(.teal)
                Text("Fingerprint")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let data = dive.fingerprintData {
                    FingerprintCopyButton(data: data)
                }
            }

            if let data = dive.fingerprintData {
                Text(data.map { String(format: "%02x", $0) }.joined(separator: " "))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }

    // MARK: - Samples Format Info

    var samplesFormatInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.teal)
                Text("Imported Data Format")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FormatInfoCell(
                    icon: "arrow.down.to.line",
                    label: "Distance",
                    value: {
                        switch dive.importDistanceUnit {
                        case "feet": return NSLocalizedString("Feet", bundle: Bundle.forAppLanguage(), comment: "Unit name: feet")
                        default:     return NSLocalizedString("Meters", bundle: Bundle.forAppLanguage(), comment: "Unit name: metres")
                        }
                    }(),
                    color: .cyan
                )
                FormatInfoCell(
                    icon: "thermometer.medium",
                    label: "Temperature",
                    value: dive.importTemperatureUnit,
                    color: .orange
                )
                FormatInfoCell(
                    icon: "gauge.with.needle",
                    label: "Pressure",
                    value: dive.importPressureUnit,
                    color: .red
                )
                FormatInfoCell(
                    icon: "cylinder",
                    label: "Volume",
                    value: {
                        switch dive.importVolumeUnit {
                        case "cubic feet": return NSLocalizedString("Cubic Feet", bundle: Bundle.forAppLanguage(), comment: "Unit name: cubic feet")
                        default:           return NSLocalizedString("Liters", bundle: Bundle.forAppLanguage(), comment: "Unit name: litres")
                        }
                    }(),
                    color: .green
                )
            }
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }

    var samplesChartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.teal)
                Text("Detailed Profile")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            UnifiedDiveChartOptimized(dive: dive)
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }

    /// Sorted tank indices that have per-tank pressure data across the whole dive.
    private var sampleTankIndices: [Int] {
        var indices = Set<Int>()
        for sample in dive.profileSamples {
            if let tp = sample.tankPressures {
                indices.formUnion(tp.keys)
            }
        }
        return indices.sorted()
    }

    /// Sorted O2 sensor indices that have per-sensor PPO2 data across the whole dive.
    private var sampleSensorIndices: [Int] {
        var indices = Set<Int>()
        for sample in dive.profileSamples {
            if let sp = sample.sensorPPO2 { indices.formUnion(sp.keys) }
        }
        return indices.sorted()
    }

    /// Rows shown before "Show all" is tapped. Keeps the tab short so the page stays easy
    /// to scroll through; the rows themselves are built lazily either way.
    static let samplesPreviewLimit = 150

    /// Width of a samples table column: its default width, widened to the header title's
    /// natural single-line width when the title is longer (e.g. French "Profondeur"), so
    /// headers never wrap in any language or text size. Header and row cells use this width
    /// so they stay aligned; it adapts to the header only, so a wide value can still wrap.
    private func sampleColumnWidth(_ column: SampleColumn) -> CGFloat {
        max(column.defaultWidth, sampleHeaderWidths[column] ?? 0)
    }

    /// A samples table header cell that reports its title's natural width, used by
    /// `sampleColumnWidth(_:)`. The title is measured before the column frame is applied,
    /// so the measurement does not depend on the width it produces.
    private func sampleHeader(_ title: Text, _ column: SampleColumn, alignment: Alignment) -> some View {
        title
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                // Only write a changed width: each write updates the whole dive detail view.
                if sampleHeaderWidths[column] != width {
                    sampleHeaderWidths[column] = width
                }
            }
            .frame(width: sampleColumnWidth(column), alignment: alignment)
    }

    var samplesTableSection: some View {
        let allSamples = dive.profileSamples
        let visibleSamples = showAllSamples ? allSamples : Array(allSamples.prefix(Self.samplesPreviewLimit))
        let tankIndices = sampleTankIndices
        let hasMultiTank = tankIndices.count > 1
        let sensorIndices = sampleSensorIndices
        let hasSensorPPO2 = !sensorIndices.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .foregroundStyle(.teal)
                Text("Raw Data (\(Double(allSamples.count).localizedString(decimals: 0)) points)")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            HorizontalPanContainer {
                VStack(alignment: .leading, spacing: 0) {
                    // Table header
                    HStack(spacing: 8) {
                        sampleHeader(Text("Time"), .time, alignment: .leading)
                        sampleHeader(Text("Depth"), .depth, alignment: .trailing)
                        sampleHeader(Text("Temp."), .temperature, alignment: .trailing)
                        if hasMultiTank {
                            ForEach(tankIndices, id: \.self) { idx in
                                sampleHeader(Text("T\(idx + 1)"), .tank(idx), alignment: .trailing)
                            }
                        } else {
                            sampleHeader(Text("Press."), .pressure, alignment: .trailing)
                        }
                        sampleHeader(Text("PPO₂"), .ppo2, alignment: .trailing)
                        if hasSensorPPO2 {
                            ForEach(sensorIndices, id: \.self) { idx in
                                sampleHeader(Text(verbatim: "S\(idx + 1)"), .sensor(idx), alignment: .trailing)
                            }
                        }
                        sampleHeader(Text("CNS"), .cns, alignment: .trailing)
                        sampleHeader(Text("NDL"), .ndl, alignment: .trailing)
                        sampleHeader(Text("Ceiling"), .ceiling, alignment: .trailing)
                        sampleHeader(Text("Stop"), .stop, alignment: .trailing)
                        sampleHeader(Text("Gas"), .gas, alignment: .trailing)
                        sampleHeader(Text("Events"), .events, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)
                    .overlay(alignment: .bottom) {
                        Divider().background(.primary.opacity(0.15))
                    }

                    // Lazy because its enclosing scroll view is now the page's vertical
                    // ScrollView: only the rows on screen are built.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleSamples.indices, id: \.self) { i in
                            let sample = visibleSamples[i]
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: (sample.time * 60).localizedString(decimals: 2))
                                    .font(.caption).foregroundStyle(.primary)
                                    .frame(width: sampleColumnWidth(.time), alignment: .leading)
                                Text(verbatim: sample.depth.localizedString(decimals: 2))
                                    .font(.caption).foregroundStyle(.cyan)
                                    .frame(width: sampleColumnWidth(.depth), alignment: .trailing)
                                if let temp = sample.temperature {
                                    Text(UserPreferences.shared.temperatureUnit.formatted(temp, from: dive.storedTemperatureUnit))
                                        .font(.caption).foregroundStyle(.orange)
                                        .frame(width: sampleColumnWidth(.temperature), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.temperature), alignment: .trailing)
                                }
                                if hasMultiTank {
                                    ForEach(tankIndices, id: \.self) { idx in
                                        if let press = sample.tankPressures?[idx] {
                                            Text(verbatim: dive.displayProfilePressure(press).localizedString(decimals: 0))
                                                .font(.caption).foregroundStyle(.red)
                                                .frame(width: sampleColumnWidth(.tank(idx)), alignment: .trailing)
                                        } else {
                                            Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.tank(idx)), alignment: .trailing)
                                        }
                                    }
                                } else {
                                    if let press = sample.tankPressure {
                                        Text(verbatim: dive.displayProfilePressure(press).localizedString(decimals: 2))
                                            .font(.caption).foregroundStyle(.red)
                                            .frame(width: sampleColumnWidth(.pressure), alignment: .trailing)
                                    } else {
                                        Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.pressure), alignment: .trailing)
                                    }
                                }
                                if let ppo2 = sample.ppo2 {
                                    Text(verbatim: ppo2.localizedString(decimals: 2))
                                        .font(.caption).foregroundStyle(ppo2Color(for: ppo2))
                                        .frame(width: sampleColumnWidth(.ppo2), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.ppo2), alignment: .trailing)
                                }
                                if hasSensorPPO2 {
                                    ForEach(sensorIndices, id: \.self) { idx in
                                        if let p = sample.sensorPPO2?[idx] {
                                            Text(verbatim: p.localizedString(decimals: 2))
                                                .font(.caption).foregroundStyle(ppo2Color(for: p))
                                                .frame(width: sampleColumnWidth(.sensor(idx)), alignment: .trailing)
                                        } else {
                                            Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.sensor(idx)), alignment: .trailing)
                                        }
                                    }
                                }
                                if let cns = sample.cns {
                                    Text(verbatim: cns.localizedString(decimals: 0) + "%")
                                        .font(.caption).foregroundStyle(cnsColor(for: cns))
                                        .frame(width: sampleColumnWidth(.cns), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.cns), alignment: .trailing)
                                }
                                if let ndl = sample.ndl {
                                    Text(verbatim: ndl >= ndlSentinel ? "—" : ndl.localizedString(decimals: 0))
                                        .font(.caption).foregroundStyle(.yellow)
                                        .frame(width: sampleColumnWidth(.ndl), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.ndl), alignment: .trailing)
                                }
                                // Raw stored ceiling, unconverted like the Depth column above,
                                // so both stay directly comparable in this debug table.
                                if let ceiling = sample.ceilingDepth {
                                    Text(verbatim: ceiling.localizedString(decimals: 2))
                                        .font(.caption).foregroundStyle(.orange)
                                        .frame(width: sampleColumnWidth(.ceiling), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.ceiling), alignment: .trailing)
                                }
                                if let ceilingTime = sample.ceilingTime {
                                    Text(verbatim: ceilingTime.localizedString(decimals: 0))
                                        .font(.caption).foregroundStyle(.orange.opacity(0.7))
                                        .frame(width: sampleColumnWidth(.stop), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.stop), alignment: .trailing)
                                }
                                if let gas = sample.currentGas, gas >= 0, gas < dive.tanks.count {
                                    Text(verbatim: "T\(gas + 1)")
                                        .font(.caption).foregroundStyle(.purple)
                                        .frame(width: sampleColumnWidth(.gas), alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.gas), alignment: .trailing)
                                }
                                if sample.events.isEmpty {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: sampleColumnWidth(.events), alignment: .leading)
                                } else {
                                    // Wraps onto more lines rather than truncating, so every event
                                    // stays readable in the fixed-width column on every platform.
                                    Text(sample.events.map(\.label).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.mint)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(width: sampleColumnWidth(.events), alignment: .leading)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .background(i % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear)
                        }
                    }
                }
            }
            // A new container per dive starts every dive at the first column, as the page
            // already returns to the top and the table to its first rows on a dive change.
            .id(dive.id)

            if visibleSamples.count < allSamples.count {
                Button {
                    showAllSamples = true
                } label: {
                    Text("Show all \(Double(allSamples.count).localizedString(decimals: 0)) points")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.teal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .borderlessButton()
            }
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }
}

// MARK: - Samples Table Columns

extension DiveDetailView {
    /// Columns of the samples table whose width adapts to their header title.
    enum SampleColumn: Hashable {
        case time, depth, temperature, pressure, ppo2, cns, ndl, ceiling, stop, gas, events
        case tank(Int)
        case sensor(Int)

        /// Width used when the header title fits (the table's original fixed widths).
        var defaultWidth: CGFloat {
            switch self {
            case .time, .temperature, .pressure, .ppo2, .tank: return 50
            case .depth, .ndl, .ceiling, .stop:                return 45
            case .sensor:                                     return 42
            case .cns:                                        return 40
            case .gas:                                        return 35
            // Wide and not sized to its content: rows are built lazily, so a row built later
            // with a long event list must not widen the table and misalign it with the header.
            // Long lists wrap instead.
            case .events:                                     return 220
            }
        }
    }
}

// MARK: - Horizontal Pan Container

/// Scrolls wide content horizontally without placing it inside a horizontal ScrollView.
///
/// A horizontal ScrollView around the samples table caused two problems: its LazyVStack was
/// not lazy vertically (every row was built at once), and on macOS every Magic Mouse or
/// trackpad scroll event over the table went through that scroll view, whose work grew with
/// the number of rows. Here the content stays in the page's vertical ScrollView and is only
/// shifted with `.offset(x:)`. The horizontal scrolling is done by an empty ScrollView laid
/// over the content, so the scroll view under the pointer holds a single empty view.
/// The offset lives in this view's own state, so scrolling redraws only this view, not the
/// whole dive detail page.
private struct HorizontalPanContainer<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var xOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        OverflowingWidthLayout {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    contentWidth = width
                }
                .offset(x: -xOffset)
        }
        .clipped()
        .overlay {
            ScrollView(.horizontal, showsIndicators: false) {
                // Full height and an explicit content shape: on iOS a scroll view only
                // receives touches over its content, and Color.clear is not hit-testable.
                Color.clear
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, x in
                xOffset = x
            }
            // The empty scroll view is only a gesture target; hiding it lets VoiceOver
            // read the table cells underneath, including clipped columns (VoiceOver does not
            // scroll a clipped column into view).
            .accessibilityHidden(true)
        }
    }
}

/// Lays out its single subview at its natural width, pinned to the leading edge, while
/// reporting only the width it is offered. A plain `.frame(maxWidth: .infinity)` would
/// report the subview's width instead and widen the card to the full table width.
private struct OverflowingWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = subview.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: nil, height: bounds.height))
    }
}
