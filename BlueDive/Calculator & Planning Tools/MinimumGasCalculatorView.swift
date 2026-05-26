import SwiftUI

// MARK: - Data model

struct MinimumGasInput {
    var depth: Double
    var sac: Double
    var tHandling: Double
    var v1: Double
    var v2: Double
    var cylVol: Double
    var fillPressure: Double
    var margin: Double
    var minMgBar: Double
    var roundUpAscent: Bool
    var safetyStop: Bool
}

struct MinimumGasResult {
    let pMoy: Double
    let t1: Double
    let t2: Double
    let tTotal: Double
    let tHandling: Double
    let safetyStopTime: Double
    let mg_L: Double
    let mg_bar: Double
    let mgWasFloored: Bool
    let rg_L: Double
    let rg_bar: Double
    let ug_L: Double
    let ug_bar: Double
    let gp_L: Double
    let gp_bar: Double
    var tGrand: Double { tTotal + safetyStopTime }
}

// Calculation always works in metric (m, L/min, bar); callers convert before passing in.
func calcMinimumGas(_ input: MinimumGasInput) -> MinimumGasResult {
    let divers                   = 2.0
    let safetyStopDuration_min   = 3.0
    let safetyStopPressure_ata   = 1.5  // 5 m in seawater: 0.5 bar gauge + 1 bar surface
    let half = input.depth / 2

    let pMoy   = (input.depth / 10) / 2 + 1
    let t1     = input.roundUpAscent ? ceil(half / input.v1) : half / input.v1
    let t2     = input.roundUpAscent ? ceil(half / input.v2) : half / input.v2
    let tTotal = input.tHandling + t1 + t2

    // Calculated at stop depth rather than folding into tTotal to avoid applying
    // pMoy (max-depth pressure) to stop gas.
    let safetyStopTime  = input.safetyStop ? safetyStopDuration_min : 0.0
    let safetyStopGas_L = input.safetyStop ? input.sac * divers * safetyStopDuration_min * safetyStopPressure_ata : 0.0

    let mg_L_raw     = input.sac * divers * tTotal * pMoy + safetyStopGas_L
    let mg_bar_raw   = mg_L_raw / input.cylVol
    let mgWasFloored = mg_bar_raw < input.minMgBar
    let mg_bar       = max(input.minMgBar, mg_bar_raw)
    let mg_L         = mg_bar * input.cylVol

    let rg_L   = input.margin * input.cylVol
    let rg_bar = input.margin

    let ug_L   = input.cylVol * input.fillPressure
    let ug_bar = input.fillPressure

    let gp_L   = ug_L - mg_L - rg_L
    let gp_bar = gp_L / input.cylVol

    return MinimumGasResult(
        pMoy: pMoy, t1: t1, t2: t2, tTotal: tTotal,
        tHandling: input.tHandling,
        safetyStopTime: safetyStopTime,
        mg_L: mg_L, mg_bar: mg_bar, mgWasFloored: mgWasFloored,
        rg_L: rg_L, rg_bar: rg_bar,
        ug_L: ug_L, ug_bar: ug_bar,
        gp_L: gp_L, gp_bar: gp_bar
    )
}

// MARK: - View

