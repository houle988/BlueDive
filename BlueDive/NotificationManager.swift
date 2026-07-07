import Foundation
import UserNotifications
import SwiftData

class NotificationManager: NSObject {
    static let shared = NotificationManager()

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
                print("✅ Notifications authorized")
            }
            return granted
        } catch {
            print("❌ Notification authorization error: \(error)")
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
            print("⚠️ No service date set for \(gear.name) - notification skipped")
            return
        }

        let content = UNMutableNotificationContent()
        let gearBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("🛠️ Service Required", bundle: gearBundle, comment: "")
        content.body = String(format: NSLocalizedString("%@ requires servicing in 30 days.", bundle: gearBundle, comment: ""), gear.name)
        content.sound = .default
        content.categoryIdentifier = "GEAR_MAINTENANCE"
        content.userInfo = [
            "gearId": gear.id.uuidString,
            "type": "maintenance",
            "gearName": gear.name,
            "dueDateTimestamp": nextServiceDate.timeIntervalSince1970
        ]

        // Notification 30 days before the scheduled service date, at 9:00 AM
        let calendar = Calendar.current
        if let reminderDate = calendar.date(byAdding: .day, value: -30, to: nextServiceDate),
           reminderDate > Date() {
            // Cancel only when a replacement is being scheduled — this preserves any active
            // snooze (a UNTimeIntervalNotificationTrigger) that shares the same identifier.
            cancelNotification(identifier: "gear-\(gear.id.uuidString)")
            var components = calendar.dateComponents([.year, .month, .day], from: reminderDate)
            components.hour = 9
            components.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "gear-\(gear.id.uuidString)", content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Notification error: \(error)")
                } else {
                    print("✅ Notification scheduled for \(gear.name) - 30 days before \(nextServiceDate.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        } else {
            print("⚠️ Service date too close or already passed for \(gear.name) - notification not scheduled")
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

        let calendar = Calendar.current

        // Notification 30 days before
        if let date30 = calendar.date(byAdding: .day, value: -30, to: expirationDate), date30 > Date() {
            scheduleExpirationNotification(
                for: cert,
                date: date30,
                daysRemaining: 30,
                identifier: "cert-30-\(cert.id.uuidString)"
            )
        }
    }

    private func scheduleExpirationNotification(for cert: Certification, date: Date, daysRemaining: Int, identifier: String) {
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
                print("❌ Certification notification error: \(error)")
            } else {
                print("✅ Notification scheduled for \(cert.name) - \(daysRemaining) days")
            }
        }
    }

    // MARK: - Milestone Achievement

    func notifyMilestoneAchieved(totalDives: Int) {
        let milestones = [100, 250, 500, 1000, 1500, 2000, 2500, 3000, 4000, 5000]
        let key = "lastMilestoneNotified"
        let last = UserDefaults.standard.integer(forKey: key)

        // Find the highest milestone that is ≤ totalDives and > last celebrated.
        // Using > last (not >=) prevents re-notifying on the same value.
        // Using max() over the filtered range handles bulk imports that skip milestones.
        guard let reached = milestones.filter({ $0 <= totalDives && $0 > last }).max() else { return }

        let content = UNMutableNotificationContent()
        let milestoneBundle = Bundle.forAppLanguage()
        content.title = NSLocalizedString("🏆 Milestone Reached!", bundle: milestoneBundle, comment: "")
        content.body = String(format: NSLocalizedString("Congratulations! You've completed %lld dives! 🎉", bundle: milestoneBundle, comment: ""), Int64(reached))
        content.sound = .default
        content.categoryIdentifier = "MILESTONE"

        let request = UNNotificationRequest(identifier: "milestone-\(reached)", content: content, trigger: nil)

        // Write the key only on successful delivery so that a denied/failed add
        // (e.g. system permission revoked) doesn't permanently consume the milestone.
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Milestone notification error: \(error)")
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

    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Cancels all pending notifications whose identifier starts with the given prefix.
    func cancelNotifications(withPrefix prefix: String) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
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

        UNUserNotificationCenter.current().setNotificationCategories([
            maintenanceCategory,
            certificationCategory
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

        // Recalculate body with the actual days remaining at the new fire time
        let fireDate = Date().addingTimeInterval(delay)
        let bundle = Bundle.forAppLanguage()

        if let type = originalContent.userInfo["type"] as? String,
           let timestamp = originalContent.userInfo["dueDateTimestamp"] as? TimeInterval {
            let dueDate = Date(timeIntervalSince1970: timestamp)
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
            default:
                break
            }
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: newContent, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Reschedule error: \(error)")
            } else {
                let days = Int(delay / 86400)
                print("✅ Notification rescheduled for \(days) day(s) from now")
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
