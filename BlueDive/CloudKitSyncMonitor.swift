import Foundation
import CoreData
import CloudKit
import Network
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - CloudKitSyncMonitor

@Observable @MainActor
final class CloudKitSyncMonitor {

    static let cloudKitContainerID = "iCloud.app.bluedive.universal"
    static let backgroundSyncTaskID = "app.bluedive.universal.cloudkit-sync"

    struct SyncState {
        enum Result {
            case unknown
            case succeeded(at: Date)
            case failed(at: Date, error: String)
        }

        var isActive: Bool = false
        var lastResult: Result = .unknown
        var timeoutGeneration: Int = 0

        var hasError: Bool {
            if case .failed = lastResult { return true }
            return false
        }
        var lastSucceeded: Date? {
            if case .succeeded(let d) = lastResult { return d }
            return nil
        }
        var errorMessage: String? {
            if case .failed(_, let m) = lastResult { return m }
            return nil
        }
    }

    var uploadState = SyncState()
    var downloadState = SyncState()
    var setupState = SyncState()

    var isSyncing: Bool { uploadState.isActive || downloadState.isActive }
    var hasError: Bool { uploadState.hasError || downloadState.hasError || setupState.hasError }

    var lastSyncDate: Date? {
        switch (uploadState.lastSucceeded, downloadState.lastSucceeded) {
        case let (u?, d?): return max(u, d)
        case let (u?, nil): return u
        case let (nil, d?): return d
        case (nil, nil): return nil
        }
    }

    // MARK: - Event History (rolling 15-minute log)

    struct SyncLogEntry {
        struct PartialErrorGroup {
            let domain: String
            let code: Int
            /// CKError code name (e.g. "quotaExceeded", "batchRequestFailed"). nil for non-CK domains.
            let codeName: String?
            let count: Int
            let description: String?
            /// True for CKErrorDomain/22 (batchRequestFailed) — cascade noise injected by CloudKit
            /// into every sibling record when one record in the same batch fails. Not the root cause.
            let isBatchCascade: Bool
            /// Up to 3 CKRecord.ID.recordName values for cross-referencing ANSCKRECORDMETADATA.ZCKRECORDNAME.
            /// Empty for cascade entries.
            let sampleRecordNames: [String]
        }

        let timestamp: Date
        let typeName: String
        let succeeded: Bool
        let durationSeconds: Double?
        let errorDescription: String?
        let errorCode: Int?
        let errorDomain: String?
        /// Human-readable CKError code name. Prefers .partialFailure when present in the error chain;
        /// falls back to the first CKError found. nil when no CKError is present (e.g. pure NSError from NSPCKC internals).
        let ckErrorCodeName: String?
        /// Retry-after interval from CKErrorRetryAfterKey if the server requested a backoff.
        let ckRetryAfterSeconds: Double?
        /// Per-record error groups from CKPartialErrorsByItemIDKey.
        /// Sorted: root-cause entries first (descending count), batchRequestFailed cascade entries last.
        /// Empty when no partialFailure was found or partialErrorsByItemID was absent.
        let partialErrorGroups: [PartialErrorGroup]
        /// True when the outer CKError is .partialFailure but partialErrorsByItemID was nil or empty.
        /// Indicates a zone-level failure (ADP key, quota, rate limit) rather than per-record rejections.
        let partialErrorsAbsent: Bool
    }

    private(set) var recentEvents: [SyncLogEntry] = []

