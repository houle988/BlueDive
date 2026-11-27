import SwiftUI
import SwiftData

// MARK: - Sync Fingerprints (Settings → Bluetooth Import)

/// Every stored sync-fingerprint record, duplicates included. Tapping one opens Edit Dive
/// Computer, the sheet Known Dive Computers uses, so both edit with the same rules.
struct FingerprintDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var records: [DeviceFingerprint]
    @State private var appeared = false
    /// The record whose Edit Dive Computer sheet is shown.
    @State private var deviceToEdit: KnownDeviceSnapshot?

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
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .sheet(item: $deviceToEdit) { device in
                EditKnownDeviceSheet(device: device)
                    .standardSheetPresentation()
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
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)

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
                    FingerprintDebugRow(record: record) {
                        deviceToEdit = KnownDeviceSnapshot(record)
                    }
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
    let record: DeviceFingerprint
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                DiveComputerIconView(name: record.iconName, isSelected: false)

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
                            .accessibilityHidden(true)
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

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
    }
}
