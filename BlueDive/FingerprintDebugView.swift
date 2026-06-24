import SwiftUI
import SwiftData

// MARK: - DEBUG ONLY — remove before release

struct FingerprintDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [DeviceFingerprint]
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    heroHeader
                        .opacity(appeared ? 1.0 : 0.0)
                        .scaleEffect(appeared ? 1.0 : 0.95)

                    VStack(spacing: 20) {
                        if records.isEmpty {
                            emptyState
                        } else {
                            devicesSection
                        }
                    }
                    .opacity(appeared ? 1.0 : 0.0)
                    .offset(y: appeared ? 0 : 15)
                    .padding(.bottom, 40)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            }
            .background(
                LinearGradient(
                    colors: [Color.platformBackground, Color.blue.opacity(0.05), Color.platformBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.cyan.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)

                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 120, height: 120)

                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 20)

            VStack(spacing: 6) {
                Text("Sync Fingerprints")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Group {
                    if records.isEmpty {
                        Text("No devices registered")
                    } else if records.count == 1 {
                        Text("1 device registered")
                    } else {
                        Text("\(records.count) devices registered")
                    }
                }
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.blue)
            }
            .padding(.top, 16)
        }
        .padding(.bottom, 30)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Devices", icon: "barcode.viewfinder", color: .blue)

            VStack(spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.opacity(0.35))

                VStack(spacing: 6) {
                    Text("No fingerprints stored")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Fingerprints are saved automatically after the first successful sync with a dive computer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(32)
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

    // MARK: - Devices Section

    private var devicesSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Devices", icon: "barcode.viewfinder", color: .blue)

            VStack(spacing: 12) {
                ForEach(records) { record in
                    FingerprintDebugRow(record: record)
                }
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
}

// MARK: - Row

private struct FingerprintDebugRow: View {
    @Bindable var record: DeviceFingerprint
    @State private var hexInput: String = ""
    @State private var errorMessage: String?
    @State private var saveSuccess = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapseHeader

            if isExpanded {
                Divider().padding(.horizontal)
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .onAppear { hexInput = record.fingerprintData.debugHexString }
    }

    // MARK: Collapse header

    private var collapseHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "memorychip")
                        .font(.body)
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Group {
                        if record.computerName.isEmpty {
                            Text("Unknown Device")
                        } else {
                            Text(verbatim: record.computerName)
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Group {
                            if record.serial.isEmpty {
                                Text("No serial")
                            } else {
                                Text(verbatim: record.serial)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if !record.familyID.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text(record.familyID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Expanded detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            metadataRow
            fingerprintDisplay
            editSection
        }
        .padding(.vertical, 12)
    }

    private var metadataRow: some View {
        HStack(spacing: 20) {
            metaCell(label: "Updated", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))

            if record.modelID != 0 {
                metaCell(label: "Model ID", value: String(format: "0x%02X", record.modelID), monospaced: true)
            }

            Spacer()
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func metaCell(label: LocalizedStringKey, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            } else {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var fingerprintDisplay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fingerprint", systemImage: "lock.doc.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(record.fingerprintData.isEmpty ? "—" : record.fingerprintData.debugHexString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(record.fingerprintData.isEmpty ? Color.secondary : Color.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.07))
            )
            .padding(.horizontal)
        }
    }

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Override (hex)", systemImage: "pencil")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 8) {
                TextField("Enter hex bytes…", text: $hexInput)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button {
                    guard let data = Data(debugHex: hexInput), !data.isEmpty else {
                        errorMessage = NSLocalizedString("Invalid hex", bundle: .forAppLanguage(), comment: "")
                        saveSuccess = false
                        return
                    }
                    record.fingerprintData = data
                    record.updatedAt = Date()
                    errorMessage = nil
                    withAnimation { saveSuccess = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { saveSuccess = false }
                    }
                } label: {
                    Label(saveSuccess ? "Saved" : "Save", systemImage: saveSuccess ? "checkmark" : "square.and.arrow.down")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .tint(saveSuccess ? .green : .blue)
                .animation(.easeInOut(duration: 0.2), value: saveSuccess)
            }
            .padding(.horizontal)

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Hex helpers (file-private to avoid conflicts)

private extension Data {
    var debugHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(debugHex hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
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