    // iCloud account info — fetched async on init, used in sheet and exportLog()
    private(set) var ckAccountStatus: CKAccountStatus = .couldNotDetermine
    private(set) var ckAccountRecordName: String = NSLocalizedString("Fetching…", bundle: Bundle.forAppLanguage(), comment: "Placeholder shown in the iCloud sync log while the account record name is being fetched")
    private(set) var ckAccountStatusFetched: Bool = false
    private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    var ckAccountStatusLabel: String {
        switch ckAccountStatus {
        case .available:
            return NSLocalizedString("Signed in", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: signed in and available")
        case .noAccount:
            return NSLocalizedString("No account", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: no iCloud account on device")
        case .restricted:
            return NSLocalizedString("Restricted", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: restricted by device management policy")
        case .couldNotDetermine:
            return NSLocalizedString("Could not determine", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: status could not be determined")
        case .temporarilyUnavailable:
            return NSLocalizedString("Temporarily unavailable", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: temporarily unavailable")
        @unknown default:
            return NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "iCloud account status: unknown value")
        }
    }

    var ckAccountStatusIcon: String {
        switch ckAccountStatus {
        case .available:              return "checkmark.icloud.fill"
        case .noAccount:              return "xmark.icloud.fill"
        case .restricted:             return "lock.icloud.fill"
        case .temporarilyUnavailable: return "exclamationmark.icloud.fill"
        default:                      return "questionmark.icloud.fill"
        }
    }

    var ckAccountStatusColor: Color {
        switch ckAccountStatus {
        case .available:              return .green
        case .noAccount:              return .orange
        case .restricted:             return .red
        case .temporarilyUnavailable: return .yellow
        default:                      return .secondary
        }
    }

    // No deinit cleanup needed: this class is an app-lifetime singleton and the block
    // captures self weakly, so the registration is harmless if it outlives the instance.
    @ObservationIgnored
    private var observation: NSObjectProtocol?
    @ObservationIgnored
    private var powerStateObservation: NSObjectProtocol?
    @ObservationIgnored
    private var accountChangedObservation: NSObjectProtocol?
    @ObservationIgnored
    private var accountFetchGeneration: Int = 0

    init() {
        fetchAccountInfo()
        observation = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
        powerStateObservation = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        accountChangedObservation = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchAccountInfo()
            }
        }
    }

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        // Record completed events for the log (setup failures included).
        if event.endDate != nil {
            recordLogEntry(from: event)
        }

        // .setup tracks CloudKit container initialisation; failures mean sync cannot start at all.
        if event.type == .setup {
            if event.endDate == nil {
                setupState.timeoutGeneration += 1
                setupState.isActive = true
                scheduleActivityTimeout(\.setupState, generation: setupState.timeoutGeneration)
            } else {
                setupState.isActive = false
                if event.succeeded {
                    setupState.lastResult = .succeeded(at: event.endDate!)
                } else {
                    setupState.lastResult = .failed(
                        at: event.endDate!,
                        error: event.error?.localizedDescription ?? NSLocalizedString(
                            "Unknown sync error",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Fallback error message when CloudKit sync fails without providing details"
                        )
                    )
                }
            }
            return
        }

        switch event.type {
        case .export:
            if event.endDate == nil {
                uploadState.timeoutGeneration += 1
                uploadState.isActive = true
                scheduleActivityTimeout(\.uploadState, generation: uploadState.timeoutGeneration)
            } else {
                uploadState.isActive = false
                if event.succeeded {
                    uploadState.lastResult = .succeeded(at: event.endDate!)
                } else {
                    uploadState.lastResult = .failed(
                        at: event.endDate!,
                        error: event.error?.localizedDescription ?? NSLocalizedString(
                            "Unknown sync error",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Fallback error message when CloudKit sync fails without providing details"
                        )
                    )
                }
            }
        case .import:
            if event.endDate == nil {
                downloadState.timeoutGeneration += 1
                downloadState.isActive = true
                scheduleActivityTimeout(\.downloadState, generation: downloadState.timeoutGeneration)
            } else {
                downloadState.isActive = false
                if event.succeeded {
                    downloadState.lastResult = .succeeded(at: event.endDate!)
                } else {
                    downloadState.lastResult = .failed(
                        at: event.endDate!,
                        error: event.error?.localizedDescription ?? NSLocalizedString(
                            "Unknown sync error",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Fallback error message when CloudKit sync fails without providing details"
                        )
                    )
                }
            }
        default:
            break
        }
    }

    private func scheduleActivityTimeout(_ keyPath: ReferenceWritableKeyPath<CloudKitSyncMonitor, SyncState>, generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self else { return }
            var state = self[keyPath: keyPath]
            // Only clear isActive if no newer begin-event has since updated the generation.
            guard state.timeoutGeneration == generation else { return }
            state.isActive = false
            self[keyPath: keyPath] = state
        }
    }

