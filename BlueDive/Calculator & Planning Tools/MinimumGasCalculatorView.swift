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
    let pBottom: Double      // ATA at max depth — used for handling time gas
    let pMean1: Double       // mean ATA for ascent phase 1 (depth → half depth)
    let pMean2: Double       // mean ATA for ascent phase 2 (half depth → surface, time-weighted when safety stop splits it)
    let t1: Double
    let t2: Double           // total second-half ascent time (excl. safety stop)
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
// Uses per-phase mean pressures and calculates handling time at actual bottom pressure.
func calcMinimumGas(_ input: MinimumGasInput) -> MinimumGasResult {
    let divers                 = 2.0
    let safetyStopDepth_m      = 5.0
    let safetyStopDuration_min = 3.0
    let half                   = input.depth / 2.0

    // ATA at key depths
    let pBottom  = input.depth / 10.0 + 1.0
    let pHalf    = half / 10.0 + 1.0
    let pStop    = safetyStopDepth_m / 10.0 + 1.0   // 1.5 ATA at 5 m
    let pSurface = 1.0

    // Phase 1: depth → half depth, speed v1
    let t1     = input.roundUpAscent ? ceil(half / input.v1) : half / input.v1
    let pMean1 = (pBottom + pHalf) / 2.0
    let gas1_L = input.sac * divers * t1 * pMean1

    // Handling time at actual bottom pressure (not mean ascent pressure)
    let gasH_L = input.sac * divers * input.tHandling * pBottom

    // Phase 2: half depth → surface, speed v2.
    // When a safety stop is enabled and the second half passes through the stop depth,
    // split phase 2 around the stop so each segment uses the correct mean pressure.
    let t2: Double
    let gas2_L: Double
    let pMean2: Double
    let safetyStopTime: Double
    let safetyStopGas_L: Double

    if input.safetyStop && half > safetyStopDepth_m {
        // Phase 2a: half depth → safety stop depth
        let dist2a  = half - safetyStopDepth_m
        let t2a     = input.roundUpAscent ? ceil(dist2a / input.v2) : dist2a / input.v2
        let pMean2a = (pHalf + pStop) / 2.0
        let gas2a_L = input.sac * divers * t2a * pMean2a

        safetyStopTime  = safetyStopDuration_min
        safetyStopGas_L = input.sac * divers * safetyStopDuration_min * pStop

        // Phase 2b: safety stop depth → surface
        let t2b     = input.roundUpAscent ? ceil(safetyStopDepth_m / input.v2) : safetyStopDepth_m / input.v2
        let pMean2b = (pStop + pSurface) / 2.0   // 1.25 ATA
        let gas2b_L = input.sac * divers * t2b * pMean2b

        t2     = t2a + t2b
        gas2_L = gas2a_L + gas2b_L
        // Time-weighted mean of the two sub-phases (used for display in details section)
        pMean2 = t2 > 0 ? (pMean2a * t2a + pMean2b * t2b) / t2 : pMean2a
    } else {
        // No safety stop, or dive too shallow for the stop to fall in the second half.
        // Only include stop gas if the diver actually passed through the stop depth.
        let stopApplies = input.safetyStop && input.depth > safetyStopDepth_m

        let t2Full     = input.roundUpAscent ? ceil(half / input.v2) : half / input.v2
        let pMean2Full = (pHalf + pSurface) / 2.0
        let gas2Full_L = input.sac * divers * t2Full * pMean2Full

        safetyStopTime  = stopApplies ? safetyStopDuration_min : 0.0
        safetyStopGas_L = stopApplies ? input.sac * divers * safetyStopDuration_min * pStop : 0.0

        t2     = t2Full
        gas2_L = gas2Full_L
        pMean2 = pMean2Full
    }

    let tTotal = input.tHandling + t1 + t2

    let mg_L_raw     = gas1_L + gas2_L + gasH_L + safetyStopGas_L
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
        pBottom: pBottom, pMean1: pMean1, pMean2: pMean2,
        t1: t1, t2: t2, tTotal: tTotal,
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
    @State private var safetyMarginEnabled = false
    @State private var safetyMarginStr = "1.5"
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

    private var safetyMarginMultiplier: Double {
        safetyMarginEnabled ? max(1.0, toDouble(safetyMarginStr)) : 1.0
    }
    private var adjustedMg_L: Double { result.mg_L * safetyMarginMultiplier }
    private var adjustedMg_bar: Double { result.mg_bar * safetyMarginMultiplier }
    private var adjustedGp_L: Double { result.ug_L - adjustedMg_L - result.rg_L }
    private var adjustedGp_bar: Double { cylVolLitres > 0 ? adjustedGp_L / cylVolLitres : 0 }

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
                            "The ascent is split in two: the first half at %1$@ m/min, the second half at %2$@ m/min. An extra %3$@ min is added at the bottom to manage the emergency before ascending. Each phase uses the mean pressure between its start and end depth. Handling time is calculated at the actual bottom pressure — the highest-pressure portion of the ascent.",
                            bundle: .forAppLanguage(),
                            comment: ""
                        )
                        let imperialFormat = NSLocalizedString(
                            "The ascent is split in two: the first half at %1$@ ft/min, the second half at %2$@ ft/min. An extra %3$@ min is added at the bottom to manage the emergency before ascending. Each phase uses the mean pressure between its start and end depth. Handling time is calculated at the actual bottom pressure — the highest-pressure portion of the ascent.",
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
                        Text("When enabled, a 3-minute safety stop at 5 m (15 ft / 1.5 ATA) is added to the Minimum Gas for both divers. When the stop depth falls within the second half of the ascent, that phase is split in two around the stop so each segment uses its own mean pressure. The stop is skipped automatically if the dive's maximum depth does not reach 5 m.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Safety Margin", systemImage: "gauge.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        Text("When enabled, the Minimum Gas is multiplied by a stress factor to account for the fact that a diver's Respiratory Minute Volume (RMV) can rise significantly under emergency conditions — panic, exertion, or exhaustion.")
                        Text(verbatim: {
                            let formatter = NumberFormatter()
                            formatter.numberStyle = .percent
                            formatter.maximumFractionDigits = 0
                            formatter.locale = locale
                            let pct = formatter.string(from: 0.5) ?? "50%"
                            return String(
                                format: NSLocalizedString(
                                    "A factor of 1.5 means you plan for %@ more gas consumption during the ascent. This buffer is applied on top of the calculated MG, before the Usable Gas is derived.",
                                    bundle: .forAppLanguage(),
                                    comment: ""
                                ),
                                pct
                            )
                        }())
                        .foregroundStyle(.secondary)
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
            Toggle("Safety Margin", isOn: $safetyMarginEnabled)
            if safetyMarginEnabled {
                numberRow("Multiplier (×)", text: $safetyMarginStr,
                          note: "Accounts for increased RMV under stress",
                          warning: toDouble(safetyMarginStr) < 1.0
                              ? "Must be 1.0 or greater"
                              : toDouble(safetyMarginStr) >= 3.0
                              ? "Stress factor above 3.0 is unusually high"
                              : nil)
            }
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
            detailRow("Handling Pressure", value: hasInvalidInputs ? "—" : String(format: "%.2f ATA", locale: locale, result.pBottom))
            detailRow("Phase 1 Pressure",  value: hasInvalidInputs ? "—" : String(format: "%.2f ATA", locale: locale, result.pMean1))
            detailRow("Phase 2 Pressure",  value: hasInvalidInputs ? "—" : String(format: "%.2f ATA", locale: locale, result.pMean2))
            detailRow("Handling Time",     value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.tHandling))
            detailRow("Ascent Phase 1",    value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.t1))
            detailRow("Ascent Phase 2",    value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.t2))
            detailRow("Safety Stop",       value: hasInvalidInputs ? "—" : (result.safetyStopTime > 0 ? String(format: "%.0f min", locale: locale, result.safetyStopTime) : "—"))
            detailRow("Total Time",        value: hasInvalidInputs ? "—" : String(format: "%.1f min", locale: locale, result.tGrand))
        }
    }

    private var resultsSection: some View {
        Section(header: Text("Results")) {
            gasRow("Minimum Gas (MG)",
                   primaryValue: displayVol(adjustedMg_L),  primaryUnit: volUnitLabel,
                   secondaryValue: displayPres(adjustedMg_bar), secondaryUnit: presUnitLabel,
                   color: .blue, isValid: !hasInvalidInputs,
                   badge: safetyMarginEnabled && !hasInvalidInputs
                       ? "× \(String(format: "%g", locale: locale, max(1.0, toDouble(safetyMarginStr))))"
                       : nil)
            // The floor (40 bar / 600 psi) is already baked into result.mg_L by calcMinimumGas.
            // When Safety Margin is on the displayed MG is floor × multiplier, which is no longer
            // equal to the floor itself, so showing "Minimum is 40 bar" would be misleading.
            if !hasInvalidInputs && result.mgWasFloored && !safetyMarginEnabled {
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
                   primaryValue: displayVol(adjustedGp_L),  primaryUnit: volUnitLabel,
                   secondaryValue: displayPres(adjustedGp_bar), secondaryUnit: presUnitLabel,
                   color: adjustedGp_L >= 0 ? .green : .red, isValid: !hasInvalidInputs)
            if !hasInvalidInputs && safetyMarginEnabled && adjustedGp_L < 0 {
                Text("Usable Gas insufficient at this stress factor")
                    .font(.caption)
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
        isValid: Bool = true,
        badge: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isValid ? color : .secondary)
                if let badge {
                    Text(verbatim: badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.12), in: Capsule())
                }
            }
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
