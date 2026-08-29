import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Export Actions & Export Tab Content

extension DiveDetailView {

    var xmlExportTabContent: some View {
        XMLExportTabView(dive: dive)
    }

    var uddfExportTabContent: some View {
        UDDFExportTabView(dive: dive)
    }

    /// Sanitised file-name–safe version of the dive site.
    func makeExportFileName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: dive.timestamp)
        let sitePart = dive.siteName.isEmpty ? dive.location : dive.siteName
        let safeSite = sitePart
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "BlueDive_\(datePart)_\(safeSite).\(ext)"
    }

    func exportToXML() {
        let xmlString = BlueDiveXMLExporter.generateXML(for: dive)
        guard let data = xmlString.data(using: .utf8) else { return }
        let fileName = makeExportFileName(extension: "bluedive")

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
        exportContentType = .blueDiveXML
        showFileExporter = true
        #endif
    }

    func exportToUDDF() {
        let uddfString = BlueDiveUDDFExporter.generateUDDF(for: dive)
        guard let data = uddfString.data(using: .utf8) else { return }
        let fileName = makeExportFileName(extension: "uddf")

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
        exportContentType = .uddf
        showFileExporter = true
        #endif
    }

    func exportToPDF() {
        // store.dives is already sorted by timestamp desc (same order ContentView's @Query delivers)
        guard let data = PDFDiveLogbook.generatePDF(for: dive, allDives: store.dives) else { return }
        let fileName = makeExportFileName(extension: "pdf")

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        exportContentType = .pdf
        showFileExporter = true
        #endif
    }
}
