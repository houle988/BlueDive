import SwiftUI

struct AppearanceSettingsView: View {
    let onNeedsRootDismiss: () -> Void

    @State private var prefs = UserPreferences.shared
    @State private var previousAppearance: AppearanceMode = UserPreferences.shared.appearanceMode
    @State private var previousLanguage: AppLanguage = UserPreferences.shared.languageMode

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Theme", selection: $prefs.appearanceMode) {
                            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    if ProcessInfo.processInfo.isiOSAppOnMac {
                        Text("Choose System to follow your device's appearance (System Settings → Appearance), or override with Light or Dark. Switching from or to System will close Settings to apply the change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        Text("Choose System to follow your device's appearance (Settings → Display & Brightness), or override with Light or Dark. Switching from or to System will close Settings to apply the change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Language", systemImage: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Language", selection: $prefs.languageMode) {
                            ForEach(AppLanguage.allCases, id: \.self) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    if ProcessInfo.processInfo.isiOSAppOnMac {
                        Text("Choose System to use your device's language (System Settings → General → Language & Region), or override with English, Français, or Deutsch. Switching from or to System will close Settings to apply the change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        Text("Choose System to use your device's language (Settings → General → Language & Region), or override with English, Français, or Deutsch. Switching from or to System will close Settings to apply the change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(Text(verbatim: NSLocalizedString("Appearance", bundle: .forAppLanguage(), value: "Appearance", comment: "")))
        .preferredColorScheme(prefs.appearanceMode.colorScheme)
        .onChange(of: prefs.appearanceMode) {
            if previousAppearance == .system || prefs.appearanceMode == .system {
                onNeedsRootDismiss()
            }
            previousAppearance = prefs.appearanceMode
        }
        .onChange(of: prefs.languageMode) {
            if previousLanguage == .system || prefs.languageMode == .system {
                onNeedsRootDismiss()
            }
            previousLanguage = prefs.languageMode
        }
    }
}
