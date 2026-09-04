import SwiftUI
import SwiftData
import UserNotifications

struct NotificationsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("notificationsEnabled")     private var notificationsEnabled = false
    @AppStorage("gearMaintenanceReminders") private var gearReminders = true
    @AppStorage("certificationReminders")   private var certReminders = true
    @AppStorage("milestoneNotifications")   private var milestoneNotifs = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $notificationsEnabled) {
                            Label("Notifications", systemImage: "bell.fill")
                        }
                        .tint(.cyan)
                        .onChange(of: notificationsEnabled) {
                            if notificationsEnabled {
                                Task { await requestNotificationPermission() }
                            } else {
                                #if canImport(UserNotifications)
                                NotificationManager.shared.cancelAllNotifications()
                                #endif
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    if notificationsEnabled {
                        Text("Reminders are automatically updated when your data changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)

                if notificationsEnabled {
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $gearReminders) {
                                Label("Equipment maintenance", systemImage: "wrench.fill")
                            }
                            .tint(.cyan)
                            .onChange(of: gearReminders) {
                                Task { await rescheduleGearNotifications() }
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $certReminders) {
                                Label("Certification expiration", systemImage: "rosette")
                            }
                            .tint(.cyan)
                            .onChange(of: certReminders) {
                                Task { await rescheduleCertNotifications() }
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $milestoneNotifs) {
                                Label("Milestones reached", systemImage: "star.fill")
                            }
                            .tint(.cyan)
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                        Text("Milestone counts dives for all divers combined. Not recommended when multiple divers share this app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal)

                    if notificationStatus == .denied {
                        VStack(spacing: 12) {
                            #if os(iOS)
                            Label {
                                Text("Notifications are disabled in iOS. Enable them in Settings → BlueDive → Notifications.")
                                    .foregroundStyle(.orange)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                            #elseif os(macOS)
                            HStack {
                                Label {
                                    Text("Notifications are disabled. Enable them in System Preferences → Notifications → BlueDive.")
                                        .foregroundStyle(.orange)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Button("Open") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                            #endif
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(Text(verbatim: NSLocalizedString("Notifications", bundle: .forAppLanguage(), value: "Notifications", comment: "")))
        .task {
            await checkNotificationStatus()
            if notificationsEnabled {
                #if canImport(UserNotifications)
                NotificationManager.shared.setupNotificationCategories()
                #endif
                await rescheduleAllNotifications()
            }
        }
    }

    // MARK: - Helpers

    private func requestNotificationPermission() async {
        #if canImport(UserNotifications)
        let currentStatus = await NotificationManager.shared.checkAuthorizationStatus()

        if currentStatus == .authorized || currentStatus == .provisional {
            await MainActor.run { NotificationManager.shared.setupNotificationCategories() }
            await checkNotificationStatus()
            await rescheduleAllNotifications()
            return
        }

        if currentStatus == .denied {
            await MainActor.run { notificationsEnabled = false }
            return
        }

        let granted = await NotificationManager.shared.requestAuthorization()
        let finalStatus = await NotificationManager.shared.checkAuthorizationStatus()

        await MainActor.run {
            notificationStatus = finalStatus
            if finalStatus == .authorized || finalStatus == .provisional || granted {
                NotificationManager.shared.setupNotificationCategories()
            } else if finalStatus == .denied {
                notificationsEnabled = false
            }
        }

        if finalStatus == .authorized || finalStatus == .provisional || granted {
            await rescheduleAllNotifications()
        }
        #else
        await MainActor.run { notificationsEnabled = false }
        #endif
    }

    @MainActor
    private func checkNotificationStatus() async {
        #if canImport(UserNotifications)
        notificationStatus = await NotificationManager.shared.checkAuthorizationStatus()
        #endif
    }

    @MainActor
    private func rescheduleGearNotifications() async {
        #if canImport(UserNotifications)
        if gearReminders {
            let allGear = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
            NotificationManager.shared.scheduleGearMaintenanceReminders(for: allGear)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "gear-")
        }
        #endif
    }

    @MainActor
    private func rescheduleCertNotifications() async {
        #if canImport(UserNotifications)
        if certReminders {
            let allCerts = (try? modelContext.fetch(FetchDescriptor<Certification>())) ?? []
            NotificationManager.shared.scheduleCertificationReminders(for: allCerts)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "cert-")
        }
        #endif
    }

    @MainActor
    private func rescheduleAllNotifications() async {
        await rescheduleGearNotifications()
        await rescheduleCertNotifications()
    }
}
