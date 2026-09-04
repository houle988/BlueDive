import SwiftUI
import CloudKit
import UniformTypeIdentifiers

struct ICloudSettingsView: View {
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    @AppStorage(BlueDiveApp.iCloudSyncEnabledKey) private var iCloudSyncEnabled = true
    #if os(iOS)
    @State private var showSyncLogExporter = false
    @State private var syncLogDocument: ExportableFileDocument?
    @State private var syncLogFileName: String = ""
    @State private var isPreparingSyncLog = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: syncMonitor.ckAccountStatusIcon)
                                .foregroundStyle(syncMonitor.ckAccountStatusColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud account")
                                    .font(.subheadline)
                                Text(verbatim: syncMonitor.ckAccountStatusLabel)
                                    .font(.caption)
                                    .foregroundStyle(syncMonitor.ckAccountStatusColor)
                            }
                            Spacer()
                            if !syncMonitor.ckAccountStatusFetched {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $iCloudSyncEnabled) {
                            Label("iCloud sync", systemImage: "arrow.triangle.2.circlepath.icloud.fill")
                        }
                        .tint(.cyan)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Sync dive data across your devices. Changes take effect after restarting the app.")
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

                if iCloudSyncEnabled {
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            #if os(iOS)
                            Button {
                                guard !isPreparingSyncLog else { return }
                                isPreparingSyncLog = true
                                Task {
                                    let log = await syncMonitor.exportLog()
                                    let df = DateFormatter()
                                    df.dateFormat = "yyyy-MM-dd"
                                    df.timeZone = TimeZone.current
                                    syncLogDocument = ExportableFileDocument(data: Data(log.utf8))
                                    syncLogFileName = "bluedive-sync-log-\(df.string(from: Date())).txt"
                                    showSyncLogExporter = true
                                    isPreparingSyncLog = false
                                }
                            } label: {
                                HStack {
                                    Label("Export Sync Log", systemImage: "square.and.arrow.up")
                                    Spacer()
                                    if isPreparingSyncLog {
                                        ProgressView().scaleEffect(0.7)
                                    }
                                }
                            }
                            #else
                            HStack {
                                Label("Export Sync Log", systemImage: "square.and.arrow.up")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            #endif
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                        Text("Last 15 minutes of sync activity.")
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
                }

                if syncMonitor.ckAccountStatusFetched && syncMonitor.ckAccountStatus != .available && iCloudSyncEnabled {
                    VStack(spacing: 12) {
                        Label {
                            Text("iCloud sync is enabled but no iCloud account is available. Data will be stored locally until you sign in.")
                                .foregroundStyle(.orange)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
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
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(Text(verbatim: NSLocalizedString("iCloud", bundle: .forAppLanguage(), value: "iCloud", comment: "")))
        #if os(iOS)
        .fileExporter(
            isPresented: $showSyncLogExporter,
            document: syncLogDocument,
            contentType: .plainText,
            defaultFilename: syncLogFileName
        ) { _ in
            syncLogDocument = nil
        }
        #endif
    }
}
