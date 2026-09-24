import SwiftUI

struct DiveProfileSettingsView: View {
    // Bound to the shared UserPreferences rather than @AppStorage: UserPreferences.init()
    // reads the key once at launch, so an @AppStorage write would leave the in-memory prefs
    // stale and the chart would keep rendering the old state until the next launch.
    @State private var prefs = UserPreferences.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $prefs.hideClearedDecoStops) {
                            // Orange to match the diamond mark's colour on the dive chart
                            // (UnifiedDiveChartFixed.swift's decoMarks PointMark).
                            Label {
                                Text("Hide early-cleared decompression stops")
                            } icon: {
                                Image(systemName: "diamond")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, the orange diamond markers are hidden for mandatory decompression stops that your dive computer cleared earlier than expected, before you reached that depth. This applies to the dive profile chart and to the PDF logbook.")
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
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Dive Profile", bundle: .forAppLanguage(), value: "Dive Profile", comment: "")))
    }
}
