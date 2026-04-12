import Foundation
import UserNotifications
import SwiftData

class NotificationManager: NSObject {
    static let shared = NotificationManager()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Badge Management
    
    /// Updates the app badge to reflect the number of delivered notifications.
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
        
        // Cancel any existing notification for this gear
        cancelNotification(identifier: "gear-\(gear.id.uuidString)")
        
        let content = UNMutableNotificationContent()
        content.title = String(localized: "🛠️ Service Required")
        content.body = String(localized: "\(gear.name) requires servicing in 30 days.")
        content.sound = .default
        content.categoryIdentifier = "GEAR_MAINTENANCE"
        content.userInfo = ["gearId": gear.id.uuidString, "type": "maintenance"]
        
        // Notification 30 days before the scheduled service date, at 9:00 AM
        let calendar = Calendar.current
        if let reminderDate = calendar.date(byAdding: .day, value: -30, to: nextServiceDate),
           reminderDate > Date() {
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
        content.title = String(localized: "⚠️ Certification Expiring")
        content.body = String(localized: "Your \(cert.name) certification expires in \(daysRemaining) days.")
        
        content.sound = .default
        content.categoryIdentifier = "CERTIFICATION_EXPIRATION"
        content.userInfo = ["certId": cert.id.uuidString, "type": "expiration"]
        
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
        
        guard milestones.contains(totalDives) else { return }
        
        let content = UNMutableNotificationContent()
        content.title = String(localized: "🏆 Milestone Reached!")
        content.body = String(localized: "Congratulations! You've completed \(totalDives) dives! \u{1F389}")
        content.sound = .default
        content.categoryIdentifier = "MILESTONE"
        
        let request = UNNotificationRequest(identifier: "milestone-\(totalDives)", content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Badge Management
    
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
    
    // MARK: - Cancel Notifications
    
    func cancelNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
    
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
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
            title: String(localized: "Mark as Done"),
            options: .foreground
        )
        
        let remindOneDayAction = UNNotificationAction(
            identifier: "REMIND_1_DAY",
            title: String(localized: "Remind in 1 Day"),
            options: []
        )
        
        let remindOneWeekAction = UNNotificationAction(
            identifier: "REMIND_1_WEEK",
            title: String(localized: "Remind in 1 Week"),
            options: []
        )
        
        let remindOneMonthAction = UNNotificationAction(
            identifier: "REMIND_1_MONTH",
            title: String(localized: "Remind in 1 Month"),
            options: []
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: String(localized: "Dismiss"),
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
            title: String(localized: "Renew"),
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
        
        // Update badge to reflect total delivered notifications
        Task { await refreshBadgeCount() }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let identifier = response.notification.request.identifier
        
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
    /// Schedules a maintenance notification ONLY if the user has set a nextServiceDue date
    func scheduleMaintenanceReminder() {
        if nextServiceDue != nil {
            NotificationManager.shared.scheduleGearMaintenanceReminder(for: self)
        }
    }
}

extension Certification {
    func scheduleExpirationReminder() {
        NotificationManager.shared.scheduleCertificationExpirationReminder(for: self)
    }
}
