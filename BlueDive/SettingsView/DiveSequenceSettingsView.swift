import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct DiveSequenceSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @AppStorage("autoSequenceEnabled") private var autoSequenceEnabled = false
    @State private var showingRecalculateSurfaceAlert = false
    @State private var showingRecalculateSurfaceDone = false
    @State private var showingRenumberDivesAlert = false
    @State private var showingRenumberDivesDone = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showingRecalculateSurfaceAlert = true
                        } label: {
                            HStack {
                                Label("Recalculate surface intervals", systemImage: "arrow.clockwise.circle.fill")
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showingRenumberDivesAlert = true
                        } label: {
                            HStack {
                                Label("Renumber dives", systemImage: "number.circle.fill")
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Dives without a diver name are not affected.")
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
                        Toggle(isOn: $autoSequenceEnabled) {
                            Label("Auto-update dive numbers", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(.cyan)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("When on, dive numbers and surface intervals are recalculated automatically when you add, delete, move, or change the date of a dive. Turn this off to update them only with the buttons above.")
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
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showDatabaseInFinder()
                        } label: {
                            HStack {
                                Label("Show database in Finder", systemImage: "folder.fill")
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Open the folder containing your database files.")
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
        .navigationTitle(Text(verbatim: NSLocalizedString("Dive Sequence", bundle: .forAppLanguage(), value: "Dive Sequence", comment: "")))
        .alert("Recalculate Surface Intervals?", isPresented: $showingRecalculateSurfaceAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Recalculate") {
                recalculateSurfaceIntervals()
                showingRecalculateSurfaceDone = true
            }
        } message: {
            Text("This will update the surface interval for all dives based on each diver's previous dive. Dives without a diver name will not be affected.")
        }
        .alert("Done", isPresented: $showingRecalculateSurfaceDone) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Surface intervals have been recalculated.")
        }
        .alert("Renumber Dives?", isPresented: $showingRenumberDivesAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Renumber") {
                renumberDives()
                showingRenumberDivesDone = true
            }
        } message: {
            Text("This will assign each diver's dives a sequential number in date order, starting at 1. Dives without a diver name will not be affected.")
        }
        .alert("Done", isPresented: $showingRenumberDivesDone) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Dives have been renumbered.")
        }
    }

    private func recalculateSurfaceIntervals() {
        Dive.recalculateSurfaceIntervals(in: modelContext)
    }

    private func renumberDives() {
        Dive.renumberDives(in: modelContext)
        store.commitListRebuild()
    }

    #if os(macOS)
    private func showDatabaseInFinder() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appSupport.path)
    }
    #endif
}
