import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct BluetoothSettingsView: View {
    @AppStorage("filterUnusedTanks") private var filterUnusedTanks = false
    @AppStorage("bleDiagnosticLoggingEnabled") private var bleDiagnosticLoggingEnabled = false
    @State private var showFingerprintDebug = false
    @State private var bleLogCount: Int = 0
    #if os(iOS)
    @State private var showLogExporter = false
    @State private var logExportDocument: ExportableFileDocument?
    @State private var logExportFileName: String = ""
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $filterUnusedTanks) {
                            Label("Filter unused tanks", systemImage: "cylinder.split.1x2")
                        }
                        .tint(.cyan)
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

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showFingerprintDebug = true
                        } label: {
                            HStack {
                                Label("Sync Fingerprints", systemImage: "barcode.viewfinder")
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("View and edit dive computer sync fingerprints.")
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
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
