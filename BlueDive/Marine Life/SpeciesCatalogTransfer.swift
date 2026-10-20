import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Species Catalogue Export / Import

/// What the Marine Life "…" menu asked for.
enum SpeciesTransferRequest: Equatable {
    case export(includeImages: Bool)
    case importFile
}

extension View {
    /// The catalogue's BlueDive XML export and import (Marine Life "…" menu), and the species
    /// files opened from outside the app (`FileImportCoordinator.pendingSpeciesXML`).
    /// `onImported` runs after species were added.
    func speciesCatalogTransfer(request: Binding<SpeciesTransferRequest?>, onImported: @escaping () -> Void) -> some View {
        modifier(SpeciesCatalogTransfer(request: request, onImported: onImported))
    }
}

private struct SpeciesCatalogTransfer: ViewModifier {
    @Binding var request: SpeciesTransferRequest?
    let onImported: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(FileImportCoordinator.self) private var importCoordinator

    @State private var showImportPicker = false
    /// A file being read and parsed: shown over the list, as in the Equipment tab.
    @State private var isImporting = false
    @State private var importProgressFileName = ""
    /// The parsed file waiting for the preview's confirmation.
    @State private var pendingSpecies: [SpeciesXMLParser.ParsedSpecies]?
    @State private var previewFileName = ""
    @State private var previewNew: [ImportPreviewItem] = []
    @State private var previewDuplicates: [ImportPreviewItem] = []
    @State private var importResult: (created: Int, linked: Int)?
    @State private var showNothingToImport = false
    @State private var importError: String?

    // iOS export
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName = ""

    func body(content: Content) -> some View {
        content
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Importing...")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if !importProgressFileName.isEmpty {
                                Text(verbatim: importProgressFileName)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(32)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isImporting)
            .onChange(of: request) { _, newValue in
                guard let newValue else { return }
                request = nil
                switch newValue {
                case .export(let includeImages): exportCatalogue(includeImages: includeImages)
                case .importFile: showImportPicker = true
                }
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
                contentType: .blueDiveXML,
                defaultFilename: exportFileName
            ) { _ in
                exportDocument = nil
            }
            #endif
            .sheet(isPresented: Binding(
                get: { pendingSpecies != nil },
                set: { if !$0 { pendingSpecies = nil } }
            )) {
                ImportPreviewSheet(
                    icon: "fish",
                    iconColor: .cyan,
                    newItems: previewNew,
                    duplicateItems: previewDuplicates,
                    fileName: previewFileName,
                    onImport: {
                        let parsed = pendingSpecies
                        pendingSpecies = nil
                        if let parsed { commitImport(parsed) }
                    },
                    onCancel: { pendingSpecies = nil }
                )
                .standardSheetPresentation()
            }
            .alert("Species Imported", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: String(format: NSLocalizedString("Species imported: %@. Sightings linked: %@.", bundle: .forAppLanguage(), value: "Species imported: %@. Sightings linked: %@.", comment: "Species catalogue import result (locale-formatted numbers)"), Double(importResult?.created ?? 0).localizedString(decimals: 0), Double(importResult?.linked ?? 0).localizedString(decimals: 0)))
            }
            .alert("Nothing to Import", isPresented: $showNothingToImport) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Every species in the file is already in the catalogue.")
            }
            .alert("Import error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: importError ?? "")
            }
            .onAppear {
                if let pending = importCoordinator.pendingSpeciesXML {
                    importCoordinator.pendingSpeciesXML = nil
                    importPending(pending)
                }
            }
            .onChange(of: importCoordinator.pendingSpeciesXML) { _, newValue in
                guard let pending = newValue else { return }
                importCoordinator.pendingSpeciesXML = nil
                importPending(pending)
            }
    }

    // MARK: - Export

    private func exportCatalogue(includeImages: Bool) {
        var descriptor = FetchDescriptor<Species>(sortBy: [SortDescriptor(\.commonName)])
        if includeImages { descriptor.relationshipKeyPathsForPrefetching = [\.image] }
        let catalogue = (try? modelContext.fetch(descriptor)) ?? []
        guard !catalogue.isEmpty else { return }
        let xml = SpeciesXMLExporter.generateXML(for: catalogue, includeImages: includeImages)
        guard let data = xml.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "BlueDive_Species_\(formatter.string(from: Date())).bluedive"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.blueDiveXML]
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

    // MARK: - Import

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importFile(named: url.lastPathComponent) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// A file opened from outside the app (Finder, Files, AirDrop, Mail), already read.
    private func importPending(_ pending: PendingXMLImport) {
        let data = pending.data
        importFile(named: pending.fileName) { data }
    }

    /// Reads (`load`) and parses the file off the main actor, then shows the preview (or why
    /// nothing is imported).
    private func importFile(named fileName: String, load: @escaping @Sendable () throws -> Data) {
        guard !isImporting, pendingSpecies == nil else { return }
        importProgressFileName = fileName
        isImporting = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { SpeciesXMLParser().parse(data: try load()) }
            }.value
            isImporting = false
            importProgressFileName = ""
            let parsed: [SpeciesXMLParser.ParsedSpecies]?
            switch outcome {
            case .success(let value):
                parsed = value
            case .failure(let error):
                importError = error.localizedDescription
                return
            }
            guard let parsed, !parsed.isEmpty else {
                importError = NSLocalizedString("No species found in the selected file.", bundle: .forAppLanguage(), value: "No species found in the selected file.", comment: "Error when an imported species catalogue file contains no species")
                return
            }
            let plan = SpeciesXMLImport.plan(parsed, in: modelContext)
            guard !plan.new.isEmpty else {
                showNothingToImport = true
                return
            }
            previewNew = plan.new.map(previewItem)
            previewDuplicates = plan.duplicates.map(previewItem)
            previewFileName = fileName
            pendingSpecies = parsed
        }
    }

    private func previewItem(_ item: SpeciesXMLParser.ParsedSpecies) -> ImportPreviewItem {
        ImportPreviewItem(
            name: item.commonName,
            detail: item.scientificName.flatMap { $0.isEmpty ? nil : $0 }
                ?? SpeciesCategory.displayName(item.category) ?? ""
        )
    }

    /// Called as the preview sheet closes. The overlay shows while thumbnails are made for the
    /// imported images.
    private func commitImport(_ parsed: [SpeciesXMLParser.ParsedSpecies]) {
        importProgressFileName = previewFileName
        isImporting = true
        Task {
            defer {
                isImporting = false
                importProgressFileName = ""
            }
            do {
                let result = try await SpeciesXMLImport.commit(parsed, in: modelContext)
                onImported()
                // Species with a scientific name but no iNaturalist link are looked up in the
                // background when lookups are on (the updater skips the others).
                INaturalistUpdater.updateInBackground(result.created, in: modelContext)
                reportAfterSheetDismissal { importResult = (result.created.count, result.linked) }
            } catch {
                let message = error.localizedDescription
                reportAfterSheetDismissal { importError = message }
            }
        }
    }

    /// Presents an alert once the preview sheet has finished closing, as the Equipment and
    /// fingerprint imports do: an alert requested while the sheet is still dismissing is not shown.
    private func reportAfterSheetDismissal(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            present()
        }
    }
}
