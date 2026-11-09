import SwiftUI

struct DiveProfileSettingsView: View {
    // Bound to the shared UserPreferences rather than @AppStorage: UserPreferences.init()
    // reads the key once at launch, so an @AppStorage write would leave the in-memory prefs
    // stale and the chart would keep rendering the old state until the next launch.
    @State private var prefs = UserPreferences.shared
    /// The Settings sheet's close action on macOS, for the Dive Detail Tabs page pushed from here.
    @Environment(\.sheetDismiss) private var sheetDismiss

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
                        Toggle(isOn: $prefs.searchDiveNotes) {
                            Label {
                                Text("Search dive notes")
                            } icon: {
                                Image(systemName: "note.text")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, the dive list search also looks in each dive's notes, ignoring capitals and accents. With a large logbook, search results can take a moment longer to appear.")
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
                        Toggle(isOn: $prefs.formatNotesAsMarkdown) {
                            Label {
                                Text("Format notes as Markdown")
                            } icon: {
                                Image(systemName: "textformat")
                                    .foregroundStyle(.purple)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, the dive details and the PDF logbook show notes with Markdown formatting: headings, bold and italic text, lists, quotes, code blocks and tables. Notes are still saved and exported exactly as typed.")
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
                        // Green and location.circle, as the matching switch in Edit Site Details.
                        Label("Include GPS coordinates when copying a site", systemImage: "location.circle")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                        Picker("Include GPS coordinates when copying a site", selection: $prefs.copySiteGPSMode) {
                            ForEach(SwitchStartMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .fullWidthSegmentedPicker()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Sets whether Include GPS Coordinates (Entry & Exit) is on when Edit Site Details opens. Last Used keeps the choice you made the last time. When on, Copy from Existing Site also copies the chosen site's entry and exit GPS coordinates and altitude; when off, the dive keeps its own.")
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

                diveDetailTabsCard
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Dive Profile", bundle: .forAppLanguage(), value: "Dive Profile", comment: "")))
    }

    /// Opens Dive Detail Tabs: the order of the dive detail tabs and which ones are shown
    /// (including the Samples tab, whose switch used to be on this page).
    private var diveDetailTabsCard: some View {
        VStack(spacing: 12) {
            NavigationLink {
                TabLayoutSettingsView()
                    .closeSheetButtonOnMac(sheetDismiss)
            } label: {
                HStack {
                    Label {
                        Text("Dive Detail Tabs")
                    } icon: {
                        Image(systemName: "rectangle.split.3x1")
                            .foregroundStyle(.teal)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding()
                .contentShape(Rectangle())
            }
            .borderlessButton()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

            Text("Choose the order of the dive detail tabs and which ones are shown, including the Samples tab with the raw data recorded by your dive computer.")
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
}
