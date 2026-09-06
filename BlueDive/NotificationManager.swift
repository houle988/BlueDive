import Foundation
import OSLog
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()
    private static let logger = Logger(subsystem: "com.bluedive.app", category: "Notifications")

    private override init() {
        super.init()
    }

    // MARK: - Badge Management

    func refreshBadgeCount() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let count = delivered.count
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                Self.logger.info("Notifications authorized")
            }
            return granted
        } catch {
            Self.logger.error("Notification authorization error: \(error)")
            return false
        }
    }

    // MARK: - Gear Maintenance Notifications

    func scheduleGearMaintenanceReminders(for gearList: [Gear]) {
        // Schedule notifications ONLY for gear that has
        // a user-defined nextServiceDue date
        for gear in gearList where gear.nextServiceDue != nil {
            scheduleGearMaintenanceReminder(for: gear)
        }
    }

    func scheduleGearMaintenanceReminder(for gear: Gear) {
        // Only schedule a notification if the user has set a service date
        guard let nextServiceDate = gear.nextServiceDue else {
            Self.logger.warning("No service date set for \(gear.name) — notification skipped")
            return
        }

        let identifier = "gear-\(gear.id.uuidString)"
        let catchUpKey = "gearCatchupFired-\(gear.id.uuidString)"
        let now = Date()
        let calendar = Calendar.current

        if let reminderDate = calendar.date(byAdding: .day, value: -30, to: nextServiceDate), reminderDate > now {
            // Normal path: fire 30 days before the service date. Record the marker (keyed
            // to this service date) so the catch-up branch won't add a second reminder once
            // the 30-day reminder is in place. A new service date changes the key, so it
            // re-notifies. Adding with the same identifier replaces any prior pending request.
            scheduleGearMaintenanceNotification(
                for: gear,
                date: reminderDate,
                daysRemaining: 30,
                useFixedBody: true,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: nextServiceDate.timeIntervalSince1970
            )
        } else {
            // Catch-up: service is due within 30 days or already overdue. Fire once per
            // service date (at the next 9:00 AM) instead of silently skipping. The marker
            // guard means we only reach the scheduling call when no reminder — and therefore
            // no active snooze — exists yet, so an existing snooze is preserved.
            guard UserDefaults.standard.double(forKey: catchUpKey) != nextServiceDate.timeIntervalSince1970 else { return }
            let fireDate = nextReminderDate(after: now, calendar: calendar)
            let days = max(0, calendarDays(from: fireDate, to: nextServiceDate, calendar: calendar))
            scheduleGearMaintenanceNotification(
                for: gear,
                date: fireDate,
                daysRemaining: days,
                useFixedBody: false,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: nextServiceDate.timeIntervalSince1970
            )
        }
    }

    private func scheduleGearMaintenanceNotification(for gear: Gear, date: Date, daysRemaining: Int, useFixedBody: Bool, identifier: String, catchUpKey: String? = nil, catchUpValue: Double? = nil) {
        let content = UNMutableNotificationContent()
        let gearBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("🛠️ Service Required", bundle: gearBundle, comment: "")
        if useFixedBody {
            content.body = String(format: NSLocalizedString("%@ requires servicing in 30 days.", bundle: gearBundle, comment: ""), gear.name)
        } else {
            content.body = String(format: NSLocalizedString("%@ requires servicing in %lld days.", bundle: gearBundle, comment: ""), gear.name, Int64(daysRemaining))
        }
        content.sound = .default
        content.categoryIdentifier = "GEAR_MAINTENANCE"
        content.userInfo = [
            "gearId": gear.id.uuidString,
            "type": "maintenance",
            "gearName": gear.name,
            "dueDateTimestamp": (gear.nextServiceDue ?? date).timeIntervalSince1970
        ]

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("Gear maintenance notification error for \(gear.name): \(error)")
            } else {
                Self.logger.info("Maintenance notification scheduled for \(gear.name) — \(daysRemaining) days")
                if let catchUpKey, let catchUpValue {
                    UserDefaults.standard.set(catchUpValue, forKey: catchUpKey)
                }
            }
        }
    }

    // MARK: - Certification Expiration

    func scheduleCertificationReminders(for certs: [Certification]) {
        for cert in certs {
            scheduleCertificationExpirationReminder(for: cert)
        }
    }

    func scheduleCertificationExpirationReminder(for cert: Certification) {
        guard let expirationDate = cert.expirationDate else { return }
        let identifier = "cert-30-\(cert.id.uuidString)"
        let catchUpKey = "certCatchupFired-\(cert.id.uuidString)"
        let now = Date()
        let calendar = Calendar.current

        // Already expired: clear any stale reminder + catch-up marker and stop.
        guard expirationDate > now else {
            cancelNotification(identifier: identifier)
            UserDefaults.standard.removeObject(forKey: catchUpKey)
            return
        }

        if let date30 = calendar.date(byAdding: .day, value: -30, to: expirationDate), date30 > now {
            // Normal path: fire 30 days before expiry. Record the marker (keyed to this
            // expiry date) so the catch-up branch won't add a second reminder once the
            // 30-day reminder is in place. A genuine renewal to a new date changes the
            // key, so it will re-notify.
            scheduleExpirationNotification(
                for: cert,
                date: date30,
                daysRemaining: 30,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: expirationDate.timeIntervalSince1970
            )
        } else {
            // Catch-up: already inside the 30-day window. Fire once per expiry date
            // (at the next 9:00 AM) instead of silently skipping.
            guard UserDefaults.standard.double(forKey: catchUpKey) != expirationDate.timeIntervalSince1970 else { return }
            let fireDate = nextReminderDate(after: now, calendar: calendar)
            let days = max(0, calendarDays(from: fireDate, to: expirationDate, calendar: calendar))
            scheduleExpirationNotification(
                for: cert,
                date: fireDate,
                daysRemaining: days,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: expirationDate.timeIntervalSince1970
            )
        }
    }

    private func scheduleExpirationNotification(for cert: Certification, date: Date, daysRemaining: Int, identifier: String, catchUpKey: String? = nil, catchUpValue: Double? = nil) {
        let content = UNMutableNotificationContent()
        let certBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("⚠️ Certification Expiring", bundle: certBundle, comment: "")
        content.body = String(format: NSLocalizedString("Your %@ certification expires in %lld days.", bundle: certBundle, comment: ""), cert.name, Int64(daysRemaining))

        content.sound = .default
        content.categoryIdentifier = "CERTIFICATION_EXPIRATION"
        content.userInfo = [
            "certId": cert.id.uuidString,
            "type": "expiration",
            "certName": cert.name,
            "dueDateTimestamp": (cert.expirationDate ?? Date()).timeIntervalSince1970
        ]

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("Certification notification error for \(cert.name): \(error)")
            } else {
                Self.logger.info("Certification notification scheduled for \(cert.name) — \(daysRemaining) days")
                if let catchUpKey, let catchUpValue {
                    UserDefaults.standard.set(catchUpValue, forKey: catchUpKey)
                }
            }
        }
    }

    // MARK: - Insurance Expiration

    func scheduleInsuranceReminders(for insurances: [DivingInsurance]) {
        for insurance in insurances {
            scheduleInsuranceExpirationReminder(for: insurance)
        }
    }

    func scheduleInsuranceExpirationReminder(for insurance: DivingInsurance) {
        let identifier = "insurance-30-\(insurance.id.uuidString)"
        let catchUpKey = "insuranceCatchupFired-\(insurance.id.uuidString)"
        let now = Date()
        let calendar = Calendar.current

        // Already expired: clear any stale reminder + catch-up marker and stop.
        guard insurance.endDate > now else {
            cancelNotification(identifier: identifier)
            UserDefaults.standard.removeObject(forKey: catchUpKey)
            return
        }

        if let date30 = calendar.date(byAdding: .day, value: -30, to: insurance.endDate), date30 > now {
            // Normal path: fire 30 days before expiry. Record the marker (keyed to this
            // expiry date) so the catch-up branch won't add a second reminder once the
            // 30-day reminder is in place. A genuine renewal to a new date changes the
            // key, so it will re-notify.
            scheduleInsuranceExpirationNotification(
                for: insurance,
                date: date30,
                daysRemaining: 30,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: insurance.endDate.timeIntervalSince1970
            )
        } else {
            // Catch-up: already inside the 30-day window. Fire once per expiry date
            // (at the next 9:00 AM) instead of silently skipping.
            guard UserDefaults.standard.double(forKey: catchUpKey) != insurance.endDate.timeIntervalSince1970 else { return }
            let fireDate = nextReminderDate(after: now, calendar: calendar)
            let days = max(0, calendarDays(from: fireDate, to: insurance.endDate, calendar: calendar))
            scheduleInsuranceExpirationNotification(
                for: insurance,
                date: fireDate,
                daysRemaining: days,
                identifier: identifier,
                catchUpKey: catchUpKey,
                catchUpValue: insurance.endDate.timeIntervalSince1970
            )
        }
    }

    private func scheduleInsuranceExpirationNotification(for insurance: DivingInsurance, date: Date, daysRemaining: Int, identifier: String, catchUpKey: String? = nil, catchUpValue: Double? = nil) {
        let content = UNMutableNotificationContent()
        let insuranceBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("⚠️ Insurance Expiring", bundle: insuranceBundle, value: "⚠️ Insurance Expiring", comment: "")
        content.body = String(format: NSLocalizedString("Your %@ insurance expires in %lld days.", bundle: insuranceBundle, value: "Your %@ insurance expires in %lld days.", comment: ""), insurance.insurerName, Int64(daysRemaining))

        content.sound = .default
        content.categoryIdentifier = "INSURANCE_EXPIRATION"
        content.userInfo = [
            "insuranceId": insurance.id.uuidString,
            "type": "insuranceExpiration",
            "insuranceName": insurance.insurerName,
            "dueDateTimestamp": insurance.endDate.timeIntervalSince1970
        ]

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("Insurance notification error for \(insurance.insurerName): \(error)")
            } else {
                Self.logger.info("Insurance notification scheduled for \(insurance.insurerName) — \(daysRemaining) days")
                if let catchUpKey, let catchUpValue {
                    UserDefaults.standard.set(catchUpValue, forKey: catchUpKey)
                }
            }
        }
    }

    // MARK: - Reminder Date Helpers

    /// The next 9:00 AM at or after `date` — today if it is currently before 9 AM, otherwise tomorrow.
    private func nextReminderDate(after date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 9
        comps.minute = 0
        let todayNine = calendar.date(from: comps) ?? date
        if todayNine > date { return todayNine }
        return calendar.date(byAdding: .day, value: 1, to: todayNine) ?? todayNine
    }

    /// Whole calendar days from start-of-day(`from`) to start-of-day(`to`).
    private func calendarDays(from: Date, to: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    // MARK: - Milestone Achievement

    func notifyMilestoneAchieved(totalDives: Int) {
        let key = "lastMilestoneNotified"
        let last = UserDefaults.standard.integer(forKey: key)

        // Find the highest milestone > last celebrated using the shared tier grid.
        // max() over the filtered range handles bulk imports that skip milestones.
        guard let reached = diveMilestones(upTo: totalDives).filter({ $0 > last }).max() else { return }

        let content = UNMutableNotificationContent()
        let milestoneBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("🏆 Milestone Reached!", bundle: milestoneBundle, comment: "")
        content.body = String(format: NSLocalizedString("Congratulations! You've completed %@ dives! 🎉", bundle: milestoneBundle, comment: ""), Double(reached).localizedString(decimals: 0))
        content.sound = .default
        content.categoryIdentifier = "MILESTONE"

        let request = UNNotificationRequest(identifier: "milestone-\(reached)", content: content, trigger: nil)

        // Write the key only on successful delivery so that a denied/failed add
        // (e.g. system permission revoked) doesn't permanently consume the milestone.
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("Milestone notification error: \(error)")
            } else {
                UserDefaults.standard.set(reached, forKey: key)
            }
        }
    }

    // MARK: - Badge Management

    func clearBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: - Cancel Notifications

    func cancelNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Cancels a gear item's maintenance reminder and clears its one-time catch-up marker.
    /// Call this when a gear item is deleted or loses its service date.
    func cancelGearReminder(id: UUID) {
        cancelNotification(identifier: "gear-\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "gearCatchupFired-\(id.uuidString)")
    }

    /// Cancels a certification's expiration reminder and clears its one-time catch-up marker.
    /// Call this when a certification is deleted or loses its expiration date.
    func cancelCertificationReminder(id: UUID) {
        cancelNotification(identifier: "cert-30-\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "certCatchupFired-\(id.uuidString)")
    }

    /// Cancels an insurance policy's expiration reminder and clears its one-time catch-up marker.
    /// Call this when an insurance policy is deleted.
    func cancelInsuranceReminder(id: UUID) {
        cancelNotification(identifier: "insurance-30-\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "insuranceCatchupFired-\(id.uuidString)")
    }

    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Removes every one-time catch-up marker. Call this ONLY when all reminder-bearing
    /// records are wiped (e.g. "Delete All Data") — never on a simple notifications-off
    /// toggle, which must preserve the already-fired state so re-enabling doesn't re-nag.
    func clearAllCatchUpMarkers() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("gearCatchupFired-")
               || key.hasPrefix("certCatchupFired-")
               || key.hasPrefix("insuranceCatchupFired-") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Cancels all pending notifications whose identifier starts with the given prefix.
    func cancelNotifications(withPrefix prefix: String) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Cancels pending reminders (and clears markers) for records that no longer exist —
    /// e.g. deleted on another device and removed locally via CloudKit sync, where no
    /// in-app delete handler ran to call `cancel…Reminder(id:)`. Pass the current valid IDs.
    func reconcilePendingReminders(gearIDs: Set<UUID>, certIDs: Set<UUID>, insuranceIDs: Set<UUID>) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        var orphanIDs: [String] = []
        for request in pending {
            let identifier = request.identifier
            if let uuid = uuid(from: identifier, prefix: "gear-"), !gearIDs.contains(uuid) {
                orphanIDs.append(identifier)
                UserDefaults.standard.removeObject(forKey: "gearCatchupFired-\(uuid.uuidString)")
            } else if let uuid = uuid(from: identifier, prefix: "cert-30-"), !certIDs.contains(uuid) {
                orphanIDs.append(identifier)
                UserDefaults.standard.removeObject(forKey: "certCatchupFired-\(uuid.uuidString)")
            } else if let uuid = uuid(from: identifier, prefix: "insurance-30-"), !insuranceIDs.contains(uuid) {
                orphanIDs.append(identifier)
                UserDefaults.standard.removeObject(forKey: "insuranceCatchupFired-\(uuid.uuidString)")
            }
        }
        guard !orphanIDs.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: orphanIDs)
        Self.logger.info("Reconciled \(orphanIDs.count) orphaned reminder(s)")
    }

    /// Extracts the trailing UUID from an identifier with the given prefix, or nil if it
    /// doesn't match (e.g. a `milestone-…` id or an unparseable suffix).
    private func uuid(from identifier: String, prefix: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
    }

    // MARK: - Check Permissions

    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }
}

