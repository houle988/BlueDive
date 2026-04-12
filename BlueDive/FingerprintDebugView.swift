import SwiftUI
import SwiftData

// MARK: - DEBUG ONLY — remove before release

struct FingerprintDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [DeviceFingerprint]

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    Text("No DeviceFingerprint records in database.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        FingerprintDebugRow(record: record)
                    }
                }
            }
            .navigationTitle("DEBUG — Fingerprints")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct FingerprintDebugRow: View {
    @Bindable var record: DeviceFingerprint
    @State private var hexInput: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.computerName.isEmpty ? "Unknown device" : record.computerName)
                .font(.headline)
            Text("Serial: \(record.serial)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Updated: \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Fingerprint hex", text: $hexInput)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button("Save") {
                    guard let data = Data(debugHex: hexInput), !data.isEmpty else {
                        errorMessage = "Invalid hex"
                        return
                    }
                    record.fingerprintData = data
                    record.updatedAt = Date()
                    errorMessage = nil
                }
                .buttonStyle(.bordered)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            hexInput = record.fingerprintData.debugHexString
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
