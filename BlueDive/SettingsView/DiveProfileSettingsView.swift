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
                        .fullWidthSwitch()
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

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $prefs.showPhotosOnProfile) {
                            // Pink to match the Photos section of the dive detail view.
                            Label {
                                Text("Show photos on the profile")
                            } icon: {
                                Image(systemName: "photo")
                                    .foregroundStyle(.pink)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, each photo taken during the dive appears on the profile chart at the moment it was taken, at the depth recorded by your dive computer. Tap a thumbnail to open the photo.")
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
                        Toggle(isOn: $prefs.showSamplesTab) {
                            // Teal to match the Samples tab's colour in the dive detail view.
                            Label {
                                Text("Show Samples tab")
                            } icon: {
                                Image(systemName: "waveform.path.ecg")
                                    .foregroundStyle(.teal)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, the dive details show a Samples tab with the raw data recorded by your dive computer at each sample point. Long dives can take a moment to display in full.")
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

                #if os(macOS)
                // The dive list's profile preview exists only on macOS (also toggled from
                // View → Show Profile Preview).
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $prefs.showDiveListProfilePreview) {
                            Label {
                                Text("Show profile preview in dive list")
                            } icon: {
                                Image(systemName: "chart.xyaxis.line")
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, the profile chart of the selected dive is shown above the dive list. Click a dive to select it; double-click it or press Return to open it. When off, a click opens the dive.")
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
                #endif
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Dive Profile", bundle: .forAppLanguage(), value: "Dive Profile", comment: "")))
    }
}
