import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - UDDF Export Tab View

/// Displays a formatted UDDF XML representation of a single dive's data.
/// UDDF generation is handled by BlueDiveUDDFExporter.
struct UDDFExportTabView: View {

    let dive: Dive

    @State private var uddfString: String = ""
    @State private var isCopied: Bool = false
    #if os(iOS)
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName: String = ""
    #endif

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            uddfPreviewSection
        }
        .onAppear { uddfString = BlueDiveUDDFExporter.generateUDDF(for: dive) }
        #if os(iOS)
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: .uddf,
            defaultFilename: exportFileName
        ) { result in
            exportDocument = nil
        }
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.teal)
                Text("UDDF Export")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                actionButtons
            }

            Text("Universal Dive Data Format v3.2.3 — SI units (metres, Kelvin, Pascal, m³)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Copy button
            Button {
                copyToClipboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        .font(.system(size: 13))
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(isCopied ? .green : .teal)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((isCopied ? Color.green : Color.teal).opacity(0.15))
                )
            }
            .buttonStyle(.plain)

            // Save As button
            Button {
                saveAsFile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                    Text("Save As")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - UDDF Preview

    /// Maximum number of lines to render in the preview to avoid exceeding
    /// Core Graphics layer size limits on large dive profiles.
    private static let previewLineLimit = 500

    private var uddfPreviewSection: some View {
        let allLines = uddfString.components(separatedBy: "\n")
        let totalLineCount = allLines.count
        let isTruncated = totalLineCount > Self.previewLineLimit
        let previewText = isTruncated
            ? allLines.prefix(Self.previewLineLimit).joined(separator: "\n")
            : uddfString

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.teal)
                Text("UDDF Content")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(totalLineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(previewText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if isTruncated {
                        Text("\n… \(totalLineCount - Self.previewLineLimit) more lines. Use Copy or Save As for full content.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.teal.opacity(0.7))
                            .padding(.top, 4)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.teal.opacity(0.25), lineWidth: 1)
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    // MARK: - Actions

    private func copyToClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = uddfString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uddfString, forType: .string)
        #endif
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }

    private func saveAsFile() {
        guard let data = uddfString.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: dive.timestamp)
        let sitePart = dive.siteName.isEmpty ? dive.location : dive.siteName
        // Sanitise the site name for use in a filename
        let safeSite = sitePart
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileName = "BlueDive_\(datePart)_\(safeSite).uddf"

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
}
