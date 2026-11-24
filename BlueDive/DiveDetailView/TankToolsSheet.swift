import SwiftUI

/// Gas tab → Tanks → Tank Tools: moves a tank to another position, or swaps the pressure
/// readings of two tanks (e.g. a transmitter's readings the import put on the wrong tank).
/// Each action is confirmed, then applied to the dive and committed to the store at once (saved
/// like every other edit); the sheet stays open with the tanks as they now are, so a second
/// action uses the current numbers.
struct TankToolsSheet: View {
    @Bindable var dive: Dive
    /// The Gas tab's selected tank: the pickers start on it, and it follows a move.
    @Binding var selectedTankIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store

    @State private var moveTank: Int
    @State private var movePosition: Int
    @State private var swapTank: Int
    @State private var swapOther: Int
    /// Off: only the tank's details move; the readings and gas switches stay at their positions
    /// (for gases the import put on the wrong tanks).
    @State private var movesSamples = true
    @State private var showMoveConfirmation = false
    @State private var showSwapConfirmation = false

    init(dive: Dive, selectedTankIndex: Binding<Int>) {
        self.dive = dive
        _selectedTankIndex = selectedTankIndex
        let count = dive.tanks.count
        let selected = min(max(selectedTankIndex.wrappedValue, 0), max(count - 1, 0))
        _moveTank = State(initialValue: selected)
        _movePosition = State(initialValue: selected)
        _swapTank = State(initialValue: selected)
        _swapOther = State(initialValue: selected == 0 ? min(1, max(count - 1, 0)) : 0)
    }

    var body: some View {
        let tanks = dive.tanks
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    moveSection(tanks)
                    swapSection(tanks)
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Tank Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .alert("Move Tank?", isPresented: $showMoveConfirmation) {
                Button("Move") { applyMove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: moveMessage(tanks))
            }
            .alert("Swap Pressure Readings?", isPresented: $showSwapConfirmation) {
                Button("Swap") { applySwap() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: swapMessage(tanks))
            }
            // Another device can change the tanks while the sheet is open.
            .onChange(of: tanks.count) { _, count in
                guard count > 1 else { dismiss(); return }
                moveTank = min(moveTank, count - 1)
                movePosition = min(movePosition, count - 1)
                swapTank = min(swapTank, count - 1)
                swapOther = min(swapOther, count - 1)
            }
        }
    }

    // MARK: - Sections

    private func moveSection(_ tanks: [TankData]) -> some View {
        Section {
            tankPicker("Tank", selection: $moveTank, tanks: tanks)
            Picker("New Position", selection: $movePosition) {
                ForEach(tanks.indices, id: \.self) { position in
                    Text(verbatim: "\(position + 1)").tag(position)
                }
            }
            Toggle("Move All Tank Data", isOn: $movesSamples)
                .fullWidthSwitch()
            Button("Move Tank") { showMoveConfirmation = true }
                .disabled(moveTank == movePosition || !isValid(moveTank, tanks) || !isValid(movePosition, tanks))
                .listRowButton()
        } header: {
            Text("Move Tank")
        } footer: {
            if movesSamples {
                Text("The tank moves with all its data: details, pressure readings and gas switches.")
            } else {
                Text("Only the tank's details move (gas, volume, start and end pressures…); the pressure readings and gas switches stay at their positions.")
            }
        }
    }

    private func swapSection(_ tanks: [TankData]) -> some View {
        Section {
            tankPicker("Tank", selection: $swapTank, tanks: tanks)
            tankPicker("With", selection: $swapOther, tanks: tanks)
            Button("Swap Readings") { showSwapConfirmation = true }
                .disabled(swapTank == swapOther || !isValid(swapTank, tanks) || !isValid(swapOther, tanks))
                .listRowButton()
        } header: {
            Text("Swap Pressure Readings")
        } footer: {
            Text("Only the pressure readings and the start and end pressures are exchanged; each tank keeps its gas.")
        }
    }

    private func tankPicker(_ title: LocalizedStringKey, selection: Binding<Int>, tanks: [TankData]) -> some View {
        Picker(title, selection: selection) {
            ForEach(tanks.indices, id: \.self) { index in
                Text(verbatim: tanks[index].pickerLabel(index: index)).tag(index)
            }
        }
    }

    private func isValid(_ index: Int, _ tanks: [TankData]) -> Bool {
        tanks.indices.contains(index)
    }

    // MARK: - Confirmation messages

    private func moveMessage(_ tanks: [TankData]) -> String {
        guard isValid(moveTank, tanks) else { return "" }
        let format = movesSamples
            ? NSLocalizedString("Move %@ to position %lld with all its data?",
                                bundle: Bundle.forAppLanguage(),
                                value: "Move %@ to position %lld with all its data?",
                                comment: "Tank Tools: move confirmation. %@ is a tank (e.g. Tank 1 — Nitrox 32%), %lld its new position.")
            : NSLocalizedString("Move %@ to position %lld? Its pressure readings and gas switches stay at their positions.",
                                bundle: Bundle.forAppLanguage(),
                                value: "Move %@ to position %lld? Its pressure readings and gas switches stay at their positions.",
                                comment: "Tank Tools: move confirmation, readings not moved. %@ is a tank (e.g. Tank 1 — Nitrox 32%), %lld its new position.")
        return String(format: format, tanks[moveTank].pickerLabel(index: moveTank), movePosition + 1)
    }

    private func swapMessage(_ tanks: [TankData]) -> String {
        guard isValid(swapTank, tanks), isValid(swapOther, tanks) else { return "" }
        return String(format: NSLocalizedString("Swap the pressure readings of %@ and %@? Their start and end pressures are exchanged too; each tank keeps its gas.",
                                                bundle: Bundle.forAppLanguage(),
                                                value: "Swap the pressure readings of %@ and %@? Their start and end pressures are exchanged too; each tank keeps its gas.",
                                                comment: "Tank Tools: swap confirmation. Each %@ is a tank (e.g. Tank 1 — Nitrox 32%)."),
                      tanks[swapTank].pickerLabel(index: swapTank), tanks[swapOther].pickerLabel(index: swapOther))
    }

    // MARK: - Actions

    /// Moves the tank, with its readings and gas switches unless `movesSamples` is off; the Gas
    /// tab's selection follows its tank.
    private func applyMove() {
        let from = moveTank, to = movePosition
        guard dive.moveTank(from: from, to: to, movesSamples: movesSamples) else { return }
        store.commit(dive, affects: .rowFields)
        selectedTankIndex = TankSlotMove.newIndex(selectedTankIndex, from: from, to: to)
        // The pickers keep pointing at the same tanks, at their new numbers.
        moveTank = to
        swapTank = TankSlotMove.newIndex(swapTank, from: from, to: to)
        swapOther = TankSlotMove.newIndex(swapOther, from: from, to: to)
    }

    /// Exchanges the two tanks' readings and start/end pressures; each keeps its gas.
    private func applySwap() {
        guard dive.swapTankReadings(swapTank, swapOther) else { return }
        store.commit(dive, affects: .rowFields)
    }
}

extension TankData {
    /// "Tank 2 — Nitrox 32%": the Gas tab's tank picker and Tank Tools label a tank this way.
    func pickerLabel(index: Int) -> String {
        let tankLabel = NSLocalizedString("Tank", bundle: Bundle.forAppLanguage(), value: "Tank", comment: "")
        return "\(tankLabel) \(index + 1) — \(gasDisplayName())"
    }
}
