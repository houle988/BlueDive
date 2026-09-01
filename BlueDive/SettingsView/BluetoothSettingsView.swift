import SwiftUI

struct BluetoothSettingsView: View {
    @AppStorage("filterUnusedTanks") private var filterUnusedTanks = false
    @State private var showFingerprintDebug = false

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
            }
            .padding(.vertical)
        }
        .navigationTitle(Text(verbatim: NSLocalizedString("Bluetooth Import", bundle: .forAppLanguage(), value: "Bluetooth Import", comment: "")))
        .sheet(isPresented: $showFingerprintDebug) {
            FingerprintDebugView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