struct MinimumGasCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage("lastAcknowledgedCalculatorWarningVersion") private var lastAcknowledgedCalculatorWarningVersion = ""
    @State private var showCalculatorWarning = false

    private enum UnitMode: CaseIterable, Identifiable {
        case metric, imperial
        var id: Self { self }
    }

    @State private var unitMode: UnitMode = .metric
    @State private var depthStr = "30"
    @State private var sacStr = "20"
    @State private var tHandlingStr = "1"
    @State private var v1Str = "9"
    @State private var v2Str = "3"
    @State private var fillPressureStr = "230"
    @State private var marginStr = "40"
    @State private var cylVolStr = "12"
    @State private var isTwinset = false
    @State private var includeReserveGas = false
    @State private var roundUpAscent = true
    @State private var safetyStop = false
    @State private var showInfo = false
    @FocusState private var isAnyFieldFocused: Bool

    private func toDouble(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // Always returns the cylinder water-volume in litres, ready for calcMinimumGas.
    // In metric, the user enters water-volume (L) directly.
    // In imperial, the user enters surface gas-volume (cuft) at the rated fill pressure,
    // so we back-calculate water-volume: waterVol_L = gasVol_L / fillPressure_bar.
    private var cylVolLitres: Double {
        let base = max(1, toDouble(cylVolStr))
        let withTwinset = isTwinset ? base * 2 : base
        if unitMode == .metric {
            return withTwinset
        } else {
            let gasVol_L   = withTwinset * 28.3168
            let fillBar    = max(1, toDouble(fillPressureStr)) / 14.5038
            return gasVol_L / fillBar
        }
    }

    private var result: MinimumGasResult {
        let imp = unitMode == .imperial
        return calcMinimumGas(MinimumGasInput(
            depth:         imp ? toDouble(depthStr) / 3.28084           : toDouble(depthStr),
            sac:           max(1, imp ? toDouble(sacStr) * 28.3168      : toDouble(sacStr)),
            tHandling:     toDouble(tHandlingStr),
            v1:            max(1, imp ? toDouble(v1Str) / 3.28084       : toDouble(v1Str)),
            v2:            max(1, imp ? toDouble(v2Str) / 3.28084       : toDouble(v2Str)),
            cylVol:        cylVolLitres,
            fillPressure:  imp ? toDouble(fillPressureStr) / 14.5038    : toDouble(fillPressureStr),
            margin:        includeReserveGas ? (imp ? toDouble(marginStr) / 14.5038 : toDouble(marginStr)) : 0,
            minMgBar:      imp ? 600.0 / 14.5038 : 40.0,
            roundUpAscent: roundUpAscent,
            safetyStop:    safetyStop
        ))
    }

    private func displayVol(_ liters: Double) -> Double {
        unitMode == .metric ? liters : liters / 28.3168
    }

    private func displayPres(_ bar: Double) -> Double {
        unitMode == .metric ? bar : bar * 14.5038
    }

    private var hasInvalidInputs: Bool {
        toDouble(sacStr) <= 0 || toDouble(v1Str) <= 0 || toDouble(v2Str) <= 0 ||
        toDouble(cylVolStr) <= 0 || toDouble(fillPressureStr) <= 0
    }

    private var volUnitLabel: LocalizedStringKey { unitMode == .metric ? "Litres" : "cuft" }
    private var presUnitLabel: LocalizedStringKey { unitMode == .metric ? "Bar" : "PSI" }

    var body: some View {
        NavigationStack {
            Form {
                unitModeSection
                parametersSection
                cylinderSection
                detailsSection
                resultsSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Minimum Gas")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.cyan)
                    }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Close") {
                        isAnyFieldFocused = false
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
            .sheet(isPresented: $showCalculatorWarning) {
                CalculatorSafetyWarningView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .onAppear {
                if lastAcknowledgedCalculatorWarningVersion != appVersionBuild() {
                    showCalculatorWarning = true
                }
            }
            .onChange(of: unitMode) { _, newMode in
                switch newMode {
                case .metric:
                    depthStr        = "30"
                    sacStr          = "20"
                    v1Str           = "9"
                    v2Str           = "3"
                    cylVolStr       = "12"
                    fillPressureStr = "230"
                    marginStr       = "40"
                case .imperial:
                    depthStr        = "100"
                    sacStr          = "0.75"
                    v1Str           = "30"
                    v2Str           = "10"
                    cylVolStr       = "100"
                    fillPressureStr = "3442"
                    marginStr       = "600"
                }
            }
        }
    }

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Minimum Gas (MG)", systemImage: "drop.fill")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("How is Minimum Gas calculated?")
                            .font(.title3.weight(.semibold))
                        Text("Minimum Gas (MG) is the air you must keep in reserve to bring both you and your buddy safely to the surface if one of you runs out of air at depth.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ascent", systemImage: "arrow.up.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.cyan)
                        let metricFormat = NSLocalizedString(
                            "The ascent is split in two: the first half at %1$@ m/min, the second half at %2$@ m/min. An extra %3$@ min is added at the bottom to manage the emergency before ascending. Average pressure is based on your maximum depth — the deeper you go, the more reserve you need.",
                            bundle: .forAppLanguage(),
                            comment: ""
                        )
                        let imperialFormat = NSLocalizedString(
                            "The ascent is split in two: the first half at %1$@ ft/min, the second half at %2$@ ft/min. An extra %3$@ min is added at the bottom to manage the emergency before ascending. Average pressure is based on your maximum depth — the deeper you go, the more reserve you need.",
                            bundle: .forAppLanguage(),
                            comment: ""
                        )
                        Text(verbatim: String(
                            format: unitMode == .metric ? metricFormat : imperialFormat,
                            String(format: "%g", locale: locale, max(1, toDouble(v1Str))),
                            String(format: "%g", locale: locale, max(1, toDouble(v2Str))),
                            String(format: "%g", locale: locale, toDouble(tHandlingStr))
                        ))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Safety Stop", systemImage: "pause.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.teal)
                        Text("When enabled, a 3-minute safety stop at 5 m (15 ft / 1.5 ATA) is added to the Minimum Gas for both divers. The stop gas is calculated at stop depth rather than at average dive pressure.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Reserve Gas (RG)", systemImage: "lock.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Reserve Gas (RG) is the fixed safety buffer set by the Reserve Gas field. It is held back separately from the MG and is never consumed during the dive — it stays in your cylinder as an absolute last resort.")
                        Text("Three factors justify keeping this reserve: regulators need a minimum inlet pressure to deliver gas reliably, submersible pressure gauges are not perfectly accurate, and gas pressure drops when water temperature is colder than the fill temperature. Together, these account for roughly 40 bar (600 psi) of unusable gas at the bottom of your cylinder.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Usable Gas (UG)", systemImage: "gauge.with.needle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text("Total Gas (TG) is your total air when full. Usable Gas (UG) is what's left after subtracting the MG and the Reserve Gas (RG) — the air you can actually use during your dive.")
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
                    Text("How MG Works")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { showInfo = false }
                }
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

    private var parametersSection: some View {
        Section(header: Text("Dive Parameters")) {
            numberRow(unitMode == .metric ? "Depth (m)"                       : "Depth (ft)",                      text: $depthStr)
            numberRow(
                unitMode == .metric ? "Respiratory Minute Volume (L/min)" : "Respiratory Minute Volume (cuft/min)",
                text: $sacStr,
                note: "RMV · Measured at the surface",
                warning: toDouble(sacStr) <= 0 ? "Must be greater than 0" : nil
            )
            numberRow("Handling Time (min)",                                                                        text: $tHandlingStr)
            numberRow(unitMode == .metric ? "Ascent Speed 1st Half (m/min)"   : "Ascent Speed 1st Half (ft/min)",  text: $v1Str,
                      warning: toDouble(v1Str) <= 0 ? "Must be greater than 0" : nil)
            numberRow(unitMode == .metric ? "Ascent Speed 2nd Half (m/min)"   : "Ascent Speed 2nd Half (ft/min)",  text: $v2Str,
                      warning: toDouble(v2Str) <= 0 ? "Must be greater than 0" : nil)
            Toggle("Round Up Ascent Time", isOn: $roundUpAscent)
            Toggle(unitMode == .metric ? "Safety Stop (5m)" : "Safety Stop (15ft)", isOn: $safetyStop)
        }
    }

    private var cylinderSection: some View {
        Section(header: Text("Tank")) {
            numberRow(unitMode == .metric ? "Volume (L)"           : "Volume (cuft)",         text: $cylVolStr,
                      warning: toDouble(cylVolStr) <= 0 ? "Must be greater than 0" : nil)
            Toggle("Twinset", isOn: $isTwinset)
            numberRow(unitMode == .metric ? "Fill Pressure (bar)"  : "Fill Pressure (psi)",   text: $fillPressureStr,
                      warning: toDouble(fillPressureStr) <= 0 ? "Must be greater than 0" : nil)
            Toggle("Reserve Gas", isOn: $includeReserveGas)
            if includeReserveGas {
                numberRow(unitMode == .metric ? "Reserve Gas (bar)" : "Reserve Gas (psi)", text: $marginStr)
            }
        }
    }

    private var detailsSection: some View {
        Section(header: Text("Calculation Details")) {
            detailRow("Mean Pressure", value: hasInvalidInputs ? "—" : String(format: "%.2f ATA", locale: locale, result.pMoy))
            detailRow("Handling Time", value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.tHandling))
            detailRow("Ascent Phase 1", value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.t1))
            detailRow("Ascent Phase 2", value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.t2))
            detailRow("Safety Stop",    value: hasInvalidInputs ? "—" : (result.safetyStopTime > 0 ? String(format: "%.0f min", locale: locale, result.safetyStopTime) : "—"))
            detailRow("Total Time",     value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.tGrand))
        }
    }

    private var resultsSection: some View {
        Section(header: Text("Results")) {
            gasRow("Minimum Gas (MG)",
                   primaryValue: displayVol(result.mg_L),  primaryUnit: volUnitLabel,
                   secondaryValue: displayPres(result.mg_bar), secondaryUnit: presUnitLabel,
                   color: .blue, isValid: !hasInvalidInputs)
            if !hasInvalidInputs && result.mgWasFloored {
                if unitMode == .metric {
                    Text("Minimum is 40 bar")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Minimum is 600 psi")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if includeReserveGas {
                gasRow("Reserve Gas (RG)",
                       primaryValue: displayVol(result.rg_L),  primaryUnit: volUnitLabel,
                       secondaryValue: displayPres(result.rg_bar), secondaryUnit: presUnitLabel,
                       color: .orange, isValid: !hasInvalidInputs)
            }
            gasRow("Total Gas (TG)",
                   primaryValue: displayVol(result.ug_L),  primaryUnit: volUnitLabel,
                   secondaryValue: displayPres(result.ug_bar), secondaryUnit: presUnitLabel,
                   color: .cyan, isValid: !hasInvalidInputs)
            gasRow("Usable Gas (UG)",
                   primaryValue: displayVol(result.gp_L),  primaryUnit: volUnitLabel,
                   secondaryValue: displayPres(result.gp_bar), secondaryUnit: presUnitLabel,
                   color: result.gp_L >= 0 ? .green : .red, isValid: !hasInvalidInputs)
            Text("All calculations provided by this tool are estimates. It is the diver's sole responsibility to verify and validate all results before any dive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func numberRow(_ label: LocalizedStringKey, text: Binding<String>, note: LocalizedStringKey? = nil, warning: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                HStack(spacing: 0) {
                    TextField("0", text: text)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60)
                        .focused($isAnyFieldFocused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    // Fixed-width slot keeps layout stable when button appears/disappears
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
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func gasRow(
        _ label: LocalizedStringKey,
        primaryValue: Double,   primaryUnit: LocalizedStringKey,
        secondaryValue: Double, secondaryUnit: LocalizedStringKey,
        color: Color,
        isValid: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isValid ? color : .secondary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: isValid ? String(format: "%.1f", locale: locale, primaryValue) : "—")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(isValid ? color : .secondary)
                    Text(primaryUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: isValid ? String(format: "%.1f", locale: locale, secondaryValue) : "—")
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(isValid ? color : .secondary)
                    Text(secondaryUnit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
