import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// How to delete BlueDive's logbook on the other devices before a restore (Restore backup →
/// "How to delete it on your other devices"). A device that keeps its old logbook can send it
/// back to iCloud and mix it with the restored one. Deleting the app deletes its data on iPhone
/// and iPad, but not on a Mac, where the database stays in BlueDive's App Group container.
struct RestoreOtherDevicesHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Quits BlueDive if it is running, then deletes the database folder of its App Group
    /// container (the store, its external files and iCloud sync's asset folder). SwiftData
    /// recreates the folder at the next launch. The quit is guarded by `is running`: a plain
    /// `quit app` launches an app that is not running in order to quit it, which would open
    /// the old logbook with iCloud sync for a moment. A blank line separates the two commands,
    /// whose second one wraps over several lines. Shown verbatim: it is a command, not text to
    /// translate.
    static let macCommand = """
        osascript -e 'if application "BlueDive" is running then tell application "BlueDive" to quit'

        rm -rf ~/Library/Group\\ Containers/group.app.bluedive.universal/Library/Application\\ Support
        """

    /// The folder holding the database folder, for the Finder steps.
    static let macFolder = "~/Library/Group Containers/group.app.bluedive.universal/Library"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Button names as in Apple's iPhone User Guide ("Remove or delete apps from iPhone").
                    Text("Touch and hold BlueDive on the Home Screen, tap Remove App, then tap Delete App and confirm. This deletes its data. Remove from Home Screen keeps the app and its data: do not use it.")
                } header: {
                    Text("iPhone and iPad")
                }

                Section {
                    Text("Moving BlueDive to the Trash does not delete its data. Quit BlueDive, then run these commands in Terminal:")
                    Text(verbatim: Self.macCommand)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        copyCommand()
                    } label: {
                        Group {
                            if copied {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy Commands", systemImage: "doc.on.doc")
                            }
                        }
                        .accentLabelOnMac()
                    }
                    .listRowButton()
                    Text("The first time, macOS asks whether Terminal may access data from other apps: click Allow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Mac")
                }

                Section {
                    // Menu and command names as in Apple's macOS User Guide ("Go directly to a
                    // specific folder on Mac", "Delete files and folders on Mac").
                    Text("In the Finder, choose Go → Go to Folder… and enter the folder below. Move its Application Support folder to the Trash, then empty the Trash.")
                    Text(verbatim: Self.macFolder)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Mac, Without Terminal")
                } footer: {
                    // Only accounts signed in to the same Apple Account sync with this iCloud data.
                    Text("Do this in every user account on that Mac that is signed in to the same Apple Account as this device.")
                }

                Section {
                    Text("Nothing to delete on the device where you restore: the restore replaces its logbook.")
                    Text("Install BlueDive again on the other devices only once the restored logbook has finished uploading to iCloud: they then download it.")
                } footer: {
                    Text("A device that keeps its old logbook can send it back to iCloud and mix it with the restored one.")
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle("Other Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copyCommand() {
        #if canImport(UIKit)
        UIPasteboard.general.string = Self.macCommand
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.macCommand, forType: .string)
        #endif
        copied = true
    }
}
