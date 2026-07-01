import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift

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
                        Text(verbatim: String(format: NSLocalizedString("%lld dive(s) downloaded", bundle: Bundle.forAppLanguage(), comment: "A text label displaying the number of dives that have been successfully downloaded. The argument is the number of dives that have been downloaded."), diveCountDuringDownload - 1))
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
        Form {
            if !knownDevices.isEmpty {
                Section {
                    ForEach(knownDevices, id: \.serial) { device in
                        KnownDeviceRow(
                            computerName: device.computerName,
                            serial: device.serial,
                            lastSynced: device.updatedAt,
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
                Text("Enable this option to ignore the fingerprint and re-download all dives from the computer. Matched dives are merged — computer data is refreshed while your personal notes and entries are kept.")
            }

            Section {
                Toggle("Sync device clock", isOn: $syncDeviceClock)
            } footer: {
                Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
            }

            Section {
                Button {
                    downloadAllDives = false
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
    }

    // MARK: - Device List View

    @ViewBuilder
    private var deviceListView: some View {
        if bleManager.discoveredPeripherals.isEmpty {
            ContentUnavailableView {
                Label("Searching...", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Make sure your dive computer is turned on and in Bluetooth transfer mode.")
            }
        } else {
            Form {
                Section {
                    ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        DeviceRow(
                            peripheral: peripheral,
                            isSelected: selectedDevice?.identifier == peripheral.identifier,
                            isConnecting: isConnecting(to: peripheral),
                            modelOverride: modelOverrides[peripheral.identifier.uuidString],
                            onTap: { connectToDevice(peripheral) },
                            onChangeModel: {
                                peripheralForModelPicker = peripheral
                            }
                        )
                        .disabled(syncState.isActive && syncState != .scanning)
                    }
                } header: {
                    HStack {
                        Text("Available Devices")
                        Spacer()
                        Text("\(bleManager.discoveredPeripherals.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Select your dive computer to download new dives. Tap the info button to change the detected model if incorrect.")
                }

                Section {
                    Toggle("Download All Dives", isOn: $downloadAllDives)
                        .disabled(true)
                } footer: {
                    Text("Download All Dives is only available for known dive computers. Sync this device once first, then use it from the main screen.")
                }

                Section {
                    Toggle("Sync device clock", isOn: $syncDeviceClock)
                        .disabled(syncState.isActive && syncState != .scanning)
                } footer: {
                    Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
                }
            }
            .formStyle(.grouped)
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
    }

    // MARK: - Completed View

    @ViewBuilder
    private func completedView(imported: Int, merged: Int, skipped: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text(imported + merged > 0 ? "Sync Complete" : "No New Dives")
                    .font(.title2)
                    .fontWeight(.semibold)

                if imported > 0 {
                    Text("\(imported) dive(s) imported")
                        .foregroundStyle(.secondary)
                }

                if merged > 0 {
                    Text("\(merged) dive(s) updated")
                        .foregroundStyle(.secondary)
                }

                if skipped > 0 {
                    Text("\(skipped) dive(s) already in logbook")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    isSearching = false
                    cachedTargetFingerprint = nil
                    if let seed = pendingDeviceStorageSeed {
                        modelOverrides.removeValue(forKey: seed.uuid)
                        pendingDeviceStorageSeed = nil
                    }
                    syncState = .idle
                }
                .buttonStyle(.bordered)

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                stopScanning()
                bleManager.close(clearDevicePtr: true)
                dismiss()
            }
            .disabled(syncState.isActive && syncState != .scanning)
        }

        if !(syncState.isActive && syncState != .scanning) {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.cyan)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            if syncState == .scanning {
                HStack(spacing: 12) {
                    Button {
                        stopScanning()
                        isSearching = false
                        cachedTargetFingerprint = nil
                        if let seed = pendingDeviceStorageSeed {
                            modelOverrides.removeValue(forKey: seed.uuid)
                            pendingDeviceStorageSeed = nil
                        }
                        syncState = .idle
                    } label: {
                        Text("Cancel")
                    }

                    Button {
                        stopScanning()
                        startScanning()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - Info Sheet

    var infoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Sync Computer Clock", systemImage: "clock.arrow.2.circlepath")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text("When enabled, your dive computer's internal clock is set to match your device's current time and time zone immediately after each successful sync. This keeps dive timestamps accurate without needing to adjust the computer manually.")
                        Text("Clock sync is only performed on dive computers that support it. If your computer does not support clock setting, this option has no effect and the sync proceeds normally.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Download All Dives", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("Normally, only dives newer than your last sync are fetched. Enabling this toggle clears the sync bookmark so the computer re-sends every dive from the beginning.")

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Duplicate handling")
                                .font(.subheadline.weight(.semibold))
                            Text("Dives already in your logbook are normally skipped. In Download All Dives mode, matched dives are merged instead — the computer refreshes its recorded data while your personal entries stay untouched.")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Refreshed from the computer")
                                .font(.subheadline.weight(.semibold))
                            Text("Depth, duration, temperatures, gas mixes, tank pressures, decompression data, dive profile, computer name, raw data, water type, and GPS coordinates.")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kept from your logbook")
                                .font(.subheadline.weight(.semibold))
                            Text("Notes, buddy, divemaster, rating, dive type, conditions, site name and details, dive number, and surface interval. Tank volume, working pressure, material, and type are also kept unless the computer explicitly reports them.")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Fingerprint scope")
                                .font(.subheadline.weight(.semibold))
                            Text("Only the fingerprint for this specific dive computer is cleared. If no serial number is available yet, no fingerprint is cleared — a first sync has no bookmark to reset anyway.")
                        }
                    }

                }
                .padding(24)
            }
            .navigationTitle("Sync Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { showInfo = false }
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
            return String(format: NSLocalizedString("Importing %lld dives...", bundle: bundle, comment: "Title shown while importing dives from a dive computer. %lld is the number of dives."), count)
        case .completed(let imported, let merged, _):
            return (imported + merged) > 0
                ? NSLocalizedString("Sync Complete", bundle: bundle, comment: "A title and some body text displayed after a successful Bluetooth sync.")
                : NSLocalizedString("No New Dives", bundle: bundle, comment: "Title shown when there are no new dives to import from the dive computer")
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
            if imported == 0 && merged == 0 && skipped == 0 {
                return NSLocalizedString("Your logbook is up to date", bundle: bundle, comment: "Subtitle shown when the logbook is already up to date after sync")
            } else if merged > 0 && imported == 0 {
                return String(format: NSLocalizedString("%lld dive(s) updated", bundle: bundle, comment: "A label indicating that a number of dives have been updated (merged) with existing dives in the logbook. The argument is the number of dives that have been updated."), merged)
            } else if skipped > 0 {
                return String(format: NSLocalizedString("%lld dive(s) already present", bundle: bundle, comment: "Subtitle showing the number of dives already present in the logbook"), skipped)
            }
            return NSLocalizedString("All dives have been imported", bundle: bundle, comment: "Subtitle shown when all dives have been successfully imported")
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
