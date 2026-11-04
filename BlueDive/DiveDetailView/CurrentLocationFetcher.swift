//
//  CurrentLocationFetcher.swift
//  BlueDive
//

import CoreLocation

/// One-shot lookup of the device's current position, for the "Use Current Location" rows of
/// Edit Site Details. Uses Core Location's async updates (no delegate); When-In-Use
/// authorization is asked for the first time (service session on iOS, location manager on macOS).
enum CurrentLocationFetcher {
    enum Failure: Error {
        /// Location access is denied or restricted for the app, or Location Services are off.
        case denied
        /// No position accurate enough arrived before the timeout.
        case unavailable
    }

    /// A fix at or below this horizontal accuracy (metres) is used at once.
    nonisolated static let targetAccuracy: CLLocationAccuracy = 50
    /// When no fix reaches `targetAccuracy` before the timeout, the best one is used only if it
    /// is within this accuracy (Wi-Fi positioning on a Mac is often 50–100 m). Coarser fixes,
    /// e.g. with Precise Location off, are rejected rather than saved as a dive site.
    nonisolated static let acceptableAccuracy: CLLocationAccuracy = 200
    /// Fixes older than this (seconds) are a cached position, not the current one.
    nonisolated static let maximumAge: TimeInterval = 30

    /// Throws `CancellationError` when the calling task is cancelled, `Failure` otherwise.
    @MainActor
    static func fetch(timeout: Duration = .seconds(15)) async throws -> CLLocationCoordinate2D {
        #if os(macOS)
        // CLServiceSession is unavailable on macOS: request authorization explicitly (as
        // DiveMapView does); the manager must stay alive until the prompt is answered.
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        defer { withExtendedLifetime(manager) {} }
        #else
        // Keep the session alive for the whole lookup: it carries the authorization request.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        #endif

        let state = LookupState()
        let result: Result<CLLocationCoordinate2D, Failure>? = await withTaskGroup(
            of: Result<CLLocationCoordinate2D, Failure>?.self
        ) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        await state.setAwaitingAuthorization(update.authorizationRequestInProgress)
                        if update.authorizationDenied || update.authorizationDeniedGlobally
                            || update.authorizationRestricted {
                            return .failure(.denied)
                        }
                        guard let location = update.location,
                              location.horizontalAccuracy >= 0,
                              -location.timestamp.timeIntervalSinceNow <= maximumAge else { continue }
                        if location.horizontalAccuracy <= targetAccuracy {
                            return .success(location.coordinate)
                        }
                        await state.offer(location)
                    }
                } catch {
                    return .failure(.unavailable)
                }
                return nil
            }
            group.addTask {
                // Count only the time not spent on the permission prompt, so a user who takes
                // a while to answer it still gets the full timeout to find a position.
                let tick: Duration = .milliseconds(250)
                var elapsed: Duration = .zero
                while elapsed < timeout {
                    do { try await Task.sleep(for: tick) } catch { return nil }
                    if await !state.awaitingAuthorization { elapsed += tick }
                }
                return nil
            }
            // The first task to finish wins; a nil from the timer means "time is up".
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        // Cancelled by the caller (e.g. the sheet closed): never hand back a position.
        try Task.checkCancellation()

        switch result {
        case .success(let coordinate):
            return coordinate
        case .failure(let failure):
            throw failure
        case nil:
            if let location = await state.location,
               location.horizontalAccuracy <= acceptableAccuracy {
                return location.coordinate
            }
            throw Failure.unavailable
        }
    }

    /// Shared between the update loop and the timeout: the most accurate fix seen so far, and
    /// whether the permission prompt is showing (the timeout does not count that time).
    private actor LookupState {
        private(set) var location: CLLocation?
        private(set) var awaitingAuthorization = false

        func offer(_ candidate: CLLocation) {
            if let location, location.horizontalAccuracy <= candidate.horizontalAccuracy { return }
            location = candidate
        }

        func setAwaitingAuthorization(_ value: Bool) {
            awaitingAuthorization = value
        }
    }
}
