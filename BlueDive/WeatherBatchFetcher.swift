import Foundation
import SwiftData
import os.log

// MARK: - Weather Batch Fetch

/// Progress, then result, of an Open-Meteo weather fetch over several dives: after a Bluetooth
/// import, or for all dives from Settings → Online Services.
enum WeatherBatchFetchStatus: Equatable {
    case running(done: Int, total: Int)
    /// `withData`: dives Open-Meteo returned values for; `filled`: dives whose values changed;
    /// `stillEmpty`: dives left with an empty field Open-Meteo had no value for.
    case finished(filled: Int, withData: Int, stillEmpty: Int, total: Int)
    /// Stopped at the first network failure (e.g. no connection on the boat). `filled`: dives
    /// already updated and saved before stopping.
    case stoppedOffline(filled: Int)
    /// Stopped because Open-Meteo answered with an error (e.g. rate limit).
    case stoppedUnavailable(filled: Int)
    /// Stopped because saving the fetched values failed (they were discarded).
    case saveFailed(filled: Int)
    /// Stopped because the app went to the background (iOS would suspend it mid-request) or
    /// the screen was closed.
    case interrupted(filled: Int)
    /// Stopped because the user chose Stop.
    case stopped(filled: Int)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Fetches the weather for a list of dives, one Open-Meteo request per dive, in order. Shared
/// by the Bluetooth import and Settings → Online Services so both behave the same.
///
/// Stops at the first network or service error instead of waiting for every request to time
/// out. Saves every few dives and once more when the run ends — also when the calling task is
/// cancelled — so stopping keeps what was fetched.
///
/// Works in its own ModelContext (author "BlueDive.weather", CLAUDE.md): each dive is fetched
/// by ID, so a deleted dive is simply skipped, and a failed save discards only this run's
/// changes, never other unsaved work in the main context. The main context picks up the saved
/// values; RemoteChangeFeeder skips "BlueDive." authors. Weather fields are not in
/// DiveSummary, so no DiveStore commit is needed.
@MainActor
enum WeatherBatchFetcher {
    static let logger = Logger(subsystem: "com.bluedive.app", category: "Weather")

    /// Runs the fetch in the calling task (cancel that task to stop) and returns the final
    /// status; `progress` receives each `.running` update.
    /// - Parameters:
    ///   - replaceExistingIDs: dives whose fetched values replace existing ones; every other
    ///     dive only gets its empty fields filled.
    static func run(ids: [PersistentIdentifier],
                    replaceExistingIDs: Set<PersistentIdentifier>,
                    container: ModelContainer,
                    progress: (WeatherBatchFetchStatus) -> Void) async -> WeatherBatchFetchStatus {
        let context = ModelContext(container)
        context.author = "BlueDive.weather"
        context.autosaveEnabled = false
        logger.info("Weather fetch started for \(ids.count) dives (replace \(replaceExistingIDs.count), fill-only \(ids.count - replaceExistingIDs.count))")
        progress(.running(done: 0, total: ids.count))

        var filled = 0          // dives whose values changed and were saved
        var withData = 0        // dives Open-Meteo returned values for
        var stillEmpty = 0      // dives left with an empty field Open-Meteo had no value for
        var unsaved = 0         // changed dives not saved yet
        var saveFailed = false
        enum Stop { case offline, unavailable, cancelled }
        var stop: Stop?
        var done = 0            // dives processed, for the debug log of an early stop

        /// Saves pending changes; on failure discards them (this context only).
        func flush() {
            guard unsaved > 0 else { return }
            do {
                try context.save()
                filled += unsaved
            } catch {
                logger.error("Weather save failed: \(error.localizedDescription)")
                context.rollback()
                saveFailed = true
            }
            unsaved = 0
        }
        /// The dive with this ID, or nil if it no longer exists (deleted meanwhile).
        func dive(_ id: PersistentIdentifier) -> Dive? {
            var descriptor = FetchDescriptor<Dive>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor))?.first
        }

        loop: for (index, id) in ids.enumerated() {
            if Task.isCancelled { stop = .cancelled; break loop }
            // Looked up before and after each request: the dive may be deleted meanwhile.
            if let current = dive(id) {
                do {
                    let fetched = try await OpenMeteoWeatherService.fetch(for: current)
                    if Task.isCancelled { stop = .cancelled; break loop }
                    // Counted only once the dive is confirmed still there.
                    if let target = dive(id) {
                        withData += 1
                        let replacesExisting = replaceExistingIDs.contains(id)
                        var result: String
                        if fetched.apply(to: target, replaceExisting: replacesExisting) {
                            unsaved += 1
                            result = "updated (\(replacesExisting ? "replace" : "fill-only"))"
                        } else {
                            result = "unchanged (values already stored)"
                        }
                        let emptyFields = target.emptyWeatherFieldNames
                        if !emptyFields.isEmpty {
                            stillEmpty += 1
                            result += "; still empty: \(emptyFields.joined(separator: ", ")) (Open-Meteo had no value)"
                        }
                        logger.info("Dive from \(target.timestamp) weather: \(result, privacy: .public)")
                    } else {
                        logger.info("Weather fetch: dive deleted during its request — skipped")
                    }
                } catch is CancellationError {
                    stop = .cancelled; break loop
                } catch OpenMeteoWeatherError.noData {
                    // No data for this dive (e.g. too recent or in the future): go on.
                    logger.info("Dive from \(current.timestamp) weather: no data from Open-Meteo")
                } catch OpenMeteoWeatherError.serviceUnavailable {
                    stop = .unavailable; break loop
                } catch {
                    stop = Task.isCancelled ? .cancelled : .offline; break loop
                }
            } else {
                logger.info("Weather fetch: dive deleted before its request — skipped")
            }
            done = index + 1
            if unsaved >= 10 { flush() }
            if saveFailed { break loop }
            progress(.running(done: done, total: ids.count))
            // A short pause between requests, to stay well within Open-Meteo's limits.
            if index + 1 < ids.count, (try? await Task.sleep(for: .milliseconds(150))) == nil {
                stop = .cancelled; break loop
            }
        }
        // Also on every early stop, including a cancel.
        flush()
        if saveFailed {
            logger.info("Weather fetch ended after \(done) of \(ids.count) dives: save failed (saved \(filled))")
            return .saveFailed(filled: filled)
        }
        switch stop {
        case .offline:
            logger.info("Weather fetch stopped after \(done) of \(ids.count) dives: offline (saved \(filled))")
            return .stoppedOffline(filled: filled)
        case .unavailable:
            logger.info("Weather fetch stopped after \(done) of \(ids.count) dives: service unavailable (saved \(filled))")
            return .stoppedUnavailable(filled: filled)
        case .cancelled:
            logger.info("Weather fetch stopped after \(done) of \(ids.count) dives: cancelled (saved \(filled))")
            return .interrupted(filled: filled)
        case nil:
            logger.info("Weather fetch finished: updated \(filled), with data \(withData), still empty \(stillEmpty), of \(ids.count)")
            return .finished(filled: filled, withData: withData, stillEmpty: stillEmpty, total: ids.count)
        }
    }
}
