import SwiftUI

// MARK: - Import Format Model

/// The unit formats selected by the user before a MacDive XML import.
struct ImportFormatOptions {
    var distanceFormat: String    = "meters"
    var temperatureFormat: String = "°c"
    var pressureFormat: String    = "bar"
    var volumeFormat: String      = "liters"
    var weightFormat: String      = "kg"
    var importGear: Bool          = true
}

// MARK: - Auto-detected unit system from XML

/// The unit system found at `dives/units` in a MacDive XML file.
enum DetectedUnitSystem {
    case metric
    case imperial
    case canadian

    /// Reads the first 4 KB of `data` and looks for `<units>Metric</units>`
    /// or `<units>Imperial</units>` anywhere in the text (case-insensitive).
    /// Returns `nil` when the tag is absent or contains an unrecognised value.
    static func detect(from data: Data) -> DetectedUnitSystem? {
        // Only scan the beginning of the file — the <units> tag always appears
        // in the file header, well within the first 4 KB.
        guard let snippet = String(data: data.prefix(4096), encoding: .utf8) else {
            return nil
        }
        let lower = snippet.lowercased()
        if lower.contains("<units>metric</units>") {
            return .metric
        } else if lower.contains("<units>imperial</units>") {
            return .imperial
        } else if lower.contains("<units>canadian</units>") {
            return .canadian
        }
        return nil
    }

    /// Returns a fully-populated `ImportFormatOptions` matching this system.
    var formatOptions: ImportFormatOptions {
        switch self {
        case .metric:
            return ImportFormatOptions(
                distanceFormat:    "meters",
                temperatureFormat: "°c",
                pressureFormat:    "bar",
                volumeFormat:      "liters",
                weightFormat:      "kg"
            )
        case .imperial:
            return ImportFormatOptions(
                distanceFormat:    "feet",
                temperatureFormat: "°f",
                pressureFormat:    "psi",
                volumeFormat:      "cubic feet",
                weightFormat:      "lb"
            )
        case .canadian:
            return ImportFormatOptions(
                distanceFormat:    "feet",
                temperatureFormat: "°c",
                pressureFormat:    "psi",
                volumeFormat:      "cubic feet",
                weightFormat:      "kg"
            )
        }
    }

    var label: String {
        let bundle = Bundle.forAppLanguage()
        switch self {
        case .metric:   return NSLocalizedString("Metric", bundle: bundle, comment: "")
        case .imperial: return NSLocalizedString("Imperial", bundle: bundle, comment: "")
        case .canadian: return NSLocalizedString("Canadian", bundle: bundle, comment: "")
        }
    }

    var icon: String {
        switch self {
        case .metric:   return "m.circle.fill"
        case .imperial: return "f.cursive.circle.fill"
        case .canadian: return "c.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .metric:   return .cyan
        case .imperial: return .orange
        case .canadian: return .red
        }
    }
}

// MARK: - Picker Sheet

/// A sheet that asks the user which unit system the imported XML file uses.
struct ImportFormatPickerView: View {

    @Binding var options: ImportFormatOptions

    /// Raw bytes of the file being imported.  When provided the view will
    /// attempt to auto-detect the unit system from `<units>` at the file head.
    var fileData: Data?

    /// The type of file being imported. When `.blueDive`, unit pickers are
    /// hidden because units are already embedded in the file.
    var fileType: ImportFileType = .macDive

    /// Called when the user taps "Import".
    var onConfirm: () -> Void

    /// Called when the user taps "Cancel".
    var onCancel: () -> Void

    // MARK: - Derived State

    /// The unit system detected from the XML, or `nil` if undetectable.
    private var detectedSystem: DetectedUnitSystem? {
        guard let data = fileData else { return nil }
        return DetectedUnitSystem.detect(from: data)
    }

    // MARK: - Option Sets

    private let distanceOptions: [(label: LocalizedStringKey, value: String)] = [
        ("Meters (m)", "meters"),
        ("Feet (ft)",  "feet")
    ]

    private let temperatureOptions: [(label: LocalizedStringKey, value: String)] = [
        ("Celsius (°C)",    "°c"),
        ("Fahrenheit (°F)", "°f"),
        ("Kelvin (°K)",     "°k")
    ]

    private let pressureOptions: [(label: LocalizedStringKey, value: String)] = [
        ("Bar",         "bar"),
        ("PSI",         "psi"),
        ("Pascal (Pa)", "pa")
    ]

    private let volumeOptions: [(label: LocalizedStringKey, value: String)] = [
        ("Liters (L)",       "liters"),
        ("Cubic Feet (ft³)", "cubic feet")
    ]

