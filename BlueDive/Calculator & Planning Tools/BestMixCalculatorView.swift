import SwiftUI

// MARK: - Calculation

struct BestMixResult {
    let ata: Double
    let bestMixPct: Double  // (po2 / ata) * 100, unclamped
}

func calcBestMix(po2: Double, depthMetres: Double, isSeawater: Bool = true) -> BestMixResult {
    let ata = max(1.0, depthMetres / (isSeawater ? 10.0 : 10.3) + 1.0)
    return BestMixResult(ata: ata, bestMixPct: (po2 / ata) * 100.0)
}

// MARK: - View

struct BestMixCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastAcknowledgedCalculatorWarningVersion") private var lastAcknowledgedCalculatorWarningVersion = ""
    @State private var showCalculatorWarning = false

    private enum UnitMode: CaseIterable, Identifiable {
        case metric, imperial
        var id: Self { self }
    }

    @State private var unitMode: UnitMode = .metric
    @State private var isSeawater = true
    @State private var po2Str = "1.4"
    @State private var depthStr = "30"
    @State private var showInfo = false
    @FocusState private var isAnyFieldFocused: Bool

    private func toDouble(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var po2: Double { max(0.01, toDouble(po2Str)) }

    private var result: BestMixResult {
        let depthM = unitMode == .imperial ? toDouble(depthStr) / 3.28084 : toDouble(depthStr)
        return calcBestMix(po2: po2, depthMetres: max(0, depthM), isSeawater: isSeawater)
    }

    // Air (21%) at depth exceeds the PO₂ limit — this depth is beyond nitrox range.
    private var isAirTooRich: Bool { result.bestMixPct < 21.0 }
    // Even pure O₂ stays below the PO₂ limit — any mix is safe.
    private var isAnyMixSafe: Bool { result.bestMixPct > 100.0 }

    private var resultColor: Color {
        if isAirTooRich { return .red }
        if isAnyMixSafe { return .green }
        if result.bestMixPct > 40.0 { return .orange }
        return .green
    }

    var body: some View {
        NavigationStack {
            Form {
                unitModeSection
                inputSection
                resultsSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Best Mix")
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
                depthStr = newMode == .metric ? "30" : "100"
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

    private var inputSection: some View {
        Section(header: Text("Parameters")) {
            numberRow("Max PO₂ (ATA)", text: $po2Str)
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
            mixResultRow
            if isAirTooRich {
                Label("Air (21%) exceeds the PO₂ limit at this depth.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if isAnyMixSafe {
                Label("Pure O₂ stays below the PO₂ limit at this depth — any mix is safe.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Round down to the nearest available mix.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("All calculations provided by this tool are estimates. It is the diver's sole responsibility to verify and validate all results before any dive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private var mixResultRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Best Nitrox Mix")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(resultColor)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if isAirTooRich {
                            Text(verbatim: "< 21 %")
                        } else if isAnyMixSafe {
                            Text(verbatim: "≤ 100 %")
                        } else {
                            Text(verbatim: String(format: "%.1f %%", result.bestMixPct))
                        }
                    }
                    .font(.title2.monospacedDigit().bold())
                    .foregroundStyle(resultColor)
                    Text(verbatim: "O₂")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: String(format: "%.2f ATA", result.ata))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func numberRow(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
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

    // MARK: - Info Sheet

    private var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Best Mix", systemImage: "bubbles.and.sparkles")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("What is Best Mix?")
                            .font(.title3.weight(.semibold))
                        Text("Best Mix is the highest percentage of oxygen in a Nitrox blend that keeps the partial pressure of oxygen (ppO₂) at or below your target limit at a given depth. It maximises the no-decompression limit and reduces nitrogen narcosis while staying within your ppO₂ ceiling.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Formula", systemImage: "function")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(verbatim: "Best Mix (%) = (ppO₂ ÷ ATA) × 100")
                            .font(.system(.body, design: .monospaced))
                        Text("Seawater: depth (m) ÷ 10 + 1 | Freshwater: depth (m) ÷ 10.3 + 1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("PO₂ Limits", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        po2LimitRow("1.4 ATA", note: "Working / recreational limit (NOAA)")
                        po2LimitRow("1.6 ATA", note: "Maximum / decompression stop limit")
                        Text("Always use the limit appropriate to your training and dive plan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Rounding", systemImage: "arrow.down.to.line")
                            .font(.headline)
                            .foregroundStyle(.cyan)
                        Text("Always round the Best Mix percentage down to the nearest available blend. Rounding up would increase the ppO₂ beyond your target at depth.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Safety", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Nitrox diving requires specific training and equipment analysis. Always dive within your training and certification limits.")
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
                    Text("How Best Mix Works")
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

    @ViewBuilder
    private func po2LimitRow(_ limit: String, note: LocalizedStringKey) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: limit)
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 70, alignment: .leading)
                .monospacedDigit()
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
