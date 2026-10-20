import SwiftUI
import SwiftData

// MARK: - Fingerprint Import Request

/// A fingerprint file to import: its contents, or the error that occurred while reading it.
/// Equality is by ID so SwiftUI onChange comparisons are O(1).
struct FingerprintImportRequest: Equatable {
    let id = UUID()
    let fileName: String
    let content: Result<Data, Error>

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// Imports a fingerprint file (FingerprintXMLExporter format) when `request` is set: shows the
    /// import preview (new and already stored devices), adds the new devices as DeviceFingerprint
    /// records and reports the result. A device already stored is skipped, never changed. Used by
    /// Settings → Bluetooth Import and by the dive list when a fingerprint file is opened from
    /// Files, Finder, AirDrop or Mail.
    func fingerprintImportFlow(_ request: Binding<FingerprintImportRequest?>) -> some View {
        modifier(FingerprintImportFlow(request: request))
    }
}

// MARK: - Fingerprint Import Flow

private struct FingerprintImportFlow: ViewModifier {
    @Binding var request: FingerprintImportRequest?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var pendingDevices: [FingerprintXMLParser.ParsedDevice] = []
    @State private var previewNew: [ImportPreviewItem] = []
    @State private var previewDuplicates: [ImportPreviewItem] = []
    @State private var previewFileName = ""
    @State private var showPreview = false
    @State private var successMessage = ""
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var showError = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, newRequest in
                guard let newRequest else { return }
                request = nil
                handle(newRequest)
            }
            .sheet(isPresented: $showPreview) {
                ImportPreviewSheet(
                    icon: "barcode.viewfinder",
                    iconColor: .blue,
                    newItems: previewNew,
                    duplicateItems: previewDuplicates,
                    fileName: previewFileName,
                    onImport: { commitImport() },
                    onCancel: { showPreview = false }
                )
                .standardSheetPresentation()
            }
            .onChange(of: showPreview) { _, isShown in
                if !isShown {
                    pendingDevices = []
                    previewNew = []
                    previewDuplicates = []
                    previewFileName = ""
                }
            }
            .alert("Import Successful", isPresented: $showSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: successMessage)
            }
            .alert("Import Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: errorMessage ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the import error alert when no specific error is available."))
            }
    }

    // MARK: - Parsing and classification

    private func handle(_ request: FingerprintImportRequest) {
        let data: Data
        switch request.content {
        case .success(let fileData):
            data = fileData
        case .failure(let error):
            reportError(error.localizedDescription)
            return
        }

        let devices: [FingerprintXMLParser.ParsedDevice]
        switch FingerprintXMLParser().parse(data: data) {
        case .success(let parsed) where parsed.isEmpty:
            reportError(NSLocalizedString("No devices found in the selected file.", bundle: .forAppLanguage(), value: "No devices found in the selected file.", comment: "Error when an imported fingerprint file contains no dive computers."))
            return
        case .success(let parsed):
            devices = parsed
        case .failure(.invalidFile):
            reportError(NSLocalizedString("The selected file is not a BlueDive fingerprint export.", bundle: .forAppLanguage(), value: "The selected file is not a BlueDive fingerprint export.", comment: "Error when the imported file is not a fingerprint XML export."))
            return
        case .failure(.invalidValue):
            reportError(NSLocalizedString("The file contains an invalid fingerprint or model ID. Nothing was imported.", bundle: .forAppLanguage(), value: "The file contains an invalid fingerprint or model ID. Nothing was imported.", comment: "Error when a fingerprint file has a malformed value."))
            return
        }

        let stored: [DeviceFingerprint]
        do {
            stored = try modelContext.fetch(FetchDescriptor<DeviceFingerprint>())
        } catch {
            reportError(error.localizedDescription)
            return
        }

        // A device is new only when no stored record — and no device listed earlier in the
        // same file — is the same dive computer. Stored records are never modified.
        var newDevices: [FingerprintXMLParser.ParsedDevice] = []
        var newItems: [ImportPreviewItem] = []
        var duplicateItems: [ImportPreviewItem] = []
        for device in devices {
            let isStored = stored.contains {
                Self.isSameComputer(serial: $0.serial, name: $0.computerName, familyID: $0.familyID, modelID: $0.modelID, as: device)
            }
            let isRepeated = newDevices.contains {
                Self.isSameComputer(serial: $0.serial, name: $0.computerName, familyID: $0.familyID, modelID: $0.modelID, as: device)
            }
            if isStored || isRepeated {
                duplicateItems.append(previewItem(for: device))
            } else {
                newDevices.append(device)
                newItems.append(previewItem(for: device))
            }
        }

        guard !newDevices.isEmpty else {
            reportError(NSLocalizedString(
                "All records in the file are already imported.",
                bundle: Bundle.forAppLanguage(),
                value: "All records in the file are already imported.",
                comment: "Message when all records in the import file already exist in the database."
            ))
            return
        }
        pendingDevices = newDevices
        previewNew = newItems
        previewDuplicates = duplicateItems
        previewFileName = request.fileName
        showPreview = true
    }

    /// Whether a stored or listed device is the same dive computer as an imported one.
    ///
    /// A genuine serial identifies the computer (compared trimmed and case-insensitively, like
    /// `deleteKnownDevice`). A sentinel or empty serial is shared by unrelated computers, so it only
    /// matches the same serial, name, family and model.
    private static func isSameComputer(serial: String, name: String, familyID: String, modelID: UInt32,
                                       as device: FingerprintXMLParser.ParsedDevice) -> Bool {
        if let deviceSerial = device.serial.normalizedComputerSerial() {
            return serial.normalizedComputerSerial() == deviceSerial
        }
        return serial == device.serial
            && name == device.computerName
            && familyID == device.familyID
            && modelID == device.modelID
    }

    private func previewItem(for device: FingerprintXMLParser.ParsedDevice) -> ImportPreviewItem {
        let name = device.computerName.isEmpty
            ? NSLocalizedString("Unknown Device", bundle: .forAppLanguage(), value: "Unknown Device", comment: "")
            : device.computerName
        let serial = device.serial.isEmpty
            ? NSLocalizedString("No serial", bundle: .forAppLanguage(), value: "No serial", comment: "")
            : device.serial
        var detail = [serial]
        if let updatedAt = device.updatedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.locale = locale
            detail.append(formatter.string(from: updatedAt))
        }
        return ImportPreviewItem(name: name, detail: detail.joined(separator: " • "))
    }

    private func reportError(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Writing

    /// Adds the new devices as DeviceFingerprint records, keeping the file's values as they are.
    ///
    /// Only SwiftData is written: before each sync `syncFingerprintFromDatabase` re-seeds LibDCSwift's
    /// UserDefaults cache from these records, so an imported fingerprint takes effect at the next sync.
    private func commitImport() {
        let devices = pendingDevices
        guard !devices.isEmpty else { return }
        showPreview = false
        for device in devices {
            let record = DeviceFingerprint(serial: device.serial, computerName: device.computerName, fingerprintData: device.fingerprintData)
            record.familyID = device.familyID
            record.modelID = device.modelID
            record.updatedAt = device.updatedAt ?? Date()
            modelContext.insert(record)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            reportAfterSheetDismissal { reportError(error.localizedDescription) }
            return
        }
        successMessage = String(
            format: NSLocalizedString("Fingerprints imported: %@", bundle: .forAppLanguage(), value: "Fingerprints imported: %@", comment: "Number of dive computer fingerprints imported from a file."),
            Double(devices.count).localizedString(decimals: 0)
        )
        reportAfterSheetDismissal { showSuccess = true }
    }

    /// Presents an alert once the preview sheet has finished closing, as DocumentsView does after
    /// its import preview: an alert requested while the sheet is still dismissing is not shown.
    private func reportAfterSheetDismissal(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            present()
        }
    }
}