    private let weightOptions: [(label: LocalizedStringKey, value: String)] = [
        ("Kilograms (kg)", "kg"),
        ("Pounds (lb)",    "lb")
    ]

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    headerView
                    if fileType == .macDive {
                        detectionBannerSection
                        unitCard(
                            icon: "arrow.down.to.line", iconColor: .cyan,
                            title: "Distance / Depth",
                            autoValue: detectedSystem?.formatOptions.distanceFormat,
                            currentValue: options.distanceFormat,
                            optionList: distanceOptions,
                            apply: { options.distanceFormat = $0 }
                        )
                        unitCard(
                            icon: "thermometer.medium", iconColor: .orange,
                            title: "Temperature",
                            autoValue: detectedSystem?.formatOptions.temperatureFormat,
                            currentValue: options.temperatureFormat,
                            optionList: temperatureOptions,
                            apply: { options.temperatureFormat = $0 }
                        )
                        unitCard(
                            icon: "gauge.with.needle.fill", iconColor: .red,
                            title: "Pressure",
                            autoValue: detectedSystem?.formatOptions.pressureFormat,
                            currentValue: options.pressureFormat,
                            optionList: pressureOptions,
                            apply: { options.pressureFormat = $0 }
                        )
                        unitCard(
                            icon: "cylinder.fill", iconColor: .indigo,
                            title: "Volume / Tank Size",
                            autoValue: detectedSystem?.formatOptions.volumeFormat,
                            currentValue: options.volumeFormat,
                            optionList: volumeOptions,
                            apply: { options.volumeFormat = $0 }
                        )
                        unitCard(
                            icon: "scalemass.fill", iconColor: .purple,
                            title: "Weight",
                            autoValue: detectedSystem?.formatOptions.weightFormat,
                            currentValue: options.weightFormat,
                            optionList: weightOptions,
                            apply: { options.weightFormat = $0 }
                        )
                    }
                    importGearToggle
                    actionButtons
                }
                .padding(.horizontal)
                .padding(.vertical, 24)
            }
        }

        #if os(macOS)
        .frame(
            minWidth: 540, idealWidth: 600, maxWidth: 750,
            minHeight: fileType == .macDive ? 580 : 280,
            idealHeight: fileType == .macDive ? 650 : 320,
            maxHeight: fileType == .macDive ? 850 : 400
        )
        #endif
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(fileType == .macDive ? "Import Units" : "Import Options")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(fileType == .macDive
                     ? "Choose the unit system used by your file"
                     : "Configure options for your import")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Unit Card

    private func unitCard(
        icon: String,
        iconColor: Color,
        title: LocalizedStringKey,
        autoValue: String?,
        currentValue: String,
        optionList: [(label: LocalizedStringKey, value: String)],
        apply: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                autoChip(autoValue: autoValue, currentValue: currentValue, apply: apply)
            }
            HStack(spacing: 8) {
                ForEach(optionList, id: \.value) { option in
                    let selected = currentValue == option.value
                    Button { withAnimation(.spring(duration: 0.25)) { apply(option.value) } } label: {
                        Text(option.label)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? iconColor : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selected ? iconColor.opacity(0.18) : Color.primary.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(selected ? iconColor.opacity(0.5) : Color.clear, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Auto Chip

    @ViewBuilder
    private func autoChip(
        autoValue: String?,
        currentValue: String,
        apply: @escaping (String) -> Void
    ) -> some View {
        if let detected = autoValue {
            if currentValue == detected {
                Label("Auto", systemImage: "checkmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button { withAnimation(.spring(duration: 0.25)) { apply(detected) } } label: {
                    Label("Auto", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        } else {
            Label("Auto", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        }
    }

    // MARK: - Import Gear Toggle

    private var importGearToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "compass.drawing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Import Gear")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("Include equipment items from the file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $options.importGear)
                .labelsHidden()
                .tint(.green)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Import").fontWeight(.bold)
                }
                .font(.subheadline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.cyan))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Detection Banner

    @ViewBuilder
    private var detectionBannerSection: some View {
        if let system = detectedSystem {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(system.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unit system detected: **\(system.label)**")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("Use \"Auto\" per unit or apply everything at once below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    withAnimation(.spring(duration: 0.35)) { options = system.formatOptions }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: system.icon)
                        Text("Apply All — \(system.label)").fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(system.color))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(system.color.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(system.color.opacity(0.3), lineWidth: 1))
            )
        } else {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No unit tag detected")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("No `<units>` tag found — please select each unit manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            )
        }
    }
}
