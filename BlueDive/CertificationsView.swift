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

struct CertificationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Certification.issueDate, order: .reverse) private var certifications: [Certification]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    var onClose: (() -> Void)? = nil
    @State private var showAddCertification = false
    @State private var appeared = false
    @State private var collapsedSections: Set<String> = []
    @State private var selectedCertification: Certification?
    @State private var certificationToDelete: Certification?
    @State private var showDeleteConfirmation = false
    @State private var showEditCertificationFor: Certification?
    @State private var showImportPicker = false
    @State private var pendingImportResult: Result<[URL], Error>?
    @State private var importError: String?
    @State private var showImportError = false
    @State private var importedCount: Int = 0
    @State private var showImportSuccess = false
    #if os(iOS)
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName: String = ""
    #endif
    
    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: certifications)
    }

    private var filteredCertifications: [Certification] {
        selectedDiver.isEmpty ? certifications : certifications.filter {
            $0.diverName.trimmingCharacters(in: .whitespaces) == selectedDiver
        }
    }

    private var groupedCertifications: [(key: String, value: [Certification])] {
        let grouped = Dictionary(grouping: filteredCertifications, by: { $0.organization })
        // Sort by CertificationOrganization.allCases order so "Other" stays last
        let knownOrder = CertificationOrganization.allCases.map(\.rawValue)
        return grouped.sorted { a, b in
            let ai = knownOrder.firstIndex(of: a.key) ?? Int.max
            let bi = knownOrder.firstIndex(of: b.key) ?? Int.max
            return ai < bi
        }
    }

    private var expiringSoon: [Certification] {
        filteredCertifications.filter { $0.isExpiringSoon }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if certifications.isEmpty {
                    ScrollView {
                        emptyStateView
                    }
                } else if filteredCertifications.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Certifications for Diver",
                        description: "No certifications were found for the selected diver."
                    )
                } else {
                    List {
                        // Alert for certifications expiring soon
                        if !expiringSoon.isEmpty {
                            Section {
                                alertSection
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }

                        // Certifications grouped by agency
                        ForEach(groupedCertifications, id: \.key) { agency, certs in
                            Section(isExpanded: Binding(
                                get: { !collapsedSections.contains(agency) },
                                set: { isExpanded in
                                    if isExpanded {
                                        collapsedSections.remove(agency)
                                    } else {
                                        collapsedSections.insert(agency)
                                    }
                                }
                            )) {
                                ForEach(certs) { cert in
                                    Button {
                                        selectedCertification = cert
                                    } label: {
                                        CertificationCard(certification: cert, showExpired: cert.isExpired)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            certificationToDelete = cert
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            selectedCertification = cert
                                        } label: {
                                            Label("View Details", systemImage: "eye")
                                        }
                                        Button {
                                            showEditCertificationFor = cert
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            certificationToDelete = cert
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
                                Text(agency)
                                    .font(.headline)
                                    .foregroundStyle(CertificationOrganization(rawValue: agency)?.swiftUIColor ?? .gray)
                                    .textCase(nil)
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
                withAnimation(.easeOut(duration: 0.4)) {
                    appeared = true
                }
            }
            .navigationTitle("")
            .background(Color.platformBackground.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            .refreshable {
                try? modelContext.save()
                NSUbiquitousKeyValueStore.default.synchronize()
                try? await Task.sleep(for: .seconds(1.5))
            }

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
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Menu {
                            Button {
                                exportCertificationsToXML()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .disabled(certifications.isEmpty)

                            Button {
                                showImportPicker = true
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .foregroundStyle(.cyan)
                        }

                        Button(action: { showAddCertification = true }) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddCertification) {
                AddCertificationView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedCertification) { cert in
                CertificationDetailView(certification: cert)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete certification?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    certificationToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let cert = certificationToDelete {
                        NotificationManager.shared.cancelNotification(identifier: "cert-30-\(cert.id.uuidString)")
                        modelContext.delete(cert)
                        certificationToDelete = nil
                    }
                }
            } message: {
                if let cert = certificationToDelete {
                    Text("Are you sure you want to delete \"\(cert.name)\"? This action cannot be undone.")
                }
            }
            .sheet(item: $showEditCertificationFor) { cert in
                AddCertificationView(certificationToEdit: cert)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
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
            Text("\(importedCount) certification(s) imported successfully.")
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: importError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the import error alert when no specific error is available."))
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
            
            ForEach(expiringSoon) { cert in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cert.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        
                        if let days = cert.daysUntilExpiration {
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

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 60))
                .foregroundStyle(.cyan.opacity(0.5))
                .scaleEffect(emptyAppeared ? 1.0 : 0.5)
                .opacity(emptyAppeared ? 1.0 : 0.0)
            
            Text("No certifications")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)
            
            Text("Add your diving certifications to easily track them")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(emptyAppeared ? 1.0 : 0.0)
                .offset(y: emptyAppeared ? 0 : 10)
            
            Button(action: { showAddCertification = true }) {
                Label("Add a certification", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cyan)
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(emptyAppeared ? 1.0 : 0.8)
            .opacity(emptyAppeared ? 1.0 : 0.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                emptyAppeared = true
            }
        }
    }

    // MARK: - Import / Export

    private func exportCertificationsToXML() {
        let xml = CertificationXMLExporter.generateXML(for: certifications)
        guard let data = xml.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: Date())
        let fileName = "BlueDive_Certifications_\(datePart).xml"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        showFileExporter = true
        #endif
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let parser = CertificationXMLParser()
                guard let parsed = parser.parse(data: data), !parsed.isEmpty else {
                    importError = NSLocalizedString("No certifications found in the selected file.", bundle: Bundle.forAppLanguage(), comment: "Error message when the user imports an XML file that contains no certifications.")
                    showImportError = true
                    return
                }

                var count = 0
                for item in parsed {
                    // Skip duplicates based on certification number + organization
                    let isDuplicate = certifications.contains { existing in
                        existing.certificationNumber == item.certificationNumber
                        && existing.organization == item.organization
                        && !item.certificationNumber.isEmpty
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
                        notes: item.notes
                    )
                    modelContext.insert(cert)
                    if cert.expirationDate != nil {
                        cert.scheduleExpirationReminder()
                    }
                    count += 1
                }

                importedCount = count
                showImportSuccess = true
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
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

    var body: some View {
        HStack(spacing: 16) {
            // Badge organisation
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
                Text(certification.name)
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
                
                HStack(spacing: 8) {
                    Label(formattedDate(certification.issueDate), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let expiration = certification.expirationDate {
                        Divider()
                            .frame(height: 12)
                        
                        Label(formattedDate(expiration), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(showExpired ? .red : (certification.isExpiringSoon ? .orange : .secondary))
                    }
                }
            }
            
            Spacer()
            
            // Status indicator
            Circle()
                .fill(showExpired ? Color.red : (certification.isExpiringSoon ? Color.orange : Color.green))
                .frame(width: 12, height: 12)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(orgColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Certification Detail View

struct CertificationDetailView: View {
    @Bindable var certification: Certification
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
    @State private var showDeleteConfirmation = false
    @State private var showEditCertification = false
    
    private var orgColor: Color { certification.organizationColor }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon header
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
                            
                            // Status badge
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
                        
                        // Details
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
                        showEditCertification = true
                    } label: {
                        Text("Edit")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.cyan)
                            )
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(certification.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 560, maxWidth: 700, minHeight: 550, idealHeight: 650, maxHeight: 800)
            #endif

            .alert("Delete certification?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    NotificationManager.shared.cancelNotification(identifier: "cert-30-\(certification.id.uuidString)")
                    modelContext.delete(certification)
                    dismiss()
                }
            } message: {
                Text("Are you sure you want to delete \"\(certification.name)\"? This action cannot be undone.")
            }
            .sheet(isPresented: $showEditCertification) {
                AddCertificationView(certificationToEdit: certification)
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Certification Autocomplete Field

private struct CertificationAutocompleteField: View {
    let label: LocalizedStringKey
    var placeholder: LocalizedStringKey? = nil
    @Binding var text: String
    let suggestions: [String]

    @State private var showSuggestions = false
    @FocusState private var isFocused: Bool

    private var filtered: [String] {
        guard !text.isEmpty else { return [] }
        return suggestions.filter {
            $0.localizedCaseInsensitiveContains(text) && $0.lowercased() != text.lowercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder ?? label, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onChange(of: text) {
                        showSuggestions = isFocused && !filtered.isEmpty
                    }
                    .onChange(of: isFocused) {
                        if isFocused {
                            showSuggestions = !filtered.isEmpty
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                showSuggestions = false
                            }
                        }
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
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
            if showSuggestions && !filtered.isEmpty {
                ForEach(filtered.prefix(4), id: \.self) { suggestion in
                    Button {
                        text = suggestion
                        showSuggestions = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.leading, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Add Certification View

struct AddCertificationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Certification.issueDate) private var allCertifications: [Certification]
    @Query(sort: \Dive.timestamp) private var allDives: [Dive]
    @Query(sort: \Gear.name) private var allGear: [Gear]

    var certificationToEdit: Certification?

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
    @State private var notes: String = ""
    @State private var nameManuallyEdited: Bool = false

    private var diverNameSuggestions: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: allCertifications)
    }

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
                        // Icon header
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

                        // General Information
                        certificationSectionCard(title: "General Information", icon: "info.circle.fill", color: .cyan) {
                            VStack(spacing: 14) {
                                CertificationAutocompleteField(
                                    label: "Diver Name",
                                    placeholder: "Diver Name (optional)",
                                    text: $diverName,
                                    suggestions: diverNameSuggestions
                                )

                                #if os(macOS)
                                certificationMenuRow("Organization", selection: organization) {
                                    ForEach(CertificationOrganization.allCases) { org in
                                        Button(org.rawValue) {
                                            DispatchQueue.main.async {
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
                                            DispatchQueue.main.async {
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

                        // Dates
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

                        // Additional information
                        certificationSectionCard(title: "Additional information", icon: "text.quote", color: .purple) {
                            VStack(spacing: 14) {
                                certificationTextField("Instructor Name", placeholder: "Instructor Name (optional)", text: $instructorName)

                                certificationTextField("Instructor Number", placeholder: "Instructor Number (optional)", text: $instructorNumber)

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
                        saveCertification()
                    } label: {
                        Text(isEditing ? LocalizedStringKey("Save") : LocalizedStringKey("Add"))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isValid ? .cyan : .cyan.opacity(0.3))
                            )
                            .foregroundStyle(isValid ? .black : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValid)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? LocalizedStringKey("Edit Certification") : LocalizedStringKey("New Certification"))
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
                    notes = cert.notes ?? ""
                    nameManuallyEdited = true
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            )
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
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
        )
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
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            cert.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

            // Reschedule or cancel expiration notification
            if hasExpiration {
                cert.scheduleExpirationReminder()
            } else {
                NotificationManager.shared.cancelNotification(identifier: "cert-30-\(cert.id.uuidString)")
            }
        } else {
            let trimmedInstructor = instructorName.trimmingCharacters(in: .whitespaces)
            let trimmedInstructorNum = instructorNumber.trimmingCharacters(in: .whitespaces)
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
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(newCert)
            
            // Schedule expiration notification for new certification
            if hasExpiration {
                newCert.scheduleExpirationReminder()
            }
        }
        dismiss()
    }
}

#Preview {
    CertificationsView()
        .modelContainer(for: Certification.self, inMemory: true)
}