    private func fetchAccountInfo() {
        accountFetchGeneration += 1
        let generation = accountFetchGeneration
        let container = CKContainer(identifier: Self.cloudKitContainerID)
        container.accountStatus { [weak self] status, _ in
            Task { @MainActor [weak self] in
                guard let self, self.accountFetchGeneration == generation else { return }
                self.ckAccountStatus = status
                self.ckAccountStatusFetched = true
            }
        }
        Task { @MainActor [weak self] in
            guard let self, self.accountFetchGeneration == generation else { return }
            do {
                let recordID = try await container.userRecordID()
                guard self.accountFetchGeneration == generation else { return }
                self.ckAccountRecordName = recordID.recordName
            } catch {
                guard self.accountFetchGeneration == generation else { return }
                self.ckAccountRecordName = NSLocalizedString("Unavailable", bundle: Bundle.forAppLanguage(), comment: "Shown in the iCloud sync log when the CloudKit account record name cannot be retrieved")
            }
        }
    }

    /// Maps a CKError integer code to its enum case name for human-readable log output.
    /// Returns nil when `domain` is not CKError.errorDomain.
    private static func ckCodeName(code: Int, domain: String) -> String? {
        guard domain == CKError.errorDomain,
              let ckCode = CKError.Code(rawValue: code) else { return nil }
        switch ckCode {
        case .internalError:                        return "internalError"
        case .partialFailure:                       return "partialFailure"
        case .networkUnavailable:                   return "networkUnavailable"
        case .networkFailure:                       return "networkFailure"
        case .badContainer:                         return "badContainer"
        case .serviceUnavailable:                   return "serviceUnavailable"
        case .requestRateLimited:                   return "requestRateLimited"
        case .missingEntitlement:                   return "missingEntitlement"
        case .notAuthenticated:                     return "notAuthenticated"
        case .permissionFailure:                    return "permissionFailure"
        case .unknownItem:                          return "unknownItem"
        case .invalidArguments:                     return "invalidArguments"
        case .resultsTruncated:                     return "resultsTruncated"
        case .serverRecordChanged:                  return "serverRecordChanged"
        case .serverRejectedRequest:                return "serverRejectedRequest"
        case .assetFileNotFound:                    return "assetFileNotFound"
        case .incompatibleVersion:                  return "incompatibleVersion"
        case .constraintViolation:                  return "constraintViolation"
        case .operationCancelled:                   return "operationCancelled"
        case .changeTokenExpired:                   return "changeTokenExpired"
        case .batchRequestFailed:                   return "batchRequestFailed"
        case .zoneBusy:                             return "zoneBusy"
        case .badDatabase:                          return "badDatabase"
        case .quotaExceeded:                        return "quotaExceeded"
        case .zoneNotFound:                         return "zoneNotFound"
        case .limitExceeded:                        return "limitExceeded"
        case .userDeletedZone:                      return "userDeletedZone"
        case .tooManyParticipants:                  return "tooManyParticipants"
        case .alreadyShared:                        return "alreadyShared"
        case .referenceViolation:                   return "referenceViolation"
        case .managedAccountRestricted:             return "managedAccountRestricted"
        case .participantMayNeedVerification:       return "participantMayNeedVerification"
        case .serverResponseLost:                   return "serverResponseLost"
        case .assetNotAvailable:                    return "assetNotAvailable"
        case .accountTemporarilyUnavailable:        return "accountTemporarilyUnavailable"
        default:                                    return "unknown(\(code))"
        }
    }

