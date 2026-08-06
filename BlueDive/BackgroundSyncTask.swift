#if os(iOS)
import BackgroundTasks
import os.log
import os

/// Defensive background task that keeps the app process alive in a background
/// window so NSPersistentCloudKitContainer's automatic sync (driven by SwiftData)
/// can continue making progress — particularly the large initial download on a
/// new device. There is no public API to pump the container explicitly under
/// SwiftData; this task simply holds the process so the container's internal
/// machinery keeps running rather than being suspended by iOS.
///
/// This does NOT fix CloudKit server-side throttling and is not a guaranteed
/// cure for partial sync. It removes one barrier: the app process being
/// suspended before a large initial download completes.
enum BackgroundSyncTask {

    private static let logger = Logger(subsystem: "com.bluedive.app", category: "BGSync")

    /// Called once, synchronously, during app launch from BlueDiveApp.init().
    /// Must be called before the app finishes launching or iOS will crash when
    /// delivering the task.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: CloudKitSyncMonitor.backgroundSyncTaskID,
            using: nil
        ) { task in
            handle(task: task as! BGProcessingTask)
        }
        logger.debug("Registered background CloudKit sync task")
    }

    /// Submitted when the app enters the background. Submitting while a request
    /// is already pending simply replaces it, so unconditional submission is safe.
    /// Guards on iCloud sync being enabled — no point requesting background time
    /// when sync is off.
    static func schedule() {
        guard UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey) else { return }

        let request = BGProcessingTaskRequest(identifier: CloudKitSyncMonitor.backgroundSyncTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled background CloudKit sync task")
        } catch {
            // Code 1 (unavailable) is expected in Simulator and when the user
            // has Background App Refresh disabled — log and continue.
            logger.debug("Could not schedule background sync task: \(error.localizedDescription)")
        }
    }

    private static func handle(task: BGProcessingTask) {
        // Re-schedule immediately so the task recurs beyond this single execution.
        schedule()

        // Single-shot guard: setTaskCompleted must be called exactly once.
        // The work Task (normal completion) and the expiration handler (early
        // termination) both call finish(_:), but only the first call goes through.
        let completed = OSAllocatedUnfairLock(initialState: false)
        func finish(_ success: Bool) {
            let shouldComplete = completed.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if shouldComplete {
                task.setTaskCompleted(success: success)
            }
        }

        let work = Task {
            // Hold the process for up to 60 seconds so the container's automatic
            // CloudKit import/export has runtime to make progress. Task.sleep
            // throws CancellationError when the expiration handler cancels it,
            // so this exits cleanly without polling.
            try? await Task.sleep(for: .seconds(60))
            finish(true)
        }

        // Called by iOS shortly before force-terminating the task.
        // Must return quickly — cancel the wait and report failure immediately.
        task.expirationHandler = {
            work.cancel()
            finish(false)
        }
    }
}
#endif
