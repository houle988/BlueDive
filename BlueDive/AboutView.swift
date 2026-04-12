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
                        
                        Text("Website: https://www.bluedive.app")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        
                        Text("Contact: support@bluedive.app")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("A feature-rich dive log for iPadOS & iOS")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.cyan)
                    }
                    
                    // Contributors
                    VStack(spacing: 16) {
                        sectionHeader(title: "Contributors", icon: "person.3.fill", color: .cyan)
                        
                        VStack(spacing: 8) {
                            contributorRow(name: "Patrick Houle")
                            Divider().opacity(0.3)
                            contributorRow(name: "Steve Houle")
                            Divider().opacity(0.3)
                            contributorRow(name: "Jérôme Devost")
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal)
                    
                    // Acknowledgements
                    VStack(spacing: 16) {
                        sectionHeader(title: "Acknowledgements", icon: "heart.fill", color: .orange)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            acknowledgementRow(
                                name: "libdivecomputer",
                                description: "Open-source library for communicating with dive computers. Provides the low-level protocol support for downloading dive data from a wide range of hardware.",
                                url: "https://www.libdivecomputer.org"
                            )
                            
                            Divider().opacity(0.3)
                            
                            acknowledgementRow(
                                name: "LibDC-Swift",
                                description: "Swift wrapper around libdivecomputer, enabling native integration with Apple platforms for dive computer communication.",
                                url: "https://github.com/latishab/LibDC-Swift"
                            )
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
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
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }
    
    // MARK: - Components
    
    private func sectionHeader(title: LocalizedStringKey, icon: String, color: Color) -> some View {
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
    
    private func contributorRow(name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.cyan)
                .frame(width: 18)
            
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private func acknowledgementRow(name: String, description: LocalizedStringKey, url: String) -> some View {
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
                Link(destination: link) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                        Text(url)
                            .font(.caption2)
                    }
                    .foregroundStyle(.cyan)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
