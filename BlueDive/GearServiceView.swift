import SwiftUI
import SwiftData

struct GearServiceView: View {
    @Bindable var gear: Gear
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    @State private var prefs = UserPreferences.shared
    private enum ServiceSheetMode: Identifiable {
        case add
        case edit(ServiceRecord)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let r): return r.id.uuidString
            }
        }
        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @State private var serviceSheetMode: ServiceSheetMode? = nil
    @State private var serviceDate = Date()
    @State private var scheduleNextService = false
    @State private var nextServiceDate = Date()
    @State private var showEditGear = false
    @State private var serviceDescription = ""
    @State private var serviceCost = ""
    /// The edited record's stored cost behind its 2-decimal pre-fill text, so an untouched cost
    /// is saved unchanged instead of rounded (see PrefilledDouble). Empty when adding.
    @State private var prefilledServiceCost = PrefilledDouble(value: nil, text: "")
    @State private var showDeleteConfirmation = false
    @State private var showClearAllConfirmation = false

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().year().locale(locale))
    }

    private var costIsInvalid: Bool {
        guard !serviceCost.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // parseFlexibleDouble rejects non-finite input ("inf", "nan") itself.
        return parseFlexibleDouble(serviceCost) == nil
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
                    
                    #if os(macOS)
                    // The Mac sheet is wide: the service gauge beside the usage statistics, and
                    // the recent dives beside Maintenance & Notes; fixedSize gives each pair the
                    // height of its taller section. Gear without a service date shows the
                    // "No Maintenance Scheduled" card full width, as on iOS, then the statistics
                    // full width; gear without dives shows Maintenance & Notes full width.
                    if gear.nextServiceDue != nil {
                        // Each section keeps its own 16 pt side padding (header and card), so the
                        // two meet 32 pt apart; spacing -8 makes the gap 24 pt, like the rows.
                        HStack(alignment: .top, spacing: -8) {
                            serviceGaugesSection
                                .frame(maxWidth: .infinity)
                            statisticsGrid
                                .frame(maxWidth: .infinity)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        serviceGaugesSection
                        statisticsGrid
                    }

                    HStack(alignment: .top, spacing: -8) {
                        if !recentDives.isEmpty {
                            recentDivesSection
                                .frame(maxWidth: .infinity)
                        }
                        serviceHistorySection
                            .frame(maxWidth: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    #else
                    serviceGaugesSection
                    
                    // Grille de statistiques
                    statisticsGrid
                    
                    if !recentDives.isEmpty {
                        recentDivesSection
                    }
                    
                    serviceHistorySection
                    #endif
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
                    .standardSheetPresentation()
            }
            .sheet(item: $serviceSheetMode) { mode in
                NavigationStack {
                    Form {
                        Section("Service Date") {
                            DatePicker(
                                "Service Date",
                                selection: $serviceDate,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .adaptiveDatePickerStyle()
                            // Informational reminder when editing a legacy record with no known date.
                            // Saving always promotes the record — verify the date shown is correct.
                            if case .edit(let record) = mode,
                               record.isLegacy,
                               record.date == .distantPast {
                                Label("Original date unknown — verify before saving.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Section("Description") {
                            formTextField("Description", text: $serviceDescription, axis: .vertical)
                                .lineLimit(4...)
                                .overlay(alignment: .trailing) {
                                    if !serviceDescription.isEmpty {
                                        Button { serviceDescription = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                                .clearButtonTapTarget()
                                                .accessibilityLabel(Text("Clear"))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 4)
                                    }
                                }
                        }

                        Section("Cost (optional)") {
                            formTextField(verbatim: 0.0.editableString(decimals: 2, minDecimals: 2), text: $serviceCost)
                                .platformKeyboardType(.decimalPad)
                                .overlay(alignment: .trailing) {
                                    if !serviceCost.isEmpty {
                                        Button { serviceCost = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                                .clearButtonTapTarget()
                                                .accessibilityLabel(Text("Clear"))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 4)
                                    }
                                }
                            if costIsInvalid {
                                Text("Invalid amount.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        if mode.isEdit {
                            Section {
                                Button(role: .destructive) {
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete Record", systemImage: "trash")
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .listRowButton()
                            }
                        }

                        if !mode.isEdit {
                            Section {
                                Toggle("Schedule Next Service", isOn: $scheduleNextService)
                                    .fullWidthSwitch()
                                    .onChange(of: scheduleNextService) { _, isOn in
                                        if isOn {
                                            nextServiceDate = Calendar.current.date(
                                                byAdding: .year, value: 1, to: serviceDate
                                            ) ?? serviceDate
                                        }
                                    }
                                    .onChange(of: serviceDate) { _, newDate in
                                        if scheduleNextService && nextServiceDate < newDate {
                                            nextServiceDate = Calendar.current.date(
                                                byAdding: .year, value: 1, to: newDate
                                            ) ?? newDate
                                        }
                                    }

                                if scheduleNextService {
                                    DatePicker(
                                        "Next Service Date",
                                        selection: $nextServiceDate,
                                        in: serviceDate...,
                                        displayedComponents: .date
                                    )
                                    .adaptiveDatePickerStyle()
                                }
                            }
                        }
                    }
                    .groupedFormStyleOnMac()
                    .alert("Delete this service record?", isPresented: $showDeleteConfirmation) {
                        Button("Delete", role: .destructive) {
                            if case .edit(let record) = mode {
                                withAnimation { gear.deleteServiceRecord(id: record.id) }
                                saveAndReschedule()
                            }
                            serviceSheetMode = nil
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                    .navigationTitle(mode.isEdit ? "Edit Service Record" : "Log Service")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { serviceSheetMode = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(mode.isEdit ? "Save" : "Confirm") {
                                let desc = serviceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                                let isBlank = serviceCost.trimmingCharacters(in: .whitespaces).isEmpty
                                // parseFlexibleDouble rejects non-finite values (e.g. "inf", "nan") —
                                // JSONEncoder throws on them, which would drop the entire record.
                                let parsedCost: Double? = isBlank ? nil : parseFlexibleDouble(serviceCost)
                                switch mode {
                                case .edit(let record):
                                    var updated = record
                                    updated.date = serviceDate
                                    updated.description = desc
                                    // Blank or whitespace-only → remove cost. Parseable → use it.
                                    // Non-empty but unparseable → preserve original to avoid silent data loss.
                                    // An untouched cost keeps the stored value (not its rounded text).
                                    if isBlank {
                                        updated.cost = nil
                                    } else if let c = prefilledServiceCost.resolve(serviceCost) {
                                        updated.cost = c
                                    }
                                    // Saving always promotes the record: clear isLegacy so the
                                    // confirmed date anchors lastServiceDate. Any sentinel ID is
                                    // promoted to a fresh UUID so it is never persisted to JSON.
                                    updated.isLegacy = false
                                    if updated.id == Gear.legacySentinelID {
                                        updated.id = UUID()
                                    }
                                    gear.updateServiceRecord(updated, originalId: record.id)
                                case .add:
                                    if scheduleNextService {
                                        gear.nextServiceDue = nextServiceDate
                                    }
                                    // Do not clear nextServiceDue when toggle is off — the user
                                    // may be logging a historical service and has a future
                                    // reminder already scheduled that should be preserved.
                                    gear.addServiceRecord(date: serviceDate, description: desc, cost: parsedCost)
                                }
                                serviceSheetMode = nil
                                saveAndReschedule()
                            }
                            .disabled(costIsInvalid)
                        }
                    }
                }
                .onAppear {
                    if case .edit(let record) = mode {
                        serviceDate = (record.isLegacy && record.date == .distantPast) ? Date() : record.date
                        serviceDescription = record.description
                        prefilledServiceCost = .decimals(record.cost, 2, minDecimals: 2)
                        serviceCost = prefilledServiceCost.text
                    }
                }
                .onDisappear { showDeleteConfirmation = false }
                .standardSheetPresentation()
            }
            .alert("Clear all service records?", isPresented: $showClearAllConfirmation) {
                Button("Clear All Records", role: .destructive) {
                    gear.nextServiceDue = nil
                    gear.lastServiceDate = nil
                    gear.saveServiceRecords([])
                    saveAndReschedule()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will also clear the scheduled maintenance reminder.")
            }
        }
    }
    
    // MARK: - View Components
    
    private var gearHeroHeader: some View {
        VStack(spacing: 0) {
            GearIconView(manufacturer: gear.manufacturer, category: gear.gearCategory, size: 100)
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

                if !gear.diverName.isEmpty {
                    Label(gear.diverName, systemImage: "person.fill")
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
                            text: price.localizedString(decimals: 0) + " \(currency)",
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
                // macOS: stretch to the Usage Statistics box beside it; iOS: unchanged.
                .fillsAvailableHeightOnMac()
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
    
    /// Usage statistics: two cards side by side, or stacked on macOS when the section is the
    /// narrow half beside the service gauge (gear with a next-service date).
    private var statisticsColumns: [GridItem] {
        #if os(macOS)
        if gear.nextServiceDue != nil {
            return [GridItem(.flexible())]
        }
        #endif
        return [GridItem(.flexible()), GridItem(.flexible())]
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
            
            LazyVGrid(columns: statisticsColumns, spacing: 16) {
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
                    value: Double(gear.totalDivesCount).localizedString(decimals: 0)
                )
            }
            .padding(.horizontal)
        }
        .usageStatisticsBoxOnMac(gear.nextServiceDue != nil)
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
            return "xmark.shield"
        }
        return "exclamationmark.triangle"
    }

    private var alertTitle: Text {
        if isServiceDueOrPast {
            return Text("SERVICE OVERDUE")
        }
        if let days = daysUntilServiceDue {
            return days == 1
                ? Text(NSLocalizedString("SERVICE DUE IN 1 DAY", bundle: .forAppLanguage(), comment: "Title for alert when a gear service is due in exactly 1 day"))
                : Text(verbatim: String(format: NSLocalizedString("SERVICE DUE IN %@ DAYS", bundle: .forAppLanguage(), comment: "Title for alert when a gear service is due in multiple days. The placeholder is the number of days."), Double(days).localizedString(decimals: 0)))
        }
        return Text("SERVICE DUE SOON")
    }

    private var alertMessage: Text {
        if isServiceDueOrPast, let nextDue = gear.nextServiceDue {
            let overdueDays = abs(daysUntilServiceDue ?? 0)
            if overdueDays == 0 {
                return Text(verbatim: String(format: NSLocalizedString("Maintenance is due today (%@).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is due today. %@ is the formatted date."), formattedDate(nextDue)))
            }
            if overdueDays == 1 {
                return Text(verbatim: String(format: NSLocalizedString("Maintenance was due on %@ (1 day ago).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is overdue by exactly 1 day. %@ is the formatted date."), formattedDate(nextDue)))
            }
            return Text(verbatim: String(format: NSLocalizedString("Maintenance was due on %@ (%@ days ago).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is overdue. First arg is the formatted date, second is the number of days overdue."), formattedDate(nextDue), Double(overdueDays).localizedString(decimals: 0)))
        }
        if let days = daysUntilServiceDue, let nextDue = gear.nextServiceDue {
            if days == 1 {
                return Text(verbatim: String(format: NSLocalizedString("Maintenance is due on %@ (1 day remaining).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is due in exactly 1 day. %@ is the formatted date."), formattedDate(nextDue)))
            }
            return Text(verbatim: String(format: NSLocalizedString("Maintenance is due on %@ (%@ days remaining).", bundle: .forAppLanguage(), comment: "Alert shown when maintenance is due soon. First arg is the formatted date, second is the number of days remaining."), formattedDate(nextDue), Double(days).localizedString(decimals: 0)))
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
                        .accessibilityHidden(true)
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
                openAddServiceSheet()
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .accessibilityHidden(true)

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
                        .accessibilityHidden(true)
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
        .fillsAvailableHeightOnMac()
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
            
            if gear.daysSinceLastService >= 0 {
                ModernStatRow(
                    icon: "calendar.badge.clock",
                    iconColor: .orange,
                    title: "Days Ago",
                    value: {
                        let days = gear.daysSinceLastService
                        let n = Double(days).localizedString(decimals: 0)
                        return days == 1
                            ? NSLocalizedString("1 day", bundle: .forAppLanguage(), comment: "Singular day count (days since the last maintenance service, current dive streak)")
                            : String(format: NSLocalizedString("%@ days", bundle: .forAppLanguage(), comment: "Plural day count (days since the last maintenance service, current dive streak), pre-formatted with locale grouping separator"), n)
                    }()
                )
            }
        } else {
            noServiceRecordedView
        }
    }
    
    private var noServiceRecordedView: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title3)
                .accessibilityHidden(true)

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
                icon: isPast ? "exclamationmark.triangle" : "calendar.badge.checkmark",
                iconColor: isPast ? .red : .green,
                title: "Next Maintenance",
                value: formattedDate(nextDue),
                statusLabel: isPast ? "Overdue" : nil
            )
        }
    }
    
    private var serviceHistoryNotesView: some View {
        let records = gear.parsedServiceRecords
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Maintenance History")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    openAddServiceSheet()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.cyan)
                        .font(.title3)
                        // Only control in this header row: empty Spacer leading, 16 pt of card
                        // padding trailing and above. Downward growth is capped at the full 8 pt
                        // gap to the first (tappable) service record row, so the two targets
                        // touch without overlapping. 48 × 44 pt.
                        .tapTargetInsets(top: 12, leading: 12, bottom: 8, trailing: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add Service Record"))
            }

            if records.isEmpty {
                Text("No service records yet. Tap + to log the first maintenance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        ServiceRecordRow(
                            record: record,
                            currency: gear.currency ?? ""
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // For legacy records with no confirmed date, seed the picker at
                            // today so the user doesn't have to scroll from year 0001.
                            serviceDate = (record.isLegacy && record.date == .distantPast) ? Date() : record.date
                            serviceDescription = record.description
                            prefilledServiceCost = .decimals(record.cost, 2, minDecimals: 2)
                            serviceCost = prefilledServiceCost.text
                            scheduleNextService = false
                            showDeleteConfirmation = false
                            serviceSheetMode = .edit(record)
                        }

                        if record.id != records.last?.id {
                            Divider()
                                .padding(.horizontal, 4)
                        }
                    }
                }

                let costs = records.compactMap(\.cost)
                let total = costs.reduce(0, +)
                if !costs.isEmpty {
                    Divider()
                    HStack(spacing: 12) {
                        Text("Total Cost")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(verbatim: total.localizedString(decimals: 2, minDecimals: 2) + (gear.currency.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        // Invisible chevron matches the layout of ServiceRecordRow so the cost columns align.
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.clear)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, 4)
                }
            }
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
    
    @ViewBuilder
    private var gearNotesView: some View {
        if let notes = gear.gearNotes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
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
                
                Text(verbatim: Double(recentDives.count).localizedString(decimals: 0))
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
                                .accessibilityHidden(true)
                        }
                        
                        // Infos de plongée
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dive.siteName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            
                            Text(dive.timestamp, format: .dateTime.day().month().year().locale(locale))
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
                                    .accessibilityHidden(true)
                                Text(verbatim: dive.displayMaxDepth.localizedString(decimals: 1) + prefs.depthUnit.symbol)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                            }
                            
                            HStack(spacing: 4) {
                                Image(systemName: "clock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                // Same "0h 42m" format as the dive list rows.
                                Text(verbatim: dive.shortFormattedDuration)
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
            .fillsAvailableHeightOnMac()
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
            closeToolbarButton {
                dismiss()
            }
        }
        
        ToolbarItem(placement: .sheetPrimaryAction) {
            Menu {
                Button {
                    showEditGear = true
                } label: {
                    Label("Edit Equipment", systemImage: "pencil")
                }

                Divider()

                Button {
                    openAddServiceSheet()
                } label: {
                    Label("Mark as Serviced", systemImage: "checkmark.circle")
                }

                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Label("Clear All Records", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.cyan)
            }
            .accessibilityLabel(Text("More"))
            .toolbarMenuIndicatorHiddenOnMac()
        }
    }

    // MARK: - Actions
    
    private func saveAndReschedule() {
        try? modelContext.save()
        NotificationManager.shared.cancelGearReminder(id: gear.id)
        gear.scheduleMaintenanceReminder()
    }

    private func openAddServiceSheet() {
        serviceDate = Date()
        scheduleNextService = false
        nextServiceDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        serviceDescription = ""
        serviceCost = ""
        prefilledServiceCost = PrefilledDouble(value: nil, text: "")
        showDeleteConfirmation = false
        serviceSheetMode = .add
    }
}

// MARK: - Supporting Views

struct ServiceRecordRow: View {
    let record: ServiceRecord
    let currency: String
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if record.isLegacy {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Legacy Note")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if record.isLegacy && record.date == .distantPast {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.date, format: .dateTime.day().month().year().locale(locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(record.description.isEmpty ? "—" : record.description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            if let cost = record.cost {
                Text(verbatim: cost.localizedString(decimals: 2, minDecimals: 2) + (currency.isEmpty ? "" : " " + currency))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }
}

struct ModernInfoPill: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .fontWeight(.semibold)
                .accessibilityHidden(true)
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
    
    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 50, height: 50)

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
        }
    }

    private var valueText: some View {
        Text(value)
            .font(.title3)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
    }

    private var titleText: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Icon above the value and title (iOS), or a compact row with the icon on the left (macOS).
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // The Mac card is a compact row (icon left of the value), so the two cards stack
        // in the Usage Statistics box without outgrowing the Next Maintenance card.
        HStack(spacing: 14) {
            iconBadge

            VStack(alignment: .leading, spacing: 4) {
                valueText
                titleText
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        #else
        VStack(spacing: 12) {
            iconBadge

            VStack(spacing: 4) {
                valueText
                titleText
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    var body: some View {
        content
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
    /// Spoken-only status (e.g. "Overdue") for rows whose urgency is otherwise conveyed by icon/colour alone.
    var statusLabel: LocalizedStringKey? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 32)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusLabel.map { Text($0) } ?? Text(verbatim: ""))
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
                        .accessibilityHidden(true)

                    if isCountdown {
                        Text(verbatim: Double(daysRemaining).localizedString(decimals: 0))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        if daysRemaining == 1 {
                            Text(NSLocalizedString("day", bundle: .forAppLanguage(), comment: "Singular day label in service countdown gauge"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(NSLocalizedString("days", bundle: .forAppLanguage(), comment: "Plural days label in service countdown gauge"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(verbatim: Double(value).localizedString(decimals: 0))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(verbatim: "/ " + Double(total).localizedString(decimals: 0))
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

private extension View {
    /// macOS, when `boxed` (Usage Statistics sits beside the Next Maintenance gauge card):
    /// frames the section as a box matching that card (title inside, same padding, corner
    /// radius and outline), stretched to the pair's height. Full width (no service date) and
    /// on iOS: returns the section unchanged.
    @ViewBuilder
    func usageStatisticsBoxOnMac(_ boxed: Bool) -> some View {
        #if os(macOS)
        if boxed {
        self
            .frame(maxWidth: .infinity)
            .fillsAvailableHeightOnMac()
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
            self
        }
        #else
        self
        #endif
    }
}
