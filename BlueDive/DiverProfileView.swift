import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Diver Profile View

struct DiverProfileView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @Query(sort: \Certification.issueDate, order: .reverse) private var certifications: [Certification]
    @Query private var insurances: [DivingInsurance]

    @AppStorage("userName") private var userName: String = ""
    @AppStorage("diverBio") private var diverBio: String = ""

    @Environment(\.dismiss) private var dismiss

    @State private var prefs = UserPreferences.shared

    @State private var avatarImage: PlatformImage? = DiverProfileView.loadAvatar()
    @State private var photoPickerItem: PhotosPickerItem? = nil

    @State private var showingEditProfile = false
    @State private var showingCertifications = false
    @State private var showingAddCertification = false
    @State private var showingInsurances = false
    @State private var showingAddInsurance = false
    @State private var profileAppeared = false

    // MARK: - Computed Stats

    private var totalDives: Int { dives.count }

    private var totalBottomTime: String {
        let total = dives.reduce(0) { $0 + $1.duration }
        let h = total / 60
        let m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var maxDepth: Double {
        dives.map { $0.displayMaxDepth }.max() ?? 0
    }

    private var countriesVisited: Int {
        Set(dives.compactMap { $0.siteCountry }.filter { !$0.isEmpty }).count
    }

    private var uniqueSites: Int {
        Set(dives.map { $0.siteName }).count
    }

    private var totalCreatures: Int {
        Set(
            dives.flatMap { ($0.seenFish ?? []).map { $0.name } }
        ).count
    }

    private var yearsActive: Int {
        guard let first = dives.last?.timestamp else { return 0 }
        return Calendar.current.dateComponents([.year], from: first, to: Date()).year ?? 0
    }

    private var topCreatures: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for dive in dives {
            for f in dive.seenFish ?? [] { counts[f.name, default: 0] += f.count }
        }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    private var goals: [DiveGoal] {
        [
            // Dive count goals
            DiveGoal(title: "100 dives",   icon: "figure.open.water.swim", color: .cyan,   current: totalDives, target: 100),
            DiveGoal(title: "250 dives",   icon: "figure.open.water.swim", color: .blue,   current: totalDives, target: 250),
            DiveGoal(title: "500 dives",   icon: "figure.open.water.swim", color: .purple, current: totalDives, target: 500),
            DiveGoal(title: "750 dives",   icon: "figure.open.water.swim", color: .indigo, current: totalDives, target: 750),
            DiveGoal(title: "1,000 dives", icon: "figure.open.water.swim", color: .teal,   current: totalDives, target: 1000),
            DiveGoal(title: "1,500 dives", icon: "figure.open.water.swim", color: .mint,   current: totalDives, target: 1500),
            DiveGoal(title: "2,000 dives", icon: "figure.open.water.swim", color: .green,  current: totalDives, target: 2000),
            DiveGoal(title: "2,500 dives", icon: "figure.open.water.swim", color: .yellow, current: totalDives, target: 2500),
            // Other goals
            DiveGoal(title: "5 countries visited",  icon: "globe",     color: .green,  current: countriesVisited, target: 5),
            DiveGoal(title: "10 countries visited", icon: "globe",     color: .mint,   current: countriesVisited, target: 10),
            DiveGoal(title: "25 species",           icon: "fish.fill", color: .orange, current: totalCreatures,   target: 25),
            DiveGoal(title: "50 species",           icon: "fish.fill", color: .yellow, current: totalCreatures,   target: 50),
        ]
        .filter { !$0.isCompleted }
        .prefix(4)
        .map { $0 }
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("")
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 700, maxWidth: 900, minHeight: 500, idealHeight: 650, maxHeight: 900)
            #endif

            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        #if os(macOS)
                        Label("Close", systemImage: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                        #else
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title3)
                        #endif
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingEditProfile = true
                    } label: {
                        Text("Edit")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileView(
                    userName: $userName,
                    diverBio: $diverBio,
                    avatarImage: $avatarImage
                )
            }
            .sheet(isPresented: $showingCertifications) {
                CertificationsView(onClose: { showingCertifications = false })
                    #if os(macOS)
                    .frame(minWidth: 550, idealWidth: 650, maxWidth: 850, minHeight: 500, idealHeight: 650, maxHeight: 900)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $showingAddCertification) {
                AddCertificationView()
            }
            .sheet(isPresented: $showingInsurances) {
                InsurancesView(onClose: { showingInsurances = false })
            }
            .sheet(isPresented: $showingAddInsurance) {
                AddInsuranceView()
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
            .frame(height: 320)

            // Decorative circles
            Circle()
                .fill(Color.cyan.opacity(0.08))
                .frame(width: 300)
                .offset(x: -60, y: -80)

            Circle()
                .fill(Color.blue.opacity(0.1))
                .frame(width: 200)
                .offset(x: 120, y: -40)

            // Content
            VStack(spacing: 14) {
                Spacer()

                // Profile photo
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let avatar = avatarImage {
                            Image(platformImage: avatar)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [.cyan.opacity(0.5), .blue.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "person.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .frame(width: 110, height: 110)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.cyan, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3
                            )
                    )
                    .shadow(color: .cyan.opacity(0.4), radius: 12, x: 0, y: 4)
                }

                // Name & bio
                VStack(spacing: 6) {
                    Group {
                        if userName.isEmpty {
                            Text("Diver")
                        } else {
                            Text(userName)
                        }
                    }
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    if !diverBio.isEmpty {
                        Text(diverBio)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    if yearsActive > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .font(.caption2)
                            Text("Diver for \(yearsActive) year\(yearsActive > 1 ? "s" : "")")
                                .font(.caption)
                        }
                        .foregroundStyle(.cyan.opacity(0.85))
                        .padding(.top, 2)
                    }
                }
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 320)
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

    private static let certificationPreviewLimit = 5

    private var previewCertifications: [Certification] {
        Array(certifications.prefix(DiverProfileView.certificationPreviewLimit))
    }

    private var remainingCertificationsCount: Int {
        max(0, certifications.count - DiverProfileView.certificationPreviewLimit)
    }

    private var certificationsSection: some View {
        ProfileCard(title: "Certifications", icon: "graduationcap.fill") {
            VStack(spacing: 0) {
                if certifications.isEmpty {
                    // Empty state
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
                } else {
                    ForEach(previewCertifications) { cert in
                        Button {
                            showingCertifications = true
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
                                    Text(cert.organization)
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
                                        Text(cert.issueDate.formatted(.dateTime.year()))
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

                    if !certifications.isEmpty {
                        HStack(spacing: 6) {
                            if remainingCertificationsCount > 0 {
                                Text(verbatim: NSLocalizedString("+%lld more", bundle: Bundle.forAppLanguage(), comment: "A small label next to the 'View All' button indicating how many additional certifications are not shown in the preview list.")
                                    .replacingOccurrences(of: "%lld", with: "\(remainingCertificationsCount)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                showingCertifications = true
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
                    // Empty state
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
                } else {
                    ForEach(insurances) { insurance in
                        Button {
                            showingInsurances = true
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
                                    Text(insurance.coverageType)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                                        if let days = insurance.daysUntilExpiration {
                                            Text("\(days)d remaining")
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.orange.opacity(0.2))
                                                .foregroundStyle(.orange)
                                                .clipShape(Capsule())
                                        }
                                    } else {
                                        Text(insurance.endDate.formatted(.dateTime.year()))
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

                        if insurance.id != insurances.last?.id {
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

                    if !insurances.isEmpty {
                        Button {
                            showingInsurances = true
                        } label: {
                            Text("View All")
                                .font(.subheadline)
                                .foregroundStyle(.blue.opacity(0.7))
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Actions

    // MARK: - Avatar Persistence

    static func loadAvatar() -> PlatformImage? {
        guard let data = UserDefaults.standard.data(forKey: "diverAvatarData") else { return nil }
        return PlatformImage(data: data)
    }

    static func saveAvatar(_ image: PlatformImage) {
        #if os(iOS)
        let data = image.jpegData(compressionQuality: 0.8)
        #elseif os(macOS)
        let data = image.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) }
        #endif
        UserDefaults.standard.set(data, forKey: "diverAvatarData")
    }
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

                Text("\(goal.current) / \(goal.target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    let current: Int
    let target: Int

    init(title: String, icon: String, color: Color, current: Int, target: Int) {
        self._rawTitle = title
        self.title = LocalizedStringKey(title)
        self.icon = icon
        self.color = color
        self.current = current
        self.target = target
    }

    var progress: Double { min(Double(current) / Double(target), 1.0) }
    var isCompleted: Bool { current >= target }
}

// MARK: - Edit Profile Sheet

struct EditProfileView: View {
    @Binding var userName: String
    @Binding var diverBio: String
    @Binding var avatarImage: PlatformImage?

    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String = ""
    @State private var editedBio: String = ""
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var pendingImage: PlatformImage? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    #if os(macOS)
                    HStack {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                        Spacer()
                        Button(action: saveAndDismiss) {
                            Text("Save")
                                .fontWeight(.bold)
                                .foregroundStyle(.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    #endif

                    // Profile photo area
                    avatarPicker

                    // Text fields
                    VStack(spacing: 0) {
                        Group {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Name", systemImage: "person.fill")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                HStack {
                                    TextField("Your first name or username (optional)", text: $editedName)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if !editedName.isEmpty {
                                        Button {
                                            editedName = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.07))
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Label("About", systemImage: "text.quote")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                TextEditor(text: $editedBio)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 90)
                                    .padding(14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.primary.opacity(0.07))
                                    )
                                    .overlay(alignment: .topLeading) {
                                        if editedBio.isEmpty {
                                            Text("About yourself (optional)")
                                                #if os(iOS)
                                                .foregroundColor(Color(uiColor: .placeholderText))
                                                #else
                                                .foregroundColor(Color(nsColor: .placeholderTextColor))
                                                #endif
                                                .padding(.top, 22)
                                                .padding(.leading, 19)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .background(Color.platformBackground.ignoresSafeArea())

            .navigationTitle("Edit Profile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 550, idealWidth: 650, maxWidth: 850, minHeight: 500, idealHeight: 650, maxHeight: 900)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(.cyan)
                }
            }
            .onAppear {
                editedName = userName
                editedBio = diverBio
                pendingImage = avatarImage
            }
            // Chargement de la photo sélectionnée
            .onChange(of: photoPickerItem) {
                guard let newItem = photoPickerItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = PlatformImage(data: data) {
                        pendingImage = image
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func saveAndDismiss() {
        userName = editedName.trimmingCharacters(in: .whitespaces)
        diverBio = editedBio.trimmingCharacters(in: .whitespacesAndNewlines)
        if let img = pendingImage {
            avatarImage = img
            DiverProfileView.saveAvatar(img)
        }
        dismiss()
    }

    // MARK: - Avatar Picker

    private var avatarPicker: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    // Photo
                    Group {
                        if let img = pendingImage {
                            Image(platformImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [.cyan.opacity(0.4), .blue.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "person.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .frame(width: 110, height: 110)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.cyan.opacity(0.5), lineWidth: 2)
                    )

                    // Bouton caméra
                    ZStack {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 32, height: 32)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.black)
                    }
                    .offset(x: 4, y: 4)
                }
            }

            Text("Tap to change photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Insurances View

struct InsurancesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var insurances: [DivingInsurance]
    var onClose: (() -> Void)? = nil
    @State private var showAddInsurance = false
    @State private var appeared = false
    @State private var selectedInsurance: DivingInsurance?
    @State private var insuranceToDelete: DivingInsurance?
    @State private var showDeleteConfirmation = false
    @State private var showEditInsuranceFor: DivingInsurance?

    private var activeInsurances: [DivingInsurance] {
        insurances.filter { !$0.isExpired }
    }

    private var expiredInsurances: [DivingInsurance] {
        insurances.filter { $0.isExpired }
    }

    private var expiringSoon: [DivingInsurance] {
        insurances.filter { $0.isExpiringSoon }
    }

    var body: some View {
        NavigationStack {
            Group {
                if insurances.isEmpty {
                    ScrollView {
                        emptyState
                    }
                } else {
                    List {
                        // Alert for insurances expiring soon
                        if !expiringSoon.isEmpty {
                            Section {
                                alertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        // Active insurances
                        if !activeInsurances.isEmpty {
                            Section {
                                ForEach(activeInsurances) { insurance in
                                    Button {
                                        selectedInsurance = insurance
                                    } label: {
                                        InsuranceCard(insurance: insurance, showExpired: false)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            insuranceToDelete = insurance
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            selectedInsurance = insurance
                                        } label: {
                                            Label("View Details", systemImage: "eye")
                                        }
                                        Button {
                                            showEditInsuranceFor = insurance
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            insuranceToDelete = insurance
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                }
                            } header: {
                                Text("Active Insurance")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                        }

                        // Expired insurances
                        if !expiredInsurances.isEmpty {
                            Section {
                                ForEach(expiredInsurances) { insurance in
                                    Button {
                                        selectedInsurance = insurance
                                    } label: {
                                        InsuranceCard(insurance: insurance, showExpired: true)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            insuranceToDelete = insurance
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            selectedInsurance = insurance
                                        } label: {
                                            Label("View Details", systemImage: "eye")
                                        }
                                        Button {
                                            showEditInsuranceFor = insurance
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            insuranceToDelete = insurance
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                }
                            } header: {
                                Text("Expired Insurance")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .opacity(appeared ? 1.0 : 0.0)
            .offset(y: appeared ? 0 : 15)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) {
                    appeared = true
                }
            }
            .navigationTitle("Insurance")
            .background(Color.platformBackground.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .frame(minWidth: 550, idealWidth: 650, maxWidth: 850, minHeight: 500, idealHeight: 650, maxHeight: 900)
            #endif

            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            onClose()
                        } label: {
                            #if os(macOS)
                            Label("Close", systemImage: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                            #else
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .font(.title3)
                            #endif
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddInsurance = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .sheet(isPresented: $showAddInsurance) {
                AddInsuranceView()
            }
            .sheet(item: $selectedInsurance) { insurance in
                InsuranceDetailView(insurance: insurance)
            }
            .alert("Delete insurance?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    insuranceToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let insurance = insuranceToDelete {
                        modelContext.delete(insurance)
                        insuranceToDelete = nil
                    }
                }
            } message: {
                if let insurance = insuranceToDelete {
                    Text("Are you sure you want to delete \"\(insurance.insurerName)\"? This action cannot be undone.")
                }
            }
            .sheet(item: $showEditInsuranceFor) { insurance in
                AddInsuranceView(insuranceToEdit: insurance)
            }
        }
    }

    // MARK: - View Components

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Expiring Soon")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            ForEach(expiringSoon) { insurance in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(insurance.insurerName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        if let days = insurance.daysUntilExpiration {
                            Text("Expires in \(days) days")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange.opacity(0.15))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal)
    }

    @State private var emptyAppeared = false

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.slash")
                .font(.system(size: 60))
                .foregroundStyle(.blue.opacity(0.4))
                .scaleEffect(emptyAppeared ? 1.0 : 0.5)
                .opacity(emptyAppeared ? 1.0 : 0.0)

            Text("No Insurance")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)

            Text("Add your diving insurance to easily track it")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)

            Button { showAddInsurance = true } label: {
                Label("Add Insurance", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
            }
            .scaleEffect(emptyAppeared ? 1.0 : 0.8)
            .opacity(emptyAppeared ? 1.0 : 0.0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                emptyAppeared = true
            }
        }
    }
}

// MARK: - Insurance Card

struct InsuranceCard: View {
    let insurance: DivingInsurance
    let showExpired: Bool

    private var statusColor: Color {
        if insurance.isExpired        { return .red    }
        if insurance.isExpiringSoon   { return .orange }
        return .blue
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 60, height: 60)
                Image(systemName: insurance.isExpired ? "exclamationmark.shield.fill" : "shield.fill")
                    .font(.title3)
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(insurance.insurerName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(insurance.coverageType)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(insurance.policyNumber, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let phone = insurance.contactPhone, !phone.isEmpty {
                        Divider().frame(height: 12)
                        Label(phone, systemImage: "phone.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(showExpired ? Color.red : (insurance.isExpiringSoon ? Color.orange : Color.blue))
                .frame(width: 12, height: 12)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Insurance Detail View

struct InsuranceDetailView: View {
    @Bindable var insurance: DivingInsurance
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var showEditInsurance = false

    private var statusColor: Color {
        if insurance.isExpired        { return .red    }
        if insurance.isExpiringSoon   { return .orange }
        return .blue
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
                            DetailRow(icon: "building.2.fill", title: "Insurer", value: insurance.insurerName)
                            DetailRow(icon: "number", title: "Policy Number", value: insurance.policyNumber)

                            if !insurance.coverageType.isEmpty {
                                DetailRow(icon: "shield.fill", title: "Coverage Type", value: insurance.coverageType)
                            }

                            DetailRow(icon: "calendar", title: "Start Date", value: insurance.startDate.formatted(date: .long, time: .omitted))
                            DetailRow(icon: "clock", title: "End Date", value: insurance.endDate.formatted(date: .long, time: .omitted))

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

                Divider().overlay(Color.primary.opacity(0.08))

                // Bottom buttons
                HStack {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showEditInsurance = true
                    } label: {
                        Text("Edit")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.blue)
                            )
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(insurance.insurerName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif

            .alert("Delete insurance?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    modelContext.delete(insurance)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete \"\(insurance.insurerName)\"? This action cannot be undone.")
            }
            .sheet(isPresented: $showEditInsurance) {
                AddInsuranceView(insuranceToEdit: insurance)
            }
        }
    }
}

// MARK: - Add Insurance View

struct AddInsuranceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var insuranceToEdit: DivingInsurance?

    private var isEditing: Bool { insuranceToEdit != nil }

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
                        insuranceSectionCard(title: "Insurer", icon: "building.2.fill", color: .cyan) {
                            VStack(spacing: 14) {
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
                                    .foregroundStyle(.primary)

                                Divider().overlay(Color.primary.opacity(0.06))

                                DatePicker("End Date / Renewal", selection: $endDate, displayedComponents: .date)
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

                Divider().overlay(Color.primary.opacity(0.08))

                // Bottom buttons
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button {
                        save()
                    } label: {
                        Text(isEditing ? "Save" : "Add")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isValid ? .blue : .blue.opacity(0.3))
                            )
                            .foregroundStyle(isValid ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Insurance" : "New Insurance")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif

            .onAppear {
                if let insurance = insuranceToEdit {
                    insurerName = insurance.insurerName
                    policyNumber = insurance.policyNumber
                    coverageType = insurance.coverageType
                    startDate = insurance.startDate
                    endDate = insurance.endDate
                    contactPhone = insurance.contactPhone ?? ""
                    contactEmail = insurance.contactEmail ?? ""
                    notes = insurance.notes ?? ""
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
            insurance.insurerName = insurerName.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.policyNumber = policyNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.coverageType = coverageType.trimmingCharacters(in: .whitespaces)
            insurance.startDate = startDate
            insurance.endDate = endDate
            let trimmedPhone = contactPhone.trimmingCharacters(in: .whitespaces)
            insurance.contactPhone = trimmedPhone.isEmpty ? nil : trimmedPhone
            let trimmedEmail = contactEmail.trimmingCharacters(in: .whitespaces)
            insurance.contactEmail = trimmedEmail.isEmpty ? nil : trimmedEmail
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            insurance.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        } else {
            let trimmedPhone = contactPhone.trimmingCharacters(in: .whitespaces)
            let trimmedEmail = contactEmail.trimmingCharacters(in: .whitespaces)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let newInsurance = DivingInsurance(
                insurerName: insurerName.trimmingCharacters(in: .whitespacesAndNewlines),
                policyNumber: policyNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                coverageType: coverageType.trimmingCharacters(in: .whitespaces),
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
