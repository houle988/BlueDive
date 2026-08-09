import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Color percentage interpolation from red to green

extension Color {
    func interpolate(percentage: Double) -> Color {
        // Clamp percentage between 0.0 and 1.0
        let percent = max(0.0, min(1.0, percentage))
        
        // Extract RGBA components for both colors
        let startComponents = UIColor(self).cgColor.components ?? [0, 0, 0, 1]
        let endComponents = UIColor(Color.green).cgColor.components ?? [0, 0, 0, 1]
        
        // Handle fallback if components are missing
        let r1 = startComponents[0]
        let g1 = startComponents[1]
        let b1 = startComponents[2]
        let a1 = startComponents.count > 3 ? startComponents[3] : 1.0
        
        let r2 = endComponents[0]
        let g2 = endComponents[1]
        let b2 = endComponents[2]
        let a2 = endComponents.count > 3 ? endComponents[3] : 1.0
        
        // Perform linear interpolation
        let r = r1 + (r2 - r1) * percent
        let g = g1 + (g2 - g1) * percent
        let b = b1 + (b2 - b1) * percent
        let a = a1 + (a2 - a1) * percent
        
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Diver Profile View

struct DiverProfileView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @Query(sort: \Certification.issueDate, order: .reverse) private var certifications: [Certification]
    @Query(sort: \DivingInsurance.endDate, order: .reverse) private var insurances: [DivingInsurance]
    @Query(sort: \Gear.name) private var allGear: [Gear]

    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var prefs = UserPreferences.shared

    @State private var documentsSection: DocumentSection?
    @State private var showingAddCertification = false
    @State private var showingAddInsurance = false
    @State private var profileAppeared = false
    @State private var selectedCertification: Certification?
    @State private var selectedInsurance: DivingInsurance?

    // MARK: - Diver Filter

    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: dives, gear: allGear, certifications: certifications, insurances: insurances)
    }

    private var filteredDives: [Dive] {
        DiverFilter.apply(selectedDiver, to: dives)
    }

    private var filteredCertifications: [Certification] {
        DiverFilter.apply(selectedDiver, to: certifications)
    }

    private var filteredInsurances: [DivingInsurance] {
        DiverFilter.apply(selectedDiver, to: insurances)
    }

    // MARK: - Computed Stats

    private var totalDives: Int { filteredDives.count }

    private var totalBottomTime: String {
        let total = filteredDives.reduce(0) { $0 + $1.duration }
        let h = total / 60
        let m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var maxDepth: Double {
        filteredDives.map { $0.displayMaxDepth }.max() ?? 0
    }

    private var countriesVisited: Int {
        Set(filteredDives.compactMap { $0.siteCountry }.filter { !$0.isEmpty }).count
    }

    private var uniqueSites: Int {
        Set(filteredDives.map { $0.siteName }).count
    }

    private var totalCreatures: Int {
        Set(
            filteredDives.flatMap { ($0.seenFish ?? []).map { $0.name } }
        ).count
    }

    private var yearsActive: Int {
        guard let first = filteredDives.map(\.timestamp).min() else { return 0 }
        return Calendar.current.dateComponents([.year], from: first, to: Date()).year ?? 0
    }

    private var topCreatures: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for dive in filteredDives {
            for f in dive.seenFish ?? [] { counts[f.name, default: 0] += 1 }
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    private var goals: [DiveGoal] {
        let increment = diveGoalIncrement(for: totalDives)
        let nextGoal = Int(ceil(Double(totalDives) / Double(increment)) * Double(increment))
        let maxGoal = nextGoal + (3 * increment)
        
        // Dive goals
        var nextGoals = Array(stride(from: nextGoal, through: maxGoal, by: increment)).map {
            DiveGoal(type: GoalType.dives, current: totalDives, target: $0)
        }
        
        nextGoals +=
        [
            // Other goals
            DiveGoal(type: GoalType.countries, current: countriesVisited, target: 5),
            DiveGoal(type: GoalType.countries, current: countriesVisited, target: 10),
            DiveGoal(type: GoalType.countries, current: countriesVisited, target: 30),
            DiveGoal(type: GoalType.species,   current: totalCreatures,   target: 25),
            DiveGoal(type: GoalType.species,   current: totalCreatures,   target: 50),
            DiveGoal(type: GoalType.species,   current: totalCreatures,   target: 100),
        ]
    
        return nextGoals.filter { !$0.isCompleted }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroHeader
                        .padding(.bottom, 28)
                        .opacity(profileAppeared ? 1.0 : 0.0)
                        .offset(y: profileAppeared ? 0 : 20)

                    VStack(spacing: 22) {
                        statsGrid
                            .opacity(profileAppeared ? 1.0 : 0.0)
                            .offset(y: profileAppeared ? 0 : 15)
                        if !goals.isEmpty        { goalsSection
                                .opacity(profileAppeared ? 1.0 : 0.0)
                                .offset(y: profileAppeared ? 0 : 15)
                        }
                        if !topCreatures.isEmpty { topCreaturesSection
                                .opacity(profileAppeared ? 1.0 : 0.0)
                                .offset(y: profileAppeared ? 0 : 15)
                        }
                        certificationsSection
                            .opacity(profileAppeared ? 1.0 : 0.0)
                            .offset(y: profileAppeared ? 0 : 15)
                        insuranceSection
                            .opacity(profileAppeared ? 1.0 : 0.0)
                            .offset(y: profileAppeared ? 0 : 15)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 40)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) {
                    profileAppeared = true
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("")
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 700, maxWidth: 900, minHeight: 500, idealHeight: 650, maxHeight: 900)
            #endif

            .toolbar {
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)

                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $documentsSection) { section in
                DocumentsView(initialSection: section, onClose: { documentsSection = nil })
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAddCertification) {
                AddCertificationView(prefilledDiverName: selectedDiver)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAddInsurance) {
                AddInsuranceView(prefilledDiverName: selectedDiver)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedCertification) { cert in
                CertificationDetailView(certification: cert, selectedCertification: $selectedCertification)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedInsurance) { insurance in
                InsuranceDetailView(insurance: insurance, selectedInsurance: $selectedInsurance)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            // Ocean gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.0, green: 0.25, blue: 0.45),
                    Color(red: 0.0, green: 0.12, blue: 0.25),
                    Color.platformBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 200)

            // Decorative circles
            Circle()
                .fill(Color.cyan.opacity(0.08))
                .frame(width: 300)
                .offset(x: -60, y: -20)

            Circle()
                .fill(Color.blue.opacity(0.1))
                .frame(width: 200)
                .offset(x: 120, y: -10)

            // Content
            VStack(spacing: 14) {
                Spacer()

                // Name
                VStack(spacing: 6) {
                    Group {
                        if selectedDiver.isEmpty {
                            Text("All Divers")
                        } else {
                            Text(verbatim: selectedDiver)
                        }
                    }
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    if yearsActive > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.caption2)
                            Text("Diver for \(yearsActive) year\(yearsActive > 1 ? "s" : "")")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 2)
                    }
                }
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 200)
        .clipped()
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(spacing: 12) {
            // Row 1 — main stats
            HStack(spacing: 12) {
                BigStatCard(
                    value: "\(totalDives)",
                    label: "Dives",
                    icon: "figure.open.water.swim",
                    color: .cyan
                )
                BigStatCard(
                    value: totalBottomTime,
                    label: "Bottom Time",
                    icon: "clock.fill",
                    color: .green
                )
            }

            // Row 2 — secondary stats
            HStack(spacing: 12) {
                SmallStatCard(value: String(format: "%.0f\(prefs.depthUnit.symbol)", maxDepth), label: "Max Depth",  icon: "arrow.down.circle.fill", color: .blue)
                SmallStatCard(value: "\(countriesVisited)",              label: "Countries",  icon: "globe",                  color: .mint)
                SmallStatCard(value: "\(uniqueSites)",                   label: "Sites",      icon: "mappin.and.ellipse",     color: .purple)
                SmallStatCard(value: "\(totalCreatures)",                label: "Species",    icon: "fish.fill",              color: .orange)
            }
        }
    }

    // MARK: - Goals Section

    private var goalsSection: some View {
        ProfileCard(title: "Next Goals", icon: "target") {
            VStack(spacing: 14) {
                ForEach(goals) { goal in
                    GoalRow(goal: goal)
                }
            }
        }
    }

    // MARK: - Top Creatures Section

    private var topCreaturesSection: some View {
        ProfileCard(title: "Most Observed Creatures", icon: "eye.fill") {
            VStack(spacing: 0) {
                ForEach(Array(topCreatures.enumerated()), id: \.offset) { index, creature in
                    HStack(spacing: 14) {
                        // Rank
                        ZStack {
                            Circle()
                                .fill(rankColor(index).opacity(0.15))
                                .frame(width: 30, height: 30)
                            Text("\(index + 1)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(rankColor(index))
                        }

                        Text(creature.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(creature.count)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 10)

                    if index < topCreatures.count - 1 {
                        Divider()
                            .background(Color.primary.opacity(0.07))
                    }
                }
            }
        }
    }

    private func rankColor(_ index: Int) -> Color {
        switch index {
        case 0: return .yellow
        case 1: return Color(white: 0.75)
        case 2: return Color(red: 0.8, green: 0.5, blue: 0.2)
        default: return .secondary
        }
    }

    // MARK: - Certifications Section

    private static let previewLimit = 5

    private var previewCertifications: [Certification] {
        Array(filteredCertifications.prefix(DiverProfileView.previewLimit))
    }

    private var remainingCertificationsCount: Int {
        max(0, filteredCertifications.count - DiverProfileView.previewLimit)
    }

    private var previewInsurances: [DivingInsurance] {
        Array(filteredInsurances.prefix(DiverProfileView.previewLimit))
    }

    private var remainingInsurancesCount: Int {
        max(0, filteredInsurances.count - DiverProfileView.previewLimit)
    }

    private var certificationsSection: some View {
        ProfileCard(title: "Certifications", icon: "graduationcap.fill") {
            VStack(spacing: 0) {
                if certifications.isEmpty {
                    // Truly empty — no certifications on record at all
                    VStack(spacing: 10) {
                        Image(systemName: "graduationcap")
                            .font(.title2)
                            .foregroundStyle(.cyan.opacity(0.5))
                        Text("No certifications")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else if filteredCertifications.isEmpty {
                    // Filter active — no certifications for the selected diver
                    VStack(spacing: 10) {
                        Image(systemName: "person.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Certifications for Diver")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(previewCertifications) { cert in
                        Button {
                            selectedCertification = cert
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(cert.isExpired ? Color.red.opacity(0.15) : Color.cyan.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: cert.isExpired ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(cert.isExpired ? .red : .cyan)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cert.level)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(cert.localizedOrganization)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    if cert.isExpired {
                                        Text("Expired")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.red.opacity(0.2))
                                            .foregroundStyle(.red)
                                            .clipShape(Capsule())
                                    } else if cert.isExpiringSoon {
                                        Text("Expires Soon")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    } else {
                                        Text(cert.issueDate.formatted(.dateTime.year().locale(locale)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if cert.id != previewCertifications.last?.id {
                            Divider()
                                .background(Color.primary.opacity(0.07))
                        }
                    }
                }

                // Buttons at bottom
                Divider()
                    .background(Color.primary.opacity(0.07))
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    Button {
                        showingAddCertification = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.cyan)
                    }

                    Spacer()

                    if !filteredCertifications.isEmpty {
                        HStack(spacing: 6) {
                            if remainingCertificationsCount > 0 {
                                Text(verbatim: String(format: NSLocalizedString("+%lld more", bundle: Bundle.forAppLanguage(), comment: "Label showing how many additional items are not shown in the preview list."), remainingCertificationsCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                documentsSection = .certifications
                            } label: {
                                Text("View All")
                                    .font(.subheadline)
                                    .foregroundStyle(.cyan.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Insurance Section

    private var insuranceSection: some View {
        ProfileCard(title: "Insurance", icon: "shield.fill") {
            VStack(spacing: 0) {
                if insurances.isEmpty {
                    // Truly empty — no insurance on record at all
                    VStack(spacing: 10) {
                        Image(systemName: "shield")
                            .font(.title2)
                            .foregroundStyle(.blue.opacity(0.5))
                        Text("No insurance recorded")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else if filteredInsurances.isEmpty {
                    // Filter active — no insurance for the selected diver
                    VStack(spacing: 10) {
                        Image(systemName: "person.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Insurance for Diver")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(previewInsurances) { insurance in
                        Button {
                            selectedInsurance = insurance
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(insurance.isExpired ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: insurance.isExpired ? "exclamationmark.shield.fill" : "shield.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(insurance.isExpired ? .red : (insurance.isExpiringSoon ? .orange : .blue))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(insurance.insurerName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    if !insurance.coverageType.isEmpty {
                                        Text(insurance.coverageType)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    if insurance.isExpired {
                                        Text("Expired")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.red.opacity(0.2))
                                            .foregroundStyle(.red)
                                            .clipShape(Capsule())
                                    } else if insurance.isExpiringSoon {
                                        Group {
                                            if let days = insurance.daysUntilExpiration {
                                                Text(verbatim: days == 0
                                    ? NSLocalizedString("0d remaining", bundle: Bundle.forAppLanguage(), comment: "Badge showing zero days remaining on expiring insurance in profile card.")
                                    : days == 1
                                    ? NSLocalizedString("1d remaining", bundle: Bundle.forAppLanguage(), comment: "Badge showing exactly one day remaining on expiring insurance in profile card.")
                                    : String(format: NSLocalizedString("%lldd remaining", bundle: Bundle.forAppLanguage(), comment: "Badge showing days remaining on expiring insurance in profile card."), days))
                                            } else {
                                                Text("Expires Soon")
                                            }
                                        }
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.2))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                    } else {
                                        Text(insurance.endDate.formatted(.dateTime.year().locale(locale)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if insurance.id != previewInsurances.last?.id {
                            Divider()
                                .background(Color.primary.opacity(0.07))
                        }
                    }
                }

                // Buttons at bottom
                Divider()
                    .background(Color.primary.opacity(0.07))
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    Button {
                        showingAddInsurance = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                    Spacer()

                    if !filteredInsurances.isEmpty {
                        HStack(spacing: 6) {
                            if remainingInsurancesCount > 0 {
                                Text(verbatim: String(format: NSLocalizedString("+%lld more", bundle: Bundle.forAppLanguage(), comment: "Label showing how many additional items are not shown in the preview list."), remainingInsurancesCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                documentsSection = .insurance
                            } label: {
                                Text("View All")
                                    .font(.subheadline)
                                    .foregroundStyle(.blue.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Actions
}

// MARK: - Profile Card Container

private struct ProfileCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Stat Cards

private struct BigStatCard: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.2))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

private struct SmallStatCard: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Goal Row

private struct GoalRow: View {
    let goal: DiveGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: goal.icon)
                    .font(.caption)
                    .foregroundStyle(goal.color)
                    .frame(width: 18)

                Text(goal.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(goal.target-goal.current)")
                    .font(.caption)
                    .foregroundStyle(goal.color)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [goal.color.opacity(0.7), goal.color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * goal.progress, height: 6)
                        .animation(.spring(duration: 0.6), value: goal.progress)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Supporting Types

struct DiveGoal: Identifiable {
    var id: String { _rawTitle }
    private let _rawTitle: String
    let title: String
    let icon: String
    let color: Color
    let current: Int
    let target: Int
    let progress: Double

    init(type: GoalType, current: Int, target: Int) {
        self._rawTitle = "\(target)-\(type)"
        let progress = min(Double(current) / Double(target), 1.0)
        self.title = type.localizedTitle(count: target)
        self.icon = type.icon
        self.progress = progress
        self.color = Color.red.interpolate(percentage: progress)
        self.current = current
        self.target = target
    }

    var isCompleted: Bool { current >= target }
}

enum GoalType {
    case dives
    case species
    case countries
    
    func localizedTitle(count: Int) -> String {
        switch self {
        case .dives:
            return String(format: NSLocalizedString("%lld dives", bundle: .forAppLanguage(), comment: "Dive count goal label"), count)
        case .species:
            return String(format: NSLocalizedString("%lld species", bundle: .forAppLanguage(), comment: "Species count goal label"), count)
        case .countries:
            return String(format: NSLocalizedString("%lld countries visited", bundle: .forAppLanguage(), comment: "Countries visited goal label"), count)
        }
    }

    var icon: String {
        switch self {
        case .dives: return "figure.open.water.swim"
        case .species: return "fish.fill"
        case .countries: return "globe"
        }
    }
}


// MARK: - Insurance Card

fileprivate extension DivingInsurance {
    var statusColor: Color {
        if isExpired      { return .red    }
        if isExpiringSoon { return .orange }
        return .blue
    }
}

struct InsuranceCard: View {
    let insurance: DivingInsurance
    let showExpired: Bool
    @Environment(\.locale) private var locale

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var statusColor: Color { insurance.statusColor }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 60, height: 60)
                Text(insurance.insurerName.isEmpty ? "?" : String(insurance.insurerName.prefix(4)))
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(insurance.insurerName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !insurance.diverName.isEmpty {
                    Text(insurance.diverName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                }

                if !insurance.coverageType.isEmpty {
                    Text(insurance.coverageType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !insurance.policyNumber.isEmpty {
                    Label(insurance.policyNumber, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Label(formattedDate(insurance.startDate), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().frame(height: 12)

                    Label(formattedDate(insurance.endDate), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(showExpired ? .red : (insurance.isExpiringSoon ? .orange : .secondary))
                }
            }

            Spacer()

            Circle()
                .fill(showExpired ? Color.red : (insurance.isExpiringSoon ? Color.orange : Color.blue))
                .frame(width: 12, height: 12)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(statusColor.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Insurance Detail View

struct InsuranceDetailView: View {
    @Bindable var insurance: DivingInsurance
    @Binding var selectedInsurance: DivingInsurance?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showEditInsurance = false
    @State private var showDeleteConfirmation = false

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var statusColor: Color { insurance.statusColor }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon header
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(statusColor.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: insurance.isExpired ? "exclamationmark.shield.fill" : "shield.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(statusColor)
                            }

                            // Status badge
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Group {
                                    if insurance.isExpired {
                                        Text("Expired")
                                    } else if insurance.isExpiringSoon {
                                        Text("Expiring Soon")
                                    } else {
                                        Text("Active")
                                    }
                                }
                                    .font(.caption)
                                    .foregroundStyle(statusColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(statusColor.opacity(0.15))
                            )
                        }
                        .padding(.top, 20)

                        // Details
                        VStack(spacing: 16) {
                            if !insurance.diverName.isEmpty {
                                DetailRow(icon: "person.fill", title: "Diver Name", value: insurance.diverName)
                            }
                            DetailRow(icon: "building.2.fill", title: "Insurer", value: insurance.insurerName)
                            if !insurance.policyNumber.isEmpty {
                                DetailRow(icon: "number", title: "Policy Number", value: insurance.policyNumber)
                            }

                            if !insurance.coverageType.isEmpty {
                                DetailRow(icon: "shield.fill", title: "Coverage Type", value: insurance.coverageType)
                            }

                            DetailRow(icon: "calendar", title: "Start Date", value: formattedDate(insurance.startDate))
                            DetailRow(icon: "clock", title: "End Date", value: formattedDate(insurance.endDate))

                            if let phone = insurance.contactPhone, !phone.isEmpty {
                                DetailRow(icon: "phone.fill", title: "Emergency Phone", value: phone)
                            }

                            if let email = insurance.contactEmail, !email.isEmpty {
                                DetailRow(icon: "envelope.fill", title: "Email", value: email)
                            }

                            if let notes = insurance.notes, !notes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Notes", systemImage: "note.text")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(notes)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.05))
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(insurance.insurerName.isEmpty
                ? NSLocalizedString("Insurance", bundle: Bundle.forAppLanguage(), comment: "Fallback navigation title for an insurance record with no insurer name.")
                : insurance.insurerName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showEditInsurance = true
                    } label: {
                        Text("Edit").fontWeight(.semibold)
                    }
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    #endif
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif
            .sheet(isPresented: $showEditInsurance) {
                AddInsuranceView(insuranceToEdit: insurance)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete insurance?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    selectedInsurance = nil
                    modelContext.delete(insurance)
                }
            } message: {
                Text(verbatim: String(format: NSLocalizedString("Are you sure you want to delete \"%@\"? This action cannot be undone.", bundle: Bundle.forAppLanguage(), comment: "Delete confirmation alert message."), insurance.insurerName))
            }
        }
    }
}

// MARK: - Add Insurance View

struct AddInsuranceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Dive.timestamp) private var allDives: [Dive]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Certification.issueDate) private var allCertifications: [Certification]
    @Query private var allInsurances: [DivingInsurance]

    var insuranceToEdit: DivingInsurance?
    var prefilledDiverName: String = ""

    private var isEditing: Bool { insuranceToEdit != nil }

    private var diverNameSuggestions: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: allCertifications, insurances: allInsurances)
    }

    @State private var diverName = ""
    @State private var insurerName = ""
    @State private var policyNumber = ""
    @State private var coverageType = ""
    @State private var startDate = Date()
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var contactPhone = ""
    @State private var contactEmail = ""
    @State private var notes = ""

    private var isValid: Bool {
        !insurerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !policyNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon header
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(.blue.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.top, 20)

                        // Insurer
                        insuranceSectionCard(title: "Insurer", icon: "building.2.fill", color: .blue) {
                            VStack(spacing: 14) {
                                DiverAutocompleteField(
                                    label: "Diver Name",
                                    placeholder: "Diver Name (optional)",
                                    text: $diverName,
                                    suggestions: diverNameSuggestions,
                                    suggestionColor: .blue
                                )

                                insuranceTextField("Insurer Name", placeholder: "e.g., DAN", text: $insurerName)

                                insuranceTextField("Policy Number", placeholder: "Policy number", text: $policyNumber)
                                    .autocorrectionDisabled()
                                    .platformKeyboardType(.asciiCapable)

                                insuranceTextField("Coverage Type", placeholder: "e.g., Comprehensive, Liability… (optional)", text: $coverageType)
                            }
                        }

                        // Validity
                        insuranceSectionCard(title: "Validity", icon: "calendar", color: .orange) {
                            VStack(spacing: 14) {
                                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                                    .adaptiveDatePickerStyle()
                                    .foregroundStyle(.primary)

                                Divider().overlay(Color.primary.opacity(0.06))

                                DatePicker("End Date / Renewal", selection: $endDate, displayedComponents: .date)
                                    .adaptiveDatePickerStyle()
                                    .foregroundStyle(.primary)
                            }
                        }

                        // Emergency Contact
                        insuranceSectionCard(title: "Emergency Contact", icon: "phone.fill", color: .red) {
                            VStack(spacing: 14) {
                                insuranceTextField("Phone", placeholder: "Emergency phone number (optional)", text: $contactPhone)
                                    .platformKeyboardType(.phonePad)

                                insuranceTextField("Email", placeholder: "Contact email (optional)", text: $contactEmail)
                                    .platformKeyboardType(.emailAddress)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                            }
                        }

                        // Notes
                        insuranceSectionCard(title: "Notes", icon: "text.quote", color: .purple) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Notes")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $notes)
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 80)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                    .overlay(alignment: .topLeading) {
                                        if notes.isEmpty {
                                            Text("Notes (optional)")
                                                #if os(iOS)
                                                .foregroundColor(Color(uiColor: .placeholderText))
                                                #else
                                                .foregroundColor(Color(nsColor: .placeholderTextColor))
                                                #endif
                                                .padding(.top, 12)
                                                .padding(.leading, 12)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? LocalizedStringKey("Edit Insurance") : LocalizedStringKey("New Insurance"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(isEditing ? LocalizedStringKey("Save") : LocalizedStringKey("Add"))
                        }
                        .fontWeight(.semibold)
                    }
                    .disabled(!isValid)
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    #endif
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif

            .onAppear {
                if let insurance = insuranceToEdit {
                    diverName = insurance.diverName
                    insurerName = insurance.insurerName
                    policyNumber = insurance.policyNumber
                    coverageType = insurance.coverageType
                    startDate = insurance.startDate
                    endDate = insurance.endDate
                    contactPhone = insurance.contactPhone ?? ""
                    contactEmail = insurance.contactEmail ?? ""
                    notes = insurance.notes ?? ""
                } else if !prefilledDiverName.isEmpty {
                    diverName = prefilledDiverName
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func insuranceSectionCard<Content: View>(title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            content()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func insuranceTextField(_ label: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    private func save() {
        if let insurance = insuranceToEdit {
            insurance.diverName = diverName.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.insurerName = insurerName.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.policyNumber = policyNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.coverageType = coverageType.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.startDate = startDate
            insurance.endDate = endDate
            let trimmedPhone = contactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.contactPhone = trimmedPhone.isEmpty ? nil : trimmedPhone
            let trimmedEmail = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.contactEmail = trimmedEmail.isEmpty ? nil : trimmedEmail
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        } else {
            let trimmedPhone = contactPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let newInsurance = DivingInsurance(
                insurerName: insurerName.trimmingCharacters(in: .whitespacesAndNewlines),
                diverName: diverName.trimmingCharacters(in: .whitespacesAndNewlines),
                policyNumber: policyNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                coverageType: coverageType.trimmingCharacters(in: .whitespacesAndNewlines),
                startDate: startDate,
                endDate: endDate,
                contactPhone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                contactEmail: trimmedEmail.isEmpty ? nil : trimmedEmail,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(newInsurance)
        }
        dismiss()
    }
}


