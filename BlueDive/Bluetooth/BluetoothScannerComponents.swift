import SwiftUI
import CoreBluetooth
import LibDCSwift

// MARK: - CBPeripheral + Identifiable

extension CBPeripheral: @retroactive Identifiable {
    public var id: UUID { identifier }
}

// MARK: - Shared Helpers

private func diveComputerIcon(forName name: String?) -> String {
    let lowercased = name?.lowercased() ?? ""
    if lowercased.contains("shearwater") { return "gauge.with.dots.needle.bottom.50percent.badge.plus" }
    if lowercased.contains("suunto")     { return "dial.medium" }
    if lowercased.contains("garmin")     { return "applewatch.watchface" }
    if lowercased.contains("mares")      { return "gauge.with.needle" }
    if lowercased.contains("scubapro")   { return "gauge.with.dots.needle.33percent" }
    if lowercased.contains("oceanic") || lowercased.contains("pelagic") { return "water.waves" }
    return "gauge.with.dots.needle.bottom.50percent"
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
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 44, height: 44)

                Image(systemName: deviceIcon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

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

    private var deviceIcon: String { diveComputerIcon(forName: peripheral.name) }
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
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: deviceIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }

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

    private var deviceIcon: String { diveComputerIcon(forName: computerName) }
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
