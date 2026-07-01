import SwiftUI
import CoreBluetooth
import LibDCSwift

// MARK: - CBPeripheral + Identifiable

extension CBPeripheral: @retroactive Identifiable {
    public var id: UUID { identifier }
}

// MARK: - Shared Helpers

// Converts an exact model name (from DeviceConfiguration.supportedModels) to its asset name.
// "Heinrichs Weikamp OSTC 2" → "DeviceIcon_HeinrichsWeikamp_OSTC_2"
// "Deepblu Cosmiq+"          → "DeviceIcon_Deepblu_Cosmiq"
private func modelLevelAssetName(_ name: String) -> String {
    let sanitized = name
        .replacingOccurrences(of: "Heinrichs Weikamp", with: "HeinrichsWeikamp")
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "_")
    return "DeviceIcon_\(sanitized)"
}

private func diveComputerAssetName(forName name: String?) -> String? {
    guard let name = name else { return nil }

    // Exact model name → per-model asset (used when model is known/resolved)
    if DeviceConfiguration.supportedModels.contains(where: { $0.name == name }) {
        return modelLevelAssetName(name)
    }

    // BLE advertisement name → brand-level fallback
    // Order matters: "oceanic" must precede "oceans"; "deepblu" must precede any future "deep" prefix.
    let lowercased = name.lowercased()
    if lowercased.contains("shearwater")                                         { return "DeviceIcon_Shearwater" }
    if lowercased.contains("suunto")                                             { return "DeviceIcon_Suunto" }
    if lowercased.contains("scubapro")                                           { return "DeviceIcon_Scubapro" }
    if lowercased.contains("mares")                                              { return "DeviceIcon_Mares" }
    if lowercased.contains("oceanic")                                            { return "DeviceIcon_Oceanic" }
    if lowercased.contains("aqualung")                                           { return "DeviceIcon_Aqualung" }
    if lowercased.contains("sherwood")                                           { return "DeviceIcon_Sherwood" }
    if lowercased.contains("heinrichs") || lowercased.contains("weikamp") || lowercased.contains("ostc") {
        return "DeviceIcon_HeinrichsWeikamp"
    }
    if lowercased.contains("cressi")                                             { return "DeviceIcon_Cressi" }
    if lowercased.contains("divesoft")                                           { return "DeviceIcon_Divesoft" }
    if lowercased.contains("deep six")                                           { return "DeviceIcon_DeepSix" }
    if lowercased.contains("deepblu")                                            { return "DeviceIcon_Deepblu" }
    if lowercased.contains("mclean")                                             { return "DeviceIcon_McLean" }
    if lowercased.contains("oceans")                                             { return "DeviceIcon_Oceans" }
    if lowercased.contains("seac")                                               { return "DeviceIcon_Seac" }
    if lowercased.contains("halcyon")                                            { return "DeviceIcon_Halcyon" }
    if lowercased.contains("ratio")                                              { return "DeviceIcon_Ratio" }
    if lowercased.contains("divesystem") || lowercased.contains("idive")        { return "DeviceIcon_DiveSystem" }
    if lowercased.contains("apeks")                                              { return "DeviceIcon_Apeks" }
    return nil
}

private func diveComputerFallbackIcon(forName name: String?) -> String {
    let lowercased = name?.lowercased() ?? ""
    if lowercased.contains("garmin") { return "applewatch.watchface" }
    return "gauge.with.dots.needle.bottom.50percent"
}

// MARK: - Device Icon View

private struct DiveComputerIconView: View {
    let name: String?
    let isSelected: Bool

    var body: some View {
        if let assetName = diveComputerAssetName(forName: name) {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: diveComputerFallbackIcon(forName: name))
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let peripheral: CBPeripheral
    let isSelected: Bool
    let isConnecting: Bool
    let modelOverride: DeviceConfiguration.ComputerModel?
    let onTap: () -> Void
    let onChangeModel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Device icon
            DiveComputerIconView(name: effectiveModelName, isSelected: isSelected)

            // Device information
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if modelOverride != nil {
                        Text(autoDetectedName)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let serial = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString)?.serial {
                        Text(verbatim: String(format: NSLocalizedString("Serial: %@", bundle: Bundle.forAppLanguage(), comment: "A subheading displaying the serial number of a device. The argument is the serial number of the device."), serial.uppercased()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(peripheral.identifier.uuidString.prefix(8) + "...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Change model button
            Button(action: onChangeModel) {
                Image(systemName: modelOverride != nil ? "pencil.circle.fill" : "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(modelOverride != nil ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)

            // Connection indicator
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contextMenu {
            Button {
                onChangeModel()
            } label: {
                Label("Change Model", systemImage: "pencil")
            }
        }
    }

    private var deviceDisplayName: String {
        if let override = modelOverride {
            return override.name
        }
        // Check DeviceStorage for a previously saved correct model
        if let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            return modelInfo.name
        }
        guard let name = peripheral.name else {
            return "Unknown Device"
        }
        return DeviceConfiguration.getDeviceDisplayName(from: name)
    }

    private var autoDetectedName: String {
        let detected = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        return "Detected: \(detected)"
    }

    // Resolves the best model name for icon selection: override > stored model > resolved BLE display name
    private var effectiveModelName: String? {
        if let override = modelOverride { return override.name }
        if let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            return modelInfo.name
        }
        guard let name = peripheral.name else { return nil }
        return DeviceConfiguration.getDeviceDisplayName(from: name)
    }
}

// MARK: - Known Device Row

struct KnownDeviceRow: View {
    let computerName: String
    let serial: String
    let lastSynced: Date
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                DiveComputerIconView(name: computerName, isSelected: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(computerName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(verbatim: String(format: NSLocalizedString("Serial: %@", bundle: Bundle.forAppLanguage(), comment: "A subheading displaying the serial number of a device. The argument is the serial number of the device."), serial.uppercased()))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Last synced \(lastSynced, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Picker Sheet

struct ModelPickerSheet: View {
    let detectedName: String
    let currentOverride: DeviceConfiguration.ComputerModel?
    let onSelect: (DeviceConfiguration.ComputerModel?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var groupedModels: [(brand: String, models: [DeviceConfiguration.ComputerModel])] {
        let models = DeviceConfiguration.supportedModels.filter { model in
            searchText.isEmpty || model.name.localizedCaseInsensitiveContains(searchText)
        }

        let grouped = Dictionary(grouping: models) { model -> String in
            // Extract brand from model name (first word, or first two for "Deep Six", "Heinrichs Weikamp")
            let parts = model.name.split(separator: " ")
            if parts.count >= 2 {
                let twoWord = "\(parts[0]) \(parts[1])"
                if ["Deep Six", "Heinrichs Weikamp"].contains(twoWord) {
                    return twoWord
                }
            }
            return String(parts.first ?? "Other")
        }

        return grouped
            .sorted { $0.key < $1.key }
            .map { (brand: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-detect")
                                    .foregroundStyle(.primary)
                                Text(detectedName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currentOverride == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                } header: {
                    Text("Detected Model")
                } footer: {
                    Text("If the detected model is incorrect, select the correct one below.")
                }

                ForEach(groupedModels, id: \.brand) { group in
                    Section(group.brand) {
                        ForEach(group.models) { model in
                            Button {
                                onSelect(model)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if currentOverride == model {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search models")
            .navigationTitle("Select Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
