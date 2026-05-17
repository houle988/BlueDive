import SwiftUI

// MARK: - Gas Densities (g/L at 0 °C, 1 atm / STP)

private let kDensityO2: Double = 1.428
private let kDensityN2: Double = 1.251
private let kDensityHe: Double = 0.179

// MARK: - Result Model

struct GasDensityResult {
    let n2Pct: Double
    let ata: Double
    let surfaceDensity: Double
    let depthDensity: Double
}

func calcGasDensity(o2Pct: Double, hePct: Double, depthMetres: Double, isSeawater: Bool = true) -> GasDensityResult {
    let n2Pct = max(0.0, 100.0 - o2Pct - hePct)
    let ata = depthMetres / (isSeawater ? 10.0 : 10.3) + 1.0
    let base = (o2Pct / 100.0 * kDensityO2)
             + (n2Pct / 100.0 * kDensityN2)
             + (hePct / 100.0 * kDensityHe)
    return GasDensityResult(n2Pct: n2Pct, ata: ata, surfaceDensity: base, depthDensity: base * ata)
}

// MARK: - View

struct GasDensityCalculatorView: View {
    @Environment(\.dismiss) private var dismiss

    private enum UnitMode: CaseIterable, Identifiable {
        case metric, imperial
        var id: Self { self }
    }

    @State private var unitMode: UnitMode = .metric
    @State private var isSeawater = true
    @State private var o2Str = "21"
    @State private var heStr = "0"
    @State private var depthStr = "0"
    @State private var showInfo = false

    private func toDouble(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var o2: Double { min(100, max(0, toDouble(o2Str))) }
    private var he: Double { min(100, max(0, toDouble(heStr))) }
    private var isValid: Bool { o2 + he <= 100 }

    private var result: GasDensityResult {
        let depthM = unitMode == .imperial ? toDouble(depthStr) / 3.28084 : toDouble(depthStr)
        return calcGasDensity(o2Pct: o2, hePct: he, depthMetres: max(0, depthM), isSeawater: isSeawater)
    }

    var body: some View {
        NavigationStack {
            Form {
                unitModeSection
                gasMixtureSection
                depthSection
                resultsSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Gas Density")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.cyan)
                    }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                #endif
            }
            .sheet(isPresented: $showInfo) {
                infoSheet
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: unitMode) { _, _ in
                depthStr = "0"
            }
        }
    }

    // MARK: - Sections

