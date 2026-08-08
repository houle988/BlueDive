import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - UI Extensions

private extension CertificationOrganization {
    var swiftUIColor: Color {
        switch self {
        case .padi: return .blue
        case .ssi: return .cyan
        case .cmas: return .orange
        case .naui: return .green
        case .sdi: return .purple
        case .tdi: return .teal
        case .bsac: return .red
        case .other: return .gray
        }
    }
}

extension Certification {
    var organizationColor: Color {
        CertificationOrganization(rawValue: organization)?.swiftUIColor ?? .gray
    }
}

// MARK: - Import Target

private enum ImportTarget {
    case certifications, insurance
}

// MARK: - Documents View

struct DocumentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Certification.issueDate, order: .reverse) private var certifications: [Certification]
    @Query(sort: \DivingInsurance.endDate, order: .reverse) private var insurances: [DivingInsurance]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    var onClose: (() -> Void)? = nil

    // MARK: - Appearance
    @State private var appeared = false
    @State private var emptyAppeared = false

    // MARK: - Collapse State (namespaced: "cert:" prefix for orgs, "ins:" prefix for insurers)
    @State private var collapsedSections: Set<String> = []

    // MARK: - Certification State
    @State private var showAddCertification = false
    @State private var selectedCertification: Certification?
    @State private var certificationToDelete: Certification?
    @State private var showDeleteCertConfirmation = false
    @State private var showEditCertificationFor: Certification?

    // MARK: - Insurance State
    @State private var showAddInsurance = false
    @State private var selectedInsurance: DivingInsurance?
    @State private var insuranceToDelete: DivingInsurance?
    @State private var showDeleteInsuranceConfirmation = false
    @State private var showEditInsuranceFor: DivingInsurance?

    // MARK: - Import / Export State
    @State private var importTarget: ImportTarget = .certifications
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var importedCount: Int = 0
    @State private var importSuccessTarget: ImportTarget = .certifications
    @State private var showImportSuccess = false
    @State private var exportError: String?
    @State private var showExportError = false
    #if os(iOS)
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName: String = ""
    #endif

    // MARK: - Computed Properties

    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: certifications, insurances: insurances)
    }

    private var filteredCertifications: [Certification] {
        DiverFilter.apply(selectedDiver, to: certifications)
    }

    private var filteredInsurances: [DivingInsurance] {
        DiverFilter.apply(selectedDiver, to: insurances)
    }

    private var groupedCertifications: [(key: String, value: [Certification])] {
        let grouped = Dictionary(grouping: filteredCertifications.filter { !$0.isExpired }, by: { $0.organization })
        let knownOrder = CertificationOrganization.allCases.map(\.rawValue)
        return grouped.sorted { a, b in
            let ai = knownOrder.firstIndex(of: a.key) ?? Int.max
            let bi = knownOrder.firstIndex(of: b.key) ?? Int.max
            return ai < bi
        }
    }

    private var groupedInsurances: [(key: String, value: [DivingInsurance])] {
        let grouped = Dictionary(grouping: filteredInsurances.filter { !$0.isExpired }, by: {
            $0.insurerName.trimmingCharacters(in: .whitespaces)
        })
        return grouped.sorted { a, b in
            if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
            return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
        }
    }

    private var certExpired: [Certification] { filteredCertifications.filter { $0.isExpired } }
    private var insuranceExpired: [DivingInsurance] { filteredInsurances.filter { $0.isExpired } }
    private var certExpiringSoon: [Certification] { filteredCertifications.filter { $0.isExpiringSoon } }
    private var insuranceExpiringSoon: [DivingInsurance] { filteredInsurances.filter { $0.isExpiringSoon } }

    private var importSuccessMessage: String {
        if importSuccessTarget == .certifications {
            return importedCount == 1
                ? NSLocalizedString("1 certification imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Alert message shown after importing exactly one certification.")
                : String(format: NSLocalizedString("%lld certifications imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Alert message shown after a successful certification XML import."), importedCount)
        } else {
            return importedCount == 1
                ? NSLocalizedString("1 insurance record imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Alert message shown after importing exactly one insurance record from XML.")
                : String(format: NSLocalizedString("%lld insurance records imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Alert message shown after importing multiple insurance records from XML."), importedCount)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if certifications.isEmpty && insurances.isEmpty {
                    ScrollView { bothEmptyStateView }
                } else if !selectedDiver.isEmpty && filteredCertifications.isEmpty && filteredInsurances.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Documents for Diver",
                        description: "No certifications or insurance were found for the selected diver."
                    )
                } else {
                    List {
                        // Expired alerts (shown first — most urgent)
                        if !certExpired.isEmpty {
                            Section {
                                certExpiredAlertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        if !insuranceExpired.isEmpty {
                            Section {
                                insuranceExpiredAlertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        // Expiring soon alerts
                        if !certExpiringSoon.isEmpty {
                            Section {
                                certExpiryAlertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        if !insuranceExpiringSoon.isEmpty {
                            Section {
                                insuranceExpiryAlertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        // ── CERTIFICATIONS DOMAIN ─────────────────────────────────
                        if !certifications.isEmpty && (filteredCertifications.isEmpty || !groupedCertifications.isEmpty) {
                            Section {
                                domainHeaderRow(
                                    title: "Certifications",
                                    icon: "graduationcap.fill",
                                    color: .cyan
                                )
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))

                            if filteredCertifications.isEmpty {
                                Section {
                                    inlineDomainEmptyRow(
                                        systemImage: "graduationcap",
                                        message: "No certifications for the selected diver."
                                    )
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            } else if !groupedCertifications.isEmpty {
                                ForEach(groupedCertifications, id: \.key) { agency, certs in
                                    Section(isExpanded: sectionBinding("cert:" + agency)) {
                                        ForEach(certs) { cert in
                                            certRow(cert)
                                        }
                                    } header: {
                                        Text(agency)
                                            .font(.headline)
                                            .foregroundStyle(CertificationOrganization(rawValue: agency)?.swiftUIColor ?? .gray)
                                            .textCase(nil)
                                    }
                                }
                            }
                        }

                        // ── INSURANCE DOMAIN ──────────────────────────────────────
                        if !insurances.isEmpty && (filteredInsurances.isEmpty || !groupedInsurances.isEmpty) {
                            Section {
                                domainHeaderRow(
                                    title: "Insurance",
                                    icon: "shield.fill",
                                    color: .blue
                                )
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))

                            if filteredInsurances.isEmpty {
                                Section {
                                    inlineDomainEmptyRow(
                                        systemImage: "shield",
                                        message: "No insurance for the selected diver."
                                    )
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            } else if !groupedInsurances.isEmpty {
                                ForEach(groupedInsurances, id: \.key) { insurer, policies in
                                    let displayName = insurer.isEmpty
                                        ? NSLocalizedString("Other", bundle: Bundle.forAppLanguage(), comment: "Fallback insurer group header when insurer name is blank.")
                                        : insurer
                                    Section(isExpanded: sectionBinding("ins:" + insurer)) {
                                        ForEach(policies) { insurance in
                                            insuranceRow(insurance)
                                        }
                                    } header: {
                                        Text(displayName)
                                            .font(.headline)
                                            .foregroundStyle(.blue)
                                            .textCase(nil)
                                    }
                                }
                            }
                        }
                    }
                    // .sidebar is required for Section(isExpanded:) collapse/expand to function
                    .listStyle(.sidebar)
                }
            }
            .opacity(appeared ? 1.0 : 0.0)
            .offset(y: appeared ? 0 : 15)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            }
            .navigationTitle("Documents")
            .background(Color.platformBackground.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            .refreshable {
                NSUbiquitousKeyValueStore.default.synchronize()
                try? await Task.sleep(for: .seconds(1.5))
            }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { onClose() }
                    }
                }
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showAddCertification = true } label: {
                            Label("Add Certification", systemImage: "graduationcap.fill")
                        }
                        Button { showAddInsurance = true } label: {
                            Label("Add Insurance", systemImage: "shield.fill")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Certifications") {
                            Button {
                                exportCertificationsToXML()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .disabled(certifications.isEmpty)

                            Button {
                                importTarget = .certifications
                                showImportPicker = true
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                        }

                        Section("Insurance") {
                            Button {
                                exportInsurancesToXML()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .disabled(insurances.isEmpty)

                            Button {
                                importTarget = .insurance
                                showImportPicker = true
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                    }
                }
            }
            // --- Certification Sheets ---
            .sheet(isPresented: $showAddCertification) {
                AddCertificationView(prefilledDiverName: selectedDiver)
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
            .sheet(item: $showEditCertificationFor) { cert in
                AddCertificationView(certificationToEdit: cert)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete certification?", isPresented: $showDeleteCertConfirmation) {
                Button("Cancel", role: .cancel) { certificationToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let cert = certificationToDelete {
                        NotificationManager.shared.cancelNotification(identifier: "cert-30-\(cert.id.uuidString)")
                        modelContext.delete(cert)
                        certificationToDelete = nil
                    }
                }
            } message: {
                if let cert = certificationToDelete {
                    Text(verbatim: String(format: NSLocalizedString("Are you sure you want to delete \"%@\"? This action cannot be undone.", bundle: Bundle.forAppLanguage(), comment: "Delete confirmation alert message."), cert.name))
                }
            }
            // --- Insurance Sheets ---
            .sheet(isPresented: $showAddInsurance) {
                AddInsuranceView(prefilledDiverName: selectedDiver)
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
            .sheet(item: $showEditInsuranceFor) { insurance in
                AddInsuranceView(insuranceToEdit: insurance)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete insurance?", isPresented: $showDeleteInsuranceConfirmation) {
                Button("Cancel", role: .cancel) { insuranceToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let insurance = insuranceToDelete {
                        modelContext.delete(insurance)
                        insuranceToDelete = nil
                    }
                }
            } message: {
                if let insurance = insuranceToDelete {
                    Text(verbatim: String(format: NSLocalizedString("Are you sure you want to delete \"%@\"? This action cannot be undone.", bundle: Bundle.forAppLanguage(), comment: "Delete confirmation alert message."), insurance.insurerName))
                }
            }
            // --- Import / Export ---
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.xml],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            #if os(iOS)
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDocument,
                contentType: .xml,
                defaultFilename: exportFileName
            ) { _ in
                exportDocument = nil
            }
            #endif
        }
        .alert("Import Successful", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: importSuccessMessage)
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: importError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the import error alert when no specific error is available."))
        }
        .alert("Export Error", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: exportError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the export error alert when no specific error is available."))
        }
    }

    // MARK: - Row Helpers

    @ViewBuilder
    private func certRow(_ cert: Certification) -> some View {
        Button { selectedCertification = cert } label: {
            CertificationCard(certification: cert, showExpired: cert.isExpired)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                certificationToDelete = cert
                showDeleteCertConfirmation = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button { selectedCertification = cert } label: {
                Label("View Details", systemImage: "eye")
            }
            Button { showEditCertificationFor = cert } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                certificationToDelete = cert
                showDeleteCertConfirmation = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func insuranceRow(_ insurance: DivingInsurance) -> some View {
        Button { selectedInsurance = insurance } label: {
            InsuranceCard(insurance: insurance, showExpired: insurance.isExpired)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                insuranceToDelete = insurance
                showDeleteInsuranceConfirmation = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button { selectedInsurance = insurance } label: {
                Label("View Details", systemImage: "eye")
            }
            Button { showEditInsuranceFor = insurance } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                insuranceToDelete = insurance
                showDeleteInsuranceConfirmation = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }

    // MARK: - Section Binding Helper

    private func sectionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(key) },
            set: { isExpanded in
                if isExpanded { collapsedSections.remove(key) }
                else { collapsedSections.insert(key) }
            }
        )
    }

    // MARK: - Domain Header Row

    private func domainHeaderRow(title: LocalizedStringKey, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Inline Empty Domain Row

    private func inlineDomainEmptyRow(systemImage: String, message: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .font(.body)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Expiry Alert Sections

    private var certExpiredAlertSection: some View {
        alertBannerSection(
            headerIcon: "xmark.circle.fill",
            headerText: "Expired",
            accentColor: .red,
            domainTitle: "Certifications",
            domainIcon: "graduationcap.fill",
            domainColor: .cyan,
            items: certExpired,
            name: \.name,
            rowSubtitle: { _ in NSLocalizedString("Expired", bundle: Bundle.forAppLanguage(), comment: "Row subtitle for an expired document in the alert banner.") },
            onTap: { selectedCertification = $0 }
        )
    }

    private var insuranceExpiredAlertSection: some View {
        alertBannerSection(
            headerIcon: "xmark.circle.fill",
            headerText: "Expired",
            accentColor: .red,
            domainTitle: "Insurance",
            domainIcon: "shield.fill",
            domainColor: .blue,
            items: insuranceExpired,
            name: \.insurerName,
            rowSubtitle: { _ in NSLocalizedString("Expired", bundle: Bundle.forAppLanguage(), comment: "Row subtitle for an expired document in the alert banner.") },
            onTap: { selectedInsurance = $0 }
        )
    }

    private var certExpiryAlertSection: some View {
        alertBannerSection(
            headerIcon: "exclamationmark.triangle.fill",
            headerText: "Expiring Soon",
            accentColor: .orange,
            domainTitle: "Certifications",
            domainIcon: "graduationcap.fill",
            domainColor: .cyan,
            items: certExpiringSoon,
            name: \.name,
            rowSubtitle: { cert in
                guard let days = cert.daysUntilExpiration else { return nil }
                if days == 0 { return NSLocalizedString("Expires today", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label when the document expires today.") }
                if days == 1 { return NSLocalizedString("Expires in 1 day", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label in the expiring-soon alert section (exactly one day).") }
                return String(format: NSLocalizedString("Expires in %lld days", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label in the expiring-soon alert section (multiple days)."), days)
            },
            onTap: { selectedCertification = $0 }
        )
    }

    private var insuranceExpiryAlertSection: some View {
        alertBannerSection(
            headerIcon: "exclamationmark.triangle.fill",
            headerText: "Expiring Soon",
            accentColor: .orange,
            domainTitle: "Insurance",
            domainIcon: "shield.fill",
            domainColor: .blue,
            items: insuranceExpiringSoon,
            name: \.insurerName,
            rowSubtitle: { insurance in
                guard let days = insurance.daysUntilExpiration else { return nil }
                if days == 0 { return NSLocalizedString("Expires today", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label when the document expires today.") }
                if days == 1 { return NSLocalizedString("Expires in 1 day", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label in the expiring-soon alert section (exactly one day).") }
                return String(format: NSLocalizedString("Expires in %lld days", bundle: Bundle.forAppLanguage(), comment: "Expiry countdown label in the expiring-soon alert section (multiple days)."), days)
            },
            onTap: { selectedInsurance = $0 }
        )
    }

    private func alertBannerSection<Item: Identifiable>(
        headerIcon: String,
        headerText: LocalizedStringKey,
        accentColor: Color,
        domainTitle: LocalizedStringKey,
        domainIcon: String,
        domainColor: Color,
        items: [Item],
        name: KeyPath<Item, String>,
        rowSubtitle: @escaping (Item) -> String?,
        onTap: @escaping (Item) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: headerIcon).foregroundStyle(accentColor)
                Text(headerText).font(.headline).foregroundStyle(.primary)
                Spacer()
                Label(domainTitle, systemImage: domainIcon)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(domainColor)
            }
            ForEach(items) { item in
                Button {
                    onTap(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item[keyPath: name])
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if let subtitle = rowSubtitle(item) {
                                Text(verbatim: subtitle)
                                    .font(.caption)
                                    .foregroundStyle(accentColor)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        .padding(.horizontal)
    }

    // MARK: - Both Empty State

    private var bothEmptyStateView: some View {
        VStack(spacing: 24) {
            HStack(spacing: 20) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.cyan.opacity(0.5))
                    .scaleEffect(emptyAppeared ? 1.0 : 0.5)
                    .opacity(emptyAppeared ? 1.0 : 0.0)
                Image(systemName: "shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue.opacity(0.5))
                    .scaleEffect(emptyAppeared ? 1.0 : 0.5)
                    .opacity(emptyAppeared ? 1.0 : 0.0)
            }

            Text("No Documents")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)

            Text("Add your certifications and insurance to track them here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)

            VStack(spacing: 12) {
                Button { showAddCertification = true } label: {
                    Label("Add Certification", systemImage: "graduationcap.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cyan))
                }
                .buttonStyle(.plain)
                .scaleEffect(emptyAppeared ? 1.0 : 0.8)
                .opacity(emptyAppeared ? 1.0 : 0.0)

                Button { showAddInsurance = true } label: {
                    Label("Add Insurance", systemImage: "shield.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                }
                .buttonStyle(.plain)
                .scaleEffect(emptyAppeared ? 1.0 : 0.8)
                .opacity(emptyAppeared ? 1.0 : 0.0)
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { emptyAppeared = true }
        }
    }

    // MARK: - Export

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func exportCertificationsToXML() {
        let xml = CertificationXMLExporter.generateXML(for: certifications)
        guard let data = xml.data(using: .utf8) else { return }
        let datePart = DocumentsView.exportDateFormatter.string(from: Date())
        let fileName = "BlueDive_Certifications_\(datePart).xml"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                Task { @MainActor in
                    self.exportError = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        showFileExporter = true
        #endif
    }

    private func exportInsurancesToXML() {
        let xml = InsuranceXMLExporter.generateXML(for: insurances)
        guard let data = xml.data(using: .utf8) else { return }
        let datePart = DocumentsView.exportDateFormatter.string(from: Date())
        let fileName = "BlueDive_Insurance_\(datePart).xml"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                Task { @MainActor in
                    self.exportError = error.localizedDescription
                    self.showExportError = true
                }
            }
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        showFileExporter = true
        #endif
    }

    // MARK: - Import

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if importTarget == .certifications {
                    handleCertificationsImport(data: data)
                } else {
                    handleInsuranceImport(data: data)
                }
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    private func handleCertificationsImport(data: Data) {
        let parser = CertificationXMLParser()
        guard let parsed = parser.parse(data: data), !parsed.isEmpty else {
            importError = NSLocalizedString(
                "No certifications found in the selected file.",
                bundle: Bundle.forAppLanguage(),
                comment: "Error message when the user imports an XML file that contains no certifications."
            )
            showImportError = true
            return
        }
        var count = 0
        for item in parsed {
            let isDuplicate = certifications.contains { existing in
                existing.id == item.id ||
                (!item.certificationNumber.isEmpty &&
                 existing.certificationNumber == item.certificationNumber &&
                 existing.organization == item.organization)
            }
            guard !isDuplicate else { continue }
            let cert = Certification(
                name: item.name,
                diverName: item.diverName,
                organization: item.organization,
                level: item.level,
                certificationNumber: item.certificationNumber,
                issueDate: item.issueDate,
                expirationDate: item.expirationDate,
                instructorName: item.instructorName,
                instructorNumber: item.instructorNumber,
                divingCentre: item.divingCentre,
                notes: item.notes
            )
            modelContext.insert(cert)
            if cert.expirationDate != nil {
                cert.scheduleExpirationReminder()
            }
            count += 1
        }
        importedCount = count
        importSuccessTarget = .certifications
        if count > 0 {
            showImportSuccess = true
        } else {
            importError = NSLocalizedString(
                "All records in the file are already imported.",
                bundle: Bundle.forAppLanguage(),
                comment: "Message when all records in the import file already exist in the database."
            )
            showImportError = true
        }
    }

    private func handleInsuranceImport(data: Data) {
        let parser = InsuranceXMLParser()
        guard let parsed = parser.parse(data: data), !parsed.isEmpty else {
            importError = NSLocalizedString(
                "No insurance records found in the selected file.",
                bundle: Bundle.forAppLanguage(),
                comment: "Error message when the user imports an XML file that contains no insurance records."
            )
            showImportError = true
            return
        }
        var count = 0
        for item in parsed {
            let isDuplicate = insurances.contains { existing in
                existing.id == item.id ||
                (!item.policyNumber.isEmpty &&
                 existing.insurerName == item.insurerName &&
                 existing.policyNumber == item.policyNumber) ||
                // Natural-key fallback for files exported before <id> was added to the format:
                // when both UUID and policyNumber are absent, match on insurer + diver + coverage type + date range.
                // Truncate to seconds before comparing — manually-created records have nanosecond precision
                // while XML round-tripped dates are truncated to seconds, so exact equality always fails.
                (item.policyNumber.isEmpty &&
                 existing.insurerName == item.insurerName &&
                 existing.diverName == item.diverName &&
                 existing.coverageType == item.coverageType &&
                 Int(existing.startDate.timeIntervalSince1970) == Int(item.startDate.timeIntervalSince1970) &&
                 Int(existing.endDate.timeIntervalSince1970) == Int(item.endDate.timeIntervalSince1970))
            }
            guard !isDuplicate else { continue }
            let record = DivingInsurance(
                id: item.id,
                insurerName: item.insurerName,
                diverName: item.diverName,
                policyNumber: item.policyNumber,
                coverageType: item.coverageType,
                startDate: item.startDate,
                endDate: item.endDate,
                contactPhone: item.contactPhone,
                contactEmail: item.contactEmail,
                notes: item.notes
            )
            modelContext.insert(record)
            count += 1
        }
        importedCount = count
        importSuccessTarget = .insurance
        if count > 0 {
            showImportSuccess = true
        } else {
            importError = NSLocalizedString(
                "All records in the file are already imported.",
                bundle: Bundle.forAppLanguage(),
                comment: "Message when all records in the import file already exist in the database."
            )
            showImportError = true
        }
    }
}

// MARK: - Certification Card

struct CertificationCard: View {
    let certification: Certification
    let showExpired: Bool
    @Environment(\.locale) private var locale

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var orgColor: Color { certification.organizationColor }

    private var displayName: String {
        let prefix = certification.organization + " - "
        if certification.name.hasPrefix(prefix) {
            return String(certification.name.dropFirst(prefix.count))
        }
        return certification.name
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(orgColor.opacity(0.2))
                    .frame(width: 60, height: 60)
                Text(certification.organization)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(orgColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if !certification.diverName.isEmpty {
                    Text(certification.diverName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                }

                Group {
                    if certification.level == "Other" {
                        Text("Other")
                    } else {
                        Text(certification.level)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !certification.certificationNumber.isEmpty {
                    Label(certification.certificationNumber, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Label(formattedDate(certification.issueDate), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let expiration = certification.expirationDate {
                        Divider().frame(height: 12)
                        Label(formattedDate(expiration), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(showExpired ? .red : (certification.isExpiringSoon ? .orange : .secondary))
                    }
                }
            }

            Spacer()

            Circle()
                .fill(showExpired ? Color.red : (certification.isExpiringSoon ? Color.orange : Color.green))
                .frame(width: 12, height: 12)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(orgColor.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Certification Detail View

struct CertificationDetailView: View {
    @Bindable var certification: Certification
    @Binding var selectedCertification: Certification?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private func formattedDate(_ date: Date, style: DateFormatter.Style = .medium) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    @State private var showEditCertification = false
    @State private var showDeleteConfirmation = false

    private var orgColor: Color { certification.organizationColor }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(orgColor.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Text(certification.organization)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(orgColor)
                            }

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(certification.isExpired ? Color.red : (certification.isExpiringSoon ? Color.orange : Color.green))
                                    .frame(width: 8, height: 8)
                                Group {
                                    if certification.isExpired {
                                        Text("Expired")
                                    } else if certification.isExpiringSoon {
                                        Text("Expiring Soon")
                                    } else {
                                        Text("Active")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(certification.isExpired ? .red : (certification.isExpiringSoon ? .orange : .green))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill((certification.isExpired ? Color.red : (certification.isExpiringSoon ? Color.orange : Color.green)).opacity(0.15))
                            )
                        }
                        .padding(.top, 20)

                        VStack(spacing: 16) {
                            if !certification.diverName.isEmpty {
                                DetailRow(icon: "person.fill", title: "Diver Name", value: certification.diverName)
                            }
                            DetailRow(icon: "building.2.fill", title: "Organization", value: certification.organization)
                            DetailRow(icon: "star.fill", title: "Level", value: certification.level == "Other" ? NSLocalizedString("Other", bundle: Bundle.forAppLanguage(), comment: "") : certification.level)
                            DetailRow(icon: "number", title: "Number", value: certification.certificationNumber)
                            DetailRow(icon: "calendar", title: "Issue Date", value: formattedDate(certification.issueDate, style: .long))

                            if let expiration = certification.expirationDate {
                                DetailRow(icon: "clock", title: "Expiration", value: formattedDate(expiration, style: .long))
                            }

                            if let instructor = certification.instructorName, !instructor.isEmpty {
                                DetailRow(icon: "person.fill", title: "Instructor", value: instructor)
                            }

                            if let instructorCertNum = certification.instructorNumber, !instructorCertNum.isEmpty {
                                DetailRow(icon: "number", title: "Instructor Number", value: instructorCertNum)
                            }

                            if let center = certification.divingCentre, !center.isEmpty {
                                DetailRow(icon: "building.2.fill", title: "Diving Centre", value: center)
                            }

                            if let notes = certification.notes, !notes.isEmpty {
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
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(certification.name)
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
                        showEditCertification = true
                    } label: {
                        Text("Edit").fontWeight(.semibold)
                    }
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    #endif
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif
            .sheet(isPresented: $showEditCertification) {
                AddCertificationView(certificationToEdit: certification)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete certification?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    NotificationManager.shared.cancelNotification(identifier: "cert-30-\(certification.id.uuidString)")
                    selectedCertification = nil
                    modelContext.delete(certification)
                }
            } message: {
                Text(verbatim: String(format: NSLocalizedString("Are you sure you want to delete \"%@\"? This action cannot be undone.", bundle: Bundle.forAppLanguage(), comment: "Delete confirmation alert message."), certification.name))
            }
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Add Certification View

struct AddCertificationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Certification.issueDate) private var allCertifications: [Certification]
    @Query(sort: \Dive.timestamp) private var allDives: [Dive]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query private var allInsurances: [DivingInsurance]

    var certificationToEdit: Certification?
    var prefilledDiverName: String = ""

    private var isEditing: Bool { certificationToEdit != nil }

    @State private var name: String = ""
    @State private var diverName: String = ""
    @State private var organization: String = "PADI"
    @State private var level: String = ""
    @State private var certificationNumber: String = ""
    @State private var issueDate: Date = Date()
    @State private var hasExpiration: Bool = false
    @State private var expirationDate: Date = Date()
    @State private var instructorName: String = ""
    @State private var instructorNumber: String = ""
    @State private var divingCentre: String = ""
    @State private var notes: String = ""
    @State private var nameManuallyEdited: Bool = false

    private var diverNameSuggestions: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: allCertifications, insurances: allInsurances)
    }

    private func certificationSuggestions(_ keyPath: KeyPath<Certification, String?>) -> [String] {
        let editingID = certificationToEdit?.id
        return Array(Set(
            allCertifications
                .filter { $0.id != editingID }
                .compactMap { $0[keyPath: keyPath]?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var instructorNameSuggestions: [String] { certificationSuggestions(\.instructorName) }
    private var instructorNumberSuggestions: [String] { certificationSuggestions(\.instructorNumber) }
    private var divingCentreSuggestions: [String] { certificationSuggestions(\.divingCentre) }

    private var autoGeneratedName: String {
        guard !organization.isEmpty, !level.isEmpty, level != "Other" else { return "" }
        return "\(organization) - \(level)"
    }

    private var selectedOrganization: CertificationOrganization {
        CertificationOrganization(rawValue: organization) ?? .other
    }

    private var availableLevels: [String] {
        selectedOrganization.levels
    }

    private var isValid: Bool {
        !name.isEmpty && !organization.isEmpty && !level.isEmpty && !certificationNumber.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(.cyan.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "graduationcap.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(.top, 20)

                        certificationSectionCard(title: "General Information", icon: "info.circle.fill", color: .cyan) {
                            VStack(spacing: 14) {
                                DiverAutocompleteField(
                                    label: "Diver Name",
                                    placeholder: "Diver Name (optional)",
                                    text: $diverName,
                                    suggestions: diverNameSuggestions
                                )

                                #if os(macOS)
                                certificationMenuRow("Organization", selection: organization) {
                                    ForEach(CertificationOrganization.allCases) { org in
                                        Button(org.rawValue) {
                                            Task { @MainActor in
                                                organization = org.rawValue
                                                if !org.levels.contains(level) {
                                                    level = ""
                                                }
                                                updateAutoName()
                                            }
                                        }
                                    }
                                }
                                certificationMenuRow("Level", selection: level) {
                                    ForEach(availableLevels, id: \.self) { lvl in
                                        Button {
                                            Task { @MainActor in
                                                level = lvl
                                                updateAutoName()
                                            }
                                        } label: {
                                            if lvl == "Other" {
                                                Text("Other")
                                            } else {
                                                Text(lvl)
                                            }
                                        }
                                    }
                                }
                                #else
                                Picker("Organization", selection: $organization) {
                                    ForEach(CertificationOrganization.allCases) { org in
                                        Text(org.rawValue).tag(org.rawValue)
                                    }
                                }
                                .onChange(of: organization) {
                                    if !availableLevels.contains(level) {
                                        level = ""
                                    }
                                    updateAutoName()
                                }
                                Picker("Level", selection: $level) {
                                    Text("Select a level").tag("")
                                    ForEach(availableLevels, id: \.self) { lvl in
                                        Group {
                                            if lvl == "Other" {
                                                Text("Other")
                                            } else {
                                                Text(lvl)
                                            }
                                        }.tag(lvl)
                                    }
                                }
                                .onChange(of: level) {
                                    updateAutoName()
                                }
                                #endif

                                certificationTextField("Certification Name", text: $name)
                                    .onChange(of: name) {
                                        if name.isEmpty {
                                            nameManuallyEdited = false
                                        } else if name != autoGeneratedName {
                                            nameManuallyEdited = true
                                        }
                                    }

                                certificationTextField("Certification Number", text: $certificationNumber)
                            }
                        }

                        certificationSectionCard(title: "Dates", icon: "calendar", color: .orange) {
                            VStack(spacing: 14) {
                                DatePicker("Issue Date", selection: $issueDate, displayedComponents: .date)
                                    .adaptiveDatePickerStyle()
                                    .foregroundStyle(.primary)

                                Divider().overlay(Color.primary.opacity(0.06))

                                Toggle("Has an expiration date", isOn: $hasExpiration.animation(.easeInOut(duration: 0.2)))
                                    .tint(.cyan)
                                    .foregroundStyle(.primary)

                                if hasExpiration {
                                    DatePicker("Expiration Date", selection: $expirationDate, displayedComponents: .date)
                                        .adaptiveDatePickerStyle()
                                        .foregroundStyle(.primary)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }

                        certificationSectionCard(title: "Additional information", icon: "text.quote", color: .purple) {
                            VStack(spacing: 14) {
                                DiverAutocompleteField(
                                    label: "Instructor Name",
                                    placeholder: "Instructor Name (optional)",
                                    text: $instructorName,
                                    suggestions: instructorNameSuggestions
                                )

                                DiverAutocompleteField(
                                    label: "Instructor Number",
                                    placeholder: "Instructor Number (optional)",
                                    text: $instructorNumber,
                                    suggestions: instructorNumberSuggestions
                                )

                                DiverAutocompleteField(
                                    label: "Diving Centre",
                                    placeholder: "Diving Centre (optional)",
                                    text: $divingCentre,
                                    suggestions: divingCentreSuggestions
                                )

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Notes")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $notes)
                                        .scrollContentBackground(.hidden)
                                        .frame(height: 80)
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
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
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? LocalizedStringKey("Edit Certification") : LocalizedStringKey("New Certification"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveCertification()
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
                    .tint(.cyan)
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
                if let cert = certificationToEdit {
                    name = cert.name
                    diverName = cert.diverName
                    organization = cert.organization
                    level = cert.level
                    certificationNumber = cert.certificationNumber
                    issueDate = cert.issueDate
                    hasExpiration = cert.expirationDate != nil
                    expirationDate = cert.expirationDate ?? Date()
                    instructorName = cert.instructorName ?? ""
                    instructorNumber = cert.instructorNumber ?? ""
                    divingCentre = cert.divingCentre ?? ""
                    notes = cert.notes ?? ""
                    nameManuallyEdited = true
                } else if !prefilledDiverName.isEmpty {
                    diverName = prefilledDiverName
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func certificationSectionCard<Content: View>(title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .padding(.horizontal)
    }

    private func certificationTextField(_ label: LocalizedStringKey, placeholder: LocalizedStringKey? = nil, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder ?? label, text: text)
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
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        }
    }

    #if os(macOS)
    private func certificationMenuRow<Content: View>(_ label: LocalizedStringKey, selection: String, @ViewBuilder menuItems: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Menu {
                menuItems()
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if selection.isEmpty {
                            Text("Choose…")
                        } else {
                            Text(selection)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.cyan)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
    #endif

    private func updateAutoName() {
        if !nameManuallyEdited {
            name = autoGeneratedName
        }
    }

    private func saveCertification() {
        if let cert = certificationToEdit {
            cert.name = name.trimmingCharacters(in: .whitespaces)
            cert.diverName = diverName.trimmingCharacters(in: .whitespaces)
            cert.organization = organization.trimmingCharacters(in: .whitespaces)
            cert.level = level.trimmingCharacters(in: .whitespaces)
            cert.certificationNumber = certificationNumber.trimmingCharacters(in: .whitespaces)
            cert.issueDate = issueDate
            cert.expirationDate = hasExpiration ? expirationDate : nil
            let trimmedInstructor = instructorName.trimmingCharacters(in: .whitespaces)
            cert.instructorName = trimmedInstructor.isEmpty ? nil : trimmedInstructor
            let trimmedInstructorNum = instructorNumber.trimmingCharacters(in: .whitespaces)
            cert.instructorNumber = trimmedInstructorNum.isEmpty ? nil : trimmedInstructorNum
            let trimmedDivingCenter = divingCentre.trimmingCharacters(in: .whitespaces)
            cert.divingCentre = trimmedDivingCenter.isEmpty ? nil : trimmedDivingCenter
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            cert.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            if hasExpiration {
                cert.scheduleExpirationReminder()
            } else {
                NotificationManager.shared.cancelNotification(identifier: "cert-30-\(cert.id.uuidString)")
            }
        } else {
            let trimmedInstructor = instructorName.trimmingCharacters(in: .whitespaces)
            let trimmedInstructorNum = instructorNumber.trimmingCharacters(in: .whitespaces)
            let trimmedDivingCenter = divingCentre.trimmingCharacters(in: .whitespaces)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let newCert = Certification(
                name: name.trimmingCharacters(in: .whitespaces),
                diverName: diverName.trimmingCharacters(in: .whitespaces),
                organization: organization.trimmingCharacters(in: .whitespaces),
                level: level.trimmingCharacters(in: .whitespaces),
                certificationNumber: certificationNumber.trimmingCharacters(in: .whitespaces),
                issueDate: issueDate,
                expirationDate: hasExpiration ? expirationDate : nil,
                instructorName: trimmedInstructor.isEmpty ? nil : trimmedInstructor,
                instructorNumber: trimmedInstructorNum.isEmpty ? nil : trimmedInstructorNum,
                divingCentre: trimmedDivingCenter.isEmpty ? nil : trimmedDivingCenter,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(newCert)
            if hasExpiration {
                newCert.scheduleExpirationReminder()
            }
        }
        dismiss()
    }
}

#Preview {
    DocumentsView()
        .modelContainer(for: [Certification.self, DivingInsurance.self], inMemory: true)
}
