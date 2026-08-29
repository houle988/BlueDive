import SwiftUI

// MARK: - Import Preview Item

struct ImportPreviewItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
}

// MARK: - Import Preview Sheet

struct ImportPreviewSheet: View {

    let icon: String
    let iconColor: Color
    let newItems: [ImportPreviewItem]
    let duplicateItems: [ImportPreviewItem]
    let fileName: String
    var onImport: () -> Void
    var onCancel: () -> Void

    @State private var activeFilter: FilterMode = .new
    @State private var showAllNew = false
    @State private var showAllDuplicates = false

    private enum FilterMode { case new, duplicates }
    private let collapsedRowLimit = 5

    private var totalCount: Int { newItems.count + duplicateItems.count }

    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    summaryCard
                    itemList
                    actionButtons
                }
                .padding(.horizontal)
                .padding(.vertical, 24)
            }
        }
        #if os(macOS)
        .frame(
            minWidth: 480, idealWidth: 560, maxWidth: 700,
            minHeight: 460, idealHeight: 580, maxHeight: 800
        )
        #endif
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: NSLocalizedString("Review Import", bundle: .forAppLanguage(), comment: "Header title for the import preview sheet"))
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(verbatim: NSLocalizedString("Review what will be imported before confirming.", bundle: .forAppLanguage(), comment: "Subtitle for the import preview sheet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                summaryStat(
                    icon: "doc.fill",
                    color: .cyan,
                    value: Double(totalCount).localizedString(decimals: 0),
                    label: NSLocalizedString("In file", bundle: .forAppLanguage(), comment: "Stat tile: total items in the imported file")
                )
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { activeFilter = .duplicates }
                } label: {
                    summaryStat(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        value: Double(duplicateItems.count).localizedString(decimals: 0),
                        label: NSLocalizedString("Duplicates", bundle: .forAppLanguage(), comment: "Stat tile: number of duplicate items detected"),
                        isSelected: activeFilter == .duplicates
                    )
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { activeFilter = .new }
                } label: {
                    summaryStat(
                        icon: "sparkles",
                        color: .green,
                        value: Double(newItems.count).localizedString(decimals: 0),
                        label: NSLocalizedString("New", bundle: .forAppLanguage(), comment: "Stat tile: number of new items that are not duplicates"),
                        isSelected: activeFilter == .new
                    )
                }
                .buttonStyle(.plain)
            }
            if !fileName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    private func summaryStat(icon: String, color: Color, value: String, label: String, isSelected: Bool = false) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(verbatim: value)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(isSelected ? 0.20 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? color.opacity(0.7) : Color.clear, lineWidth: 1.5)
                )
        )
    }

    // MARK: - Item Lists

    @ViewBuilder
    private var itemList: some View {
        if activeFilter == .new {
            newItemsList
        } else {
            duplicateItemsList
        }
    }

    private var newItemsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text(verbatim: NSLocalizedString("New — will be imported", bundle: .forAppLanguage(), comment: "Section header for the list of new items that will be imported"))
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: Double(newItems.count).localizedString(decimals: 0))
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
            }
            .padding(.horizontal, 4)

            if newItems.isEmpty {
                Text(verbatim: NSLocalizedString("No new items in this file.", bundle: .forAppLanguage(), comment: "Empty state when all items in the imported file are already in the logbook"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                let visible = showAllNew || newItems.count <= collapsedRowLimit
                    ? newItems : Array(newItems.prefix(collapsedRowLimit))
                LazyVStack(spacing: 8) {
                    ForEach(visible) { item in
                        previewRow(item: item, color: .green)
                    }
                }
                if newItems.count > collapsedRowLimit {
                    expandButton(showAll: $showAllNew, color: .green, hiddenCount: newItems.count - collapsedRowLimit)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    private var duplicateItemsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text(verbatim: NSLocalizedString("Already imported — will be skipped", bundle: .forAppLanguage(), comment: "Section header for the list of duplicate items that are already in the logbook"))
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: Double(duplicateItems.count).localizedString(decimals: 0))
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            }
            .padding(.horizontal, 4)

            if duplicateItems.isEmpty {
                Text(verbatim: NSLocalizedString("No duplicates found.", bundle: .forAppLanguage(), comment: "Empty state when no items in the imported file are duplicates"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                let visible = showAllDuplicates || duplicateItems.count <= collapsedRowLimit
                    ? duplicateItems : Array(duplicateItems.prefix(collapsedRowLimit))
                LazyVStack(spacing: 8) {
                    ForEach(visible) { item in
                        previewRow(item: item, color: .orange)
                    }
                }
                if duplicateItems.count > collapsedRowLimit {
                    expandButton(showAll: $showAllDuplicates, color: .orange, hiddenCount: duplicateItems.count - collapsedRowLimit)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    private func previewRow(item: ImportPreviewItem, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: color == .green ? "sparkles" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(verbatim: item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25), lineWidth: 1))
        )
    }

    private func expandButton(showAll: Binding<Bool>, color: Color, hiddenCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showAll.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAll.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption.bold())
                if showAll.wrappedValue {
                    Text(verbatim: NSLocalizedString("Show Less", bundle: .forAppLanguage(), comment: "Button to collapse the expanded item list"))
                } else {
                    Text(verbatim: String(
                        format: NSLocalizedString("See All (%lld more)", bundle: .forAppLanguage(), comment: "Button to expand the item list, with the count of additional hidden items"),
                        hiddenCount
                    ))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.3), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: onImport) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                    if newItems.count == 1 {
                        Text(verbatim: NSLocalizedString("Import 1 New Item", bundle: .forAppLanguage(), comment: "Button label when exactly one new item will be imported"))
                            .fontWeight(.bold)
                    } else {
                        Text(verbatim: String(
                            format: NSLocalizedString("Import %lld New Items", bundle: .forAppLanguage(), comment: "Button label showing the count of new items that will be imported"),
                            newItems.count
                        ))
                        .fontWeight(.bold)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.green))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text(verbatim: NSLocalizedString("Cancel", bundle: .forAppLanguage(), comment: "Button to cancel the import preview"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}
