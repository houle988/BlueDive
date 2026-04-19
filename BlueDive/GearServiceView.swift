import SwiftUI
import SwiftData

struct GearServiceView: View {
    @Bindable var gear: Gear
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var prefs = UserPreferences.shared
    @State private var showServiceConfirmation = false
    @State private var serviceDate = Date()
    @State private var showEditGear = false
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Computed Properties

    /// How many days remain until `nextServiceDue`. Nil when no date is set.
    private var daysUntilServiceDue: Int? {
        guard let nextDue = gear.nextServiceDue else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let serviceDay = calendar.startOfDay(for: nextDue)
        return calendar.dateComponents([.day], from: today, to: serviceDay).day
    }

    /// Whether a date-based maintenance warning should be shown (within 30 days or past due).
    private var showDateBasedWarning: Bool {
        guard let days = daysUntilServiceDue else { return false }
        return days <= 30
    }

    /// Whether the service date is today or already past.
    private var isServiceDueOrPast: Bool {
        guard let days = daysUntilServiceDue else { return false }
        return days <= 0
    }
    
    private var recentDives: [Dive] {
        (gear.dives ?? [])
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(5)
            .map { $0 }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero header avec gradient
                    gearHeroHeader
                    
                    if showDateBasedWarning {
                        serviceAlertSection
                    }
                    
                    serviceGaugesSection
                    
                    // Grille de statistiques
                    statisticsGrid
                    
                    if !recentDives.isEmpty {
                        recentDivesSection
                    }
                    
                    serviceHistorySection
                }
                .padding(.vertical, 20)
                .padding(.bottom, 20) // Espace supplémentaire en bas pour éviter le débordement
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .background(
                LinearGradient(
                    colors: [
                        Color.platformBackground,
                        Color.blue.opacity(0.05),
                        Color.platformBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )

            .toolbar { toolbarContent }
            .sheet(isPresented: $showEditGear) {
                EditGearView(gear: gear)
                    #if os(macOS)
                    .frame(minWidth: 560, minHeight: 600)
                    #endif
            }
            .confirmationDialog(
                "Mark as Serviced",
                isPresented: $showServiceConfirmation,
                titleVisibility: .visible
            ) {
                Button("Today") {
                    markAsServiced(on: Date())
                }
                Button("Choose a date") {
                    // TODO: Display a date picker
                    markAsServiced(on: serviceDate)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("On what date was the maintenance performed?")
            }
        }
    }
    
    // MARK: - View Components
    
    private var gearHeroHeader: some View {
        VStack(spacing: 0) {
            // Grande icône avec gradient background
            ZStack {
                // Cercle avec gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.3), Color.blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 120, height: 120)
                
                if let category = gear.gearCategory {
                    Image(systemName: category.icon)
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .padding(.top, 20)
            
            // Nom et catégorie
            VStack(spacing: 6) {
                Text(gear.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(gear.gearCategory?.localizedName ?? LocalizedStringKey(gear.category))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.cyan)
                
                if let manufacturer = gear.manufacturer, !manufacturer.isEmpty {
                    Text(manufacturer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(gear.isInactive ? .red : .green)
                        .frame(width: 8, height: 8)
                    Text(gear.isInactive ? "Inactive Equipment" : "Active Equipment")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(gear.isInactive ? .red : .green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((gear.isInactive ? Color.red : Color.green).opacity(0.1))
                .cornerRadius(8)
                .padding(.top, 4)
                
                if let model = gear.model, !model.isEmpty {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 16)
            
            // Pills avec infos clés
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let serial = gear.serialNumber, !serial.isEmpty {
                        ModernInfoPill(icon: "number", text: serial, color: .gray)
                    }
                    
                    ModernInfoPill(
                        icon: "calendar",
                        text: formattedDate(gear.datePurchased),
                        color: .cyan
                    )
                    
                    if let price = gear.purchasePrice {
                        let currency = gear.currency ?? "CAD"
                        ModernInfoPill(
                            icon: "dollarsign.circle.fill",
                            text: String(format: "%.0f %@", price, currency),
                            color: .green
                        )
                    }
                    
                    if gear.weightContribution > 0 {
                        ModernInfoPill(
                            icon: "scalemass.fill",
                            text: prefs.weightUnit.formatted(gear.weightContribution, from: WeightUnit.from(importFormat: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)),
                            color: .orange
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 16)
            
            // Détails additionnels dans une carte élégante
            if gear.purchasedFrom != nil && !gear.purchasedFrom!.isEmpty {
                VStack(spacing: 12) {
                    if let shop = gear.purchasedFrom, !shop.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "storefront.fill")
                                .font(.body)
                                .foregroundStyle(.orange)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Purchased from")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(shop)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            
                            Spacer()
                        }
                    }
                    
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
                .padding(.top, 16)
            }
            
            // Quick action button
            Button {
                showEditGear = true
            } label: {
                Label("Edit Equipment", systemImage: "pencil")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 20)
        }
        .padding(.bottom, 8)
    }
    
    private var gearInfoCard: some View {
        VStack(spacing: 12) {
            // Icône et nom
            HStack {
                if let category = gear.gearCategory {
                    Image(systemName: category.icon)
                        .font(.largeTitle)
                        .foregroundStyle(.cyan)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(gear.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(gear.gearCategory?.localizedName ?? LocalizedStringKey(gear.category))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let model = gear.model, !model.isEmpty {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()

                // Quick edit shortcut
                Button {
                    showEditGear = true
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            // Détails achat
            VStack(alignment: .leading, spacing: 8) {
                if let serial = gear.serialNumber, !serial.isEmpty {
                    gearDetailRow(icon: "number", label: "N° de série", value: serial, color: .gray)
                }
                gearDetailRow(icon: "calendar", label: "Date d'achat",
                              value: formattedDate(gear.datePurchased), color: .cyan)
                if let price = gear.purchasePrice {
                    let currency = gear.currency ?? "CAD"
                    gearDetailRow(icon: "dollarsign.circle", label: "Prix d'achat",
                                  value: String(format: "%.2f \(currency)", price), color: .green)
                }
                if let shop = gear.purchasedFrom, !shop.isEmpty {
                    gearDetailRow(icon: "storefront.fill", label: "Purchased From", value: shop, color: .orange)
                }
                if gear.weightContribution > 0 {
                    gearDetailRow(icon: "scalemass", label: "Weight", value: prefs.weightUnit.formatted(gear.weightContribution, from: WeightUnit.from(importFormat: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)), color: .gray)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
        .padding(.horizontal)
    }
    
    private func gearDetailRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.caption).foregroundStyle(color).frame(width: 18)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium).foregroundStyle(.primary)
        }
    }
    
    private var serviceGaugesSection: some View {
        VStack(spacing: 16) {
            // N'afficher le gauge que si un entretien est programmé
            if let nextServiceDate = gear.nextServiceDue {
                // Calcul RÉEL du nombre de jours entre aujourd'hui et la date d'entretien
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let serviceDay = calendar.startOfDay(for: nextServiceDate)
                let daysRemaining = calendar.dateComponents([.day], from: today, to: serviceDay).day ?? 0
                
                // Calcul du total de jours depuis le dernier entretien (ou achat)
                let startDate = gear.lastServiceDate ?? gear.datePurchased
                let totalDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: startDate), to: serviceDay).day ?? 365
                
                // Le nombre de jours écoulés depuis le début
                let elapsedDays = totalDays - daysRemaining
                
                VStack(spacing: 16) {
                    HStack {
                        Text("Next Maintenance")
                            .font(.title3)
                            .fontWeight(.bold)
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    ServiceGauge(
                        value: Double(elapsedDays),
                        total: Double(totalDays),
                        label: "Days Remaining Before Maintenance",
                        icon: "calendar.badge.clock",
                        color: .orange,
                        isCountdown: true,
                        daysRemaining: daysRemaining
                    )
                }
                .padding(.vertical)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
            } else {
                // Message si aucun entretien programmé - version améliorée
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.1))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 8)
                    
                    VStack(spacing: 8) {
                        Text("No Maintenance Scheduled")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        
                        Text("Mark a maintenance to start automatic tracking of your equipment")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
            }
        }
    }
    
    private var statisticsGrid: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Usage Statistics")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                StatCard(
                    icon: "clock.fill",
                    iconColor: .cyan,
                    title: "Total Time",
                    value: gear.formattedTotalTime
                )
                
                StatCard(
                    icon: "water.waves",
                    iconColor: .blue,
                    title: "Dives",
                    value: "\(gear.totalDivesCount)"
                )
            }
            .padding(.horizontal)
        }
    }
    
    private var statisticsSection: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Usage statistics", icon: "chart.bar.fill")
            
            Divider()
            
            StatRow(
                title: "Total submerged time",
                value: gear.formattedTotalTime,
                icon: "clock.fill"
            )
            
            StatRow(
                title: "Average per dive",
                value: "\(gear.averageTimePerDive) min",
                icon: "waveform.path.ecg"
            )
            
            StatRow(
                title: "Total dives",
                value: "\(gear.totalDivesCount)",
                icon: "water.waves"
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }
    
    /// Resolves alert colour: red if due/past-due, orange if within 30 days.
    private var alertColor: Color {
        if isServiceDueOrPast {
            return .red
        }
        return .orange
    }

    private var alertIcon: String {
        if isServiceDueOrPast {
            return "xmark.shield.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private var alertTitle: Text {
        if isServiceDueOrPast {
            return Text("SERVICE OVERDUE")
        }
        if let days = daysUntilServiceDue {
            return Text("SERVICE DUE IN \(days) DAYS")
        }
        return Text("SERVICE DUE SOON")
    }

    private var alertMessage: Text {
        if isServiceDueOrPast, let nextDue = gear.nextServiceDue {
            let overdueDays = abs(daysUntilServiceDue ?? 0)
            if overdueDays == 0 {
                return Text(verbatim: String(format: NSLocalizedString("Maintenance is due today (%@).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is due today. %@ is the formatted date."), formattedDate(nextDue)))
            }
            return Text(verbatim: String(format: NSLocalizedString("Maintenance was due on %@ (%lld days ago).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is overdue. First arg is the formatted date, second is the number of days overdue."), formattedDate(nextDue), Int64(overdueDays)))
        }
        if let days = daysUntilServiceDue, let nextDue = gear.nextServiceDue {
            return Text(verbatim: String(format: NSLocalizedString("Maintenance is due on %@ (%lld days remaining).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is due soon. First arg is the formatted date, second is the number of days remaining."), formattedDate(nextDue), Int64(days)))
        }
        return Text("Maintenance due soon.")
    }

    private var serviceAlertSection: some View {
        VStack(spacing: 0) {
            // En-tête avec icône animée
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(alertColor.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: alertIcon)
                        .font(.title2)
                        .foregroundStyle(alertColor)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    alertTitle
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(alertColor)
                    
                    alertMessage
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(alertColor.opacity(0.1))
            )
            
            // Bouton d'action moderne
            Button {
                showServiceConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mark as Serviced")
                            .font(.subheadline)
                            .fontWeight(.bold)
                        Text("Reset Counters")
                            .font(.caption2)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.bold)
                }
                .foregroundStyle(.black)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [alertColor, alertColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(alertColor.opacity(0.3), lineWidth: 2)
                )
                .shadow(color: alertColor.opacity(0.3), radius: 20, y: 10)
        )
        .padding(.horizontal)
    }

    
    private var serviceHistorySection: some View {
        VStack(spacing: 16) {
            sectionHeaderView
            serviceContentView
        }
    }
    
    private var sectionHeaderView: some View {
        HStack {
            Label("Maintenance & Notes", systemImage: "clock.arrow.circlepath")
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
        }
        .padding(.horizontal)
    }
    
    private var serviceContentView: some View {
        VStack(spacing: 12) {
            serviceDatesView
            nextServiceDueView
            serviceHistoryNotesView
            gearNotesView
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
    
    @ViewBuilder
    private var serviceDatesView: some View {
        if let lastService = gear.lastServiceDate {
            ModernStatRow(
                icon: "wrench.adjustable.fill",
                iconColor: .cyan,
                title: "Last Maintenance",
                value: formattedDate(lastService)
            )
            
            ModernStatRow(
                icon: "calendar.badge.clock",
                iconColor: .orange,
                title: "Days Ago",
                value: "\(gear.daysSinceLastService) days"
            )
        } else {
            noServiceRecordedView
        }
    }
    
    private var noServiceRecordedView: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("No Maintenance Recorded")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Mark the first maintenance to start tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
    }
    
    @ViewBuilder
    private var nextServiceDueView: some View {
        if let nextDue = gear.nextServiceDue {
            let isPast = nextDue < Date()
            ModernStatRow(
                icon: isPast ? "exclamationmark.triangle.fill" : "calendar.badge.checkmark",
                iconColor: isPast ? .red : .green,
                title: "Next Maintenance",
                value: formattedDate(nextDue)
            )
        }
    }
    
    @ViewBuilder
    private var serviceHistoryNotesView: some View {
        if let history = gear.serviceHistory, !history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                    Text("Maintenance Log")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                
                Text(history)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.03))
                    )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
    
    @ViewBuilder
    private var gearNotesView: some View {
        if let notes = gear.gearNotes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.yellow)
                    Text("Notes")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.03))
                    )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.yellow.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
    
    private var recentDivesSection: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Recent dives", systemImage: "list.bullet.below.rectangle")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                
                Text("\(recentDives.count)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.cyan.opacity(0.2))
                    )
            }
            .padding(.horizontal)
            
            VStack(spacing: 0) {
                ForEach(recentDives.indices, id: \.self) { index in
                    let dive = recentDives[index]
                    
                    HStack(spacing: 12) {
                        // Icône de plongée
                        ZStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.15))
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: "figure.water.fitness")
                                .font(.body)
                                .foregroundStyle(.cyan)
                        }
                        
                        // Infos de plongée
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dive.siteName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            
                            Text(verbatim: formattedDate(dive.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        // Statistiques
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Text("\(dive.displayMaxDepth, specifier: "%.1f")\(prefs.depthUnit.symbol)")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                            }
                            
                            HStack(spacing: 4) {
                                Image(systemName: "clock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text("\(dive.duration) min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                    )
                    
                    if index < recentDives.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
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
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                dismiss()
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showEditGear = true
                } label: {
                    Label("Edit Equipment", systemImage: "pencil")
                }

                Divider()

                Button {
                    showServiceConfirmation = true
                } label: {
                    Label("Mark as Serviced", systemImage: "checkmark.circle")
                }
                
                Button(role: .destructive) {
                    // Reset service date
                    gear.lastServiceDate = nil
                    try? modelContext.save()
                } label: {
                    Label("Reset Maintenance", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.cyan)
            }
        }
    }
    
    // MARK: - Actions
    
    private func markAsServiced(on date: Date) {
        withAnimation {
            gear.markAsServiced(on: date)
            try? modelContext.save()
        }
        // Cancel the current notification, then reschedule if a future
        // service date is still set (e.g. recurring maintenance interval)
        NotificationManager.shared.cancelNotification(
            identifier: "gear-\(gear.id.uuidString)"
        )
        gear.scheduleMaintenanceReminder()
    }
}

