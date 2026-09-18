import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Views

extension BluetoothScannerView {

    // MARK: - Sync Status Header

    @ViewBuilder
    var syncStatusHeader: some View {
        VStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(syncStateColor.opacity(0.15))
                    .frame(width: 80, height: 80)

                Group {
                    switch syncState {
                    case .scanning:
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.variableColor.iterative.reversing)
                    case .connecting:
                        Image(systemName: "link")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.pulse)
                    case .downloading:
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.bounce.byLayer)
                    case .importing:
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.bounce)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    case .idle:
                        Image(systemName: "antenna.radiowaves.left.and.right.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityHidden(true)

            // Status text
            VStack(spacing: 4) {
                Text(syncStateTitle)
                    .font(.headline)

                Text(syncStateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Progress bar
            if case .downloading(let current, let total) = syncState {
                VStack(spacing: 4) {
                    if total > 0 {
                        ProgressView(value: Double(current), total: Double(total))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if diveCountDuringDownload > 1 {
                        let downloadedCount = diveCountDuringDownload - 1
                        Text(verbatim: downloadedCount == 1
                        ? NSLocalizedString("1 dive downloaded", bundle: Bundle.forAppLanguage(), comment: "A text label displayed when exactly one dive has been downloaded.")
                        : String(format: NSLocalizedString("%lld dives downloaded", bundle: Bundle.forAppLanguage(), comment: "A text label displaying the number of dives that have been successfully downloaded."), downloadedCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: NSLocalizedString("Downloading...", bundle: Bundle.forAppLanguage(), comment: "A placeholder text displayed when downloading dives."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if case .importing = syncState {
                ProgressView(value: importProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    // MARK: - Main Content

    @ViewBuilder
    var mainContent: some View {
        switch syncState {
        case .completed(let imported, let merged, let skipped):
            completedView(imported: imported, merged: merged, skipped: skipped)
        case .error(let message):
            errorView(message: message)
        case .idle where !isSearching:
            knownDevicesView
        case .scanning, .idle:
            deviceListView
        case .connecting, .downloading, .importing:
            Spacer()
        }
    }

    // MARK: - Known Devices View

    @ViewBuilder
    private var knownDevicesView: some View {
        let diverNames = diverNameBySerial
        Form {
            if !knownDevices.isEmpty {
                Section {
                    // Identified by persistentModelID, not serial: sentinel/empty serials are
                    // deliberately exempt from dedupedKnownDevices' de-duplication, so two
                    // different physical computers can both report e.g. "0" and would otherwise
                    // produce two rows sharing one SwiftUI id (undefined list diffing — a swipe
                    // or tap could land on the wrong row).
                    ForEach(dedupedKnownDevices, id: \.persistentModelID) { device in
                        KnownDeviceRow(
                            computerName: device.computerName,
                            serial: device.serial,
                            lastSynced: device.updatedAt,
                            diverName: diverNames[device.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
                            onTap: { connectToKnownDevice(device) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deviceToDelete = device
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deviceToDelete = device
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Known Dive Computers")
                } footer: {
                    Text("Tap a device to scan and connect automatically.")
                }
            }

            Section {
                Toggle("Download All Dives", isOn: $downloadAllDives)
            } footer: {
                Text("Re-downloads all dives and merges matched ones. Tap ⓘ at the top right for details.")
            }

            // The date cutoff is only offered alongside Download All Dives — the one known-device
            // case that re-downloads the whole history. A normal incremental sync is already
            // limited by the fingerprint watermark, so a cutoff would have nothing to do.
            if downloadAllDives {
                Section {
                    Toggle("Limit Import by Date", isOn: $importCutoffEnabled.animation(.easeInOut(duration: 0.2)))

                    if importCutoffEnabled {
                        DatePicker(
                            "Import Dives On or After",
                            selection: importCutoffDateBinding,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .adaptiveDatePickerStyle()
                    }
                } footer: {
                    Text("Dives recorded before this date are still transferred from the dive computer, then discarded — they are neither re-imported nor updated. This does not make the sync faster, and applies to this sync only.")
                }
            }

            Section {
                Toggle("Sync device clock", isOn: $syncDeviceClock)
            } footer: {
                Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
            }

            Section {
                Button {
                    downloadAllDives = false
                    // Disarmed here explicitly rather than relying on the onChange below: tapping
                    // this button flips mainContent over to deviceListView in the same update, so
                    // SwiftUI tears this view down before an onChange on downloadAllDives would be
                    // delivered, and an armed cutoff would otherwise survive into the search flow
                    // unseen. Unconditional is correct — this screen's cutoff Section only exists
                    // while downloadAllDives is true, so either it was already false (the Section
                    // was never visible, nothing could have been armed from here) or it is true and
                    // about to become false, which is exactly the case needing the disarm.
                    disarmImportCutoff()
                    isSearching = true
                    startScanning()
                } label: {
                    Label(
                        "Search for Devices",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
            } footer: {
                if knownDevices.isEmpty {
                    Text("No previously synced dive computers found. Tap to search for nearby Bluetooth devices.")
                } else {
                    Text("Search for new or previously unpaired dive computers.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            prepareImportCutoffDefault()
        }
        // The cutoff section only exists while Download All Dives is on, so turning that off has
        // to disarm the cutoff too — otherwise an invisible importCutoffEnabled would still apply
        // to a later sync the user never armed it for. This observer covers only the *manual*
        // toggle-off, where this view stays on screen to receive the change; the "Search for
        // Devices" button above does its own explicit disarm because it navigates away in the same
        // update and this handler cannot be relied on to fire for it. It deliberately does not live
        // in connectToKnownDevice: that function's scan-fallback path leaves downloadAllDives
        // untouched precisely so a cutoff already armed for the in-flight known-device sync
        // survives the switch to the scanning screen.
        .onChange(of: downloadAllDives) { _, isOn in
            if !isOn { disarmImportCutoff() }
        }
    }

    // MARK: - Device List View

    @ViewBuilder
    private var deviceListView: some View {
        // The Form is the outer structure in BOTH the empty and populated states, and the
        // "searching, nothing found yet" ContentUnavailableView lives INSIDE the devices Section
        // rather than replacing the whole Form. An earlier version swapped the entire Form out
        // while the peripheral list was empty, which also took the cutoff Section with it — so a
        // user who armed "Limit Import by Date" and then cancelled the import confirmation while
        // still scanning had no way to disarm it again until a device happened to be discovered.
        Form {
            Section {
                if bleManager.discoveredPeripherals.isEmpty {
                    ContentUnavailableView {
                        Label("Searching...", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Make sure your dive computer is turned on and in Bluetooth transfer mode.")
                    }
                } else {
                    ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        DeviceRow(
                            peripheral: peripheral,
                            isSelected: selectedDevice?.identifier == peripheral.identifier,
                            isConnecting: isConnecting(to: peripheral),
                            modelOverride: modelOverrides[peripheral.identifier.uuidString],
                            onTap: { handleDeviceTap(peripheral) },
                            onChangeModel: {
                                peripheralForModelPicker = peripheral
                            }
                        )
                        .disabled(syncState.isActive && syncState != .scanning)
                    }
                }
            } header: {
                HStack {
                    Text("Available Devices")
                    Spacer()
                    Text("\(bleManager.discoveredPeripherals.count)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                // Dropped entirely while the list is empty: there is nothing to select and no
                // info button to tap, so the instruction would describe controls that aren't on
                // screen. The ContentUnavailableView above already carries the empty-state copy.
                if !bleManager.discoveredPeripherals.isEmpty {
                    Text("Select your dive computer to download new dives. Tap the info button to change the detected model if incorrect.")
                }
            }

            Section {
                Toggle("Download All Dives", isOn: $downloadAllDives)
                    .disabled(true)
            } footer: {
                // The toggle is always disabled here, but the value it displays is NOT always
                // false: connectToKnownDevice's scan fallback (and returning here after cancelling
                // the "Import Dives" alert) can both reach this screen with downloadAllDives still
                // true, carried over from knownDevicesView. The footer has to describe whichever
                // state is actually on screen rather than assume the toggle is inert.
                if downloadAllDives {
                    Text("Download All Dives is on for this sync, carried over from the known-devices screen — it re-downloads the full history and merges matched dives. Turn it off from the main screen.")
                } else {
                    Text("Download All Dives is only available for known dive computers. Sync this device once first, then use it from the main screen.")
                }
            }

            // Always shown, never gated on cachedTargetFingerprint or on whether any peripheral
            // has been discovered yet. This screen can start a sync for ANY row the user taps —
            // including an unrelated device tapped while a connectToKnownDevice scan fallback is
            // still searching for its own target in the background — and the cutoff, if armed,
            // applies to whichever device the tap actually connects to. Hiding this control during
            // that fallback used to let the cutoff silently apply to a device the user never saw it
            // armed for; it must stay visible so the user can always see, and disarm, what is about
            // to be applied.
            Section {
                Toggle("Limit Import by Date", isOn: $importCutoffEnabled.animation(.easeInOut(duration: 0.2)))
                    .disabled(syncState.isActive && syncState != .scanning)

                if importCutoffEnabled {
                    DatePicker(
                        "Import Dives On or After",
                        selection: importCutoffDateBinding,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .adaptiveDatePickerStyle()
                    .disabled(syncState.isActive && syncState != .scanning)
                }
            } footer: {
                // This screen can start a sync for a known, already-synced device too — via
                // connectToKnownDevice's scan fallback, which leaves downloadAllDives exactly as
                // the user set it on the known-devices screen. That makes the two branches below
                // cover genuinely different guarantees:
                //
                // • downloadAllDives == true — NOT the plain scan screen (that path forces
                //   downloadAllDives false and disables its toggle above). Only reachable via a
                //   known device's scan fallback, or by returning here after cancelling the
                //   "Import Dives" alert with Download All Dives still on. Both are full-history
                //   downloads, so the cutoff always applies and the footer must NOT claim
                //   otherwise. It reuses knownDevicesView's exact wording rather than
                //   re-describing the same effect differently.
                // • downloadAllDives == false — the plain scan screen (never-synced device, cutoff
                //   always applies) OR the fallback for a known device whose fingerprint restored,
                //   where the download is incremental and the cutoff has no effect at all. Because
                //   this branch covers both, it has to keep the "already synced" caveat: it is the
                //   only hedge the user gets for the case where the control is armed but silently
                //   inert.
                if downloadAllDives {
                    Text("Dives recorded before this date are still transferred from the dive computer, then discarded — they are neither re-imported nor updated. This does not make the sync faster, and applies to this sync only.")
                } else {
                    // "the most recent dive in your logbook" rather than "your most recent logged
                    // dive": a never-synced computer has no Gear record tying it to a diver, so on
                    // this screen the default can only be narrowed as far as the active diver
                    // filter — it cannot promise to be the reader's own dive.
                    Text("Dives recorded before this date are still transferred from the dive computer, then discarded instead of being added to your logbook — this does not make the sync faster. The date defaults to the most recent dive in your logbook, or one year ago if your logbook is empty, and applies to this sync only. Has no effect on a device you've already synced.")
                }
            }

            Section {
                Toggle("Sync device clock", isOn: $syncDeviceClock)
                    .disabled(syncState.isActive && syncState != .scanning)
            } footer: {
                Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            prepareImportCutoffDefault()
        }
        .sheet(item: $peripheralForModelPicker) { peripheral in
            ModelPickerSheet(
                detectedName: DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown"),
                currentOverride: modelOverrides[peripheral.identifier.uuidString],
                onSelect: { model in
                    if let model = model {
                        modelOverrides[peripheral.identifier.uuidString] = model
                    } else {
                        modelOverrides.removeValue(forKey: peripheral.identifier.uuidString)
                    }
                }
            )
            .presentationSizing(.page)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Completed View

    @ViewBuilder
    private func completedView(imported: Int, merged: Int, skipped: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                if imported + merged > 0 {
                    Text("Sync Complete")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else if cutoffFilteredCount > 0 {
                    Text("Older Dives Skipped")
                        .font(.title2)
                        .fontWeight(.semibold)
                } else {
                    Text("No New Dives")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                if imported > 0 {
                    // %@ + localizedString, not %lld + a raw Int: a dive count can reach four
                    // digits and must carry the OS region's thousands separator per the Number
                    // Formatting rule. Shares its key with syncStateSubtitle's cutoff-aware branch
                    // so the same count never renders two different ways on one screen.
                    Text(verbatim: imported == 1
                        ? NSLocalizedString("1 dive imported", bundle: .forAppLanguage(), comment: "A label displayed when exactly one dive has been imported.")
                        : String(format: NSLocalizedString("%@ dives imported", bundle: .forAppLanguage(), value: "%@ dives imported", comment: "A label in the Bluetooth sync results showing how many dives were imported. %@ is the locale-formatted dive count."), Double(imported).localizedString(decimals: 0)))
                        .foregroundStyle(.secondary)
                }

                if merged > 0 {
                    // %@ + localizedString, not %lld + a raw Int — same rule as the imported
                    // count above, and shares its key with syncStateSubtitle's merged branch so
                    // the same count never renders two different ways on one screen.
                    Text(verbatim: merged == 1
                        ? NSLocalizedString("1 dive updated", bundle: .forAppLanguage(), comment: "A label displayed when exactly one dive has been updated.")
                        : String(format: NSLocalizedString("%@ dives updated", bundle: .forAppLanguage(), value: "%@ dives updated", comment: "A label indicating dives have been updated. %@ is the locale-formatted dive count."), Double(merged).localizedString(decimals: 0)))
                        .foregroundStyle(.secondary)
                }

                if skipped > 0 {
                    Text(verbatim: skipped == 1
                        ? NSLocalizedString("1 dive already in logbook", bundle: .forAppLanguage(), comment: "A footnote when exactly one dive was skipped because it was already in the logbook.")
                        : String(format: NSLocalizedString("%@ dives already in logbook", bundle: .forAppLanguage(), value: "%@ dives already in logbook", comment: "A footnote showing how many dives were skipped because they were already in the logbook. %@ is the locale-formatted dive count."), Double(skipped).localizedString(decimals: 0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if cutoffFilteredCount > 0 {
                    Text(verbatim: cutoffFilteredCount == 1
                        ? NSLocalizedString("1 older dive not imported", bundle: .forAppLanguage(), value: "1 older dive not imported", comment: "A footnote in the Bluetooth sync results when exactly one downloaded dive was discarded because it was recorded before the user's import cutoff date.")
                        : String(format: NSLocalizedString("%@ older dives not imported", bundle: .forAppLanguage(), value: "%@ older dives not imported", comment: "A footnote in the Bluetooth sync results showing how many downloaded dives were discarded because they were recorded before the user's import cutoff date. %@ is the locale-formatted dive count."), Double(cutoffFilteredCount).localizedString(decimals: 0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let cutoffAppliedDate {
                        Text(verbatim: String(format: NSLocalizedString("They were downloaded from your dive computer, then discarded because they were recorded before %@.", bundle: .forAppLanguage(), value: "They were downloaded from your dive computer, then discarded because they were recorded before %@.", comment: "Explanation in the Bluetooth sync results for dives discarded by the import cutoff date. %@ is the cutoff date."), cutoffAppliedDate.formatted(.dateTime.locale(locale).day().month(.wide).year())))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                // Surfaces the same partial-sync warning the pre-import confirmation alert shows —
                // needed here specifically because that alert is skipped when the cutoff filters
                // out every downloaded dive. `skipped == 0` is the gate that keeps this from ALSO
                // re-showing the warning for the pre-existing, unrelated case where every
                // downloaded dive turned out to be an exact duplicate: that case always reaches
                // completion through showingImportConfirmation, which already displayed the
                // warning once. `cutoffFilteredCount > 0` cannot exclude it on its own, because a
                // sync can be both partly duplicate and partly cutoff-filtered (e.g. a re-sync
                // after the fingerprint record was lost). The all-filtered branch, by contrast,
                // always reports .completed(imported: 0, merged: 0, skipped: 0), so the extra
                // gate never suppresses the warning where it is genuinely needed.
                if isPartialSync && cutoffFilteredCount > 0 && imported == 0 && merged == 0 && skipped == 0 {
                    Text(verbatim: NSLocalizedString("Sync was incomplete — one or more older dives on the device could not be read.", bundle: .forAppLanguage(), value: "Sync was incomplete — one or more older dives on the device could not be read.", comment: "Note appended to the import confirmation alert when a BLE sync completed only partially due to a protocol error on the dive computer (e.g. a corrupt dive slot)."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Sync Error")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Retry") {
                    // The cutoff toggle is ungated on the Search-for-Devices scan screen, so
                    // abandoning a sync without completing it must not leave it silently armed
                    // for whatever the user does next.
                    abandonScanSession()
                }
                .buttonStyle(.bordered)

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            if let logURL = BLEDiagnosticSession.shared.currentLogURL {
                Button {
                    saveDiagnosticLog(logURL)
                } label: {
                    Label("Save Diagnostic Log", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        #if os(iOS)
        .fileExporter(
            isPresented: $showLogExporter,
            document: logExportDocument,
            contentType: .plainText,
            defaultFilename: logExportFileName
        ) { _ in
            logExportDocument = nil
        }
        #endif
    }

    /// Saves the diagnostic log via the app's standard export flow (fileExporter on
    /// iOS / "Designed for iPad" on Mac, NSSavePanel on the macOS target), matching
    /// XML export and database backup. The log is saved as plain text (.txt).
    private func saveDiagnosticLog(_ url: URL) {
        guard let payload = BLEDiagnosticSession.shared.exportPayload(for: url) else { return }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Save Diagnostic Log", bundle: .forAppLanguage(), value: "Save Diagnostic Log", comment: "")
        panel.nameFieldStringValue = payload.filename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? payload.data.write(to: destination)
        }
        #else
        logExportDocument = ExportableFileDocument(data: payload.data)
        logExportFileName = payload.filename
        showLogExporter = true
        #endif
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            closeToolbarButton {
                stopScanning()
                bleManager.close(clearDevicePtr: true)
                dismiss()
            }
            // Blocks the explicit tap path into the unsafe teardown. The swipe-to-dismiss
            // path is blocked separately by the presenting view's
            // `.interactiveDismissDisabled(...)`; both read `isTeardownUnsafe(_:)` so they
            // always agree on which states are unsafe to interrupt.
            .disabled(Self.isTeardownUnsafe(syncState))
        }

        if !(syncState.isActive && syncState != .scanning) {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info")
                }
                .accessibilityLabel(Text("Information"))
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.cyan)
                }
                .accessibilityLabel(Text("Information"))
            }
            #endif
        }

        if syncState == .scanning {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    abandonScanSession()
                } label: {
                    Text("Cancel")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    stopScanning()
                    // Drop peripherals discovered by the previous scan so a rescan starts from a
                    // clean list — same pattern as connectToKnownDevice's scan-fallback path.
                    bleManager.clearDiscoveredPeripherals()
                    startScanning()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("Rescan"))
            }
        }
    }

    // MARK: - Info Sheet

    var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Sync Computer Clock", systemImage: "clock.arrow.2.circlepath")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("When enabled, your dive computer's internal clock is set to match your device's current time and time zone immediately after each successful sync. This keeps dive timestamps accurate without needing to adjust the computer manually.")
                        Text("Clock sync is only performed on dive computers that support it. If your computer does not support clock setting, this option has no effect and the sync proceeds normally.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Download All Dives", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("Normally, only dives newer than your last sync are fetched. Enabling this toggle clears the sync bookmark so the computer re-sends every dive from the beginning.")

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Duplicate handling")
                                .font(.subheadline.weight(.semibold))
                            Text("Dives already in your logbook are normally skipped. In Download All Dives mode, matched dives are merged instead — the computer refreshes its recorded data while your personal entries stay untouched.")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Refreshed from the computer")
                                .font(.subheadline.weight(.semibold))
                            Text("Depth, duration, temperatures, gas mixes, tank pressures, decompression data, dive profile, computer name, raw data, water type, and GPS coordinates.")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Kept from your logbook")
                                .font(.subheadline.weight(.semibold))
                            Text("Notes, buddy, divemaster, rating, dive type, conditions, site name and details, dive number, and surface interval. Tank volume, working pressure, material, and type are also kept unless the computer explicitly reports them.")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Fingerprint scope")
                                .font(.subheadline.weight(.semibold))
                            Text("Only the fingerprint for this specific dive computer is cleared. If no serial number is available yet, no fingerprint is cleared — a first sync has no bookmark to reset anyway.")
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Limit Import by Date", systemImage: "calendar.badge.clock")
                            .font(.headline)
                            .foregroundStyle(.purple)

                        Text("Available when searching for new devices, and alongside Download All Dives for a known computer — the common cases where a dive computer sends its whole history. A never-synced computer has no sync bookmark, so it sends everything by default; that can mean hundreds of dives you already logged by hand or imported from another app. If a computer you've already synced turns out not to need a full re-download, the limit simply has nothing to do.")

                        Text("Dives recorded before the date you choose are discarded after they arrive, instead of being added to your logbook. Every dive is still transferred from the computer, so the sync takes exactly as long — only your logbook stays clean. When re-downloading a known computer, older dives are also not refreshed with the computer's data.")

                        // Same wording caveat as the Search screen's footer: this paragraph covers
                        // both screens, and on the Search screen the owning diver is unknowable.
                        Text("The date defaults to the most recent dive in your logbook, or one year ago if your logbook is empty. The limit applies to a single sync and is never remembered: once a computer is known, the sync bookmark fetches only new dives on its own, so a saved date limit could silently hide dives later.")

                        Text("The sync bookmark is saved even when every downloaded dive falls before your date, so the next sync still fetches only genuinely new dives.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Partial re-download", systemImage: "arrow.down.circle.dotted")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("To re-download only dives newer than a specific point, override the sync fingerprint in **Settings → Bluetooth Import → Sync Fingerprints**. [Instructions & details](https://github.com/houle988/BlueDive/wiki/Dive-Computer-Sync-Fingerprints#overriding-a-fingerprint)")
                    }

                }
                .padding(24)
            }
            .navigationTitle("Sync Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { showInfo = false }
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var syncStateColor: Color {
        switch syncState {
        case .idle: return .secondary
        case .scanning: return .cyan
        case .connecting: return .orange
        case .downloading: return .blue
        case .importing: return .purple
        case .completed: return .green
        case .error: return .red
        }
    }

    private var syncStateTitle: String {
        let bundle = Bundle.forAppLanguage()
        switch syncState {
        case .idle:
            return isSearching
                ? NSLocalizedString("Ready", bundle: bundle, comment: "Title shown in the Bluetooth scanner when ready to connect to a device")
                : NSLocalizedString("Sync", bundle: bundle, comment: "The title of the screen where users can sync their dives with their dive computer.")
        case .scanning:
            return NSLocalizedString("Searching...", bundle: bundle, comment: "A label with an image that indicates a search is in progress.")
        case .connecting(let name):
            return String(format: NSLocalizedString("Connecting to %@", bundle: bundle, comment: "Title shown while connecting to a Bluetooth dive computer. %@ is the device name."), name)
        case .downloading:
            return NSLocalizedString("Downloading...", bundle: bundle, comment: "A placeholder text displayed when downloading dives.")
        case .importing(let count):
            return count == 1
                ? NSLocalizedString("Importing 1 dive...", bundle: bundle, comment: "Title shown while importing exactly one dive from a dive computer.")
                : String(format: NSLocalizedString("Importing %lld dives...", bundle: bundle, comment: "Title shown while importing multiple dives from a dive computer. %lld is the number of dives."), count)
        case .completed(let imported, let merged, _):
            if (imported + merged) > 0 {
                return NSLocalizedString("Sync Complete", bundle: bundle, comment: "A title and some body text displayed after a successful Bluetooth sync.")
            }
            if cutoffFilteredCount > 0 {
                return NSLocalizedString("Older Dives Skipped", bundle: bundle, value: "Older Dives Skipped", comment: "Title shown after a Bluetooth sync in which every downloaded dive was discarded because it predated the user's import cutoff date.")
            }
            return NSLocalizedString("No New Dives", bundle: bundle, comment: "Title shown when there are no new dives to import from the dive computer")
        case .error:
            return NSLocalizedString("Error", bundle: bundle, comment: "The title of an alert that appears when there is a validation error.")
        }
    }

    private var syncStateSubtitle: String {
        let bundle = Bundle.forAppLanguage()
        switch syncState {
        case .idle:
            return isSearching
                ? NSLocalizedString("Select a device to begin", bundle: bundle, comment: "Subtitle shown in the Bluetooth scanner when ready to select a device")
                : NSLocalizedString("Select a dive computer to sync", bundle: bundle, comment: "Subtitle shown in the Bluetooth scanner idle state")
        case .scanning:
            return cachedTargetFingerprint != nil
                ? NSLocalizedString("Looking for your dive computer...", bundle: bundle, comment: "Subtitle shown while scanning for a specific known dive computer")
                : NSLocalizedString("Searching for Bluetooth dive computers...", bundle: bundle, comment: "Subtitle shown while scanning for Bluetooth dive computers")
        case .connecting:
            return NSLocalizedString("Establishing connection...", bundle: bundle, comment: "Subtitle shown while connecting to a Bluetooth dive computer")
        case .downloading:
            if diveCountDuringDownload > 0 {
                return String(format: NSLocalizedString("Downloading dive %lld...", bundle: bundle, comment: "Subtitle showing the current dive being downloaded. %lld is the dive number."), diveCountDuringDownload)
            }
            return NSLocalizedString("Reading dive computer...", bundle: bundle, comment: "Subtitle shown while reading data from a dive computer")
        case .importing:
            return NSLocalizedString("Saving to logbook...", bundle: bundle, comment: "Subtitle shown while saving downloaded dives to the logbook")
        case .completed(let imported, let merged, let skipped):
            // Built as a base message (the pre-existing, cutoff-unaware priority chain, left
            // exactly as-is so a sync with no cutoff involved is byte-for-byte unchanged) with
            // the cutoff detail appended when applicable — rather than a growing set of
            // special-cased conditions — so no combination of imported/merged/skipped/cutoff
            // counts can silently omit a detail that completedView's body always shows.
            let base: String
            if imported == 0 && merged == 0 && skipped == 0 && cutoffFilteredCount == 0 {
                base = NSLocalizedString("Your logbook is up to date", bundle: bundle, comment: "Subtitle shown when the logbook is already up to date after sync")
            } else if merged > 0 && imported == 0 {
                base = merged == 1
                    ? NSLocalizedString("1 dive updated", bundle: bundle, comment: "A label displayed when exactly one dive has been updated.")
                    : String(format: NSLocalizedString("%@ dives updated", bundle: bundle, value: "%@ dives updated", comment: "A label indicating dives have been updated. %@ is the locale-formatted dive count."), Double(merged).localizedString(decimals: 0))
            } else if skipped > 0 {
                base = skipped == 1
                    ? NSLocalizedString("1 dive already present", bundle: bundle, comment: "Subtitle displayed when exactly one dive is already present in the logbook.")
                    : String(format: NSLocalizedString("%@ dives already present", bundle: bundle, value: "%@ dives already present", comment: "Subtitle showing the number of dives already present in the logbook. %@ is the locale-formatted dive count."), Double(skipped).localizedString(decimals: 0))
            } else if imported > 0 && cutoffFilteredCount > 0 {
                // "All dives have been imported" is only a true statement when nothing was held
                // back. With a cutoff in play some downloaded dives were deliberately discarded,
                // so report the count that actually made it into the logbook instead. Both the
                // singular and the plural reuse the same keys completedView's body uses, so the
                // header and the body render an identical count identically.
                base = imported == 1
                    ? NSLocalizedString("1 dive imported", bundle: bundle, comment: "A label displayed when exactly one dive has been imported.")
                    : String(format: NSLocalizedString("%@ dives imported", bundle: bundle, value: "%@ dives imported", comment: "Subtitle showing how many dives were imported when a cutoff also discarded older dives during the same sync. %@ is the locale-formatted dive count."), Double(imported).localizedString(decimals: 0))
            } else if imported > 0 {
                base = NSLocalizedString("All dives have been imported", bundle: bundle, comment: "Subtitle shown when all dives have been successfully imported")
            } else {
                // imported == 0, merged == 0, skipped == 0, but cutoffFilteredCount > 0 —
                // nothing else to report; the cutoff detail below is the entire message.
                base = ""
            }
            guard cutoffFilteredCount > 0 else { return base }
            // Deliberately different wording from completedView's body ("N older dives not
            // imported") — every other case in this subtitle already varies its phrasing from
            // the body's for the same count (e.g. "dive already present" vs "dive already in
            // logbook"), specifically so the header and body don't read as a literal duplicate
            // when both are visible on screen at once.
            let cutoffPart = cutoffFilteredCount == 1
                ? NSLocalizedString("1 older dive skipped", bundle: bundle, value: "1 older dive skipped", comment: "Subtitle footnote when exactly one downloaded dive was discarded because it was recorded before the user's import cutoff date.")
                : String(format: NSLocalizedString("%@ older dives skipped", bundle: bundle, value: "%@ older dives skipped", comment: "Subtitle footnote showing how many downloaded dives were discarded because they were recorded before the user's import cutoff date. %@ is the locale-formatted dive count."), Double(cutoffFilteredCount).localizedString(decimals: 0))
            return base.isEmpty ? cutoffPart : "\(base)\n\(cutoffPart)"
        case .error(let message):
            return message
        }
    }

    private func isConnecting(to peripheral: CBPeripheral) -> Bool {
        // Match the connecting device by its unique identifier rather than its (non-unique) name
        guard case .connecting = syncState,
              let selectedDevice = selectedDevice else {
            return false
        }

        return peripheral.identifier == selectedDevice.identifier
    }

}