// MARK: - Notification Categories

extension NotificationManager {
    func setupNotificationCategories() {
        // Actions for gear maintenance
        let markAsDoneAction = UNNotificationAction(
            identifier: "MARK_DONE",
            title: NSLocalizedString("Open", bundle: Bundle.forAppLanguage(), comment: "Notification action button that opens the gear's service view"),
            options: .foreground
        )

        let remindOneDayAction = UNNotificationAction(
            identifier: "REMIND_1_DAY",
            title: NSLocalizedString("Remind in 1 Day", bundle: Bundle.forAppLanguage(), comment: ""),
            options: []
        )

        let remindOneWeekAction = UNNotificationAction(
            identifier: "REMIND_1_WEEK",
            title: NSLocalizedString("Remind in 1 Week", bundle: Bundle.forAppLanguage(), comment: ""),
            options: []
        )

        let remindOneMonthAction = UNNotificationAction(
            identifier: "REMIND_1_MONTH",
            title: NSLocalizedString("Remind in 1 Month", bundle: Bundle.forAppLanguage(), comment: ""),
            options: []
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: NSLocalizedString("Dismiss", bundle: Bundle.forAppLanguage(), comment: ""),
            options: .destructive
        )

        let maintenanceCategory = UNNotificationCategory(
            identifier: "GEAR_MAINTENANCE",
            actions: [markAsDoneAction, remindOneDayAction, remindOneWeekAction, remindOneMonthAction, dismissAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        // Actions for certifications
        let renewAction = UNNotificationAction(
            identifier: "RENEW",
            title: NSLocalizedString("Renew", bundle: Bundle.forAppLanguage(), comment: ""),
            options: .foreground
        )

        let certificationCategory = UNNotificationCategory(
            identifier: "CERTIFICATION_EXPIRATION",
            actions: [renewAction, remindOneDayAction, remindOneWeekAction, remindOneMonthAction, dismissAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        // Actions for insurance
        let renewInsuranceAction = UNNotificationAction(
            identifier: "RENEW_INSURANCE",
            title: NSLocalizedString("Renew", bundle: Bundle.forAppLanguage(), comment: ""),
            options: .foreground
        )

        let insuranceCategory = UNNotificationCategory(
            identifier: "INSURANCE_EXPIRATION",
            actions: [renewInsuranceAction, remindOneDayAction, remindOneWeekAction, remindOneMonthAction, dismissAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            maintenanceCategory,
            certificationCategory,
            insuranceCategory
        ])
    }
}

// MARK: - Notification Delegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Allow notifications to display even when the app is in the foreground
        completionHandler([.banner, .sound])

        // Count delivered notifications, excluding the one being presented (it may or may not
        // already be in the delivered list depending on timing), then add 1 for this one.
        let presentingId = notification.request.identifier
        Task {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let count = delivered.filter { $0.request.identifier != presentingId }.count + 1
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let identifier = response.notification.request.identifier

        // Handle primary action buttons
        switch response.actionIdentifier {
        case "MARK_DONE":
            if let gearId = content.userInfo["gearId"] as? String {
                cancelNotification(identifier: "gear-\(gearId)")
                UserDefaults.standard.set(gearId, forKey: "pendingGearDeepLink")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingGearDeepLinkTime")
                NotificationCenter.default.post(name: .openEquipmentForService, object: gearId)
            }
        case "RENEW":
            if let certId = content.userInfo["certId"] as? String {
                cancelNotification(identifier: "cert-30-\(certId)")
                UserDefaults.standard.set(certId, forKey: "pendingCertDeepLink")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingCertDeepLinkTime")
                NotificationCenter.default.post(name: .openCertificationsForRenewal, object: certId)
            }
        case "RENEW_INSURANCE":
            if let insuranceId = content.userInfo["insuranceId"] as? String {
                cancelNotification(identifier: "insurance-30-\(insuranceId)")
                UserDefaults.standard.set(insuranceId, forKey: "pendingInsuranceDeepLink")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingInsuranceDeepLinkTime")
                NotificationCenter.default.post(name: .openInsuranceForRenewal, object: insuranceId)
            }
        case "DISMISS":
            break  // OS already dismissed the notification; nothing to do
        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification body — same behaviour as the primary open action
            switch content.categoryIdentifier {
            case "GEAR_MAINTENANCE":
                if let gearId = content.userInfo["gearId"] as? String {
                    cancelNotification(identifier: "gear-\(gearId)")
                    UserDefaults.standard.set(gearId, forKey: "pendingGearDeepLink")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingGearDeepLinkTime")
                    NotificationCenter.default.post(name: .openEquipmentForService, object: gearId)
                }
            case "CERTIFICATION_EXPIRATION":
                if let certId = content.userInfo["certId"] as? String {
                    cancelNotification(identifier: "cert-30-\(certId)")
                    UserDefaults.standard.set(certId, forKey: "pendingCertDeepLink")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingCertDeepLinkTime")
                    NotificationCenter.default.post(name: .openCertificationsForRenewal, object: certId)
                }
            case "INSURANCE_EXPIRATION":
                if let insuranceId = content.userInfo["insuranceId"] as? String {
                    cancelNotification(identifier: "insurance-30-\(insuranceId)")
                    UserDefaults.standard.set(insuranceId, forKey: "pendingInsuranceDeepLink")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pendingInsuranceDeepLinkTime")
                    NotificationCenter.default.post(name: .openInsuranceForRenewal, object: insuranceId)
                }
            default:
                break
            }
        default:
            break
        }

        let delayInterval: TimeInterval? = switch response.actionIdentifier {
        case "REMIND_1_DAY":   1 * 86400
        case "REMIND_1_WEEK":  7 * 86400
        case "REMIND_1_MONTH": 30 * 86400
        default: nil
        }

        if let delayInterval {
            rescheduleNotification(originalContent: content, identifier: identifier, delay: delayInterval)
        }

        // Update badge to reflect remaining delivered notifications
        Task { await refreshBadgeCount() }

        completionHandler()
    }

    private func rescheduleNotification(originalContent: UNNotificationContent, identifier: String, delay: TimeInterval) {
        let newContent = originalContent.mutableCopy() as! UNMutableNotificationContent

        let now = Date()
        let calendar = Calendar.current
        // Recalculate body with the actual days remaining at the new fire time
        var fireDate = now.addingTimeInterval(delay)
        let bundle = Bundle.forAppLanguage()

        if let type = originalContent.userInfo["type"] as? String,
           let timestamp = originalContent.userInfo["dueDateTimestamp"] as? TimeInterval {
            let dueDate = Date(timeIntervalSince1970: timestamp)

            // Never remind after the deadline: if the snooze would land on or after the
            // due date, fire one last reminder at 9:00 AM on the due date instead.
            if fireDate >= dueDate {
                var dueComps = calendar.dateComponents([.year, .month, .day], from: dueDate)
                dueComps.hour = 9
                dueComps.minute = 0
                fireDate = calendar.date(from: dueComps) ?? dueDate
            }

            let daysRemaining = max(0, Int(dueDate.timeIntervalSince(fireDate) / 86400))

            switch type {
            case "maintenance":
                if let name = originalContent.userInfo["gearName"] as? String {
                    newContent.body = String(format: NSLocalizedString("%@ requires servicing in %lld days.", bundle: bundle, comment: ""), name, Int64(daysRemaining))
                }
            case "expiration":
                if let name = originalContent.userInfo["certName"] as? String {
                    newContent.body = String(format: NSLocalizedString("Your %@ certification expires in %lld days.", bundle: bundle, comment: ""), name, Int64(daysRemaining))
                }
            case "insuranceExpiration":
                if let name = originalContent.userInfo["insuranceName"] as? String {
                    newContent.body = String(format: NSLocalizedString("Your %@ insurance expires in %lld days.", bundle: bundle, comment: ""), name, Int64(daysRemaining))
                }
            default:
                break
            }
        }

        // If the (possibly clamped) fire date is not in the future, the deadline has
        // already passed — there is nothing useful left to remind about.
        let interval = fireDate.timeIntervalSince(now)
        guard interval > 0 else {
            Self.logger.info("Snooze skipped — deadline already reached for \(identifier)")
            return
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: newContent, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Self.logger.error("Reschedule notification error: \(error)")
            } else {
                let days = Int(interval / 86400)
                Self.logger.info("Notification rescheduled for \(days) day(s) from now")
            }
        }
    }
}

// MARK: - Helper Extensions

extension Gear {
    /// Schedules a maintenance notification ONLY if notifications are enabled and a service date is set.
    func scheduleMaintenanceReminder() {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
              UserDefaults.standard.object(forKey: "gearMaintenanceReminders") as? Bool ?? true,
              nextServiceDue != nil else { return }
        NotificationManager.shared.scheduleGearMaintenanceReminder(for: self)
    }
}

extension Certification {
    func scheduleExpirationReminder() {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
              UserDefaults.standard.object(forKey: "certificationReminders") as? Bool ?? true else { return }
        NotificationManager.shared.scheduleCertificationExpirationReminder(for: self)
    }
}

extension DivingInsurance {
    func scheduleExpirationReminder() {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
              UserDefaults.standard.object(forKey: "insuranceReminders") as? Bool ?? true else { return }
        NotificationManager.shared.scheduleInsuranceExpirationReminder(for: self)
    }
}