// MARK: - Supporting Views

struct ModernInfoPill: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .fontWeight(.semibold)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
        .foregroundStyle(color)
    }
}

struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let value: String
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }
            
            VStack(spacing: 4) {
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

struct ModernStatRow: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let value: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 32)
            
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

struct ServiceGauge: View {
    let value: Double
    let total: Double
    let label: LocalizedStringKey
    let icon: String
    let color: Color
    var isCountdown: Bool = false
    var daysRemaining: Int = 0
    
    private var progress: Double {
        guard total.isFinite, total > 0, value.isFinite else { return 0 }
        if isCountdown {
            // Pour le compte à rebours: la barre avance au fur et à mesure
            // que les jours passent (value = jours écoulés)
            return max(0, min(value / total, 1.0))
        } else {
            // Mode normal
            return max(0, min(value / total, 1.0))
        }
    }
    
    private var gaugeColor: Color {
        if isCountdown {
            // Couleur basée sur les jours restants
            if daysRemaining <= 30 {
                return .red
            } else if daysRemaining <= 90 {
                return .orange
            } else {
                return color
            }
        } else {
            // Normal: more usage = more urgent
            return progress >= 1.0 ? .red : progress >= 0.8 ? .orange : color
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                // Background circle avec gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [gaugeColor.opacity(0.1), gaugeColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                
                // Cercle de fond
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 14)
                    .frame(width: 140, height: 140)
                
                // Cercle de progression avec effet glow
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [gaugeColor, gaugeColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: gaugeColor.opacity(0.5), radius: 8, x: 0, y: 0)
                    .animation(.spring(response: 0.8, dampingFraction: 0.8), value: progress)
                
                // Contenu central
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(gaugeColor)
                    
                    if isCountdown {
                        Text("\(daysRemaining)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Int(value))")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("/ \(Int(total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            VStack(spacing: 4) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                
                // Barre de progression additionnelle
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [gaugeColor, gaugeColor.opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geometry.size.width) * progress)
                        }
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 200)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct StatRow: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    let icon: String
    
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}

struct InfoPill: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.cyan.opacity(0.15))
        )
        .foregroundStyle(.cyan)
    }
}