    private var unitModeSection: some View {
        Section {
            Picker(selection: $unitMode) {
                Text("Metric").tag(UnitMode.metric)
                Text("Imperial").tag(UnitMode.imperial)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var gasMixtureSection: some View {
        Section(header: Text("Gas Mixture")) {
            numberRow("Oxygen (O₂)", unit: "%", text: $o2Str)
            numberRow("Helium (He)", unit: "%", text: $heStr)
            LabeledContent {
                Text(verbatim: isValid
                    ? String(format: "%.1f %%", result.n2Pct)
                    : String(format: NSLocalizedString("Over %@", bundle: .forAppLanguage(), comment: ""), "100%"))
                    .foregroundStyle(isValid ? Color.secondary : .red)
                    .monospacedDigit()
            } label: {
                HStack(spacing: 2) {
                    Text("Nitrogen (N₂)")
                    Text(verbatim: "%").foregroundStyle(.secondary)
                }
            }
            if !isValid {
                Text(verbatim: String(format: NSLocalizedString("Total exceeds %@. Adjust the gas fractions.", bundle: .forAppLanguage(), comment: ""), "100%"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var depthSection: some View {
        Section(header: Text("Depth")) {
            numberRow(unitMode == .metric ? "Depth (m)" : "Depth (ft)", text: $depthStr)
            Toggle("Seawater", isOn: $isSeawater)
            LabeledContent("Pressure") {
                Text(verbatim: String(format: "%.2f ATA", result.ata))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var resultsSection: some View {
        Section(header: Text("Results")) {
            if isValid {
                densityRow("Surface Density", value: result.surfaceDensity, color: surfaceDensityColor, ataPart: "1.00 ATA")
                densityRow("Density at Depth", value: result.depthDensity,
                           color: depthDensityColor,
                           ataPart: String(format: "%.2f ATA", result.ata))
                densityWarning(result.depthDensity)
            } else {
                Label {
                    Text(verbatim: String(format: NSLocalizedString("Gas fractions exceed %@. Adjust the mixture to calculate density.", bundle: .forAppLanguage(), comment: ""), "100%"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            }
            Text("All calculations provided by this tool are estimates. It is the diver's sole responsibility to verify and validate all results before any dive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func numberRow(_ label: LocalizedStringKey, unit: String = "", text: Binding<String>) -> some View {
        HStack {
            HStack(spacing: 2) {
                Text(label)
                if !unit.isEmpty {
                    Text(verbatim: unit).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 0) {
                TextField("0", text: text)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                ZStack {
                    Color.clear.frame(width: 24, height: 24)
                    if !text.wrappedValue.isEmpty {
                        Button { text.wrappedValue = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func densityRow(_ label: LocalizedStringKey, value: Double, color: Color, ataPart: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: "%.3f", value))
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(color)
                    Text(verbatim: "g/L")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: ataPart)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    private var surfaceDensityColor: Color {
        if result.surfaceDensity >= 6.2 { return .red }
        if result.surfaceDensity >= 5.2 { return .orange }
        return .green
    }

    private var depthDensityColor: Color {
        if result.depthDensity >= 6.2 { return .red }
        if result.depthDensity >= 5.2 { return .orange }
        return .green
    }

    @ViewBuilder
    private func densityWarning(_ density: Double) -> some View {
        if density >= 6.2 {
            Label("High gas density — increased risk of breathing difficulty.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if density >= 5.2 {
            Label("Elevated gas density — approach with caution.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Gas density within safe range.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Info Sheet

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Gas Density", systemImage: "atom")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("What is gas density?")
                            .font(.title3.weight(.semibold))
                        Text("Gas density measures the mass of gas per unit volume (g/L) at a given pressure. As you descend, pressure increases and the gas you breathe becomes denser, making it harder to breathe and increasing the work of breathing.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("CO₂ Retention", systemImage: "lungs.fill")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        Text("CO₂ Retention Risk")
                            .font(.title3.weight(.semibold))
                        Text("Denser gas increases airway resistance and the work of breathing. To compensate, divers tend to unconsciously breathe shallower, which reduces alveolar ventilation below what is needed to clear CO₂. This causes hypercapnia (CO₂ build-up) even when breathing effort feels normal. Elevated CO₂ causes headaches, narcosis-like impairment, and in severe cases loss of consciousness — sometimes before the diver is aware of a problem.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Reference Densities", systemImage: "list.bullet")
                            .font(.headline)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 4) {
                            densityRefRow("Oxygen (O₂)",   density: kDensityO2)
                            densityRefRow("Nitrogen (N₂)", density: kDensityN2)
                            densityRefRow("Helium (He)",   density: kDensityHe)
                            densityRefRow("Air (21/79)",   density: 1.293)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Formula", systemImage: "function")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(verbatim: "Density (g/L) = (O₂% × 1.428 + N₂% × 1.251 + He% × 0.179) × ATA")
                            .font(.system(.body, design: .monospaced))
                        Text("Seawater: depth (m) ÷ 10 + 1 | Freshwater: depth (m) ÷ 10.3 + 1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Thresholds", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Label("< 5.2 g/L: Safe — normal breathing effort.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Label("≥ 5.2 g/L: Elevated — approach with caution.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Label("≥ 6.2 g/L: High — significant risk of respiratory impairment.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text("These thresholds guide depth limits and gas selection for technical diving (Anthony & Mitchell, 2016).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Safety", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Always dive within your training and certification limits.")
                            .italic()
                        Text("All calculations provided by this tool are estimates. It is the diver's sole responsibility to verify and validate all results before any dive.")
                            .italic()
                    }
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("How Gas Density Works")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showInfo = false }
                }
            }
        }
    }

    @ViewBuilder
    private func densityRefRow(_ gas: String, density: Double) -> some View {
        HStack {
            Text(verbatim: gas)
                .frame(minWidth: 120, alignment: .leading)
            Text(verbatim: String(format: "%.3f g/L", density))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
