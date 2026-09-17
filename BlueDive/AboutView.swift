import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // App Icon & Name
                    VStack(spacing: 12) {
                        Image("BlueDiveIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 26))
                            .shadow(color: .cyan.opacity(0.3), radius: 20)
                            .padding(.top, 20)
                        
                        Text("BlueDive")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 4) {
                            Text("Website:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Link(destination: URL(string: "https://www.bluedive.app")!) {
                                Text(verbatim: "https://www.bluedive.app")
                                    .font(.subheadline)
                                    .foregroundStyle(.cyan)
                            }
                        }

                        HStack(spacing: 4) {
                            Text("Contact:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Link(destination: URL(string: "mailto:support@bluedive.app")!) {
                                Text(verbatim: "support@bluedive.app")
                                    .font(.subheadline)
                                    .foregroundStyle(.cyan)
                            }
                        }

                        Text("A feature-rich dive log for iPadOS & iOS")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.cyan)
                    }
                    
                    // Documentation
                    VStack(spacing: 16) {
                        AboutSectionHeader(title: "Documentation", icon: "book.fill", color: .blue)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Guides, tips, and reference material to help you get the most out of BlueDive.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ExternalLinkView(url: wikiDocumentationURL)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sectionCardBackground()
                    }
                    .padding(.horizontal)

                    // Contributors
                    VStack(spacing: 16) {
                        AboutSectionHeader(title: "Contributors", icon: "person.3.fill", color: .cyan)
                        
                        VStack(spacing: 8) {
                            ContributorRow(name: "Patrick Houle")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Steve Houle")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Jérôme Devost")
                        }
                        .padding()
                        .sectionCardBackground()
                    }
                    .padding(.horizontal)
                    
                    // Community Contributors
                    VStack(spacing: 16) {
                        AboutSectionHeader(title: "Key Community Contributors", icon: "person.3.fill", color: .cyan)

                        VStack(spacing: 8) {
                            ContributorRow(name: "Thomas MacDermott", role: "Testing and ideas for new features")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Espen Moe", role: "Testing and ideas for new features")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Lionel Prost", role: "Testing and ideas for new features")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Mark Kuiphuis", role: "Dutch Translation, Testing and ideas for new features")
                            Divider().opacity(0.3)
                            ContributorRow(name: "Simone Ueberwasser", role: "German Translation, Testing and ideas for new features")
                        }
                        .padding()
                        .sectionCardBackground()
                    }
                    .padding(.horizontal)

                    // Acknowledgements
                    VStack(spacing: 16) {
                        AboutSectionHeader(title: "Acknowledgements", icon: "heart.fill", color: .orange)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            AcknowledgementRow(
                                name: "libdivecomputer",
                                description: "Open-source library for communicating with dive computers. Provides the low-level protocol support for downloading dive data from a wide range of hardware.",
                                url: "https://www.libdivecomputer.org"
                            )
                            
                            Divider().opacity(0.3)
                            
                            AcknowledgementRow(
                                name: "LibDC-Swift",
                                description: "Swift wrapper around libdivecomputer, enabling native integration with Apple platforms for dive computer communication.",
                                url: "https://github.com/latishab/LibDC-Swift"
                            )
                        }
                        .padding()
                        .sectionCardBackground()
                    }
                    .padding(.horizontal)
                    
                    // Copyright
                    Text(verbatim: "© \(Calendar.current.component(.year, from: Date())) BlueDive. \(NSLocalizedString("All rights reserved.", bundle: Bundle.forAppLanguage(), comment: "Copyright notice in the About view"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 30)
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.platformBackground,
                        Color.cyan.opacity(0.05),
                        Color.platformBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("About")
            #if os(macOS)
            .frame(minWidth: 420, idealWidth: 500, maxWidth: 600, minHeight: 500, idealHeight: 600, maxHeight: 800)
            #endif

            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }
    
}

// MARK: - Components

/// Used to be a plain function that inlined its HStack/ZStack/Text tree at every call
/// site; `AboutView.body` combines it with `ContributorRow`/`AcknowledgementRow` for 14
/// static calls total in one property — the same class of bug that caused two confirmed
/// `EXC_BAD_ACCESS` crashes elsewhere in this app (too many inlined view trees combined in
/// one `some View` property overflow the stack during Swift's runtime value-witness copy).
/// Packaging this as a nominal struct bounds the complexity at its own `body`.
struct AboutSectionHeader: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Spacer()
        }
    }
}

/// See `AboutSectionHeader` above for why this was converted from a plain function to a
/// nominal struct. `name` is a person's proper name, deliberately displayed verbatim
/// (`Text(name)` on a `String`), never looked up in the localization catalog.
struct ContributorRow: View {
    let name: String
    var role: LocalizedStringKey? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.cyan)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let role {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// See `AboutSectionHeader` above for why this was converted from a plain function to a
/// nominal struct.
struct AcknowledgementRow: View {
    let name: String
    let description: LocalizedStringKey
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let link = URL(string: url) {
                ExternalLinkView(url: link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct ExternalLinkView: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                Text(verbatim: url.absoluteString)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.cyan)
        }
    }
}

