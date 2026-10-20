import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct BluetoothSettingsView: View {
    @AppStorage("filterUnusedTanks") private var filterUnusedTanks = false
    @AppStorage("bleDiagnosticLoggingEnabled") private var bleDiagnosticLoggingEnabled = false
    @Query(sort: \DeviceFingerprint.updatedAt, order: .reverse) private var fingerprintRecords: [DeviceFingerprint]
    @State private var showFingerprintDebug = false
    @State private var bleLogCount: Int = 0
    #if os(iOS)
    @State private var showLogExporter = false
    @State private var logExportDocument: ExportableFileDocument?
    @State private var logExportFileName: String = ""
    @State private var showFingerprintExporter = false
    @State private var fingerprintExportDocument: ExportableFileDocument?
    @State private var fingerprintExportFileName: String = ""
    #endif

    // Fingerprint XML import / export
    @State private var showFingerprintImporter = false
    @State private var fingerprintImportRequest: FingerprintImportRequest?
    @State private var fingerprintExportError: String?
    @State private var showFingerprintExportError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $filterUnusedTanks) {
                            Label("Filter unused tanks", systemImage: "cylinder.split.1x2")
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Some dive computers (Aqualung, Oceanic, Sherwood, HW OSTC, Cressi, DeepSix, Deepblu, Oceans, McLean) report all configured gas slots even when only one was used. When enabled, phantom tanks are filtered out. Disable if you carry configured-but-unused tanks (e.g. pony bottle, bailout).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)

                fingerprintCard

                diagnosticLoggingCard
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Bluetooth Import", bundle: .forAppLanguage(), value: "Bluetooth Import", comment: "")))
        .onAppear {
            bleLogCount = BLEDiagnosticSession.shared.logFileCount
            // Apply the 24h auto-off: if the window has elapsed, this clears the flag,
            // which the toggle's display binding (reading bleDiagnosticLoggingEnabled)
            // then reflects as "off".
            _ = BLEDiagnosticSession.resolveLoggingEnabled()
        }
        .sheet(isPresented: $showFingerprintDebug) {
            FingerprintDebugView()
                .standardSheetPresentation()
        }
        #if os(iOS)
        .fileExporter(
            isPresented: $showLogExporter,
            document: logExportDocument,
            contentType: .plainText,
            defaultFilename: logExportFileName
        ) { _ in
            logExportDocument = nil
        }
        #endif
    }

    /// Saves the diagnostic log via the app's standard export flow (fileExporter on
    /// iOS / "Designed for iPad" on Mac, NSSavePanel on the macOS target), matching
    /// XML export and database backup. The log is saved as plain text (.txt).
    private func saveDiagnosticLog(_ url: URL) {
        guard let payload = BLEDiagnosticSession.shared.exportPayload(for: url) else { return }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Save Diagnostic Log", bundle: .forAppLanguage(), value: "Save Diagnostic Log", comment: "")
        panel.nameFieldStringValue = payload.filename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? payload.data.write(to: destination)
        }
        #else
        logExportDocument = ExportableFileDocument(data: payload.data)
        logExportFileName = payload.filename
        showLogExporter = true
        #endif
    }

    // MARK: - Sync Fingerprints

    private var fingerprintCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                fingerprintRowButton(showsChevron: true) {
                    showFingerprintDebug = true
                } label: {
                    Label("Sync Fingerprints", systemImage: "barcode.viewfinder")
                }

                Divider().padding(.horizontal)

                fingerprintRowButton {
                    exportFingerprintsToXML()
                } label: {
                    Label("Export Fingerprints", systemImage: "square.and.arrow.up")
                }
                .disabled(fingerprintRecords.isEmpty)

                Divider().padding(.horizontal)

                fingerprintRowButton {
                    showFingerprintImporter = true
                } label: {
                    Label("Import Fingerprints", systemImage: "square.and.arrow.down")
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

            Text("View and edit dive computer sync fingerprints.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Text("Export the fingerprints to a file, or import a file to add the dive computers that are not stored yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        // Attached to the card, not the page, so they don't collide with the page's
        // diagnostic-log fileExporter (one file presenter per view).
        .fileImporter(
            isPresented: $showFingerprintImporter,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false
        ) { result in
            handleFingerprintImportResult(result)
        }
        #if os(iOS)
        .fileExporter(
            isPresented: $showFingerprintExporter,
            document: fingerprintExportDocument,
            contentType: .blueDiveXML,
            defaultFilename: fingerprintExportFileName
        ) { _ in
            fingerprintExportDocument = nil
        }
        #endif
        .fingerprintImportFlow($fingerprintImportRequest)
        .alert("Export Error", isPresented: $showFingerprintExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: fingerprintExportError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the export error alert when no specific error is available."))
        }
    }

    /// A full-width row button of the Sync Fingerprints card. `showsChevron` marks a row that
    /// opens another screen, as in Online Services; action rows (export, import) have none.
    private func fingerprintRowButton<L: View>(showsChevron: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            // The padding sits inside the button so the whole row responds, not only the
            // drawn label (a borderless Button only responds where something is drawn).
            .padding()
            .contentShape(Rectangle())
        }
        .borderlessButton()
    }

    private static let fingerprintExportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func exportFingerprintsToXML() {
        let xml = FingerprintXMLExporter.generateXML(for: fingerprintRecords)
        guard let data = xml.data(using: .utf8) else { return }
        let datePart = Self.fingerprintExportDateFormatter.string(from: Date())
        let fileName = "BlueDive_Fingerprints_\(datePart).bluedive"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.blueDiveXML]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                Task { @MainActor in
                    fingerprintExportError = error.localizedDescription
                    showFingerprintExportError = true
                }
            }
        }
        #else
        fingerprintExportDocument = ExportableFileDocument(data: data)
        fingerprintExportFileName = fileName
        showFingerprintExporter = true
        #endif
    }

    /// Reads the picked file and hands it to the shared fingerprint import flow.
    private func handleFingerprintImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            fingerprintImportRequest = FingerprintImportRequest(fileName: url.lastPathComponent, content: Result { try Data(contentsOf: url) })
        case .failure(let error):
            fingerprintImportRequest = FingerprintImportRequest(fileName: "", content: .failure(error))
        }
    }

    // MARK: - BLE Diagnostic Logging

    private var diagnosticLoggingCard: some View {
        VStack(spacing: 12) {
            ModernToggleRow(
                isOn: Binding(
                    get: { bleDiagnosticLoggingEnabled },
                    set: { BLEDiagnosticSession.setLoggingEnabled($0) }
                ),
                icon: "antenna.radiowaves.left.and.right",
                iconColor: .purple,
                title: "BLE Diagnostic Logging",
                subtitle: "Records full BLE packet traces for troubleshooting sync errors"
            )

            if bleDiagnosticLoggingEnabled {
                Text("Enable before connecting to a device. Save the log from the error screen after a sync failure.")
                    .font(.caption)
                    .foregroundStyle(.purple.opacity(0.8))
                    .padding(.horizontal)

                // "24 hours" mirrors BLEDiagnosticSession.autoOffInterval — update both together.
                Text("Turns off automatically 24 hours after you enable it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let logURL = BLEDiagnosticSession.shared.mostRecentLogURL {
                Button {
                    saveDiagnosticLog(logURL)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "square.and.arrow.down")
                                .font(.body)
                                .foregroundStyle(.purple)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Save Diagnostic Log")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(verbatim: logURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)
            }

            if bleLogCount > 0 {
                Divider()

                Button(role: .destructive) {
                    BLEDiagnosticSession.shared.clearAllLogs()
                    bleLogCount = 0
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "trash.fill")
                                .font(.body)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clear Diagnostic Logs")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.red)
                            Text("Clear all BLE log files from Documents")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
}