    private func recordLogEntry(from event: NSPersistentCloudKitContainer.Event) {
        let typeName: String
        switch event.type {
        case .setup:          typeName = "Setup"
        case .export:         typeName = "Upload"
        case .import:         typeName = "Download"
        @unknown default:     typeName = "Unknown"
        }

        var duration: Double? = nil
        if let end = event.endDate {
            duration = end.timeIntervalSince(event.startDate)
        }

        var errorDescription: String? = nil
        var errorCode: Int? = nil
        var errorDomain: String? = nil
        var ckErrorCodeName: String? = nil
        var ckRetryAfterSeconds: Double? = nil
        var partialErrorGroups: [SyncLogEntry.PartialErrorGroup] = []
        var partialErrorsAbsent: Bool = false

        if let error = event.error {
            errorDescription = error.localizedDescription
            let nsError = error as NSError
            errorCode = nsError.code
            errorDomain = nsError.domain

            // BFS over the full error chain to find the first CKError.partialFailure (preferred)
            // or any CKError (fallback). NSPCKC wraps errors under NSUnderlyingErrorKey,
            // NSMultipleUnderlyingErrorsKey, and NSDetailedErrorsKey — walk all three.
            struct GroupKey: Hashable { let domain: String; let code: Int }
            var worklist: [Error] = [error]
            var visited = Set<ObjectIdentifier>()
            var firstCKError: CKError? = nil
            var firstRetryAfterCKError: CKError? = nil
            var partialCKError: CKError? = nil
            var detailedChildErrors: [Error] = []

            // visited.count < 256: guards against cyclic chains from value-typed Swift errors
            // whose `as NSError` bridge produces a fresh wrapper on every cast, making
            // ObjectIdentifier an unreliable dedup key and the guard ineffective.
            while !worklist.isEmpty && partialCKError == nil && visited.count < 256 {
                let current = worklist.removeFirst()
                let ns = current as NSError
                let id = ObjectIdentifier(ns)
                guard !visited.contains(id) else { continue }
                visited.insert(id)

                if let ck = current as? CKError {
                    if firstCKError == nil { firstCKError = ck }
                    if firstRetryAfterCKError == nil && ck.retryAfterSeconds != nil { firstRetryAfterCKError = ck }
                    if ck.code == .partialFailure { partialCKError = ck; break }
                }
                if let u = ns.userInfo[NSUnderlyingErrorKey] as? Error {
                    worklist.append(u)
                }
                if let ms = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
                    worklist.append(contentsOf: ms)
                }
                if let ds = ns.userInfo[NSDetailedErrorsKey] as? [Error] {
                    worklist.append(contentsOf: ds)
                    detailedChildErrors.append(contentsOf: ds)
                }
            }

            let targetCKError = partialCKError ?? firstCKError
            if let ck = targetCKError {
                ckErrorCodeName = Self.ckCodeName(code: ck.code.rawValue, domain: CKError.errorDomain)
            }
            // Read retry-after from the first error that carries it — typically the outer wrapper
            // (e.g. requestRateLimited), not the inner partialFailure which rarely has it.
            ckRetryAfterSeconds = firstRetryAfterCKError?.retryAfterSeconds

            if let ck = partialCKError {
                if let partials = ck.partialErrorsByItemID, !partials.isEmpty {
                    var freq: [GroupKey: (count: Int, description: String?, sampleIDs: [String])] = [:]
                    let cascadeCode = CKError.Code.batchRequestFailed.rawValue

                    for (itemID, itemError) in partials {
                        let nsErr = itemError as NSError
                        let key = GroupKey(domain: nsErr.domain, code: nsErr.code)
                        let isCascade = nsErr.domain == CKError.errorDomain && nsErr.code == cascadeCode
                        var existing = freq[key] ?? (count: 0, description: nil, sampleIDs: [])
                        existing.count += 1
                        if existing.description == nil { existing.description = nsErr.localizedDescription }
                        // Collect up to 3 sample IDs per error group; skip cascade entries (they are not
                        // the failing records — they are innocent bystanders in the same batch).
                        if !isCascade && existing.sampleIDs.count < 3,
                           let recordID = itemID as? CKRecord.ID {
                            existing.sampleIDs.append(recordID.recordName)
                        }
                        freq[key] = existing
                    }

                    partialErrorGroups = freq
                        .map { key, val in
                            SyncLogEntry.PartialErrorGroup(
                                domain: key.domain,
                                code: key.code,
                                codeName: Self.ckCodeName(code: key.code, domain: key.domain),
                                count: val.count,
                                description: val.description,
                                isBatchCascade: key.domain == CKError.errorDomain && key.code == cascadeCode,
                                sampleRecordNames: val.sampleIDs
                            )
                        }
                        // Root-cause entries first (descending count), cascade entries last.
                        .sorted {
                            if $0.isBatchCascade != $1.isBatchCascade { return !$0.isBatchCascade }
                            return $0.count > $1.count
                        }
                } else {
                    // partialErrorsByItemID is nil/empty. NSPCKC occasionally surfaces
                    // per-record errors via NSDetailedErrorsKey on an outer node instead.
                    // Try to harvest those before concluding it is a zone-level failure.
                    let perRecordCandidates = detailedChildErrors
                        .compactMap { $0 as? CKError }
                        .filter { $0.code != .partialFailure }
                    if !perRecordCandidates.isEmpty {
                        let cascadeCode = CKError.Code.batchRequestFailed.rawValue
                        var freq: [GroupKey: (count: Int, description: String?)] = [:]
                        for itemError in perRecordCandidates {
                            let nsErr = itemError as NSError
                            let key = GroupKey(domain: nsErr.domain, code: nsErr.code)
                            var existing = freq[key] ?? (count: 0, description: nil)
                            existing.count += 1
                            if existing.description == nil { existing.description = nsErr.localizedDescription }
                            freq[key] = existing
                        }
                        partialErrorGroups = freq
                            .map { key, val in
                                SyncLogEntry.PartialErrorGroup(
                                    domain: key.domain,
                                    code: key.code,
                                    codeName: Self.ckCodeName(code: key.code, domain: key.domain),
                                    count: val.count,
                                    description: val.description,
                                    isBatchCascade: key.domain == CKError.errorDomain && key.code == cascadeCode,
                                    sampleRecordNames: []
                                )
                            }
                            .sorted {
                                if $0.isBatchCascade != $1.isBatchCascade { return !$0.isBatchCascade }
                                return $0.count > $1.count
                            }
                    } else {
                        // No per-record details found anywhere: zone-level failure
                        // (ADP key unavailable, quota exceeded at zone level, rate limit, etc.)
                        partialErrorsAbsent = true
                    }
                }
            }
        }

