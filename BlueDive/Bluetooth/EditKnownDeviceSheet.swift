import SwiftUI
import SwiftData
import DiveComputerKit

// MARK: - Catalog lookups

extension DeviceFingerprint {
    /// The catalog model this record stands for: the model named like the record when it has
    /// the record's family and model number, else the only model with that family and number.
    /// Nil when several models share them and the name does not tell which (e.g. Shearwater Tern
    /// and Tern TX), and for a legacy record without a family.
    var catalogModel: ComputerModel? {
        if let named = DeviceCatalog.model(named: computerName),
           named.family == family, named.modelID == modelID {
            return named
        }
        guard let family else { return nil }
        let candidates = DeviceCatalog.supportedModels.filter { $0.family == family && $0.modelID == modelID }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Whether the record holds a family and model, so a download keeps them instead of seeding
    /// its auto-detected ones. A family this build does not know is kept, as before, unless its
    /// model number is 0.
    var hasStoredIdentity: Bool {
        guard !familyID.isEmpty else { return false }
        guard modelID == 0 else { return true }
        return family.map { Self.isModelSet(family: $0, modelID: 0) } ?? false
    }

    /// Whether `modelID` is a model of `family` rather than "not set". Model number 0 is a real
    /// model in some families (Suunto EON Steel, the Deep Six family…), so it means "not set"
    /// only where the catalog has no model 0 for the family. Used wherever a stored model decides
    /// how a computer is opened (download, DeviceStorage re-seed, scan fallback).
    static func isModelSet(family: DeviceFamily, modelID: UInt32) -> Bool {
        modelID != 0 || DeviceCatalog.model(family: family, modelID: 0) != nil
    }

    /// The name `DiveComputerIconView` picks the artwork from: the catalog model's name, so the
    /// icon follows the family and model; the stored name for a legacy record.
    var iconName: String {
        catalogModel?.name ?? computerName
    }
}

// MARK: - Fingerprint hex

extension Data {
    /// The bytes as lowercase hex ("1a2b3c4d"), as a sync fingerprint is shown and edited.
    var fingerprintHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes a hex string ("0a1b2c…"; spaces, tabs and line breaks allowed, e.g. hex pasted
    /// from a wrapped log). An empty string is an empty fingerprint; nil when the text is not an
    /// even number of hex digits. Shared by the Edit sheet, Sync Fingerprints and the
    /// fingerprint XML import.
    init?(fingerprintHex hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        // UInt8(_:radix:) accepts a leading "+"/"-", so require ASCII hex digits only
        // (Character.isHexDigit also accepts their full-width forms).
        guard cleaned.count % 2 == 0, cleaned.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

// MARK: - Edit Known Device Sheet

/// The values the Edit sheet shows, copied from the record when the user picks Edit. The sheet
/// never holds the record itself: an iCloud sync can delete it while the sheet is open, and
/// reading a deleted SwiftData object crashes (the sheet's view is re-created on every redraw of
/// the list, so even reading it in `init` is unsafe). Save fetches the live records again.
struct KnownDeviceSnapshot: Identifiable {
    let id: PersistentIdentifier
    let serial: String
    let computerName: String
    let family: DeviceFamily?
    let iconName: String
    let catalogModel: ComputerModel?
    let lastSynced: Date
    let fingerprint: Data

    init(_ device: DeviceFingerprint) {
        id = device.persistentModelID
        serial = device.serial
        computerName = device.computerName
        family = device.family
        iconName = device.iconName
        catalogModel = device.catalogModel
        lastSynced = device.updatedAt
        fingerprint = device.fingerprintData
    }
}

/// Edits a known dive computer (Bluetooth sheet → Known Dive Computers → swipe right → Edit):
/// its model and, under Advanced, its sync fingerprint. The name is not editable: it follows the
/// model, as a download with a model override does, so the name-based matching that finds a
/// known computer again (scan fallback, reassociation) keeps working.
struct EditKnownDeviceSheet: View {
    private let device: KnownDeviceSnapshot

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var selectedModel: ComputerModel?
    @State private var fingerprintText: String
    @State private var showsAdvanced = false
    @State private var showingModelPicker = false
    @State private var showingClearConfirmation = false
    @State private var showingSaveError = false

    init(device: KnownDeviceSnapshot) {
        self.device = device
        _selectedModel = State(initialValue: device.catalogModel)
        _fingerprintText = State(initialValue: device.fingerprint.fingerprintHexString)
    }

    // MARK: Derived state

    private var trimmedFingerprint: String {
        fingerprintText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The typed fingerprint: empty data for an empty field (clears it), nil when not valid hex.
    private var parsedFingerprint: Data? {
        trimmedFingerprint.isEmpty ? Data() : Data(fingerprintHex: trimmedFingerprint)
    }

    private var modelChanged: Bool {
        guard let selectedModel else { return false }
        return selectedModel.name != device.catalogModel?.name
    }

    private var fingerprintChanged: Bool {
        guard let parsedFingerprint else { return false }
        return parsedFingerprint != device.fingerprint
    }

    /// A new fingerprint whose length differs from the stored one: libdivecomputer may reject
    /// it, which makes the next sync download the whole history.
    private var showsLengthWarning: Bool {
        guard let parsedFingerprint, !parsedFingerprint.isEmpty, !device.fingerprint.isEmpty else { return false }
        return parsedFingerprint.count != device.fingerprint.count
    }

    private var canSave: Bool {
        parsedFingerprint != nil && (modelChanged || fingerprintChanged)
    }

    private var displayedName: String {
        modelChanged ? (selectedModel?.name ?? device.computerName) : device.computerName
    }

    private var displayedIconName: String {
        selectedModel?.name ?? device.iconName
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                computerSection
                modelSection
                advancedSection
            }
            .groupedFormStyleOnMac()
            .navigationTitle("Edit Dive Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(
                    detectedName: device.computerName,
                    currentOverride: selectedModel,
                    showsAutoDetect: false,
                    onSelect: { model in
                        if let model { selectedModel = model }
                    }
                )
                .standardSheetPresentation()
            }
            .alert("Clear Fingerprint?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) { apply() }
            } message: {
                Text("Without a fingerprint, the next sync re-downloads all dives from this computer and merges the ones already in your logbook.")
            }
            .alert("Changes Not Saved", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The changes to this dive computer could not be saved. Try again.")
            }
        }
    }

    // MARK: Sections

    private var computerSection: some View {
        Section {
            HStack(spacing: 12) {
                DiveComputerIconView(name: displayedIconName, isSelected: true)
                    // The name beside it is read; the artwork's asset name is not.
                    .accessibilityHidden(true)
                Text(verbatim: displayedName)
                    .font(.headline)
            }
            LabeledContent("Serial") {
                Text(verbatim: device.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                    .monospaced()
            }
            LabeledContent("Last Synced") {
                Text(device.lastSynced, format: .dateTime.day().month().year().hour().minute().locale(locale))
            }
        } header: {
            Text("Dive Computer")
        } footer: {
            Text("The name follows the model.")
        }
    }

    private var modelSection: some View {
        Section {
            Button {
                showingModelPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                        Text(verbatim: selectedModel?.name ?? device.computerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .listRowButton()

            if let family = selectedModel?.family ?? device.family {
                LabeledContent("Device Family") {
                    Text(verbatim: family.rawValue)
                        .monospaced()
                }
            }
        } footer: {
            Text("The model sets how BlueDive communicates with this dive computer. Change it only if the detected model is incorrect.")
        }
    }

    private var advancedSection: some View {
        Section {
            // A row button rather than a DisclosureGroup: in a Form only a DisclosureGroup's
            // label takes the tap, not the rest of its row.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .accentLabelOnMac()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .listRowButton()
            // Stays open while the text is not valid hex: Save is disabled then, and the
            // warning below is the only place that says why.
            .disabled(showsAdvanced && parsedFingerprint == nil)
            .accessibilityValue(showsAdvanced ? Text("Expanded") : Text("Collapsed"))

            if showsAdvanced {
                HStack(spacing: 8) {
                    formTextField("Fingerprint (hex)", text: $fingerprintText)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .platformKeyboardType(.asciiCapable)
                        .platformTextInputAutocapitalization(PlatformTextInputAutocapitalizationType.never)
                    if !fingerprintText.isEmpty {
                        Button {
                            fingerprintText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .clearButtonTapTarget()
                                .accessibilityLabel(Text("Clear"))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if parsedFingerprint == nil {
                    warningRow(Text("Enter the fingerprint as hexadecimal bytes (0–9, a–f), two digits per byte."))
                } else if showsLengthWarning {
                    warningRow(Text(verbatim: String(format: NSLocalizedString("The stored fingerprint has %1$@ bytes and this one has %2$@. If the dive computer rejects it, the next sync re-downloads all dives.", bundle: Bundle.forAppLanguage(), value: "The stored fingerprint has %1$@ bytes and this one has %2$@. If the dive computer rejects it, the next sync re-downloads all dives.", comment: "Edit Dive Computer → Advanced: warning when the typed sync fingerprint's length differs from the stored one. %1$@ is the stored length in bytes, %2$@ the typed length."),
                                                     Double(device.fingerprint.count).localizedString(decimals: 0),
                                                     Double(parsedFingerprint?.count ?? 0).localizedString(decimals: 0))))
                }
            }
        } footer: {
            Text("The fingerprint marks the newest dive already downloaded: the next sync downloads only the dives recorded after it. Leave it empty to download all dives at the next sync.")
        }
    }

    private func warningRow(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            text
                .foregroundStyle(.orange)
        }
        .font(.caption)
    }

    // MARK: Save

    private func save() {
        // Clearing the fingerprint makes the next sync a full download: confirm it first.
        if fingerprintChanged, parsedFingerprint?.isEmpty == true {
            showingClearConfirmation = true
        } else {
            apply()
        }
    }

    /// Saves the edit (see `KnownDeviceEdit` for what is written), then closes the sheet.
    private func apply() {
        guard let fingerprint = parsedFingerprint else { return }
        let newModel = modelChanged ? selectedModel : nil
        let newFingerprint = fingerprintChanged ? fingerprint : nil

        // Fetched again, so only live records are written: one deleted here or by another
        // device while the sheet was open is simply absent.
        let all = (try? modelContext.fetch(FetchDescriptor<DeviceFingerprint>())) ?? []
        let records = KnownDeviceEdit.records(matching: device, in: all)
        guard !records.isEmpty else {
            dismiss()
            return
        }
        let originals = KnownDeviceEdit.write(model: newModel, fingerprint: newFingerprint, to: records)
        do {
            try modelContext.save()
        } catch {
            // The records get their values back, so the edit is really not saved (the main
            // context autosaves: left changed, it would be stored later behind the alert), and
            // DeviceStorage is left as it was. The sheet stays open to try again.
            KnownDeviceEdit.restore(originals)
            DiveComputerLog.shared.log("[Known device] Could not save the edit of serial \(device.serial): \(error.localizedDescription)", level: .warning)
            showingSaveError = true
            return
        }

        // The next connection opens with the stored family and model, whichever path it takes
        // (a known-device tap re-seeds DeviceStorage from the record only when it connects by
        // the stored identifier).
        if let newModel, let serialKey = device.serial.normalizedComputerSerial(),
           let stored = DeviceStorage.shared.getAllStoredDevices() {
            let result = KnownDeviceEdit.storedDevices(stored, withSerial: serialKey, setTo: newModel)
            if result.updated > 0 { DeviceStorage.shared.updateStoredDevices(result.devices) }
            DiveComputerLog.shared.log("[Known device] Edited serial \(serialKey): model \(newModel.name) (\(newModel.family) \(newModel.modelID)), \(result.updated) DeviceStorage entr\(result.updated == 1 ? "y" : "ies") updated", level: .info)
        }
        if newFingerprint != nil {
            DiveComputerLog.shared.log("[Known device] Edited the fingerprint of serial \(device.serial) (\(fingerprint.count) bytes) on \(records.count) record(s)", level: .info)
        }
        dismiss()
    }
}

// MARK: - Edit rules

/// What Save in Edit Dive Computer writes, apart from the view so it can be tested.
enum KnownDeviceEdit {
    /// The records an edit applies to: every record of the computer's serial (an iCloud merge
    /// can leave duplicates under differently-cased serials, and an older one must not bring the
    /// old values back), or only the edited record for a placeholder serial ("0"…) shared by
    /// unrelated computers — the rule `deleteKnownDevice` uses.
    static func records(matching device: KnownDeviceSnapshot, in all: [DeviceFingerprint]) -> [DeviceFingerprint] {
        if let serialKey = device.serial.normalizedComputerSerial() {
            return all.filter { $0.serial.normalizedComputerSerial() == serialKey }
        }
        return all.filter { $0.persistentModelID == device.id }
    }

    /// A record's edited values before an edit, to put them back if it cannot be saved.
    struct OriginalValues {
        let record: DeviceFingerprint
        let computerName: String
        let familyID: String
        let modelID: UInt32
        let fingerprint: Data
    }

    /// Writes the changed values only (nil leaves a field as it is) and returns each record's
    /// values from before. The name follows the model, as a download with a model override does.
    /// `updatedAt` ("Last synced") is kept: an edit is not a sync.
    @discardableResult
    static func write(model: ComputerModel?, fingerprint: Data?, to records: [DeviceFingerprint]) -> [OriginalValues] {
        records.map { record in
            let original = OriginalValues(record: record, computerName: record.computerName, familyID: record.familyID,
                                          modelID: record.modelID, fingerprint: record.fingerprintData)
            if let model {
                record.computerName = model.name
                record.family = model.family
                record.modelID = model.modelID
            }
            if let fingerprint {
                record.fingerprintData = fingerprint
            }
            return original
        }
    }

    /// Puts back the values `write` replaced (the raw family string too, so a family this build
    /// does not know survives).
    static func restore(_ originals: [OriginalValues]) {
        for original in originals {
            original.record.computerName = original.computerName
            original.record.familyID = original.familyID
            original.record.modelID = original.modelID
            original.record.fingerprintData = original.fingerprint
        }
    }

    /// The DeviceStorage list with the entries of `serialKey` (a normalized, non-placeholder
    /// serial) set to `model`. The stored name stays the advertised one (it keys the Pelagic
    /// access codes) and `lastConnected` is kept (it picks the identifier a known-device tap
    /// uses); the order is unchanged. Entries without a serial are left to the re-seed at the
    /// next known-device tap.
    static func storedDevices(_ stored: [StoredDevice], withSerial serialKey: String,
                              setTo model: ComputerModel) -> (devices: [StoredDevice], updated: Int) {
        var updated = 0
        let devices = stored.map { entry -> StoredDevice in
            guard entry.serial?.normalizedComputerSerial() == serialKey else { return entry }
            updated += 1
            return StoredDevice(uuid: entry.uuid, name: entry.name, family: model.family,
                                model: model.modelID, lastConnected: entry.lastConnected,
                                serial: entry.serial)
        }
        return (devices, updated)
    }
}