        let entry = SyncLogEntry(
            timestamp: event.endDate ?? Date(),
            typeName: typeName,
            succeeded: event.succeeded,
            durationSeconds: duration,
            errorDescription: errorDescription,
            errorCode: errorCode,
            errorDomain: errorDomain,
            ckErrorCodeName: ckErrorCodeName,
            ckRetryAfterSeconds: ckRetryAfterSeconds,
            partialErrorGroups: partialErrorGroups,
            partialErrorsAbsent: partialErrorsAbsent
        )

        let cutoff = Date().addingTimeInterval(-900)
        recentEvents.removeAll { $0.timestamp < cutoff }
        recentEvents.append(entry)
    }

    private func currentNetworkStatus() async -> String {
        // Holds mutable state as a reference type so both closures capture `let` bindings,
        // avoiding @Sendable local-function issues and mutable-capture warnings.
        final class State: @unchecked Sendable {
            let lock = NSLock()
            nonisolated(unsafe) var resumed = false
        }
        let state = State()

        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                let status: String
                if path.status == .unsatisfied || path.status == .requiresConnection {
                    status = "None"
                } else {
                    let hasWifi = path.usesInterfaceType(.wifi)
                    let hasCellular = path.usesInterfaceType(.cellular)
                    if hasWifi && hasCellular { status = "Wi-Fi + Cellular" }
                    else if hasWifi            { status = "Wi-Fi" }
                    else if hasCellular        { status = "Cellular" }
                    else                       { status = "Other" }
                }
                state.lock.lock()
                let shouldResume = !state.resumed
                if shouldResume { state.resumed = true }
                state.lock.unlock()
                if shouldResume { continuation.resume(returning: status) }
            }
            monitor.start(queue: .global(qos: .utility))

            // Timeout: if pathUpdateHandler never fires, resume with "Unknown" after 1 second.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                monitor.cancel()
                state.lock.lock()
                let shouldResume = !state.resumed
                if shouldResume { state.resumed = true }
                state.lock.unlock()
                if shouldResume { continuation.resume(returning: "Unknown") }
            }
        }
    }

    private func readCPUTicks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
    }

    private func measureCPUUsage() async -> Int? {
        guard let t0 = readCPUTicks() else { return nil }
        try? await Task.sleep(for: .milliseconds(100))
        guard let t1 = readCPUTicks() else { return nil }
        let user   = Double(t1.user   &- t0.user)
        let system = Double(t1.system &- t0.system)
        let idle   = Double(t1.idle   &- t0.idle)
        let nice   = Double(t1.nice   &- t0.nice)
        let total  = user + system + idle + nice
        guard total > 0 else { return nil }
        return Int((user + system + nice) / total * 100)
    }

    private func readRAMInfo() -> (used: UInt64, free: UInt64, total: UInt64)? {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let total    = ProcessInfo.processInfo.physicalMemory
        let free     = UInt64(vmStats.free_count) * pageSize
        let used     = (UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)) * pageSize
        return (used: used, free: free, total: total)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    func exportLog() async -> String {
        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        headerFormatter.timeZone = TimeZone.current

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.timeZone = TimeZone.current

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let buildEnv = "Debug / CloudKit Development"
        #else
        let buildEnv = "Release / CloudKit Production"
        #endif

        // Gather async diagnostics before building the log string.
        let networkStatus = await currentNetworkStatus()
        let ramInfo = readRAMInfo()
        let cpuUsed = await measureCPUUsage()

        let accountStatusLabel: String
        switch ckAccountStatus {
        case .available:                accountStatusLabel = "Available"
        case .noAccount:                accountStatusLabel = "No account"
        case .restricted:               accountStatusLabel = "Restricted"
        case .couldNotDetermine:        accountStatusLabel = "Could not determine"
        case .temporarilyUnavailable:   accountStatusLabel = "Temporarily unavailable"
        @unknown default:               accountStatusLabel = "Unknown (\(ckAccountStatus.rawValue))"
        }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "Yes (sync may be throttled)" : "No"

        var lines: [String] = []
        lines.append("BlueDive iCloud Sync Log")
        lines.append(String(repeating: "-", count: 44))
        lines.append("Generated:    \(headerFormatter.string(from: Date()))")
        lines.append("App Version:  \(appVersion) (\(buildNumber))")
        lines.append("Environment:  \(buildEnv)")
        #if canImport(UIKit)
        lines.append("Device:       \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        #endif
        lines.append("Network:      \(networkStatus)")
        if let ram = ramInfo {
            lines.append("RAM:          Used: \(formatBytes(ram.used)) / Free: \(formatBytes(ram.free)) / Total: \(formatBytes(ram.total))  (active+wired+compressed; excludes reclaimable inactive)")
        }
        let cores = ProcessInfo.processInfo.processorCount
        if let used = cpuUsed {
            lines.append("CPU:          Used: \(used)% / Idle: \(100 - used)%  (\(cores) cores, system-wide)")
        } else {
            lines.append("CPU:          \(cores) cores")
        }
        lines.append("Container:    \(Self.cloudKitContainerID)")
        lines.append("iCloud:       \(accountStatusLabel)")
        lines.append("Account ID:   \(ckAccountRecordName)  (unique per device–account pair, not a personal identifier)")
        lines.append("Low Power:    \(lowPower)")
        lines.append("Note:         Events since last app launch only (not persisted between sessions)")
        lines.append("")

        let cutoff = Date().addingTimeInterval(-900)
        let filtered = recentEvents
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }

        if filtered.isEmpty {
            lines.append("No events recorded in the past 15 minutes.")
        } else {
            lines.append("Past 15 min: \(filtered.count) event(s)")
            lines.append("")
            for entry in filtered {
                let time = timeFormatter.string(from: entry.timestamp)
                let typeCol = entry.typeName.padding(toLength: 10, withPad: " ", startingAt: 0)
                let status = entry.succeeded ? "✓" : "✗"
                var line = "\(time)  \(typeCol)  \(status)"
                if let duration = entry.durationSeconds {
                    line += "  \(String(format: "%.1f", duration))s"
                }
                if !entry.succeeded, let desc = entry.errorDescription {
                    if let code = entry.errorCode, let domain = entry.errorDomain {
                        let shortDomain = domain.components(separatedBy: ".").last ?? domain
                        line += "  —  \(shortDomain)/\(code): \(desc)"
                    } else {
                        line += "  —  \(desc)"
                    }
                }
                lines.append(line)
                // CKError outer context — always present when any CKError is in the chain
                if !entry.succeeded, let codeName = entry.ckErrorCodeName {
                    var ckLine = "           CKError: \(codeName)"
                    if let retry = entry.ckRetryAfterSeconds {
                        ckLine += "  retry-after: \(String(format: "%.0f", retry))s"
                    }
                    if entry.partialErrorsAbsent {
                        ckLine += "  — no per-record errors (zone/ADP/quota/rate-limit level)"
                    }
                    lines.append(ckLine)
                }
                // Per-record error breakdown (root-cause groups first, batchRequestFailed cascade last)
                for group in entry.partialErrorGroups {
                    let shortDomain = group.domain.components(separatedBy: ".").last ?? group.domain
                    let codeLabel = group.codeName.map { "\(shortDomain)/\(group.code) (\($0))" }
                        ?? "\(shortDomain)/\(group.code)"
                    let tag = group.isBatchCascade ? "[cascade]" : "[root]   "
                    var groupLine = "           Per-record \(tag): \(codeLabel) ×\(group.count)"
                    if let desc = group.description, !group.isBatchCascade {
                        groupLine += "  \"\(desc)\""
                    }
                    if !group.sampleRecordNames.isEmpty {
                        groupLine += "  samples: \(group.sampleRecordNames.joined(separator: ", "))"
                    }
                    lines.append(groupLine)
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - SyncState helpers used by both the toolbar popover and Settings

extension CloudKitSyncMonitor.SyncState {

    var statusColor: Color {
        if isActive { return .cyan }
        if hasError { return .orange }
        if lastSucceeded != nil { return .green }
        return .secondary
    }

    func subtitleText(locale: Locale) -> String {
        if isActive {
            return NSLocalizedString(
                "Syncing…",
                bundle: Bundle.forAppLanguage(),
                comment: "CloudKit sync state label when sync is currently in progress"
            )
        }
        if let msg = errorMessage {
            return String(
                format: NSLocalizedString(
                    "Error: %@",
                    bundle: Bundle.forAppLanguage(),
                    comment: "CloudKit sync error label followed by the error description"
                ),
                msg
            )
        }
        if let date = lastSucceeded {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: date, relativeTo: Date())
            return String(
                format: NSLocalizedString(
                    "Synced %@",
                    bundle: Bundle.forAppLanguage(),
                    comment: "CloudKit sync success label with a relative time, e.g. 'Synced 2 minutes ago'"
                ),
                relative
            )
        }
        return NSLocalizedString(
            "Not yet synced",
            bundle: Bundle.forAppLanguage(),
            comment: "CloudKit sync state label when no sync has occurred since app launch"
        )
    }
}

// MARK: - Sync Status View (half-sheet)

struct CloudKitSyncStatusView: View {
    @Environment(CloudKitSyncMonitor.self) private var monitor
    @Environment(\.locale) private var locale

    @State private var showExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFilename: String = ""
    @State private var isPreparingExport = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.platformBackground, Color.cyan.opacity(0.05), Color.platformBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroHeader

                    VStack(spacing: 12) {
                        syncCard(icon: "icloud.and.arrow.up.fill",   title: "Upload",   state: monitor.uploadState)
                        syncCard(icon: "icloud.and.arrow.down.fill", title: "Download", state: monitor.downloadState)
                        if monitor.setupState.hasError || monitor.setupState.isActive {
                            syncCard(icon: "gearshape.fill", title: "Setup", state: monitor.setupState)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                    if monitor.isLowPowerMode {
                        lowPowerCard
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }

                    accountStatusRow
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    exportRow
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                }
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.3), Color.blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 16)

                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 80, height: 80)

                if monitor.isSyncing {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.cyan)
                } else {
                    Image(systemName: monitor.hasError ? "exclamationmark.icloud.fill" : "icloud.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(
                            LinearGradient(
                                colors: monitor.hasError ? [.orange, .red] : [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .padding(.top, 24)

            VStack(spacing: 4) {
                Text("iCloud Sync")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(verbatim: heroSubtitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(monitor.hasError ? .orange : .cyan)
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var heroSubtitle: String {
        if monitor.isSyncing {
            return NSLocalizedString(
                "Syncing…",
                bundle: Bundle.forAppLanguage(),
                comment: "CloudKit sync state label when sync is currently in progress"
            )
        }
        if monitor.hasError {
            return NSLocalizedString(
                "Sync Error",
                bundle: Bundle.forAppLanguage(),
                comment: "A label displayed in the iCloud sync status sheet when a CloudKit sync error has occurred."
            )
        }
        if let date = monitor.lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: date, relativeTo: Date())
            return String(
                format: NSLocalizedString(
                    "Synced %@",
                    bundle: Bundle.forAppLanguage(),
                    comment: "CloudKit sync success label with a relative time, e.g. 'Synced 2 minutes ago'"
                ),
                relative
            )
        }
        return NSLocalizedString(
            "Not yet synced",
            bundle: Bundle.forAppLanguage(),
            comment: "CloudKit sync state label when no sync has occurred since app launch"
        )
    }

    @ViewBuilder
    private func syncCard(icon: String, title: LocalizedStringKey, state: CloudKitSyncMonitor.SyncState) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(state.statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if state.isActive {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(state.statusColor)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(state.statusColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(verbatim: state.subtitleText(locale: locale))
                    .font(.footnote)
                    .foregroundStyle(state.hasError ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var lowPowerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "battery.25")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Low Power Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Low Power Mode is on — iCloud sync may be slower. Turn it off in Settings > Battery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.yellow.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var accountStatusRow: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(monitor.ckAccountStatusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                if !monitor.ckAccountStatusFetched {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: monitor.ckAccountStatusIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(monitor.ckAccountStatusColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("iCloud account")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(verbatim: monitor.ckAccountStatusLabel)
                    .font(.footnote)
                    .foregroundStyle(monitor.ckAccountStatusColor)
                if monitor.ckAccountStatusFetched && monitor.ckAccountStatus == .noAccount {
                    Text("Sign in to iCloud in Settings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var exportRow: some View {
        VStack(spacing: 8) {
            Button {
                guard !isPreparingExport else { return }
                isPreparingExport = true
                Task {
                    let log = await monitor.exportLog()
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    df.timeZone = TimeZone.current
                    exportDocument = ExportableFileDocument(data: Data(log.utf8))
                    exportFilename = "bluedive-sync-log-\(df.string(from: Date())).txt"
                    showExporter = true
                    isPreparingExport = false
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.15))
                            .frame(width: 44, height: 44)
                        if isPreparingExport {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.cyan)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                                .foregroundStyle(.cyan)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export Sync Log")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text("Last 15 minutes of sync activity")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            Text("Events recorded since last app launch only")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}
